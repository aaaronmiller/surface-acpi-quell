#!/bin/bash
# Surface ACPI Quell — Watcher daemon
# Checks every 60s (via systemd timer) that the fix is intact,
# auto-repairs if broken, and notifies the user.
#
# Usage:
#   watcher.sh              # normal check (exit 0 = ok, >0 = problems)
#   watcher.sh --fix        # attempt repair even if check passes
#   watcher.sh --verbose    # print status to stdout
#
set -euo pipefail

SCRIPTPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# ── Config ─────────────────────────────────────────────────────────────────

# Source config file if it exists (safe key=value parser — no bash execution)
# Lines must match ^[A-Z_]+=value. Comments (#) and blank lines are ignored.
CONFIG_FILE="/etc/surface-acpi-quell/config.conf"
if [ -f "$CONFIG_FILE" ]; then
    # Verify ownership: must be root:root or owned by effective user
    cfg_owner=$(stat -c "%U:%G" "$CONFIG_FILE" 2>/dev/null || echo "unknown")
    case "$cfg_owner" in
        root:root|root:*) ;;
        *) echo "surface-acpi-watcher: WARNING config $CONFIG_FILE owned by $cfg_owner, skipping" >&2
           cfg_skip=1 ;;
    esac
    if [ -z "${cfg_skip:-}" ]; then
        while IFS='=' read -r cfg_key cfg_val; do
            case "$cfg_key" in
                GPE_LIST|IRQ_THRESHOLD|ACPI_ERR_THRESHOLD|IRQ_NUMBER|MODULE_CHECK_INTERVAL_MS|WATCHER_INTERVAL|HISTORY_MAX_ENTRIES|GPE_AUTO_DETECT_RATE|REQUIRE_SURFACE_HARDWARE|ENABLE_NOTIFICATIONS|ENABLE_WALL)
                    eval "export $cfg_key=\$cfg_val"
                    ;;
                MONITOR_PATHS)
                    export MONITOR_PATHS="$cfg_val"
                    ;;
                *) ;;
            esac
        done < <(grep -v '^[[:space:]]*#' "$CONFIG_FILE" 2>/dev/null | grep -v '^[[:space:]]*$' | grep '^[A-Z_][A-Z_]*=')
    fi
    unset cfg_skip cfg_owner cfg_key cfg_val
fi

# ── Defaults ─────────────────────────────────────────────────────────────────
# Override these by setting env vars: SURFACE_ACPI_MODULE=...
MODULE_NAME="${SURFACE_ACPI_MODULE:-surface_fixed_event_quell}"
LOG_TAG="surface-acpi-quell"
GPE_LIST=(68 69 6A 6B 6C 6D 6E 6F)
IRQ_THRESHOLD=500              # max IRQ9 delta/sec before alert
ACPI_ERR_THRESHOLD=100         # max ACPI Error messages/min before alert

# ── Helpers ────────────────────────────────────────────────────────────────

VERBOSE=false
FIX_MODE=false

log()    { logger -t "$LOG_TAG" "$1"; $VERBOSE && echo "$1"; }

notify() {
    local msg="$1"
    log "🔥 $msg"
    wall -n "🔥 Surface ACPI: $msg" 2>/dev/null || true
    if [ -n "${DISPLAY:-}" ] && command -v notify-send &>/dev/null; then
        notify-send -u critical "🔥 Surface ACPI Quell" "$msg" 2>/dev/null || true
    fi
}

all_clear() {
    local msg="$1"
    logger -t "$LOG_TAG" "✅ $msg"
    if [ -n "${DISPLAY:-}" ] && command -v notify-send &>/dev/null; then
        notify-send -u normal "✅ Surface ACPI Quell" "$msg" 2>/dev/null || true
    fi
}

# ── Checks ─────────────────────────────────────────────────────────────────

check_module() {
    [ "$(lsmod | grep -c "$MODULE_NAME" || true)" -gt 0 ]
}

