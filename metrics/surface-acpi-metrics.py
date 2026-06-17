#!/usr/bin/env python3
"""
Surface ACPI Quell — Prometheus Metrics Exporter
Reads state.json and history.log, serves metrics on HTTP.

Usage:
  ./metrics.py              # daemon mode, port 9899
  ./metrics.py --once       # print once and exit
  ./metrics.py --port 9899  # custom port

Grafana can scrape http://localhost:9899/metrics
"""
import http.server
import json
import os
import sys
import time
from pathlib import Path

STATE_FILE = "/var/lib/surface-acpi-quell/state.json"
HISTORY_FILE = "/var/lib/surface-acpi-quell/history.log"
PORT = 9899

METRICS_HEADER = """# HELP surface_acpi_module_loaded Whether the kernel module is loaded (1=yes)
# TYPE surface_acpi_module_loaded gauge
# HELP surface_acpi_irq9_count Total ACPI IRQ 9 interrupts since boot
# TYPE surface_acpi_irq9_count gauge
# HELP surface_acpi_irq9_rate ACPI IRQ 9 interrupts per second
# TYPE surface_acpi_irq9_rate gauge
# HELP surface_acpi_problems Number of problems detected by last watcher run
# TYPE surface_acpi_problems gauge
# HELP surface_acpi_acpi_errors_1m ACPI Error messages in last minute
# TYPE surface_acpi_acpi_errors_1m gauge
# HELP surface_acpi_uptime_seconds System uptime in seconds
# TYPE surface_acpi_uptime_seconds gauge
# HELP surface_acpi_history_entries Total history entries recorded
# TYPE surface_acpi_history_entries gauge
# HELP surface_acpi_history_problems Total problem entries in history
# TYPE surface_acpi_history_problems gauge
"""


def read_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def generate_metrics():
    state = read_state()
    lines = [METRICS_HEADER]

    # Core metrics
    lines.append("surface_acpi_module_loaded %d" % state.get("module_loaded", 0))
    lines.append("surface_acpi_irq9_count %d" % state.get("irq9_count", 0))
    lines.append("surface_acpi_irq9_rate %d" % state.get("irq9_rate", 0))
    lines.append("surface_acpi_problems %d" % state.get("problems", 0))
    lines.append("surface_acpi_acpi_errors_1m %d" % state.get("acpi_errors_1m", 0))
    uptime = state.get("uptime_seconds", 0)
    if uptime == 0:
        try:
            uptime = int(open("/proc/uptime").read().split()[0])
        except Exception:
            pass
    lines.append("surface_acpi_uptime_seconds %d" % uptime)

    # History totals
    try:
        with open(HISTORY_FILE) as f:
            all_lines = f.readlines()
        total = len(all_lines) - 1  # subtract header
        problems = sum(1 for l in all_lines[1:] if l.strip() and int(l.split(",")[2]) > 0)
        lines.append("surface_acpi_history_entries %d" % total)
        lines.append("surface_acpi_history_problems %d" % problems)
    except Exception:
        lines.append("surface_acpi_history_entries 0")
        lines.append("surface_acpi_history_problems 0")

    return "\n".join(lines) + "\n"


class MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            metrics = generate_metrics()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(metrics.encode())
        elif self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            html = """<html><head><title>Surface ACPI Quell</title>
<meta http-equiv="refresh" content="5">
<style>body{font-family:monospace;padding:2em;background:#111;color:#0f0}
.metric{margin:0.5em 0}.ok{color:#0f0}.warn{color:#ff0}.err{color:#f00}</style>
</head><body><h1>Surface ACPI Quell</h1><pre>
"""
            self.wfile.write(html.encode())
            for line in generate_metrics().split("\n"):
                if line.startswith("#"):
                    self.wfile.write(("<span class='muted'>%s</span>\n" % line).encode())
                elif "1" in line and "gauge" not in line:
                    self.wfile.write(("<span class='ok'>%s</span>\n" % line).encode())
                elif "0" in line and "gauge" not in line:
                    self.wfile.write(("<span class='ok'>%s</span>\n" % line).encode())
                else:
                    self.wfile.write(("<span>%s</span>\n" % line).encode())
            self.wfile.write(b"</pre></body></html>")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), format % args))


def main():
    if "--once" in sys.argv:
        print(generate_metrics())
        return
    port = PORT
    for i, a in enumerate(sys.argv):
        if a == "--port" and i + 1 < len(sys.argv):
            port = int(sys.argv[i + 1])
    server = http.server.HTTPServer(("0.0.0.0", port), MetricsHandler)
    print("🌐 Surface ACPI metrics at http://localhost:%d/metrics" % port)
    print("   HTML dashboard at http://localhost:%d/" % port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
