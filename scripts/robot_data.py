#!/usr/bin/env python3
"""Goal 47 M0: the robot fleet from real public data (DROID 720p, CC-BY-4.0, LeRobot format), mirroring claims_data.py.

    pixi run python -I scripts/robot_data.py OUT [DATASET ...]      (default datasets: ~/data/robot-scout/droid720*)

Reads each dataset with mojoui/lerobot.py (the generic LeRobot source) and writes into OUT, deterministically:
  fleet.csv          one row per episode whose telemetry is on disk (video only where it was fetched: clip blank else):
                     episode (S/F + the dataset's episode index), lab, robot, date, outcome, success (1/0), success_pct (100/0: an average reads as a percent), n (1: a pivot's
                     sum of it counts episodes), task, verb (its first word; one used by fewer than 1,000 episodes: "other"),
                     duration_s, frames, grasps (gripper closes), missed_grasp (1: the fingers closed on nothing, held
                     above 0.85), regrasps (closes after the first), slipped (1: a hold that closed further by > 0.2
                     without opening), peak_speed (the fastest joint, rad/s), clip (clips/<episode>.mp4, blank without video), video (1/0),
                     source (the paper the row comes from: droid-paper.pdf), task_from, uuid.
                     Failures in DROID carry no instruction: their task is the nearest success on the same robot the same
                     day (task_from says so), else blank.
  telemetry.parquet  one row per frame of every fleet episode (15 Hz): episode, t, joint_vel_1..7, gripper, pos_x/y/z,
                     rot_roll/pitch/yaw (unwrapped), speed, track_err, gripper_event ('close', 'open' or '').
  clips/<ep>.mp4     each episode's left external camera, cut from the packed file (re-encoded: H.264, a key frame every
                     15 frames, so a scrub lands fast), exactly `frames` frames.
  limits.csv         joint, limit_rad_s, source: the Franka Panda's joint velocity limits (libfranka's published control
                     parameters), for the peaks against the spec.
  paper/droid-paper.pdf  the DROID paper (arXiv 2403.12945v2, CC-BY-4.0), when it is in ~/data/robot-scout/docs.
  truth.json         the fleet's totals, success rate by lab and by verb, the failure counts by kind and their episodes, the hero.
  ATTRIBUTION.txt    where the data came from and its licence.
Two runs give byte-equal fleet.csv, limits.csv and truth.json (and telemetry.parquet's values).
"""

import csv
import json
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "mojoui"))
import lerobot as lr  # noqa: E402

DATA = Path.home() / "data" / "robot-scout"
CAMERA = "observation.images.left_external"
PAPER = DATA / "docs" / "droid-2403.12945v2.pdf"
VERB_MOST = 1000  # verbs used by fewer episodes are grouped as "other" (D-4727)
PAPER_NAME = "droid-paper.pdf"  # where each row comes from: the dataset's paper, in paper/ (a key link marks it, D-4712)
# libfranka "Robot and interface specifications" (frankaemika.github.io/docs/control_parameters.html): joint velocity limits
LIMITS = [(1, 2.1750), (2, 2.1750), (3, 2.1750), (4, 2.1750), (5, 2.6100), (6, 2.6100), (7, 2.6100)]
HERO = "F00118"  # the story's featured failure: AUTOLab 44bb9c36, 2023-11-21: the peach shirt, held over the box, falls at
# ~12.7 s and lands hanging on the box's outside wall (looked at frame by frame, D-4718); the rule below picks one only when
# it isn't in the data
LIMITS_SOURCE = "Franka Emika Panda, libfranka control parameters (frankaemika.github.io/docs/control_parameters.html)"


def missed(g):
    """The fingers closed on nothing: a closed span whose hold (median after it settles) is above 0.85."""
    for a, b in spans(g):
        s = g[a:b]
        if len(s) >= 4 and float(np.median(s[2:])) > 0.85:
            return 1
    return 0


def spans(g):
    out, start = [], None
    for f, k in lr.gripper_events(g):
        if k == "close":
            start = f
        elif start is not None:
            out.append((start, f))
            start = None
    if start is not None:
        out.append((start, len(g)))
    return out


