#!/bin/bash
# surface-acpi-rollback — Roll back to a previous kernel module version
# Uses backups saved by the kernel-install hook in /var/lib/surface-acpi-quell/backup/
set -euo pipefail

BACKUP_DIR="/var/lib/surface-acpi-quell/backup"
MODULE_NAME="surface_fixed_event_quell"

if [ "$EUID" -ne 0 ]; then
    echo "Usage: sudo $0"
    exit 1
fi

echo "Available module backups:"
echo ""
if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls "$BACKUP_DIR"/${MODULE_NAME}.ko.* 2>/dev/null)" ]; then
    echo "  No backups found. Module has never been rebuilt via kernel-install hook."
    echo "  Backups are created automatically when a new kernel is installed."
    exit 0
fi

backups=()
i=0
for b in "$BACKUP_DIR"/${MODULE_NAME}.ko.*; do
    i=$((i + 1))
    bname=$(basename "$b")
    # Extract kernel version from filename: surface_fixed_event_quell.ko.6.19.8-2.surface.fc43
    kver="${bname#${MODULE_NAME}.ko.}"
    bsize=$(stat -c "%s" "$b" 2>/dev/null || echo 0)
    echo "  [$i] kernel=$kver  size=${bsize} bytes"
    backups+=("$b")
done

echo ""
echo -n "Select backup to restore [1-$i, Enter=cancel]: "
read -r sel
if [ -z "$sel" ]; then
    echo "Cancelled."
    exit 0
fi
if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "$i" ]; then
    echo "Invalid selection."
    exit 1
fi

selected="${backups[$((sel - 1))]}"
kver="${selected##*.}"

# Unload current module
echo "Unloading current module..."
rmmod "$MODULE_NAME" 2>/dev/null || true

# Install selected backup
echo "Restoring from backup: $selected"
DEST="/lib/modules/$(uname -r)/extra/${MODULE_NAME}.ko"
cp "$selected" "$DEST"
depmod -a

# Load it
echo "Loading restored module..."
modprobe "$MODULE_NAME" && echo "✅ Module loaded successfully" || echo "❌ Failed to load module"

echo ""
echo "Module restored from backup. Verify with: lsmod | grep $MODULE_NAME" 
