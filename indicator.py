#!/usr/bin/env python3
"""
Surface ACPI Quell — Tray indicator
Shows status in the system tray with right-click actions.

Works on Wayland and X11 via XDG StatusNotifierItem (AppIndicator3):
  GNOME   → needs gnome-shell-extension-appindicator
  KDE     → native System Tray support
  Hyprland → waybar tray or any SNI panel
  Sway/XFCE/Cinnamon → all supported

Usage:
  indicator.py              # start in background
  indicator.py --icon-dir PATH  # where to find status icons
"""
import gi
gi.require_version('Gtk', '3.0')
gi.require_version('AppIndicator3', '0.1')

import argparse
import os
import shutil
import subprocess
import sys
import threading
import time
from gi.repository import Gtk, AppIndicator3, GLib
from pathlib import Path

# ── Config ─────────────────────────────────────────────────────────────────

CHECK_INTERVAL = 30            # seconds between status re-checks
MODULE_NAME = "surface_fixed_event_quell"

# Icon names used in the icon theme
ICONS = {
    0: "surface-acpi-ok",       # OK
    1: "surface-acpi-warning",  # WARNING
    2: "surface-acpi-critical", # CRITICAL
    3: "surface-acpi-unknown",  # UNKNOWN
}

OK, WARNING, CRITICAL, UNKNOWN = range(4)

# ── State ──────────────────────────────────────────────────────────────────

class State:
    def __init__(self):
        self.status = UNKNOWN
        self.module_loaded = False
        self.irq9_rate = 0
        self.acpi_errors_1m = 0
        self.last_check = "never"
        self.details = []
        self.message = "Starting…"


# ── Checks ─────────────────────────────────────────────────────────────────

def read_irq9_sum():
    """Return total ACPI interrupts across all CPUs, or -1 on failure."""
    try:
        with open("/proc/interrupts") as f:
            for line in f:
                if "acpi" in line.lower():
                    # columns: IRQ, CPU0..CPUn, type, name
                    fields = line.split()
                    counts = []
                    for x in fields[1:-3]:
                        try:
                            counts.append(int(x))
                        except ValueError:
                            pass
                    return sum(counts) if counts else -1
    except Exception:
        return -1


def module_loaded():
    try:
        r = subprocess.run(["lsmod"], capture_output=True,
                           text=True, timeout=5)
        return MODULE_NAME in r.stdout
    except Exception:
        return False


def acpi_errors_last(seconds=60):
    try:
        r = subprocess.run(
            ["journalctl", "-k", f"--since={seconds} seconds ago",
             "--no-pager"],
            capture_output=True, text=True, timeout=10)
        return r.stdout.count("ACPI Error")
    except Exception:
        return -1