check_irq9() {
    local c1 c2 delta
    # Emit EMPTY (not 0) on read failure so a genuine read error is
    # distinguishable from a healthy zero count. A zero IRQ-9 count is the
    # GOOD state (storm fully quelled) and must NOT be treated as a failure —
    # the old `[ "$c1" = "0" ]` guard misread it as "cannot read", which made
    # main() call repair_irq9() and rmmod/modprobe the ACPI module every 60s
    # (spurious fixed-ACPI events → session logout).
    c1=$(awk '/acpi/ {s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}' /proc/interrupts 2>/dev/null || echo "")
    sleep 1
    c2=$(awk '/acpi/ {s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}' /proc/interrupts 2>/dev/null || echo "")

    if [ -z "$c1" ] || [ -z "$c2" ]; then
        notify "Cannot read ACPI IRQ count — /proc/interrupts issue?"
        return 1
    fi

    delta=$(( c2 - c1 ))
    if [ "$delta" -gt "$IRQ_THRESHOLD" ]; then
        log "IRQ 9 rising: +${delta}/sec (threshold ${IRQ_THRESHOLD})"
        return 1
    fi
    return 0
}

check_gpes() {
    local fail=0
    for gpe in "${GPE_LIST[@]}"; do
        if ! echo "disable" > "/sys/firmware/acpi/interrupts/gpe${gpe}" 2>/dev/null; then
            fail=$((fail + 1))
        fi
    done
    return "$fail"
}

check_acpi_errors() {
    local count
    count=$(timeout 2 journalctl -k --since "30 seconds ago" --no-pager 2>/dev/null | grep -c "ACPI Error" || true)
    [ "$count" -gt "${ACPI_ERR_THRESHOLD:-100}" ] && return 1 || return 0
}

# Auto-detect GPEs with high interrupt counts
auto_detect_gpes() {
    local gpe_dir="/sys/firmware/acpi/interrupts"
    local rate_threshold="${GPE_AUTO_DETECT_RATE:-100}"
    local found=0
    
    [ -d "$gpe_dir" ] || return 0
    
    # Sample once
    local tmp_file samples1 samples2
    tmp_file=$(mktemp)
    
    for f in "$gpe_dir"/gpe[0-9a-fA-F]*; do
        local name count
        name=$(basename "$f")
        count=$(cat "$f" 2>/dev/null | awk '{print $1}')
        [[ "$count" =~ ^[0-9]+$ ]] && echo "$name $count" >> "$tmp_file"
    done
    
    sleep 1
    
    while read -r name c1; do
        local c2 rate
        c2=$(cat "$gpe_dir/$name" 2>/dev/null | awk '{print $1}')
        [[ "$c2" =~ ^[0-9]+$ ]] || continue
        rate=$(( c2 - c1 ))
        if [ "$rate" -gt "$rate_threshold" ]; then
            local gpe_num
            gpe_num="${name#gpe}"
            if ! echo "disable" > "$gpe_dir/$name" 2>/dev/null; then
                log "Auto-detect: GPE $gpe_num rate ${rate}/sec (disable failed)"
            else
                log "Auto-detect: disabled GPE $gpe_num (rate ${rate}/sec)"
                found=$((found + 1))
            fi
        fi
    done < "$tmp_file"
    
    rm -f "$tmp_file"
    return "$found"
}

# Graceful degradation monitoring
check_monitor_paths() {
    local config="${MONITOR_PATHS:-}"
    [ -z "$config" ] && return 0
    
    local problems=0
    IFS=$'
'
    for entry in $config; do
        local label path max_age current now
        label=$(echo "$entry" | cut -d: -f1)
        path=$(echo "$entry" | cut -d: -f2)
        max_age=$(echo "$entry" | cut -d: -f3)
        
        if [ -f "$path" ]; then
            current=$(cat "$path" 2>/dev/null || echo "")
            if [ -z "$current" ]; then
                problems=$((problems + 1))
            fi
        fi
    done
    return "$problems"
}

# ── Repairs ────────────────────────────────────────────────────────────────

