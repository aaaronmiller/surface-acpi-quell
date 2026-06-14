# Surface ACPI Quell — Roadmap

## Status: Active Development (v1.0.0)

Current release: **5ef2332** — 5 commits, 20 files, fully functional on Surface Laptop Studio 2 (Fedora 43, kernel 6.19.8-surface).

---

## Phase 1: Foundation ✅ (Complete)

| Item | Status |
|------|--------|
| Kernel module to mask IRQ 9 | ✅ `surface_fixed_event_quell.ko` |
| GPE mask kernel parameter | ✅ `acpi_mask_gpe=0-3,7-22,104-111` |
| Watcher daemon (60s auto-repair) | ✅ systemd timer + script |
| Tray indicator (AppIndicator3) | ✅ Python/GTK indicator |
| Boot-time verification | ✅ `surface-acpi-verify.service` |
| Kernel update auto-rebuild hook | ✅ `/etc/kernel/install.d/` |
| Data logging & reporting | ✅ JSON state + CSV history + `--report` |
| MIT License | ✅ |
| GitHub public repo | ✅ `aaaronmiller/surface-acpi-quell` |

## Phase 2: Polish 🔜 (Next Up)

| Item | Priority | Effort | Notes |
|------|----------|--------|-------|
| **Custom tray icon** | P0 | low | User providing mudflap silhouette; swap into icon theme |
| **Config file** | P1 | medium | `/etc/surface-acpi-quell.conf` for IRQ threshold, GPE list, check interval |
| **Auto-detect GPEs** | P1 | medium | Scan `/sys/firmware/acpi/interrupts/` for high-count GPEs instead of hardcoding 68-6F |
| **Journal log rotation** | P1 | low | Ensure `99-acpi-rate-limit.conf` includes log rotation policy |
| **Non-Surface safety** | P2 | medium | Detect hardware; warn/abort if not a Surface device to prevent IRQ 9 masking on standard hardware |
| **Graceful degradation** | P2 | high | Monitor battery/thermal/lid after IRQ 9 mask; alert if ACPI functions are needed |

## Phase 3: Distribution 📦 (Near-term)

| Item | Priority | Effort | Notes |
|------|----------|--------|-------|
| **Fedora COPR** | P1 | medium | Build RPM for `dnf install surface-acpi-quell` |
| **Arch AUR** | P1 | low | PKGBUILD for `yay -S surface-acpi-quell` |
| **Ubuntu PPA** | P2 | medium | `apt-add-repository ppa:surface-acpi-quell` |
| **openSUSE OBS** | P2 | medium | Build Service package |
| **NixOS module** | P3 | high | Nix expression for declarative config |

## Phase 4: Cross-Desktop & Hardware 🌐 (Mid-term)

| Item | Priority | Effort | Notes |
|------|----------|--------|-------|
| **KDE Plasma validation** | P1 | low | Test indicator works natively with KDE System Tray |
| **Hyprland validation** | P1 | low | Test with `waybar` tray / `eww` SNI widget |
| **Sway / River validation** | P2 | low | Test with `waybar-tray` |
| **Surface Pro testing** | P2 | medium | Validate GPEs match on Surface Pro 7/8/9 |
| **Surface Book testing** | P2 | medium | Validate GPEs match on Surface Book 3 |
| **Non-Surface hardware support** | P3 | high | Provide GPE mask only (no IRQ 9 mask) for other vendors' broken ACPI |

## Phase 5: Intelligence 🤖 (Long-term)

| Item | Priority | Effort | Notes |
|------|----------|--------|-------|
| **Self-tuning** | P2 | high | Auto-detect problem GPEs from interrupt counts at boot |
| **Predictive alerts** | P3 | high | Trend analysis of IRQ rate over time; predict failures |
| **Automatic regression rollback** | P3 | high | If kernel update + new module = worse, roll back to previous |
| **ML anomaly detection** | P4 | very high | Learn normal IRQ patterns; flag deviations |

## Phase 6: Upstream 🌟 (Halo Goals)

| Item | Priority | Effort | Notes |
|------|----------|--------|-------|
| **Surface kernel patch** | P2 | high | Submit `surface_gpe` module fix to surface-kernel maintainers |
| **ACPI CA fix** | P3 | very high | Fix kernel ACPI CA to not loop-log errors for disabled fixed events |
| **Mainline Linux** | P4 | massive | Get Surface ACPI quirk accepted into drivers/acpi/quirks.c |
| **Hardware vendor fix** | P5 | impossible | Convince Microsoft to fix their firmware ACPI tables |

---

## Legend

| Priority | Meaning |
|----------|---------|
| **P0** | Blocking — must do next |
| **P1** | High — should do soon |
| **P2** | Medium — would be nice |
| **P3** | Low — when we get around to it |
| **P4** | Stretch — aspirational |
| **P5** | Pipe dream — probably won't happen |

## How to Contribute

1. Check the repo: [github.com/aaaronmiller/surface-acpi-quell](https://github.com/aaaronmiller/surface-acpi-quell)
2. Open an issue for bugs or feature requests
3. PRs welcome — see `README.md` for build instructions
