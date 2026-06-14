#!/bin/bash
# Surface ACPI Quell — one-command installer
# Run: sudo ./install.sh
set -euo pipefail

cd "$(dirname "$0")"

echo "🔧 Surface ACPI Quell Installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run with sudo"
    exit 1
fi

# 1. Build kernel module
echo "▸ Building kernel module…"
make clean 2>/dev/null || true
make -j$(nproc)

# 2. Install everything
echo "▸ Installing…"
make install

# 3. Add kernel parameter (if not already present)
CMDLINE_FILE="/etc/kernel/cmdline"
GPE_PARAM="acpi_mask_gpe=0-3,7-22,104-111"
if [ -f "$CMDLINE_FILE" ]; then
    if ! grep -q "$GPE_PARAM" "$CMDLINE_FILE"; then
        echo "▸ Adding GPE mask to $CMDLINE_FILE…"
        sed -i "s/$/ $GPE_PARAM/" "$CMDLINE_FILE"
    else
        echo "▸ GPE mask already in $CMDLINE_FILE"
    fi
else
    echo "▸ Creating $CMDLINE_FILE…"
    echo "$GPE_PARAM" > "$CMDLINE_FILE"
fi

# Also update GRUB config
GRUB_FILE="/etc/default/grub"
if [ -f "$GRUB_FILE" ]; then
    if ! grep -q "$GPE_PARAM" "$GRUB_FILE"; then
        echo "▸ Adding GPE mask to $GRUB_FILE…"
        sed -i "s/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"$GPE_PARAM /" "$GRUB_FILE"
    fi
    echo "▸ Regenerating GRUB config…"
    if command -v grub2-mkconfig &>/dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    fi
    # Update grubenv if BLS
    if command -v grub2-editenv &>/dev/null; then
        CURRENT=$(grub2-editenv list 2>/dev/null | grep kernelopts || true)
        if echo "$CURRENT" | grep -q "kernelopts="; then
            NEW_OPTS=$(echo "$CURRENT" | sed 's/^kernelopts=//' | sed "s/$/ $GPE_PARAM/" | sed 's/  */ /g')
            grub2-editenv - set "kernelopts=$NEW_OPTS"
        fi
    fi
fi

# 4. Enable and start services
echo "▸ Enabling services…"
systemctl enable --now surface-acpi-watcher.timer 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

# 5. Load module now
echo "▸ Loading kernel module…"
modprobe surface_fixed_event_quell 2>/dev/null || true

# 6. Update icon cache
gtk-update-icon-cache /usr/local/share/icons/hicolor 2>/dev/null || true

echo ""
echo "✅ Surface ACPI Quell installed!"
echo ""
echo "   Next steps:"
echo "   1. Reboot to apply the kernel parameter"
echo "      (or test now: sudo modprobe surface_fixed_event_quell)"
echo "   2. The watcher is running every 60s"
echo "   3. The tray indicator will appear on next login"
echo "      (or start now: surface-acpi-indicator &)"
echo ""
echo "   After reboot, verify:"
echo "     cat /proc/interrupts | grep acpi  # IRQ 9 should be stable"
echo "     journalctl -k -n 10 | grep ACPI   # should be silent"