def slipped(g):
    """A hold (median of its first frames) that closed further by more than 0.2 without opening: the object left the
    fingers."""
    for a, b in spans(g):
        s = g[a:b]
        if len(s) < 8:
            continue
        hold = float(np.median(s[3:min(len(s), 12)]))
        if hold < 0.8 and float(s[3:].max()) - hold > 0.2:
            return 1
    return 0


def episodes(datasets):
    """(dataset, episode, success, has_video) for every episode whose telemetry is on disk; one per uuid, the copy with
    video preferred; in data-file order (each file read once)."""
    best = {}
    for d in datasets:
        ds = lr.Dataset(d)
        ok = "failure" not in Path(d).name
        for e in ds.episodes(present_only=True):
            vid = CAMERA in e.clips and e.clips[CAMERA].path.exists()
            if e.uuid not in best or (vid and not best[e.uuid][3]):
                best[e.uuid] = (ds, e, ok, vid)
    return sorted(best.values(), key=lambda x: (str(x[1].data_path), x[1].index))


def cut(job):
    src, start, frames, fps, dst = job
    if dst.exists() and dst.stat().st_size > 0:
        return
    tmp = dst.with_suffix(".part.mp4")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", f"{start:.6f}", "-i", str(src), "-frames:v", str(frames),
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-g", "15", "-pix_fmt", "yuv420p", "-an",
                    "-r", f"{fps:g}", "-threads", "2", str(tmp)], check=True)
    tmp.rename(dst)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1]).resolve()
    datasets = sys.argv[2:] or sorted(str(p) for p in DATA.glob("droid720*") if (p / "meta" / "info.json").exists())
    (out / "clips").mkdir(parents=True, exist_ok=True)
    (out / "paper").mkdir(exist_ok=True)
    found = episodes(datasets)
    rows, tele, cuts = [], {k: [] for k in ["episode", "t"]}, []
    successes = {}  # (robot, date) → [(time, task)]
    for ds, e, ok, vid in found:
        lab, robot, date, time = lr.parse_uuid(e.uuid)
        if ok and e.tasks:
            successes.setdefault((robot, date), []).append((time, e.tasks[0]))
    for ds, e, ok, vid in found:
        lab, robot, date, time = lr.parse_uuid(e.uuid)
        ep = ("S" if ok else "F") + f"{e.index:05d}"
        frames = ds.frames(e)
        t = lr.telemetry(frames, ds.fps)
        n = len(t["t"])
        g = t["gripper"]
        ev = lr.gripper_events(g)
        closes = sum(1 for _, k in ev if k == "close")
        task, task_from = (e.tasks[0], "instruction") if e.tasks else ("", "")
        if not task and (robot, date) in successes:
            def secs(s):
                h, m, x = (int(v) for v in s.split(":"))
                return h * 3600 + m * 60 + x
            near = min(successes[(robot, date)], key=lambda p: (abs(secs(p[0]) - secs(time)), p[1]))
            task, task_from = near[1], "nearest success, same robot and day"
        clip = e.clips.get(CAMERA)
        rows.append({
            "episode": ep, "lab": lab, "robot": robot, "date": date, "outcome": "success" if ok else "failure", "success": 1 if ok else 0, "success_pct": 100 if ok else 0,
            "n": 1, "task": task.strip(), "verb": lr.verb_of(task) or "(none)",
            "duration_s": lr.finite(n / ds.fps, 2), "frames": n, "grasps": closes, "missed_grasp": missed(g),
            "regrasps": max(closes - 1, 0), "slipped": slipped(g), "peak_speed": lr.finite(t["speed"].max(), 3),
            "clip": f"clips/{ep}.mp4" if vid else "", "video": 1 if vid else 0, "source": PAPER_NAME, "task_from": task_from, "uuid": e.uuid,
        })
        if vid:
            cuts.append((clip.path, clip.start, n, ds.fps, out / "clips" / f"{ep}.mp4"))
        evcol = [""] * n
        for f, k in ev:
            evcol[f] = k
        tele["episode"].extend([ep] * n)
        for k, v in t.items():
            tele.setdefault(k, [])
            if k not in ("episode",):
                tele[k].extend(np.round(v, 5).tolist())
        tele.setdefault("gripper_event", []).extend(evcol)
    counts = {}
    for r in rows:
        counts[r["verb"]] = counts.get(r["verb"], 0) + 1
    for r in rows:  # (a verb fewer than VERB_MOST episodes use reads as "other": a chart by verb then compares real groups)
        if counts[r["verb"]] < VERB_MOST:
            r["verb"] = "other"
    rows.sort(key=lambda r: (r["outcome"] != "failure", r["lab"], r["date"], r["uuid"]))
    cols = list(rows[0].keys())
    with open(out / "fleet.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    names = [k for k in tele if k != "gripper_event"] + ["gripper_event"]
    table = pa.table({k: pa.array(tele[k]) for k in names})
    pq.write_table(table, out / "telemetry.parquet", compression="zstd")
    with open(out / "limits.csv", "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["joint", "limit_rad_s", "source"])
        for j, v in LIMITS:
            w.writerow([f"joint_vel_{j}", f"{v:.4f}", LIMITS_SOURCE])
    if PAPER.exists():
        shutil.copyfile(PAPER, out / "paper" / PAPER_NAME)
    workers = max(2, min(12, (os.cpu_count() or 4) // 2))
    if os.environ.get("ROBOT_CLIPS", "1") != "0":  # (ROBOT_CLIPS=0: the tables only, as the determinism check runs it)
        with ThreadPoolExecutor(workers) as pool:
            list(pool.map(cut, cuts))
    fails = [r for r in rows if r["success"] == 0]
    hero = [r for r in fails if r["episode"] == HERO and r["video"]]
    hero = hero or sorted((r for r in fails if r["video"] and r["slipped"] and r["frames"] >= 60), key=lambda r: (-r["frames"], r["episode"]))
    hero = hero or sorted((r for r in fails if r["video"] and r["missed_grasp"]), key=lambda r: (-r["frames"], r["episode"]))
    truth = {
        "episodes": len(rows), "failures": len(fails), "frames": sum(r["frames"] for r in rows),
        "labs": sorted({r["lab"] for r in rows}),
        "success_rate_by_lab": {lab: round(sum(r["success"] for r in rows if r["lab"] == lab) / max(1, sum(1 for r in rows if r["lab"] == lab)), 4)
                                for lab in sorted({r["lab"] for r in rows})},
        "success_rate_by_verb": {v: round(sum(r["success"] for r in rows if r["verb"] == v) / sum(1 for r in rows if r["verb"] == v), 4)
                                 for v in sorted({r["verb"] for r in rows})},
        "failures_by_kind": {"missed_grasp": sum(r["missed_grasp"] for r in fails), "slipped": sum(r["slipped"] for r in fails),
                             "regrasped": sum(1 for r in fails if r["regrasps"] > 0), "never_closed": sum(1 for r in fails if r["grasps"] == 0)},
        "slipped_failures": sorted(r["episode"] for r in fails if r["slipped"]),
        "regrasped_failures": sorted(r["episode"] for r in fails if r["regrasps"] > 0),
        "hero": hero[0]["episode"] if hero else (fails[0]["episode"] if fails else rows[0]["episode"]),
        "peak_speed_max": max(r["peak_speed"] for r in rows),
        "limits": {f"joint_vel_{j}": v for j, v in LIMITS},
        "datasets": [str(Path(d).name) for d in datasets],
    }
    (out / "truth.json").write_text(json.dumps(truth, indent=1, sort_keys=True) + "\n")
    (out / "ATTRIBUTION.txt").write_text(
        "Robot episodes: DROID (Khazatsky et al., 2024, arXiv 2403.12945), CC-BY-4.0, via the LeRobot 720p ports "
        "jnogga/droid_success and jnogga/droid_failure (CC-BY-4.0) on the Hugging Face Hub.\n"
        "paper/droid-paper.pdf: the DROID paper, arXiv 2403.12945v2, CC-BY-4.0.\n"
        "limits.csv: " + LIMITS_SOURCE + ".\n"
        "Derived columns (grasps, missed_grasp, regrasps, slipped, peak_speed, unwrapped rotation) are computed by "
        "scripts/robot_data.py with mojoui/lerobot.py.\n")
    print(f"{len(rows)} episodes ({len(fails)} failures), {truth['frames']} frames, labs {truth['labs']}; hero {truth['hero']}; "
          f"failures by kind {truth['failures_by_kind']}; wrote {out}")


if __name__ == "__main__":
    main()