repair_module() {
    log "Loading $MODULE_NAME module…"
    local src="${MODULE_SRC:-}"
    local dst="/lib/modules/$(uname -r)/extra/${MODULE_NAME}.ko"

    # Try modprobe first (module installed in kernel tree)
    modprobe "$MODULE_NAME" 2>/dev/null && return 0

    # Try known locations for the .ko file
    local search_paths=(
        "$src"
        "/usr/local/lib/surface-acpi-quell/${MODULE_NAME}.ko"
        "/usr/local/lib/surface-acpi-quell/surface_fixed_event_quell.ko"
        "/usr/local/src/surface-acpi-quell/surface_fixed_event_quell.ko"
        "$HOME/code/surface-fixed-event-quell/surface_fixed_event_quell.ko"
        "${SCRIPTPATH:-.}/../surface_fixed_event_quell.ko"
    )

    for p in "${search_paths[@]}"; do
        [ -n "$p" ] || continue
        if [ -f "$p" ]; then
            log "Found module at $p"
            mkdir -p "$(dirname "$dst")"
            cp "$p" "$dst"
            depmod -a
            modprobe "$MODULE_NAME" 2>/dev/null && return 0
        fi
    done

    # Last resort: try to rebuild from known source trees
    local build_dirs=(
        "/usr/local/src/surface-acpi-quell"
        "${SCRIPTPATH:-.}/.."
        "$HOME/code/surface-fixed-event-quell"
    )
    for bd in "${build_dirs[@]}"; do
        if [ -f "$bd/Makefile" ] && [ -f "$bd/surface_fixed_event_quell.c" ]; then
            log "Rebuilding module from $bd…"
            cd "$bd"
            make clean && make && make install && depmod -a
            modprobe "$MODULE_NAME" 2>/dev/null && return 0
        fi
    done

    return 1
}

repair_irq9() {
    if check_module; then
        log "IRQ 9 still rising — reloading module to re-mask"
        rmmod "$MODULE_NAME" 2>/dev/null || true
        sleep 1
        modprobe "$MODULE_NAME" 2>/dev/null && return 0
    fi
    return 1
}

# ── Status ─────────────────────────────────────────────────────────────────

print_status() {
    local m="✗" i="✗" g="✗" e="✗"
    check_module() { [ "$(lsmod | grep -c "$MODULE_NAME" || true)" -gt 0 ]; } && m="✓" || m="✗"
    local i_str
    i_str=$(awk '/acpi/ {s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}' /proc/interrupts 2>/dev/null || echo "?")
    local c1 c2
    c1=$(awk '/acpi/ {s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}' /proc/interrupts 2>/dev/null || echo 0)
    sleep 1
    c2=$(awk '/acpi/ {s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}' /proc/interrupts 2>/dev/null || echo 0)
    local delta=$(( c2 - c1 ))
    [ "$delta" -le "$IRQ_THRESHOLD" ] && i="✓" || i="🚨 +${delta}/s"

    local errs
    errs=$(timeout 2 journalctl -k --since "30 seconds ago" --no-pager 2>/dev/null | grep -c "ACPI Error" || true)
    [ "$errs" -le "$ACPI_ERR_THRESHOLD" ] && e="✓ ($errs/min)" || e="🚨 $errs/min"

    echo "Surface ACPI Quell Status:"
    echo "  Module:  $m"
    echo "  IRQ 9:   $i (count: $i_str)"
    echo "  GPEs:    $g"
    echo "  Errors:  $e"
}


# ── Short Status (parseable one-liner) ─────────────────────────────────────

