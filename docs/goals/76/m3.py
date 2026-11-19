"""Goal 76 M3: nothing regressed. Goal 73's whole check (M1-M3 its own proofs through the ribbon, M4 goal 71's M5 chain
71 -> 70 -> 68 -> 47 plus scenario.py robots), the component matrix fresh, the decisions lint, and the AppKit build
(a failed build is a FAIL: this goal changed mojoui/hosts/appkit.mojo)."""
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build/g76/m3"


def run(cmd, timeout, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def check():
    OUT.mkdir(parents=True, exist_ok=True)
    data = os.environ.get("G73_DATA") or next((str(p) for p in (ROOT / "build/g47/full", ROOT.parent / "mojo-ui-g73/build/g47/full")
                                               if (p / "fleet.csv").exists()), str(ROOT / "build/g47/full"))
    r = run(["pixi", "run", "python", "docs/goals/73-check.py"], 4 * 3600, {"G73_DATA": data})
    (OUT / "73-check.log").write_text(r.stdout + r.stderr)
    lines = [l for l in r.stdout.splitlines() if l[:2] in ("M1", "M2", "M3", "M4")]
    if len(lines) < 4 or any(": PASS" not in l for l in lines):
        return False, "73-check: " + " | ".join(l[:160] for l in lines)
    r = run(["pixi", "run", "python", "scripts/components.py", "--check"], 600)
    if r.returncode != 0:
        return False, "the component matrix is stale (pixi run python scripts/components.py)"
    r = run(["pixi", "run", "python", "scripts/decisions_lint.py"], 600)
    if r.returncode != 0:
        return False, "decisions lint: " + (r.stdout + r.stderr)[-300:]
    r = run(["scripts/build.sh", "omxplorer", "mac"], 3600)
    (OUT / "mac-build.log").write_text(r.stdout + r.stderr)
    if r.returncode != 0:  # (review round 1: this goal changed the AppKit host, so a failed build is a FAIL, not a note)
        return False, "AppKit build failed: " + (r.stdout + r.stderr).strip()[-300:]
    return True, "73-check M1-M4 PASS; matrix fresh; decisions lint ok; AppKit build ok"