def watcher_status():
    try:
        r = subprocess.run(
            ["systemctl", "is-active", "surface-acpi-watcher.timer"],
            capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except Exception:
        return "unknown"


def watcher_last_run():
    try:
        r = subprocess.run(
            ["journalctl", "-u", "surface-acpi-watcher.service",
             "-n", "1", "--output=short-iso", "--no-pager"],
            capture_output=True, text=True, timeout=5)
        # Parse the last line for "Deactivated" timestamp
        for line in r.stdout.strip().split("\n")[-1:]:
            if "Deactivated" in line:
                return line.split(" ")[0] if line else "?"
        return "?"
    except Exception:
        return "?"


def check_all(state):
    state.module_loaded = module_loaded()

    c1 = read_irq9_sum()
    time.sleep(1)
    c2 = read_irq9_sum()
    state.irq9_rate = (c2 - c1) if (c1 >= 0 and c2 >= 0) else -1

    state.acpi_errors_1m = acpi_errors_last(60)
    state.last_check = time.strftime("%H:%M:%S")

    # Build details
    d = []
    d.append(
        f"Module: {'✅ loaded' if state.module_loaded else '⛔ NOT LOADED'}")

    if state.irq9_rate < 0:
        d.append("IRQ 9: ❓ unreadable")
    elif state.irq9_rate > 500:
        d.append(f"IRQ 9: 🚨 +{state.irq9_rate}/sec")
    elif state.irq9_rate > 50:
        d.append(f"IRQ 9: ⚠️  +{state.irq9_rate}/sec")
    else:
        d.append(f"IRQ 9: ✅ +{state.irq9_rate}/sec")

    if state.acpi_errors_1m < 0:
        d.append("ACPI errs: ❓ unreadable")
    elif state.acpi_errors_1m > 100:
        d.append(f"ACPI errs: 🚨 {state.acpi_errors_1m}/min")
    elif state.acpi_errors_1m > 10:
        d.append(f"ACPI errs: ⚠️  {state.acpi_errors_1m}/min")
    else:
        d.append(f"ACPI errs: ✅ {state.acpi_errors_1m}/min")

    tw = watcher_status()
    lr = watcher_last_run()
    d.append(f"Watcher: {tw} (last: {lr})")
    d.append(f"Updated: {state.last_check}")
    state.details = d

    # Overall status
    if not state.module_loaded:
        state.status = CRITICAL
        state.message = "ACPI fix module NOT loaded — storm may return!"
    elif state.irq9_rate > 500 or state.acpi_errors_1m > 100:
        state.status = CRITICAL
        state.message = (
            f"ACPI storm ACTIVE! IRQ9+{state.irq9_rate}/s, "
            f"{state.acpi_errors_1m} errs/min")
    elif state.irq9_rate > 50 or state.acpi_errors_1m > 10:
        state.status = WARNING
        state.message = "ACPI fix degraded — investigate soon"
    else:
        state.status = OK
        state.message = "ACPI storm suppressed ✓"


# ── Actions ────────────────────────────────────────────────────────────────

def run_watcher_fix():
    subprocess.Popen(
        ["pkexec", "surface-acpi-watcher", "--fix"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def rebuild_module():
    # Try to find the source tree in several known locations
    candidates = [
        "/usr/local/src/surface-acpi-quell",
        os.path.expanduser("~/code/surface-fixed-event-quell"),
        os.path.expanduser("~/surface-acpi-quell"),
    ]
    for d in candidates:
        if os.path.isfile(os.path.join(d, "Makefile")):
            script = (
                f"cd '{d}' && make clean && make && make install && "
                f"depmod -a && dracut --force "
                f"--add-drivers surface_fixed_event_quell "
                f"&& modprobe surface_fixed_event_quell"
            )
            subprocess.Popen(
                ["pkexec", "sh", "-c", script],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
    # Fallback: notify the user
    subprocess.Popen(
        ["notify-send", "-u", "critical",
         "Surface ACPI Quell",
         "Cannot find module source tree. Clone from GitHub and rebuild."])


def open_doc():
    doc = "/usr/local/share/doc/surface-acpi-quell/README.md"
    if os.path.isfile(doc):
        subprocess.Popen(["xdg-open", doc])


def open_log():
    term = (shutil.which("gnome-terminal") or shutil.which("kgx")
            or "xterm")
    subprocess.Popen(
        [term, "-e",
         "journalctl -u surface-acpi-watcher.service -n 50 "
         "--since '1 hour ago'"])


# ── UI ─────────────────────────────────────────────────────────────────────

def build_menu(state):
    menu = Gtk.Menu()

    labels = {
        OK:       "✅ ACPI Storm Suppressed",
        WARNING:  "⚠️  ACPI Fix Degraded",
        CRITICAL: "🚨 ACPI Fix FAILED",
        UNKNOWN:  "❓ Status Unknown",
    }

    title = Gtk.MenuItem(label=labels.get(state.status, "Unknown"))
    title.set_sensitive(False)
    if state.status == CRITICAL:
        title.get_style_context().add_class("critical")
    menu.append(title)

    for detail in state.details:
        item = Gtk.MenuItem(label=detail)
        item.set_sensitive(False)
        menu.append(item)

    menu.append(Gtk.SeparatorMenuItem())

    actions = [
        ("🔍 Check Now", lambda w: do_check()),
        ("🔧 Run Fix Script", lambda w: run_watcher_fix()),
        ("🔨 Rebuild Module", lambda w: rebuild_module()),
    ]
    for label, cb in actions:
        item = Gtk.MenuItem(label=label)
        item.connect("activate", cb)
        menu.append(item)

    menu.append(Gtk.SeparatorMenuItem())

    more = [
        ("📋 View Watcher Log", lambda w: open_log()),
        ("📖 Documentation", lambda w: open_doc()),
        ("🚪 Quit", lambda w: Gtk.main_quit()),
    ]
    for label, cb in more:
        item = Gtk.MenuItem(label=label)
        item.connect("activate", cb)
        menu.append(item)

    menu.show_all()
    return menu


# ── App Loop ───────────────────────────────────────────────────────────────

state = State()
indicator = None


def set_icon():
    icon = ICONS.get(state.status, ICONS[UNKNOWN])
    indicator.set_icon_full(icon, state.message)


def do_check():
    def _run():
        check_all(state)
        GLib.idle_add(_update_ui)
    threading.Thread(target=_run, daemon=True).start()


def _update_ui():
    set_icon()
    indicator.set_label(state.message[:45], "")
    indicator.set_menu(build_menu(state))
    return False


def periodic():
    do_check()
    return True


def main():
    global indicator

    parser = argparse.ArgumentParser(
        description="Surface ACPI Quell tray indicator")
    parser.add_argument("--icon-dir",
                        help="Path to custom icon directory")
    args = parser.parse_args()

    GLib.set_application_name("Surface ACPI Quell")

    if args.icon_dir:
        icon_theme = Gtk.IconTheme.get_default()
        icon_theme.append_search_path(args.icon_dir)

    indicator = AppIndicator3.Indicator.new(
        "surface-acpi-quell", "surface-acpi-ok",
        AppIndicator3.IndicatorCategory.APPLICATION_STATUS,
    )
    indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)

    do_check()
    GLib.timeout_add_seconds(CHECK_INTERVAL, periodic)

    print(f"🐚 Surface ACPI Quell indicator started "
          f"(check every {CHECK_INTERVAL}s)", flush=True)

    try:
        Gtk.main()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