do_short_status() {
    local data_dir="/var/lib/surface-acpi-quell"
    local state_file="$data_dir/state.json"
    local mod irq err upt
    mod="?"
    irq="?"
    err="?"
    upt="?"
    if [ -f "$state_file" ]; then
        mod=$(grep -o '"module_loaded": *[01]' "$state_file" | grep -o '[01]$')
        irq=$(grep -o '"irq9_count": *[0-9\-]*' "$state_file" | grep -o '[0-9\-]*$')
        err=$(grep -o '"acpi_errors_1m": *[0-9\-]*' "$state_file" | grep -o '[0-9\-]*$')
        upt=$(grep -o '"uptime_seconds": *[0-9]*' "$state_file" | grep -o '[0-9]*$')
    fi
    # Fallback uptime
    [ "$upt" = "0" ] || [ -z "$upt" ] && upt=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    # Format uptime
    if [ "$upt" -gt 86400 ]; then
        upt_str="$((upt / 86400))d"
    elif [ "$upt" -gt 3600 ]; then
        upt_str="$((upt / 3600))h"
    else
        upt_str="${upt}s"
    fi
    local status="OK"
    [ "$mod" != "1" ] && status="FAIL" && irq="ERR"
    echo "${status}|IRQ9=${irq}|MOD=${mod}|ERR=${err}|UPTIME=${upt_str}"
}

# ── Report ───────────────────────────────────────────────────────────────────

do_report() {
    local data_dir="/var/lib/surface-acpi-quell"
    local state_file="$data_dir/state.json"
    local hist_file="$data_dir/history.log"

    echo "=========================================="
    echo "  Surface ACPI Quell — Status Report"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================="
    echo ""

    # Current state
    if [ -f "$state_file" ]; then
        local ts irq mod acpi kern upt
        ts=$(grep -o '"timestamp": [0-9]*' "$state_file" | cut -d' ' -f2)
        irq=$(grep -o '"irq9_count": [0-9\-]*' "$state_file" | cut -d' ' -f2)
        mod=$(grep -o '"module_loaded": [01]' "$state_file" | cut -d' ' -f2)
        acpi=$(grep -o '"acpi_errors_1m": [0-9\-]*' "$state_file" | cut -d' ' -f2)
        kern=$(grep -o '"kernel": "[^"]*"' "$state_file" | cut -d'"' -f4)
        upt=$(grep -o '"uptime_seconds": [0-9]*' "$state_file" | cut -d' ' -f2)

        local uptime_str
        if [ "$upt" -gt 86400 ]; then
            uptime_str="$((upt / 86400))d $(((upt % 86400) / 3600))h"
        elif [ "$upt" -gt 3600 ]; then
            uptime_str="$((upt / 3600))h $(((upt % 3600) / 60))m"
        else
            uptime_str="${upt}s"
        fi

        echo "  Kernel:       $kern"
        echo "  Uptime:       $uptime_str"
        echo "  Module:       $([ "$mod" = "1" ] && echo 'loaded ✅' || echo 'NOT LOADED ❌')"
        echo "  IRQ 9 count:  $irq"
        echo "  ACPI errs/m:  ${acpi:-N/A}"
        echo "  Last check:   $(date -d "@$ts" '+%H:%M:%S' 2>/dev/null || echo 'N/A')"
    else
        echo "  No state data yet (watcher hasn't run)"
    fi
    echo ""

    # Trend analysis (last 30 readings)
    if [ -f "$hist_file" ] && [ "$(wc -l < "$hist_file")" -gt 30 ]; then
        local recent trend_irq first_irq last_irq irq_slope
        recent=$(tail -30 "$hist_file")
        first_irq=$(echo "$recent" | head -1 | cut -d',' -f2)
        last_irq=$(echo "$recent" | tail -1 | cut -d',' -f2)
        irq_slope=$(( (last_irq - first_irq) / 30 ))

        echo "  Trend (last 30 checks, ~30min):"
        if [ "$irq_slope" -le 1 ]; then
            echo "    IRQ 9:    stable (Δ${irq_slope}/check) ✅"
        elif [ "$irq_slope" -le 10 ]; then
            echo "    IRQ 9:    slowly rising (Δ${irq_slope}/check) ⚠️"
        else
            echo "    IRQ 9:    RISING (Δ${irq_slope}/check) 🚨"
        fi

        local err_entries problem_entries
        err_entries=$(echo "$recent" | awk -F',' '{s+=$5} END {print s}')
        problem_entries=$(echo "$recent" | awk -F',' '$3 > 0' | wc -l)
        echo "    Problems: ${problem_entries}/30 runs had issues"
        echo "    ACPI errs: ${err_entries} total in last 30 checks"
        echo ""
    fi

    # History summary
    if [ -f "$hist_file" ] && [ -s "$hist_file" ]; then
        local total_entries
        total_entries=$(wc -l < "$hist_file")
        local error_entries
        error_entries=$(awk -F',' '$3 > 0' "$hist_file" | wc -l)
        local first_ts last_ts
        first_ts=$(tail -n +2 "$hist_file" | head -1 | cut -d',' -f1)
        last_ts=$(tail -1 "$hist_file" | cut -d',' -f1)
        local duration=${duration:-0}
        if [ -n "$last_ts" ] && [ -n "$first_ts" ] && [ "$last_ts" -gt "$first_ts" ] 2>/dev/null; then
            duration=$(( last_ts - first_ts ))
        fi

        echo "  History:      ${total_entries} entries over ${duration}s"
        echo "  Issues:       ${error_entries} runs had problems"
        echo "  Health:       $([ "$error_entries" -eq 0 ] && echo '100% ✅' || echo "~$(( (total_entries - error_entries) * 100 / total_entries ))%")"
        echo ""

        # Last 10 readings
        echo "  Last 10 checks (IRQ9, Problems, Module, ACPI errs):"
        echo "  ───────────────────────────────────────────────"
        tail -n +2 "$hist_file" | tail -10 | awk -F',' '{
            printf "  %s  IRQ=%-8s  %s  Mod=%s  Errs=%s\n",
                strftime("%H:%M:%S", $1),
                $2,
                ($3 > 0 ? "❗" : "✓"),
                ($4 == 1 ? "✓" : "✗"),
                ($5 > 0 ? "❗" : "✓")
        }' 2>/dev/null
    else
        echo "  No history data yet."
    fi
    echo ""
    echo "=========================================="
}


