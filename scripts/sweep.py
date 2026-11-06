"""Build every example for each platform it lists and build and run every Mojo test, then write what happened as JSON:
a compiler move (goal 52: Mojo 1.1 to 1.2) is "nothing regressed" when nothing that passed in the old checkout's sweep
fails in the new one's.
  pixi run python scripts/sweep.py --out build/sweep.json                    # this checkout
  pixi run python scripts/sweep.py --root ../mojo-ui-g50 --out base.json     # another one, with its own env and scripts
Examples: scripts/build.sh <app> <platform> for each line of examples/<app>/platforms (none: linux web mac ios), one app
at a time per worker. Tests: tests/test_*.mojo built with scripts/mojo_flare.sh when they import Flare or what's built on
it (mojoui.serve, mojoui.http_flare), else scripts/mxbuild.sh, then run with no arguments (a test that needs a server
or data it doesn't find fails in both sweeps alike)."""
import argparse
import json
import os
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

FLARE_IMPORTS = re.compile(r"^\s*(from|import)\s+(flare|mojoui\.serve|mojoui\.http_flare)\b", re.M)


SOURCES = ["mojoui", "themes", "hosts", "examples", "tests", "vendor", "scripts/build.sh", "scripts/mxbuild.sh",
           "scripts/mxlink.sh", "scripts/mojo_flare.sh", "scripts/flare_ffi.sh", "pixi.toml", "pixi.lock"]


def stamp(root):
    """A hash of every file the sweep builds from: a sweep of other sources doesn't count."""
    import hashlib
    h = hashlib.sha256()
    for top in SOURCES:
        p = root / top
        for f in sorted([p] if p.is_file() else p.rglob("*")):
            if f.is_file() and "__pycache__" not in f.parts:
                h.update(str(f.relative_to(root)).encode() + b"\0" + f.read_bytes())
    return h.hexdigest()[:16]


def tail(text, n=600):
    return text[-n:] if text else ""


def run(root, cmd, timeout):
    t = time.time()
    try:
        r = subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL,
                           env=dict(os.environ, MOJOUI_HEADLESS="1"))
        return r.returncode, r.stdout + r.stderr, time.time() - t
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return "timeout", out, time.time() - t


def example(root, app):
    plats = (root / "examples" / app / "platforms")
    plats = plats.read_text().split() if plats.exists() else ["linux", "web", "mac", "ios"]
    out = {}
    for p in plats:
        code, text, secs = run(root, ["scripts/build.sh", app, p], 1800)
        out[p] = {"ok": code == 0, "code": code, "secs": round(secs, 1), "tail": "" if code == 0 else tail(text)}
    return app, out


def test(root, src):
    name = src.stem
    flare = bool(FLARE_IMPORTS.search(src.read_text()))
    exe = root / "build" / "sweep" / name
    exe.parent.mkdir(parents=True, exist_ok=True)
    build = (["scripts/mojo_flare.sh", "build"] if flare else ["scripts/mxbuild.sh"]) + [str(src.relative_to(root)), "-o", str(exe)]
    code, text, secs = run(root, build, 1800)
    if code != 0:
        return name, {"built": False, "passed": False, "code": code, "secs": round(secs, 1), "tail": tail(text)}
    rcode, rtext, rsecs = run(root, [str(exe)], 300)
    return name, {"built": True, "passed": rcode == 0, "code": rcode, "secs": round(secs + rsecs, 1),
                  "tail": "" if rcode == 0 else tail(rtext)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--out", required=True)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--only", choices=["examples", "tests"])
    a = ap.parse_args()
    root = Path(a.root).resolve()
    mojo = subprocess.run(["pixi", "run", "mojo", "--version"], cwd=root, capture_output=True, text=True).stdout.strip()
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=root, capture_output=True, text=True).stdout.strip()
    result = {"root": str(root), "commit": head, "mojo": mojo, "stamp": stamp(root), "examples": {}, "tests": {}}
    # the Flare shims and the codec links first, once (every build would make them, racing each other)
    subprocess.run(["bash", "scripts/flare_ffi.sh"], cwd=root, capture_output=True)
    if a.only != "tests":
        apps = sorted(d.name for d in (root / "examples").iterdir() if (d / "app.mojo").exists())
        with ThreadPoolExecutor(max(1, a.jobs // 2)) as pool:
            for app, out in pool.map(lambda x: example(root, x), apps):
                result["examples"][app] = out
                print(f"example {app}: " + " ".join(f"{p}={'ok' if v['ok'] else 'FAIL'}" for p, v in out.items()), flush=True)
    if a.only != "examples":
        srcs = sorted((root / "tests").glob("test_*.mojo"))
        with ThreadPoolExecutor(a.jobs) as pool:
            for name, out in pool.map(lambda s: test(root, s), srcs):
                result["tests"][name] = out
                print(f"test {name}: {'pass' if out['passed'] else ('FAIL' if out['built'] else 'NO BUILD')} ({out['secs']} s)", flush=True)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(result, indent=1))


if __name__ == "__main__":
    main()
