"""Personal Note's own desktop launcher, cold, for goal 79's race (D-7950): runs ~/Projects/personalnotev2/desktop.py
unchanged in this process, on a scratch database and a scratch data folder (XDG_DATA_HOME), with one change made from
outside: the Chromium app window it starts also opens a DevTools port (so webcold.mjs can see the page). Prints
`PROCSTART_EPOCH_MS: <ms>` (this process's start, by /proc as the native app's FIRSTSCREEN measures its own).

  <PN>/.venv/bin/python docs/goals/79/desktop_cold.py <PN root> <DevTools port>
"""
import os
import sys
import time


def proc_age_ms() -> float:
    with open("/proc/uptime") as f:
        up = float(f.read().split()[0])
    with open("/proc/self/stat") as f:
        stat = f.read()
    fields = stat[stat.rfind(")") + 2:].split()
    return (up - int(fields[19]) / os.sysconf("SC_CLK_TCK")) * 1000.0


now = time.time() * 1000.0
print(f"PROCSTART_EPOCH_MS: {now - proc_age_ms():.1f}", flush=True)
root, port = sys.argv[1], sys.argv[2]
sys.path.insert(0, root)
os.chdir(root)
import chromium_app  # noqa: E402

_command = chromium_app.chromium_command


def command_with_port(binary, url, profile_dir):
    return _command(binary, url, profile_dir) + [f"--remote-debugging-port={port}"]


chromium_app.chromium_command = command_with_port
import desktop  # noqa: E402

sys.exit(desktop.main(["--no-build", "--engine", "chromium"]))
