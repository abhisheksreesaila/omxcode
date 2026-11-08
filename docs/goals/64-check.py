"""Goal 64: the two things omxconsole still can't do (GOAL.md) — porting a model MAX can't run, and
reaching the endpoint from another machine over HTTPS. Prints PASS, FAIL or BLOCKED per milestone.
  scripts/check            every milestone
  scripts/check M2 M4      only those
Everything runs against a throwaway MXC_HOME under build/g64 on free ports, with stand-ins for the three
external programs the pipeline drives (claude, the skill's gates, max): never the owner's daemon on :11435,
never ~/.mxc, never a real API key, never a real multi-hour port."""
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
BUILD = ROOT / "build"
G64 = BUILD / "g64"
FIX = ROOT / "docs/goals/64"          # the stand-ins and step files


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g50 = load("g50check", ROOT / "docs/goals/50-check.py")
g55 = load("g55check", ROOT / "docs/goals/55-check.py")
run, mojo_build, free_port, wait_port, http = g50.run, g50.mojo_build, g50.free_port, g50.wait_port, g50.http
body = g55.body

BLOCKED = "BLOCKED"


class Daemon:
    """consoled on a throwaway home and a free port, with the pipeline's stand-ins wired in."""

    def __init__(self, home, extra=None):
        self.home, self.extra = Path(home), extra or {}
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        self.admin = "g64-admin-" + os.urandom(4).hex()
        self.p = None
        self.log_path = G64 / (self.home.name + ".log")

    def env(self):
        e = dict(os.environ, MXC_HOME=str(self.home), MXC_PORT=str(self.port), MXC_ADMIN_KEY=self.admin)
        e.update(self.extra)
        return e

    def start(self):
        self.home.mkdir(parents=True, exist_ok=True)
        self.log = open(self.log_path, "a")
        self.p = subprocess.Popen([str(BUILD / "consoled")], cwd=ROOT, env=self.env(), stdout=self.log,
                                  stderr=subprocess.STDOUT)
        return wait_port(self.port, 30)

    def stop(self):
        if self.p and self.p.poll() is None:
            self.p.send_signal(signal.SIGTERM)
            try:
                self.p.wait(30)
            except subprocess.TimeoutExpired:
                self.p.kill()
        self.p = None

    def call(self, method, path, body=None, admin=True, timeout=120):
        return http(method, self.url + path, body, {"X-Mst-Admin": self.admin} if admin else {}, timeout=timeout)

    def log_text(self):
        return self.log_path.read_text(errors="replace") if self.log_path.exists() else ""

    def __enter__(self):
        if not self.start():
            raise RuntimeError("consoled didn't listen: " + self.log_text()[-600:])
        return self

    def __exit__(self, *a):
        self.stop()


def build_all():
    err = mojo_build("examples/consoled/main.mojo", BUILD / "consoled")
    if err:
        return err
    r = run(["scripts/build.sh", "console", "linux"])
    return None if r.returncode == 0 else "console build: " + (r.stdout + r.stderr)[-400:]


# ---- milestones -------------------------------------------------------------------------------------------------------

def m0():
    return False, "not built yet"


def m1():
    return False, "not built yet"


def m2():
    return False, "not built yet"


def m3():
    return False, "not built yet"


def m4():
    return False, "not built yet"


def m5():
    return False, "not built yet"


MILESTONES = [("M0", m0), ("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4), ("M5", m5)]


def main():
    G64.mkdir(parents=True, exist_ok=True)
    import headless
    headless.ensure()
    only = sys.argv[1:]
    results = []
    for name, fn in MILESTONES:
        if only and name not in only:
            continue
        t0 = time.time()
        try:
            ok, msg = fn()
        except Exception as e:  # noqa: BLE001
            import traceback
            traceback.print_exc()
            ok, msg = False, f"crashed: {e!r}"
        results.append(ok is True or ok == BLOCKED)
        word = "PASS" if ok is True else ("BLOCKED" if ok == BLOCKED else "FAIL")
        print(f"{word}  {name}  {msg}  ({time.time() - t0:.0f} s)", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
