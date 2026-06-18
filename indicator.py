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
import json
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

# ── Sound diagnosis log directory ──────────────────────────────────────────
SOUND_LOG_DIR = os.path.expanduser("~/surface-sound-logs")

# ── Rogue watcher status file (written by rogue-watcher.sh) ────────────────
ROGUE_STATUS_FILE = "/tmp/rogue-watcher.json"


def read_rogue_status():
    """Return dict from rogue-watcher status file, or None."""
    try:
        with open(ROGUE_STATUS_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


# ── State ──────────────────────────────────────────────────────────────────

class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.status = UNKNOWN
        self.module_loaded = False
        self.irq9_rate = 0
        self.acpi_errors_1m = 0
        self.last_check = "never"
        self.details = []
        self.message = "Starting…"
        self.rogue = None

    def update(self, **kwargs):
        with self.lock:
            for k, v in kwargs.items():
                setattr(self, k, v)

    def snapshot(self):
        with self.lock:
            return {k: getattr(self, k) for k in [
                "status", "module_loaded", "irq9_rate", "acpi_errors_1m",
                "last_check", "details", "message", "rogue"
            ]}


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
    # First-run guard: if no state file exists yet, show a placeholder
    if not os.path.isfile("/var/lib/surface-acpi-quell/state.json"):
        state.update(status=UNKNOWN, message="No data yet — watcher hasn't run",
                     details=["Watcher hasn't recorded state yet",
                              "The systemd timer runs every 60s",
                              "Wait a moment and check again"],
                     last_check=time.strftime("%H:%M:%S"))
        return
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

    # Rogue process status
    rogue = read_rogue_status()
    state.rogue = rogue
    if rogue:
        n = rogue.get('tracked', 0)
        a = rogue.get('alerts_5m', 0)
        if a > 0:
            d.append(f"🦜 ROGUES: {a} alerts in 5m, tracking {n} procs")
        else:
            d.append(f"🦜 No rogues — tracking {n} procs")
    else:
        d.append("🦜 Rogue watcher: not running")

    state.update(details=list(d))

    # Overall status
    s = state.snapshot()
    if not s["module_loaded"]:
        state.update(status=CRITICAL,
                     message="ACPI fix module NOT loaded — storm may return!")
    elif s["irq9_rate"] > 500 or s["acpi_errors_1m"] > 100:
        state.update(status=CRITICAL,
                     message=f"ACPI storm ACTIVE! IRQ9+{s['irq9_rate']}/s, {s['acpi_errors_1m']} errs/min")
    elif s["irq9_rate"] > 50 or s["acpi_errors_1m"] > 10:
        state.update(status=WARNING,
                     message="ACPI fix degraded — investigate soon")
    else:
        state.update(status=OK,
                     message="ACPI storm suppressed ✓")


# ── Actions ────────────────────────────────────────────────────────────────

def run_watcher_fix():
    subprocess.Popen(
        ["pkexec", "/usr/local/bin/surface-acpi-watcher", "--fix"],
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


def open_report():
    """Generate and show the status report."""
    try:
        result = subprocess.run(
            ["/usr/local/bin/surface-acpi-watcher", "--report"],
            capture_output=True, text=True, timeout=10)
        report = result.stdout
    except Exception:
        report = "Failed to generate report"
    # Show in a dialog
    dialog = Gtk.Dialog(title="Surface ACPI Quell — Status Report",
                         transient_for=None, flags=Gtk.DialogFlags.MODAL)
    dialog.add_buttons(Gtk.STOCK_OK, Gtk.ResponseType.OK)
    dialog.set_default_size(500, 400)
    scrolled = Gtk.ScrolledWindow()
    scrolled.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
    textview = Gtk.TextView()
    textview.set_editable(False)
    textview.set_wrap_mode(Gtk.WrapMode.WORD)
    buf = textview.get_buffer()
    buf.set_text(report)
    scrolled.add(textview)
    dialog.vbox.pack_start(scrolled, True, True, 0)
    dialog.show_all()
    dialog.run()
    dialog.destroy()


def cycle_extensions():
    """Cycle all GNOME Shell extensions to reset the audio context.

    This is the known workaround for the periodic ~8-10s sound bug on
    Surface Laptop Studio 2: disabling all extensions and re-enabling
    them clears the stuck libcanberra event loop in gnome-shell.
    """
    def _run():
        try:
            subprocess.run(
                ["bash", "-c", (
                    r'exts=$(gnome-extensions list --enabled); '
                    r'echo "$exts" | while read ext; do '
                    r'  gnome-extensions disable "$ext"; '
                    r'done; '
                    r'sleep 1; '
                    r'echo "$exts" | while read ext; do '
                    r'  gnome-extensions enable "$ext"; '
                    r'done'
                )],
                capture_output=True, text=True, timeout=30
            )
            subprocess.Popen(
                ["notify-send", "-u", "normal",
                 "🔁 GNOME Extensions",
                 "Extensions cycled — audio context reset"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as e:
            subprocess.Popen(
                ["notify-send", "-u", "critical",
                 "🔁 GNOME Extensions",
                 f"Failed to cycle extensions: {e}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    threading.Thread(target=_run, daemon=True).start()


def capture_system_snapshot(event_type):
    """Capture a comprehensive system snapshot to a timestamped log file.

    event_type: 'sound' (when the bug sound IS playing) or
                'nosound' (when it's absent). Comparing the two
                across multiple captures may reveal the trigger.
    """
    os.makedirs(SOUND_LOG_DIR, exist_ok=True)
    timestamp = time.strftime("%Y-%m-%d_%H%M%S")
    filename = f"{event_type}-{timestamp}.log"
    filepath = os.path.join(SOUND_LOG_DIR, filename)

    def _run():
        lines = []
        lines.append("=" * 72)
        lines.append("  Surface Sound Diagnosis Log")
        lines.append(f"  Event type: {event_type.upper()}")
        lines.append(f"  Timestamp:  {time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
        lines.append(f"  Hostname:   {os.uname().nodename}")
        lines.append(f"  Kernel:     {os.uname().release}")
        lines.append(f"  Desktop:    {os.environ.get('XDG_SESSION_DESKTOP', '?')}")
        lines.append(f"  Session:    {os.environ.get('XDG_SESSION_TYPE', '?')}")
        lines.append(f"  Uptime:     {open('/proc/uptime').read().split()[0]}s")
        lines.append("=" * 72)
        lines.append("")

        def run_cmd(cmd, label=None, timeout=15):
            hdr = label or (cmd[0] if isinstance(cmd, list) else cmd)
            lines.append(f"── {hdr} ──")
            try:
                r = subprocess.run(cmd, capture_output=True, text=True,
                                   timeout=timeout)
                out = (r.stdout or "").strip()
                err = (r.stderr or "").strip()
                if out:
                    lines.append(out)
                if err:
                    lines.append(f"[stderr] {err}")
            except Exception as e:
                lines.append(f"[error] {e}")
            lines.append("")
            return out

        # 1. Running processes (sorted by CPU)
        run_cmd(["ps", "aux", "--sort=-%cpu"],
                "Running processes (top 60 by CPU)")

        # 2. Audio state
        run_cmd(["pactl", "info"], "PipeWire/PulseAudio info")
        run_cmd(["pactl", "list", "sinks"], "Audio sinks")
        run_cmd(["pactl", "list", "sink-inputs"], "Active sink inputs")
        run_cmd(["pw-cli", "list-objects", "Node"],
                "PipeWire nodes", timeout=10)

        # 3. GNOME extensions
        run_cmd(["gnome-extensions", "list", "--enabled"],
                "Enabled GNOME extensions")

        # 4. ACPI / IRQ / dmesg
        run_cmd(["cat", "/proc/interrupts"], "Interrupts", timeout=5)
        run_cmd(["journalctl", "-k", "--since=5 minutes ago", "--no-pager"],
                "Kernel messages (last 5 min)", timeout=10)

        # 5. System load
        run_cmd(["cat", "/proc/loadavg"], "Load average", timeout=5)
        run_cmd(["free", "-h"], "Memory", timeout=5)
        run_cmd(["uptime"], "Uptime", timeout=5)

        # 6. D-Bus services
        run_cmd(["busctl", "list", "--no-legend"],
                "D-Bus services", timeout=10)

        # 7. ACPI module & GPEs
        run_cmd(["bash", "-c", "lsmod | grep surface"],
                "Surface modules", timeout=5)
        run_cmd(["ls", "-la", "/sys/firmware/acpi/interrupts/"],
                "ACPI GPE directory", timeout=5)

        # 8. Audio power management
        for p in [
            "/sys/module/snd_hda_intel/parameters/power_save",
            "/sys/module/snd_hda_intel/parameters/power_save_controller",
        ]:
            v = open(p).read().strip() if os.path.isfile(p) else "N/A"
            lines.append(f"{p}: {v}")
        lines.append("")

        # 9. Sound-using processes (lsof on /dev/snd)
        run_cmd(["lsof", "/dev/snd/"],
                "Processes with audio devices open", timeout=10)

        # 10. ACPI watcher state
        run_cmd(["cat", "/var/lib/surface-acpi-quell/state.json"],
                "Surface ACPI quell state", timeout=5)

        # 11. List all systemd user timers
        run_cmd(["systemctl", "--user", "list-timers", "--all"],
                "User timers", timeout=10)

        # 12. Audio timer info
        run_cmd(["systemctl", "--user", "status", "gnome-audio-reset.timer",
                 "--no-pager"],
                "Audio reset timer status", timeout=5)
        run_cmd(["systemctl", "--user", "status", "gnome-audio-reset.service",
                 "--no-pager"],
                "Audio reset service status", timeout=5)

        lines.append("=" * 72)
        lines.append(f"  End of {event_type.upper()} event snapshot")
        lines.append(f"  {filepath}")
        lines.append("=" * 72)
        lines.append("")

        # Write atomically: temp file then rename
        tmp_path = filepath + ".tmp"
        try:
            with open(tmp_path, "w") as f:
                f.write("\n".join(lines) + "\n")
            os.rename(tmp_path, filepath)
            subprocess.Popen(
                ["notify-send", "-u", "normal",
                 "📝 Sound Diagnosis",
                 f"{event_type.upper()} event logged to\n{filepath}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as e:
            subprocess.Popen(
                ["notify-send", "-u", "critical",
                 "📝 Sound Diagnosis",
                 f"Failed to write log: {e}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    threading.Thread(target=_run, daemon=True).start()


def capture_sound_event():
    """Log system snapshot when the periodic sound IS playing."""
    capture_system_snapshot("sound")


def capture_nosound_event():
    """Log system snapshot when the sound is NOT playing."""
    capture_system_snapshot("nosound")


def open_sound_logs_dir():
    """Open the sound diagnosis log directory in the file manager."""
    os.makedirs(SOUND_LOG_DIR, exist_ok=True)
    subprocess.Popen(["xdg-open", SOUND_LOG_DIR])


def reset_bluetooth():
    """Reset Bluetooth by toggling rfkill — workaround for BT devices
    that don't auto-connect after switching from another machine."""
    def _run():
        try:
            subprocess.run(["rfkill", "block", "bluetooth"],
                           capture_output=True, timeout=10)
            time.sleep(2)
            subprocess.run(["rfkill", "unblock", "bluetooth"],
                           capture_output=True, timeout=10)
            time.sleep(2)
            subprocess.Popen(
                ["notify-send", "-u", "normal",
                 "🔁 Bluetooth Reset",
                 "Bluetooth toggled off/on — devices should reconnect"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as e:
            subprocess.Popen(
                ["notify-send", "-u", "critical",
                 "🔁 Bluetooth Reset",
                 f"Failed: {e}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    threading.Thread(target=_run, daemon=True).start()


def _unload_acpi_module():
    """Unload the ACPI quell kernel module safely."""
    subprocess.run(
        ["pkexec", "rmmod", "surface_fixed_event_quell"],
        capture_output=True, timeout=15)


def safe_shutdown():
    """Unload the ACPI quell module first, then power off.
    The module masks IRQ 9 (ACPI SCI) which prevents ACPI power-off
    events from being delivered. Unloading it first ensures a clean
    shutdown."""
    def _run():
        _unload_acpi_module()
        time.sleep(1)
        subprocess.run(["systemctl", "poweroff"], timeout=30)
    threading.Thread(target=_run, daemon=True).start()


def safe_reboot():
    """Unload the ACPI quell module first, then reboot."""
    def _run():
        _unload_acpi_module()
        time.sleep(1)
        subprocess.run(["systemctl", "reboot"], timeout=30)
    threading.Thread(target=_run, daemon=True).start()


def module_is_loaded():
    """Check if the ACPI quell kernel module is loaded."""
    try:
        r = subprocess.run(["lsmod"], capture_output=True,
                           text=True, timeout=5)
        return "surface_fixed_event_quell" in r.stdout
    except Exception:
        return False


def toggle_module():
    """Toggle the ACPI quell kernel module on or off."""
    def _run():
        if module_is_loaded():
            _unload_acpi_module()
            subprocess.Popen(
                ["notify-send", "-u", "normal",
                 "↕️ ACPI Quell Module",
                 "Module unloaded — IRQ 9 re-enabled, ACPI events active"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.run(
                ["pkexec", "modprobe", "surface_fixed_event_quell"],
                capture_output=True, timeout=15)
            subprocess.Popen(
                ["notify-send", "-u", "normal",
                 "↕️ ACPI Quell Module",
                 "Module loaded — ACPI SCI IRQ9 masked"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    threading.Thread(target=_run, daemon=True).start()


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

    # ── Audio bug tools ─────────────────────────────────────────────────
    menu.append(Gtk.SeparatorMenuItem())
    audio_items = [
        ("🔁 Cycle Extensions (fix sound)", lambda w: cycle_extensions()),
        ("🔊 Log SOUND event", lambda w: capture_sound_event()),
        ("🔇 Log NO-SOUND event", lambda w: capture_nosound_event()),
        ("📂 Open logs folder", lambda w: open_sound_logs_dir()),
    ]
    for label, cb in audio_items:
        item = Gtk.MenuItem(label=label)
        item.connect("activate", cb)
        menu.append(item)

    # ── Bluetooth / Shutdown remediation ────────────────────────────────
    menu.append(Gtk.SeparatorMenuItem())
    sys_items = [
        ("🔁 Reset Bluetooth", lambda w: reset_bluetooth()),
        ("↕️ Toggle ACPI Module", lambda w: toggle_module()),
        ("🛑 Safe Shutdown", lambda w: safe_shutdown()),
        ("🔄 Safe Reboot", lambda w: safe_reboot()),
    ]
    for label, cb in sys_items:
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
    # Try our custom icon; fall back to standard status icons if not found
    theme = Gtk.IconTheme.get_default()
    info = theme.lookup_icon(icon, 22, 0)
    if not info:
        fallback = {OK: "face-smile-symbolic", WARNING: "face-worried-symbolic",
                    CRITICAL: "dialog-error-symbolic", UNKNOWN: "dialog-question-symbolic"}
        icon = fallback.get(state.status, fallback[UNKNOWN])
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
