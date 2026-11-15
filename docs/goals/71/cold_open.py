"""Goal 71 M4: the cold open, recorded from the live app on Linux and cut scene by scene (docs/goals/71/cold-open.md).

    pixi run python docs/goals/71/cold_open.py <index.parquet> [out.mp4]       (default build/g71/cold-open.mp4)

1. Learning runs (scripts/live.py, 1920x1080, real clicks) find where each control sits.
2. The take: one recording of the window while a person's clicks play: show the SO-100 sorting clip, back, pick the three
   LIBERO drawer clips, More like these, Export. Each event's time in the take is known from the waits.
3. The cut (ffmpeg): five scenes from the take, a caption on each (Inter, an opaque bar: omxqua's texture), scene 2 zoomed
   on the pool's line, scene 3's end zoomed on the hero card, the payoff (the export's toast) frozen.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from demo_drive import boxes, reports, centre, live  # noqa: E402

OUT = ROOT / "build/g71/cold"
FONT = ROOT / "mojoui/hosts/static/fonts/Inter-SemiBold.ttf"
SIZE = "1920x1080"
SAMPLE = ["lerobot/svla_so100_sorting:7", "lerobot/libero:14", "lerobot/libero:15", "lerobot/libero:16"]
# (scene, its length in the film, its caption) — the words are cold-open.md's
SCENES = [
    (5.0, "Hours of robot video. Which clips show the same task?"),
    (4.0, "1,851 episodes, 8.3 h, 4 LeRobot datasets: opened where they sit"),
    (7.0, "Show one clip: every episode like it, ranked in ~1 ms on the GPU"),
    (9.0, "Pick a few: More like these. 24 of 24 the same task"),
    (9.0, "Export: a LeRobot v3 dataset. LeRobotDataset(root=...) loads it"),
]


def run_live(cmds, env, name):
    import demo_drive

    demo_drive.APP = ROOT / "build/omxplorer/linux/omxplorer"
    r = subprocess.run(["pixi", "run", "python", "scripts/live.py", str(demo_drive.APP), ";".join(cmds), "--size", SIZE,
                        *sum((["--env", f"{k}={v}"] for k, v in env.items()), [])], cwd=ROOT, capture_output=True, text=True, timeout=900)
    text = r.stdout + r.stderr
    (OUT / f"{name}.txt").write_text(text)
    return text


def ff(args):
    r = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *args], capture_output=True, text=True)
    if r.returncode:
        sys.exit("ffmpeg: " + r.stderr[-800:])


def esc(t):
    return t.replace("\\", "\\\\").replace(":", "\\:").replace("'", "’").replace(",", "\\,")


def caption(t):
    return (f"drawtext=fontfile={FONT}:text='{esc(t)}':fontsize=46:fontcolor=white:box=1:boxcolor=0x14171C:boxborderw=26:"
            f"x=(w-text_w)/2:y=h-text_h-86")


def zoom(b, pad=40):
    """A 16:9 crop around box b (x, y, w, h), scaled to the frame."""
    x, y, w, h = b
    cw = max(w + 2 * pad, (h + 2 * pad) * 16 / 9, 640)
    ch = cw * 9 / 16
    cx = min(max(0, x + w / 2 - cw / 2), 1920 - cw)
    cy = min(max(0, y + h / 2 - ch / 2), 1080 - ch)
    return f"crop={int(cw)}:{int(ch)}:{int(cx)}:{int(cy)},scale=1920:1080:flags=lanczos"


def main(index, out_mp4):
    OUT.mkdir(parents=True, exist_ok=True)
    b = subprocess.run(["scripts/build.sh", "omxplorer", "linux"], cwd=ROOT, capture_output=True, text=True, timeout=3600)
    if b.returncode:
        sys.exit("build: " + (b.stdout + b.stderr)[-400:])
    cfg = OUT / "config"
    cfg.mkdir(exist_ok=True)
    (cfg / "settings.txt").write_text("appearance=light\n")
    exports = OUT / "exports"
    subprocess.run(["rm", "-rf", str(exports)])  # (this script's own scratch folder under build/g71)
    env = {"OMX_ROBOT_POOL": index, "OMX_CONFIG": str(cfg), "OMX_ROBOT_SAMPLE": ",".join(SAMPLE), "OMX_ROBOT_EXPORTS": str(exports),
           "OMX_DOCUMENTS": str(OUT)}
    start = ["wait:6000", "report"]
    t = run_live(start, env, "learn1")
    b0 = boxes(t)
    pool_line, clip0 = b0["robot-pool-line"], b0["robot-clip-0"]
    t = run_live(start + [f"click:{centre(clip0)}", "wait:3000", "report"], env, "learn2")
    b1 = boxes(reports(t)[-1])
    back, hero = b1["robot-back"], b1["robot-hero-card"]
    t = run_live(start + [f"click:{centre(clip0)}", "wait:3000", f"click:{centre(back)}", "wait:1500", "report"], env, "learn3")
    b2 = boxes(reports(t)[-1])
    picks = [b2[f"robot-clip-pick-{i}"] for i in (1, 2, 3)]
    more, export = b2["robot-more"], b2["robot-export"]
    # the take: event times (seconds from the recording's start) follow from the waits
    raw = OUT / "take.mp4"
    take = ["wait:6000", f"record:{raw}", "wait:3000", f"glideto:{centre(clip0)}", "wait:2400", f"click:{centre(clip0)}", "wait:5600",
            f"glideto:{centre(back)}", "wait:400", f"click:{centre(back)}", "wait:1200"]
    for p in picks:
        take += [f"glideto:{centre(p)}", "wait:350", f"click:{centre(p)}", "wait:500"]
    take += [f"glideto:{centre(more)}", "wait:400", f"click:{centre(more)}", "wait:5200", f"glideto:{centre(export)}", "wait:400",
             f"click:{centre(export)}", "wait:5000", "stoprecord"]
    run_live(take, env, "take")
    if not raw.exists():
        sys.exit("no take recorded")
    # the take's moments: 0 start, 5.2 the clip shown (3.0 + glide 0.2 + 2.4 ... ), etc.
    t_click = 3.0 + 0.2 + 2.4
    t_back = t_click + 5.6
    t_more = t_back + 0.2 + 0.4 + 1.2 + 3 * (0.2 + 0.35 + 0.5) + 0.2 + 0.4
    t_export = t_more + 5.2 + 0.2 + 0.4
    segs = OUT / "segs"
    segs.mkdir(exist_ok=True)
    parts = []

    def cut(i, t0, t1, filters, hold=0.0):
        p = segs / f"s{i}.mp4"
        vf = ",".join(filters + ([f"tpad=stop_mode=clone:stop_duration={hold}"] if hold > 0 else []))
        ff(["-ss", f"{t0:.2f}", "-to", f"{t1:.2f}", "-i", str(raw), "-vf", vf + ",fps=30,format=yuv420p", "-an", "-c:v", "libx264", "-crf", "18",
            "-preset", "medium", str(p)])
        parts.append(p)

    d = [s[0] for s in SCENES]
    # 1: the pool page, the question over it (first 2 s held still, then the page)
    cut(1, 0.0, d[0] - 2.0, [f"tpad=start_mode=clone:start_duration=2", caption(SCENES[0][1])])
    # 2: zoomed on the pool's line
    cut(2, d[0] - 2.0, d[0] - 2.0 + d[1] - 1.0, [zoom(pool_line, 60), caption(SCENES[1][1])], hold=1.0)
    # 3: the click and the ranked results, then the hero card zoomed (the time it took)
    cut(3, t_click - 0.6, t_click + d[2] - 2.6, [caption(SCENES[2][1])])
    p3 = segs / "s3b.mp4"
    ff(["-ss", f"{t_back - 0.3:.2f}", "-i", str(raw), "-frames:v", "1", "-vf", zoom(hero, 30) + "," + caption(SCENES[2][1]), str(segs / "hero.png")])
    ff(["-loop", "1", "-t", "2.0", "-i", str(segs / "hero.png"), "-vf", "fps=30,format=yuv420p", "-c:v", "libx264", "-crf", "18", str(p3)])
    parts.append(p3)
    # 4: back, three picks, More like these
    cut(4, t_back - 0.2, t_back - 0.2 + d[3], [caption(SCENES[3][1])])
    # 5: Export, the toast, frozen
    cut(5, t_export - 0.6, t_export + 4.4, [caption(SCENES[4][1])], hold=d[4] - 5.0)
    lst = segs / "list.txt"
    lst.write_text("".join(f"file '{p}'\n" for p in parts))
    ff(["-f", "concat", "-safe", "0", "-i", str(lst), "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(out_mp4)])
    made = sorted(str(p) for p in exports.iterdir()) if exports.exists() else []
    starts, at = [], 0.0
    for s in d:
        starts.append(round(at, 1))
        at += s
    info = {"film": str(out_mp4), "scene_starts": starts, "length": at, "exports": made,
            "boxes": {"pool_line": pool_line, "hero": hero}}
    (OUT / "cold.json").write_text(json.dumps(info, indent=1))
    print(json.dumps(info, indent=1))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else str(ROOT / "build/g71/cold-open.mp4"))
