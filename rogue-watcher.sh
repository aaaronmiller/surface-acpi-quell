#!/usr/bin/env bash
# rogue-detector — Snapshot-comparison process anomaly watcher
#
# Detects processes that haven't changed their resource profile across
# multiple sampling cycles — the telltale sign of a stuck/orphaned
# process (like codex writing SQLite at 6MB/s for 4.5 days unchanged).
#
# Uses a lockfile (/var/lock/rogue-detector) to prevent multiple instances.
# Only one copy of this script runs system-wide at a time.
#
# Usage:
#   rogue-detector                    # run once (for systemd timer)
#   rogue-detector --oneshot          # single check, print to stdout
#   rogue-detector --interval 30      # check every 30s
#   rogue-detector --cycles 5         # flag after 5 unchanged samples
#   rogue-detector --min-age 30       # only flag procs running >30min
#   rogue-detector --foreground       # run continuously in terminal
#   rogue-detector --dry-run          # print, no desktop notification

set -euo pipefail

# ── Singleton lock ──────────────────────────────────────────────────────────
# Only one instance allowed system-wide. Uses flock(1) on a lockfile so the
# lock is automatically released even if the process is hard-killed.
LOCKFILE="/var/lock/rogue-detector"
exec 9>"$LOCKFILE"
flock -n 9 || {
    echo "rogue-detector: another instance is already running (lock held by $LOCKFILE)" >&2
    exit 1
}

INTERVAL=30
CYCLES=5
MIN_AGE=30
DRY_RUN=false
FOREGROUND=false
ONESHOT=false
STATUS_FILE="/var/lib/surface-acpi-quell/rogue-status.json"

while [ $# -gt 0 ]; do
    case "$1" in
        --interval)   INTERVAL="${2:-30}";   shift 2 ;;
        --cycles)     CYCLES="${2:-5}";      shift 2 ;;
        --min-age)    MIN_AGE="${2:-30}";    shift 2 ;;
        --dry-run)    DRY_RUN=true;          shift ;;
        --foreground) FOREGROUND=true;       shift ;;
        --oneshot)    ONESHOT=true;          shift ;;
        --help|-h)    sed -n '4,16p' "$0" | sed 's/^# //'; exit 0 ;;
        *) echo "unknown: $1"; exit 1 ;;
    esac
done

LOG()    { logger -t "rogue-detector" "$*"; echo "rogue-detector: $*"; }
NOTIFY() {
    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] notify: $*"
    else
        notify-send -u critical "🦜 Rogue Detected" "$*" 2>/dev/null || true
        LOG "ALERT: $*"
    fi
}

# ---- is_orphaned: check if a process is truly orphaned/likely-stuck ----------
is_orphaned() {
    local pid="$1"
    local tty="$2"
    local ppid="$3"

    [ "$tty" = "?" ] || return 1
    [ "$ppid" = "1" ] && return 0

    if [ -n "$ppid" ] && [ "$ppid" != "0" ]; then
        kill -0 "$ppid" 2>/dev/null || return 0
        local pstate
        pstate=$(awk '{print $3}' "/proc/$ppid/stat" 2>/dev/null || echo "")
        [ "$pstate" = "Z" ] && return 0
    fi

    [ ! -r "/proc/$pid/exe" ] && return 0
    return 1
}

