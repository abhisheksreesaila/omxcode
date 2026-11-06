"""Runs packaged Linux downloads the way a stranger would (goal 53): each dist/<app>-linux-x86_64.tar.gz unpacked into an
empty folder and started with a bare environment (no pixi, no Mojo, a fresh HOME, PATH=/usr/bin:/bin) on a headless
display. Passes when the app is still running after a few seconds and its window has something drawn in it; writes a
screenshot per app to build/g53/bare/<app>.png and a summary to build/g53/bare.json.
  pixi run python scripts/bare_run.py sketch jot keeper widgets lens todo
An app with a web view (widgets) needs WebKitGTK 6.0 on the machine: $WEBKITGTK_DIR (a folder from scripts/webkitgtk.sh)
stands in for a system install, laid over /usr/lib as the app's launcher does, and then the run fails if the app fell
back to its stand-ins. Each result records the tarball's sha256, so a repackaged download needs a new run."""
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import headless  # noqa: E402
import hashlib  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
# an app's own settings for the run (goal 55: omxconsole on a spare port and a throwaway home, with no MAX, so it never
# finds or touches a service already running on this machine; its home then says MAX isn't installed)
APP_ENV = {"omxconsole": lambda tmp: {"MXC_PORT": str(_free_port()), "MXC_HOME": tmp + "/mxc", "MXC_MAX": tmp + "/no-max"}}
MUST_SAY = {"omxconsole": "CONSOLED UP"}


def _free_port():
    import socket
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port
OUT = ROOT / "build/g53/bare"
WAIT_S = 6


def colours(png):
    """How many distinct colours the screenshot has: a blank or crashed window has one or two."""
    r = subprocess.run(["magick", str(png), "-format", "%k", "info:"], capture_output=True, text=True)
    return int(r.stdout.strip() or 0)


def run(app):
    tar = ROOT / "dist" / f"{app}-linux-x86_64.tar.gz"
    if not tar.exists():
        return {"ok": False, "why": f"no {tar.name}: scripts/package.sh {app} linux"}
    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(tar) as t:
            t.extractall(tmp, filter="tar")
        here = Path(tmp) / f"{app}-linux-x86_64"
        wk = os.environ.get("WEBKITGTK_DIR", "")
        if (here / f"{app}.bin").exists() and wk:  # (as if WebKitGTK 6.0 were installed: the launcher overlays it)
            (here / f"{app}.webkitgtk").write_text(wk)
        home = Path(tmp) / "home"
        home.mkdir()
        env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "XDG_RUNTIME_DIR": tmp}
        env.update({k: os.environ[k] for k in ("DISPLAY", "GDK_BACKEND", "GSK_RENDERER", "GDK_DISABLE", "GDK_SCALE",
                                               "XKB_CONFIG_ROOT") if k in os.environ})
        if app in APP_ENV:
            env.update(APP_ENV[app](tmp))
        log = open(OUT / f"{app}.log", "w")
        p = subprocess.Popen([str(here / app)], cwd=here, env=env, stdout=log, stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL)
        time.sleep(WAIT_S)
        alive = p.poll() is None
        shot = OUT / f"{app}.png"
        subprocess.run(["import", "-display", env["DISPLAY"], "-window", "root", str(shot)], capture_output=True)
        p.terminate()
        try:
            p.wait(5)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
        log.close()
        n = colours(shot) if shot.exists() else 0
        text = (OUT / f"{app}.log").read_text()
        stand_ins = "show their stand-ins" in text
        said = MUST_SAY.get(app, "") in text
        ok = alive and n > 16 and not stand_ins and said
        why = "" if ok else ("exited with " + str(p.returncode) if not alive else
                             ("its web view didn't load (WebKitGTK 6.0: $WEBKITGTK_DIR)" if stand_ins else
                              (f"no '{MUST_SAY.get(app)}' line" if not said else f"window looks empty ({n} colours)")))
        return {"ok": ok, "alive": alive, "colours": n, "stand_ins": stand_ins, "why": why,
                "sha256": hashlib.sha256(tar.read_bytes()).hexdigest(),
                "log_tail": (OUT / f"{app}.log").read_text()[-400:]}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    headless.ensure()
    if "DISPLAY" not in os.environ:
        sys.exit("no headless display")
    res = {}
    for app in sys.argv[1:]:
        res[app] = run(app)
        print(f"{app}: {'ok' if res[app]['ok'] else 'FAIL ' + res[app]['why']}", flush=True)
    # the apps run here replace their own entries; the others' runs stay (a run of one app once wiped six, goal 55)
    out = ROOT / "build/g53/bare.json"
    kept = json.loads(out.read_text()) if out.exists() else {}
    out.write_text(json.dumps({**kept, **res}, indent=1))
    headless.stop()
    sys.exit(0 if all(r["ok"] for r in res.values()) else 1)


if __name__ == "__main__":
    main()
