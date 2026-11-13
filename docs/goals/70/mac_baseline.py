"""Goal 70 M0's Mac reference: the undefined symbols of each Mac app on the engine, cross-built from main's own tree
(9e3e9d0f, engine 834ef9a), written to docs/goals/70/mac-undefined-main-<app>.json.

    pixi run python -I docs/goals/70/mac_baseline.py [APP ...]      (default: jobwake jot keeper omxplorer)

main is `git archive`d into build/g70/main-src (this checkout's pixi environment linked in: the same pixi.lock) and
each app is built there with main's scripts/build.sh; nothing in this checkout changes. Logs: build/g70/mac-main-<app>.log."""
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MAIN = "9e3e9d0f"
SRC = ROOT / "build/g70/main-src"


def undefined(app):
    objs = sorted(str(p.resolve()) for p in (SRC / f"build/{app}/mac").glob("*.o"))
    if not objs:
        return None
    nm = lambda *a: subprocess.run(["pixi", "run", "llvm-nm", *a, *objs], cwd=ROOT, capture_output=True, text=True).stdout.split()  # noqa: E731
    defined = set(nm("-j", "--defined-only"))
    return sorted({s for s in nm("-u", "-j") if s not in defined and not s.endswith(":")})


def main():
    apps = sys.argv[1:] or ["jobwake", "jot", "keeper", "omxplorer"]
    if not (SRC / ".git-archive-" / MAIN).exists():
        shutil.rmtree(SRC, ignore_errors=True)
        SRC.mkdir(parents=True)
        a = subprocess.run(f"git -C {ROOT} archive {MAIN} | tar -x -C {SRC}", shell=True, capture_output=True, text=True)
        if a.returncode:
            raise SystemExit("git archive: " + a.stderr[-300:])
        (SRC / ".pixi").symlink_to(ROOT / ".pixi")
        (SRC / ".git-archive-").mkdir()
        (SRC / ".git-archive-" / MAIN).touch()
    bad = False
    for app in apps:
        r = subprocess.run(["scripts/build.sh", app, "mac"], cwd=SRC, capture_output=True, text=True)
        (ROOT / f"build/g70/mac-main-{app}.log").write_text(r.stdout + r.stderr)
        syms = undefined(app)
        if syms is None:
            print(f"{app}: no objects (see build/g70/mac-main-{app}.log)")
            bad = True
            continue
        (ROOT / f"docs/goals/70/mac-undefined-main-{app}.json").write_text(json.dumps(syms))
        print(f"{app}: {'links' if r.returncode == 0 else 'link fails'}, {len(syms)} undefined symbols")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
