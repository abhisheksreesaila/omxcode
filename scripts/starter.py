"""The robot starter: goal 47's DROID set made ready for the hosted copy (goal 62). omxplorer's Start screen offers it
when OMX_STARTER names its folder; the web host loads its tables once per process and every visitor reads them.

    pixi run python scripts/starter.py --from build/g47/full --to build/starter/robot [--clips all|story] [--width 480]

The folder holds: fleet.csv and telemetry.parquet (copied as they are), limits.csv, paper/, ATTRIBUTION.txt, clips/ (each
re-encoded to the width the page shows: H.264, 15 fps as recorded, every frame kept, no sound) and story.json, which
tells omxplorer what the starter is: its sheet, its table cards, its documents, its links, the run it opens on, and the
story's questions in words with their SQL (from scripts/scenario.py's ROBOT_* constants, the ones goal 47's scenario
asks). Every file is made read-only. Run again, it checks what it made (sizes against manifest.json) and only makes
what is missing; --clips story keeps only the story's clips (the picked failures and the regrasped ones), for a small
volume."""

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from scenario import ROBOT_LINKS, ROBOT_Q1, ROBOT_SQL1, ROBOT_Q2, ROBOT_SQL2, ROBOT_SQL3, ROBOT_PICKED  # noqa: E402

CREDIT = "Robot runs: DROID (Khazatsky et al., 2024), CC-BY-4.0"


def story(fleet_rows):
    return {
        "title": "Why did the robot drop it?",
        "start": "Start the robot story",
        "lead": f"{fleet_rows:,} robot runs from DROID, with their telemetry, video and the paper, linked",
        "credit": CREDIT,
        "license": "CC-BY-4.0",
        "source": "https://droid-dataset.github.io",
        "sheet": "fleet.csv",
        "tables": ["telemetry.parquet"],
        "documents": "paper",
        "links": list(ROBOT_LINKS),
        "hero": "F00118",
        "questions": [
            {"name": "regrasped", "question": ROBOT_Q1, "sql": ROBOT_SQL1},
            {"name": "fastest", "question": ROBOT_Q2, "sql": ROBOT_SQL2},
            {"name": "picked", "question": "the featured drop and the two failures beside it on its bench (Export pack them)", "sql": ROBOT_SQL3},
        ],
    }


def encode(src, dst, width):
    tmp = dst.with_suffix(".part.mp4")
    r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(src), "-vf", f"scale={width}:-2", "-c:v", "libx264", "-preset", "veryfast",
                        "-crf", "30", "-an", "-threads", "1", "-movflags", "+faststart", str(tmp)], capture_output=True, text=True)
    if r.returncode:
        tmp.unlink(missing_ok=True)
        return f"{src.name}: {r.stderr.strip()[-200:]}"
    tmp.rename(dst)
    dst.chmod(0o444)
    return ""


def copy(src, dst):
    if dst.exists() and dst.stat().st_size == src.stat().st_size:
        return False
    if dst.exists():
        dst.chmod(0o644)
    shutil.copyfile(src, dst)
    dst.chmod(0o444)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="src", required=True)
    ap.add_argument("--to", dest="dst", required=True)
    ap.add_argument("--clips", choices=["all", "story"], default="all")
    ap.add_argument("--width", type=int, default=480)
    a = ap.parse_args()
    src, dst = Path(a.src).resolve(), Path(a.dst)
    t0 = time.time()
    for d in (dst, dst / "clips", dst / "paper"):
        d.mkdir(parents=True, exist_ok=True)
        d.chmod(0o755)
    made = [f for f in ("fleet.csv", "telemetry.parquet", "limits.csv", "ATTRIBUTION.txt") if copy(src / f, dst / f)]
    made += [f"paper/{p.name}" for p in sorted((src / "paper").glob("*.pdf")) if copy(p, dst / "paper" / p.name)]
    rows = list(csv.DictReader(open(dst / "fleet.csv")))
    wanted = sorted({r["clip"] for r in rows if r["clip"]})
    if a.clips == "story":
        truth = json.loads((src / "truth.json").read_text())
        keep = set(ROBOT_PICKED) | set(truth.get("regrasped_failures", [])[:200]) | {truth["hero"]}
        wanted = [c for c in wanted if Path(c).stem in keep]
    todo = [c for c in wanted if not (dst / c).exists() and (src / c).exists()]
    problems = []
    with ThreadPoolExecutor(max(2, (os.cpu_count() or 4) // 2)) as ex:
        problems = [p for p in ex.map(lambda c: encode(src / c, dst / c, a.width), todo) if p]
    have = sorted(str(p.relative_to(dst)) for p in (dst / "clips").glob("*.mp4"))
    (dst / "story.json").chmod(0o644) if (dst / "story.json").exists() else None
    (dst / "story.json").write_text(json.dumps(story(len(rows)), indent=1) + "\n")
    (dst / "story.json").chmod(0o444)
    manifest = {"from": str(src), "clips": a.clips, "width": a.width, "files": {}}
    for p in sorted(dst.rglob("*")):
        if p.is_file() and p.name != "manifest.json":
            manifest["files"][str(p.relative_to(dst))] = p.stat().st_size
    m = dst / "manifest.json"
    if m.exists():
        m.chmod(0o644)
    m.write_text(json.dumps(manifest, indent=1) + "\n")
    m.chmod(0o444)
    size = sum(manifest["files"].values())
    print(f"starter: {dst} · {len(rows):,} runs · {len(have)} clips ({len(todo)} encoded now, {len(problems)} failed) · "
          f"{size / 2**30:.2f} GB · {time.time() - t0:.0f} s" + (f" · copied {made}" if made else ""))
    for p in problems[:10]:
        print("  clip failed:", p)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