# ---- snapshot via ps (fast) ------------------------------------------------
snapshot() {
    local now_jiffies
    now_jiffies=$(awk '{print int($1+$2)}' /proc/uptime)
    ps --no-header -eo pid:1,etime:1,s:1,rss:1,pcpu:1,comm:1,tty:1,ppid:1 2>/dev/null | while IFS=' ' read -r pid etime state rss pcpu comm tty ppid; do
        [ -z "$pid" ] && continue
        local sec=0
        if [[ "$etime" == *-* ]]; then
            local d=${etime%%-*}; local t=${etime#*-}
            sec=$(( ${d} * 86400 ))
            IFS=':' read -r h m s <<< "$t"
            h=${h##0}; m=${m##0}; s=${s##0}
            : ${h:=0} ${m:=0} ${s:=0}
            sec=$(( sec + h*3600 + m*60 + s ))
        elif [[ "$etime" == *:*:* ]]; then
            IFS=':' read -r h m s <<< "$etime"
            h=${h##0}; m=${m##0}; s=${s##0}
            : ${h:=0} ${m:=0} ${s:=0}
            sec=$(( h*3600 + m*60 + s ))
        elif [[ "$etime" == *:* ]]; then
            IFS=':' read -r m s <<< "$etime"
            m=${m##0}; s=${s##0}
            : ${m:=0} ${s:=0}
            sec=$(( m*60 + s ))
        else
            sec=$(( etime ))
        fi
        [ "$sec" -lt $((MIN_AGE * 60)) ] && continue

        local disk_w=0
        [ -r "/proc/${pid}/io" ] && disk_w=$(awk '/^write_bytes/{print $2}' "/proc/${pid}/io" 2>/dev/null || echo 0)

        echo "${pid}|${sec}|${state}|${rss:-0}|${pcpu:-0}|${comm:-?}|${disk_w}|${tty:-?}|${ppid:-0}"
    done
    while IFS=' ' read -r zpid zstat zcomm zppid; do
        [ -z "$zpid" ] && continue
        echo "${zpid}|0|Z|0|0|${zcomm}|0|?|${zppid}"
    done < <(ps --no-header -eo pid:1,state:1,comm:1,ppid:1 2>/dev/null | awk '$2 == "Z" || $2 ~ /^Z/')
}

# ---- fingerprint: quantised resource profile --------------------------------
fingerprint() {
    local IFS='|'
    local pid sec state rss pcpu comm disk_w tty ppid
    read -r pid sec state rss pcpu comm disk_w tty ppid <<< "$1"
    echo "${state}|$((rss/1024))|${pcpu%.*}|$((disk_w/1073741824))"
}

# ---- main -------------------------------------------------------------------
declare -A snap_window
declare -A proc_info
CURRENT_CYCLE=0

[[ "$FOREGROUND" = false && "$ONESHOT" = false ]] && exec &> /dev/null

while true; do
    CURRENT_CYCLE=$((CURRENT_CYCLE + 1))
    raw=$(snapshot)

    while IFS='|' read -r pid sec state rss pcpu comm disk_w tty ppid; do
        [ -z "$pid" ] && continue

        proc_info["$pid"]="${comm}|${tty}|${ppid}"

        fp=$(fingerprint "$pid|$sec|$state|$rss|$pcpu|$comm|$disk_w|$tty|$ppid")

        if [ -n "${snap_window[$pid]:-}" ]; then
            IFS='|' read -r prev_cycle prev_fp prev_tty prev_ppid <<< "${snap_window[$pid]}"

            if [ "$fp" = "$prev_fp" ]; then
                new_cycle=$((prev_cycle + 1))
                snap_window["$pid"]="${new_cycle}|${fp}|${tty}|${ppid}"

                if [ "$new_cycle" -ge "$CYCLES" ] && is_orphaned "$pid" "$tty" "$ppid"; then
                    age_min=$(( sec / 60 ))
                    disk_w_mb=$(( disk_w / 1048576 ))
                    [[ "$disk_w_mb" -eq 0 ]] && disk_w_mb=""
                    ppid_comm=$(cat /proc/$ppid/comm 2>/dev/null || echo "?")

                    msg="PID ${pid} (${comm}) — no TTY, PPID=${ppid} (${ppid_comm}), unchanged ${new_cycle} cycles, running ${age_min}m${disk_w_mb:+, ${disk_w_mb}MB written} — likely stuck/orphaned"
                    if [ "$state" = "Z" ]; then
                        msg="ZOMBIE PID ${pid} (${comm}) — parent PPID=${ppid} (${ppid_comm}), not reaped — zombie/stuck process"
                    fi
                    NOTIFY "$msg"
                    snap_window["$pid"]="0|${fp}|${tty}|${ppid}"
                fi
            else
                snap_window["$pid"]="0|${fp}|${tty}|${ppid}"
            fi
        else
            snap_window["$pid"]="0|${fp}|${tty}|${ppid}"
        fi
    done <<< "$raw"

    for pid in "${!snap_window[@]}"; do
        kill -0 "$pid" 2>/dev/null || unset snap_window["$pid"]
    done
    for pid in "${!proc_info[@]}"; do
        kill -0 "$pid" 2>/dev/null || unset proc_info["$pid"]
    done

    _alert_count=$(journalctl -u rogue-detector.service --since "5 minutes ago" --no-pager 2>/dev/null | grep -c "ALERT" || true)
    printf '{"cycle":%d,"tracked":%d,"timestamp":%d,"alerts_5m":%s}\n' \
      "$CURRENT_CYCLE" \
      "${#snap_window[@]}" \
      "$(date +%s)" \
      "$_alert_count" > "$STATUS_FILE"

    [[ "$ONESHOT" = true ]] && exit 0
    [[ "$FOREGROUND" = true ]] && echo "[cycle ${CURRENT_CYCLE}] $(date +%H:%M:%S) — tracking ${#snap_window[@]} procs"
    sleep "$INTERVAL"
done
