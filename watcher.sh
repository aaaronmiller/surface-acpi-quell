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
    c1=$(awk '/acpi/ {s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}' /proc/interrupts 2>/dev/null || echo 0)
    sleep 1
    c2=$(awk '/acpi/ {s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}' /proc/interrupts 2>/dev/null || echo 0)

    if [ -z "$c1" ] || [ -z "$c2" ] || [ "$c1" = "0" ]; then
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
    [ "$count" -gt "$ACPI_ERR_THRESHOLD" ] && return 1 || return 0
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

# ── Main ───────────────────────────────────────────────────────────────────

problems=0

for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=true ;;
        --fix|-f)     FIX_MODE=true ;;
        --status|-s)  print_status; exit 0 ;;
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

# 3. GPE refresh (idempotent)
check_gpes || true

# 4. Journal check
if check_module && check_irq9; then
    if ! check_acpi_errors; then
        notify "ACPI errors still in journal despite stable IRQ 9 — investigate"
        problems=$((problems + 1))
    fi
fi

# 5. Force fix mode
if $FIX_MODE && [ "$problems" -eq 0 ]; then
    log "Force fix requested — reloading module"
    rmmod "$MODULE_NAME" 2>/dev/null || true
    sleep 1
    modprobe "$MODULE_NAME" 2>/dev/null || repair_module
fi

exit "$problems"