# ── Health Check (exit 0 = OK, exit 1 = problem) ─────────────────────

do_health() {
    local issues=0
    if [ "$(lsmod | grep -c surface_fixed_event_quell || true)" -eq 0 ]; then
        echo "FAIL: module not loaded" >&2
        issues=$((issues + 1))
    fi
    local c1 c2
    c1=$(awk '''/acpi/ {s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}''' /proc/interrupts 2>/dev/null || echo 0)
    sleep 1
    c2=$(awk '''/acpi/ {s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}''' /proc/interrupts 2>/dev/null || echo 0)
    local delta=$(( c2 - c1 ))
    if [ "$delta" -gt 500 ] 2>/dev/null; then
        echo "FAIL: IRQ 9 rising (+${delta}/sec)" >&2
        issues=$((issues + 1))
    fi
    local errs
    errs=$(timeout 2 journalctl -k --since "30 seconds ago" --no-pager 2>/dev/null | grep -c "ACPI Error" || true)
    if [ "$errs" -gt 100 ]; then
        echo "FAIL: ${errs} ACPI errors/min" >&2
        issues=$((issues + 1))
    fi
    if [ ! -f /etc/systemd/journald.conf.d/99-acpi-rate-limit.conf ]; then
        echo "WARN: journal rate limit not configured" >&2
    fi
    if ! systemctl is-active surface-acpi-watcher.timer >/dev/null 2>&1; then
        echo "FAIL: watcher timer not active" >&2
        issues=$((issues + 1))
    fi
    if [ "$issues" -gt 0 ]; then
        exit 1
    fi
    echo "OK"
    exit 0
}

# ── Main ───────────────────────────────────────────────────────────────────

problems=0

for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=true ;;
        --fix|-f)     FIX_MODE=true ;;
        --status|-s)  print_status; exit 0 ;;
        --short-status)  do_short_status; exit 0 ;;
        --health)  do_health; exit 0 ;;
        --report|-r)  do_report; exit 0 ;;
        --help|-h)
            echo "Usage: $0 [--verbose|--fix|--status|--help]"
            echo "  --verbose   Print status to stdout"
            echo "  --fix       Force repair even if checks pass"
            echo "  --status    Print summary and exit"
            exit 0 ;;
    esac
