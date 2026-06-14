#!/bin/bash
# surface-acpi-verify — boot-time check that all fix layers are active

set -euo pipefail
LOG_TAG="surface-acpi-verify"

log() { logger -t "$LOG_TAG" "$1"; echo "$1"; }
warn() { logger -t "$LOG_TAG" "⚠️ $1"; echo "⚠️ $1"; }
fail() { logger -t "$LOG_TAG" "🚨 $1"; echo "🚨 $1"; }

errors=0

# 1. GPE mask in cmdline
if grep -c "acpi_mask_gpe=0-3,7-22,104-111" /proc/cmdline >/dev/null 2>&1; then
    log "✅ GPE mask present in kernel cmdline"
else
    warn "GPE mask NOT in kernel cmdline — /etc/kernel/cmdline may need updating"
    errors=$((errors + 1))
fi

# 2. Module loaded (use grep -c to avoid pipefail SIGPIPE)
if [ "$(lsmod | grep -c surface_fixed_event_quell || true)" -gt 0 ]; then
    log "✅ Kernel module loaded"
else
    warn "surface_fixed_event_quell NOT loaded — modprobe may have failed"
    errors=$((errors + 1))
fi

# 3. IRQ 9 stable
C1=$(awk '/acpi/ {s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}' /proc/interrupts 2>/dev/null || echo 0)
sleep 1
C2=$(awk '/acpi/ {s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}' /proc/interrupts 2>/dev/null || echo 0)
DELTA=$((C2 - C1))
if [ "$DELTA" -le 500 ] 2>/dev/null; then
    log "✅ IRQ 9 stable (+${DELTA}/sec)"
else
    warn "IRQ 9 rising: +${DELTA}/sec — ACPI storm may be active"
    errors=$((errors + 1))
fi

# 4. Journal config
[ -f /etc/systemd/journald.conf.d/99-acpi-rate-limit.conf ] \
    && log "✅ Journal rate limit configured" \
    || warn "Journal rate limit config missing"

# 5. Watcher timer
TIMER_STATE=$(systemctl is-enabled surface-acpi-watcher.timer 2>/dev/null || echo "missing")
if [ "$TIMER_STATE" = "enabled" ]; then
    log "✅ Watcher timer enabled"
else
    warn "Watcher timer NOT enabled — run: systemctl enable surface-acpi-watcher.timer"
    errors=$((errors + 1))
fi

# 6. Module autoload
[ -f /etc/modules-load.d/surface_fixed_event_quell.conf ] \
    && log "✅ Module autoload configured" \
    || warn "Module autoload config missing"

# 7. Indicator process
INDICATOR_PID=$(pgrep -f "surface-acpi-indicator.py" 2>/dev/null || echo "")
if [ -n "$INDICATOR_PID" ]; then
    log "✅ Tray indicator running (PID $INDICATOR_PID)"
else
    warn "Tray indicator NOT running — check ~/.config/autostart/surface-acpi-indicator.desktop"
fi

if [ "$errors" -gt 0 ]; then
    fail "$errors issue(s) found — run surface-acpi-watcher --fix"
    exit "$errors"
fi

log "✅ All fix layers verified"
exit 0
