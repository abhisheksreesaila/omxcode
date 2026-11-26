"""Goal 73 M4's extra: the DROID story through the agent tools (scripts/scenario.py robots) still exits 0 on this branch:
open the fleet, add telemetry, type the four links, play F00118, two questions, the pack. (Goal 71's M5 chain, run by
73-check's m4, covers goal 70's M3, goal 68's M6 with goal 47 inside, the component matrix, the message ranges, and the
decisions, libc and seek lints.)"""
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build/g73/m4"
DATA = Path(os.environ.get("G73_DATA", ROOT / "build/g47/full"))  # (goal 47's DROID folder: scripts/robot_data.py)


def check():
    if not (DATA / "fleet.csv").exists():
        return None, f"no DROID data at {DATA} (scripts/robot_data.py makes it; or set G73_DATA)"
    OUT.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(["pixi", "run", "python", "scripts/scenario.py", "robots", "--media", str(DATA), "--out", str(OUT / "robots")],
                       cwd=ROOT, capture_output=True, text=True, timeout=3600)
    (OUT / "robots.log").write_text(r.stdout + r.stderr)
    if r.returncode != 0:
        return False, f"scenario robots exited {r.returncode}: " + (r.stdout + r.stderr)[-400:]
    pack = [l for l in r.stdout.splitlines() if l.startswith("pack:")]
    return True, "scenario robots exit 0 (" + (pack[-1][:120] if pack else "no pack line") + ")"