done

# 1. Module check
if ! check_module; then
    notify "$MODULE_NAME module NOT LOADED — ACPI storm may return"
    problems=$((problems + 1))
    if repair_module; then
        all_clear "$MODULE_NAME module re-loaded"
        problems=$((problems - 1))
    else
        notify "FAILED to load $MODULE_NAME — needs manual rebuild"
    fi
fi

# 2. IRQ 9 check
if check_module && ! check_irq9; then
    notify "IRQ 9 rising despite module — re-masking"
    problems=$((problems + 1))
    if repair_irq9; then
        all_clear "IRQ 9 re-masked"
        problems=$((problems - 1))
    else
        notify "FAILED to re-mask IRQ 9 — manual intervention needed"
    fi
fi

# 3. GPE refresh (idempotent) + auto-detect
check_gpes || true

auto_detect_gpes || true

# 4. Journal check
if check_module && check_irq9; then
    if ! check_acpi_errors; then
        notify "ACPI errors still in journal despite stable IRQ 9 — investigate"
        problems=$((problems + 1))
    fi
fi

# 5. Check tray indicator (restart if dead)
if ! pgrep -f surface-acpi-indicator.py >/dev/null 2>&1; then
    log "Tray indicator not running — restarting"
    if command -v setsid >/dev/null 2>&1; then
        setsid surface-acpi-indicator >/dev/null 2>&1 &
    else
        surface-acpi-indicator >/dev/null 2>&1 &
    fi
    sleep 2
    if pgrep -f surface-acpi-indicator.py >/dev/null 2>&1; then
        all_clear "Tray indicator restarted"
    else
        notify "Failed to start tray indicator"
        problems=$((problems + 1))
    fi
fi

# 6. Check graceful degradation
check_monitor_paths || true

# 7. Force fix mode
if $FIX_MODE && [ "$problems" -eq 0 ]; then
    log "Force fix requested — reloading module"
    rmmod "$MODULE_NAME" 2>/dev/null || true
    sleep 1
    modprobe "$MODULE_NAME" 2>/dev/null || repair_module
fi

# ── Data logging ──────────────────────────────────────────────────────────

DATA_DIR="/var/lib/surface-acpi-quell"
DATA_FILE="$DATA_DIR/history.log"
STATE_FILE="$DATA_DIR/state.json"

if [ -d "$DATA_DIR" ]; then
    # Collect current readings
    IRQ_NOW=$(awk '/acpi/ {s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}' /proc/interrupts 2>/dev/null || echo -1)
    MOD_OK=$([ "$problems" -eq 0 ] && echo "1" || echo "0")
    ACPI_NOW=$(timeout 2 journalctl -k --since "30 seconds ago" --no-pager 2>/dev/null | grep -c "ACPI Error" || true)
    
    # Append CSV: timestamp,irq9_count,problems,module_ok,acpi_errors
    echo "$(date +%s),${IRQ_NOW},${problems},${MOD_OK},${ACPI_NOW}" >> "$DATA_FILE"
    
    # Keep last 2000 lines (ring buffer)
    tail -n 2000 "$DATA_FILE" > "${DATA_FILE}.tmp" && mv "${DATA_FILE}.tmp" "$DATA_FILE"
    
    # Update JSON state file (atomic write: temp then rename)
    STATE_TMP="${STATE_FILE}.tmp"
    cat > "$STATE_TMP" << JSONEOF
{
  "timestamp": $(date +%s),
  "irq9_count": ${IRQ_NOW},
  "irq9_rate": ${IRQ9_RATE:-0},
  "problems": ${problems},
  "module_loaded": ${MOD_OK},
  "acpi_errors_1m": ${ACPI_NOW},
  "kernel": "$(uname -r)",
  "uptime_seconds": $(awk '{print int(\$1)}' /proc/uptime 2>/dev/null || echo 0)
}
JSONEOF
    mv -f "$STATE_TMP" "$STATE_FILE" 2>/dev/null || true
fi

exit "$problems"


# Find the case block and add --health
# We'll do this with sed after writing
