# Surface ACPI Quell

**Silence the ACPI interrupt storm on Microsoft Surface laptops running Linux.**

Surface firmware emits **~227,000 unnecessary ACPI interrupts per second** — GPEs and fixed events that the Linux kernel can't handle because Microsoft's ACPI tables lack the expected implementations. This floods the CPU, spins up fans, burns NVMe writes with error logs, and drains battery.

**Surface ACPI Quell** kills the storm at three layers:

| Layer | Method | Effect |
|-------|--------|--------|
| 1 | Kernel parameter `acpi_mask_gpe` | Blocks problem GPEs (0x68–0x6F) before the kernel even sees them |
| 2 | Kernel module `surface_fixed_event_quell` | Masks the ACPI SCI (IRQ 9) — safe because Surface hardware uses its own Aggregator Module for battery/thermal/fan |
| 3 | Watcher daemon | systemd timer every 60s that checks integrity, auto-repairs, and notifies you |

**Result:** Zero ACPI errors. Zero unnecessary interrupts. Cool and quiet.

---

## Quick Start

```bash
# Clone and build
cd surface-acpi-quell
make
sudo make install
```

```bash
# Add the kernel parameter for GPE mask (one-time, survives kernel updates)
# Edit /etc/kernel/cmdline and add:
#   acpi_mask_gpe=0-3,7-22,104-111
# Then run:
sudo kernel-install -v add $(uname -r) /lib/modules/$(uname -r)/vmlinuz
```

```bash
# Reboot
sudo systemctl reboot
```

After reboot, verify:

```bash
cat /proc/interrupts | grep acpi   # IRQ 9 should be stable (not rising)
lsmod | grep surface_fixed          # module should be loaded
journalctl -k -n 10 | grep -c "ACPI Error"  # should be 0
```

---

## Components

### 1. Kernel Module (`surface_fixed_event_quell.ko`)

Masks the ACPI SCI interrupt (IRQ 9 by default, configurable via `irq_number` parameter). A re-arm timer fires every 10 seconds to catch firmware re-enables.

```bash
# Load manually
sudo modprobe surface_fixed_event_quell

# With custom IRQ
sudo insmod surface_fixed_event_quell.ko irq_number=9

# Check status
lsmod | grep surface_fixed_event_quell
```

### 2. Watcher Daemon (`surface-acpi-watcher`)

A bash script triggered by a systemd timer every 60 seconds. Checks:

- **Module loaded?** If missing, tries to load/reload/rebuild.
- **IRQ 9 stable?** If rising >500/sec, reloads the module to re-mask.
- **GPEs disabled?** Refreshes GPE 0x68–0x6F disable (idempotent).
- **Journal clean?** If ACPI errors still appear, notifies user.

Notifications via `wall`, `notify-send`, and syslog.

### 3. Tray Indicator (`surface-acpi-indicator`)

A Python/GTK system tray icon that shows status at a glance and provides quick actions via right-click menu.

| Icon | Meaning |
|------|---------|
| Green | ✅ ACPI storm suppressed |
| Yellow | ⚠️ Degraded — investigate |
| Red | 🚨 Fix failed — active storm |
| Gray | ❓ Status unknown |

Right-click menu: Check Now, Run Fix, Rebuild Module, View Log, Documentation.

Works on all Wayland desktops via XDG StatusNotifierItem (AppIndicator3):
- **GNOME:** needs `gnome-shell-extension-appindicator`
- **KDE Plasma:** native support
- **Hyprland:** waybar tray or any SNI panel
- **Sway, XFCE, Cinnamon:** all supported

---

## After a Kernel Update

The GPE mask in the kernel parameter survives kernel updates (it's stored in
`/etc/kernel/cmdline`). The kernel module must be rebuilt for the new kernel:

```bash
cd /path/to/surface-acpi-quell
make clean && make
sudo make install
sudo dracut --force --add-drivers surface_fixed_event_quell
sudo systemctl reboot
```

The watcher will alert you if you forget — but the machine will heat up until
you rebuild.

---

## Uninstall

```bash
sudo make uninstall
```

Then remove the `acpi_mask_gpe=0-3,7-22,104-111` parameter from
`/etc/default/grub` and `/etc/kernel/cmdline`, and reboot.

---

## Compatibility

Tested on:

| Device | Kernel | Status |
|--------|--------|--------|
| Surface Laptop Studio 2 | 6.19.8-surface.fc43 | ✅ Confirmed |
| Surface Pro (expected) | surface kernel | ✅ Should work |
| Surface Book (expected) | surface kernel | ✅ Should work |

The IRQ 9 mask is safe on any Surface device because the Surface Aggregator
Module (SAM) — not ACPI — handles battery, thermal, fan, and platform
monitoring.

**Non-Surface devices:** Do not use the IRQ 9 mask. Standard ACPI interrupts
are required for power management on non-Surface hardware. The GPE mask may
still be useful if you have a similar firmware bug — adjust the GPE numbers
in the kernel parameter to match your hardware's flood.

---

## License

MIT. See [LICENSE](LICENSE).

## Author

Barnacle O'Byte — a surly Irish pirate who'd rather code than plunder.
