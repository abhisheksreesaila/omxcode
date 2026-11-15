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
SIZE = "1440x810"   # recorded at 1440x810 and scaled to 1920x1080: the UI reads at film size, never a shrunk window
W, H = 1440, 810
SAMPLE = ["lerobot/svla_so100_sorting:7", "lerobot/libero:14", "lerobot/libero:15", "lerobot/libero:16"]
DRAWER_TASK = "put the black bowl in the bottom drawer of the cabinet and close it"   # libero 14, 15 and 16's task
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


def caption(t, top=False):
    """The scene's caption on an opaque bar, at the bottom (or the top, when the payoff sits at the bottom)."""
    return (f"drawtext=fontfile={FONT}:text='{esc(t)}':fontsize=46:fontcolor=white:box=1:boxcolor=0x14171C:boxborderw=26:"
            f"x=(w-text_w)/2:y=" + ("86" if top else "h-text_h-86"))


def zoom(b, pad=40):
    """A 16:9 crop around box b (x, y, w, h), scaled to the frame."""
    x, y, w, h = b
    cw = max(w + 2 * pad, (h + 2 * pad) * 16 / 9, 640)
    ch = cw * 9 / 16
    cx = min(max(0, x + w / 2 - cw / 2), W - cw)
    cy = min(max(0, y + h / 2 - ch / 2), H - ch)
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
    # a real arrow, not X's bare "x", where no widget sets a cursor (the headless display has no window manager)
    import os
    sys.path.insert(0, str(ROOT / "scripts"))
    import headless

    headless.ensure()
    subprocess.run(["xsetroot", "-cursor_name", "left_ptr"], env=dict(os.environ, XCURSOR_THEME="Adwaita", XCURSOR_SIZE="24"))
    gtkcfg = OUT / "xdg/gtk-4.0"
    gtkcfg.mkdir(parents=True, exist_ok=True)
    (gtkcfg / "settings.ini").write_text("[Settings]\ngtk-cursor-theme-name=Adwaita\ngtk-cursor-theme-size=24\n")
    env.update({"XCURSOR_THEME": "Adwaita", "XCURSOR_SIZE": "24", "XDG_CONFIG_HOME": str(OUT / "xdg")})
    # the take's commands, built step by step: each control's place is read from a run of the take so far (picking adds a
    # Clear button and moves More like these and Export; D-7112)
    raw = OUT / "take.mp4"
    take = ["wait:6000", f"record:{raw}", "wait:3000"]
    marks = {}

    def at_end(name):
        t = run_live([c for c in take if not c.startswith("record:")] + ["wait:400", "report"], env, name)
        return boxes(reports(t)[-1])

    def secs():
        return sum(float(c.split(":")[1]) / 1000 for c in take[take.index(f"record:{raw}") + 1:] if c.startswith("wait:")) + 0.2 * sum(
            c.startswith("glideto:") for c in take[take.index(f"record:{raw}") + 1:])

    b = at_end("learn1")
    pool_line, clip0 = b["robot-pool-line"], b["robot-clip-0"]
    take += [f"glideto:{centre(clip0)}", "wait:1600"]
    marks["click"] = secs()
    take += [f"click:{centre(clip0)}", "wait:5600"]
    b = at_end("learn2")
    back, hero = b["robot-back"], b["robot-hero-card"]
    take += [f"glideto:{centre(back)}", "wait:300"]
    marks["back"] = secs()
    take += [f"click:{centre(back)}", "wait:1400"]
    for k in (1, 2, 3):
        b = at_end(f"learn-pick{k}")
        p = b[f"robot-clip-pick-{k}"]
        take += [f"glideto:{centre(p)}", "wait:300", f"click:{centre(p)}", "wait:600"]
    b = at_end("learn-more")
    zone = [b[f"robot-clip-tile-{k}"] for k in (1, 2, 3)] + [b["robot-more"]]   # scene 4's zoom: the three picks and More like these
    zx, zy = min(z[0] for z in zone), min(z[1] for z in zone)
    pick_zone = (zx, zy, max(z[0] + z[2] for z in zone) - zx, max(z[1] + z[3] for z in zone) - zy)
    take += [f"glideto:{centre(b['robot-more'])}", "wait:400"]
    marks["more"] = secs()
    take += [f"click:{centre(b['robot-more'])}", "wait:5200"]
    b = at_end("learn-export")
    take += [f"glideto:{centre(b['robot-export'])}", "wait:400"]
    marks["export"] = secs()
    take += [f"click:{centre(b['robot-export'])}", "wait:9000", "stoprecord"]
    t = run_live(take + ["report"], env, "take")
    if not raw.exists():
        sys.exit("no take recorded")
    fin = reports(t)
    toast = re.search(r"^TOAST: (.*)$", t, re.M)
    more_ok = bool(re.search(r"^LABEL: More like these 3$", t, re.M))
    # scene 4's caption says 24 of 24 the same task: the take's last report must show it (the 24 result tiles' titles; the
    # hero card's lines start "· ")
    same = len(re.findall(r"^LABEL: " + re.escape(DRAWER_TASK) + "$", t, re.M))
    if not more_ok or same != 24:
        sys.exit(f"the take doesn't show the caption's claim: More like these 3 {more_ok}, {same} of 24 results '{DRAWER_TASK}'")
    # the real moments (live.py's LIVE-AT lines: each step's time into the recording), over the waits' sums
    at = {}
    for m in re.finditer(r"^LIVE-AT: ([\d.]+) click:(\S+)$", t, re.M):
        at.setdefault(m.group(2), []).append(float(m.group(1)))
    clicks = [float(m.group(1)) for m in re.finditer(r"^LIVE-AT: ([\d.]+) click:", t, re.M)]
    if len(clicks) != 7:  # (the clip, back, three picks, More like these, Export)
        sys.exit(f"the take made {len(clicks)} clicks, want 7")
    marks = {"click": clicks[0], "back": clicks[1], "more": clicks[5], "export": clicks[6]}
    t_click, t_back, t_more, t_export = marks["click"], marks["back"], marks["more"], marks["export"]
    segs = OUT / "segs"
    segs.mkdir(exist_ok=True)
    parts = []
    up = "scale=1920:1080:flags=lanczos"

    def cut(i, t0, t1, filters, hold=0.0):
        p = segs / f"s{i}.mp4"
        vf = ",".join(filters + ([f"tpad=stop_mode=clone:stop_duration={hold}"] if hold > 0 else []))
        ff(["-ss", f"{t0:.2f}", "-to", f"{t1:.2f}", "-i", str(raw), "-vf", vf + ",fps=30,format=yuv420p", "-an", "-c:v", "libx264", "-crf", "18",
            "-preset", "medium", str(p)])
        parts.append(p)

    def still(i, t, filters, length):
        png = segs / f"still{i}.png"
        p = segs / f"s{i}.mp4"
        ff(["-ss", f"{t:.2f}", "-i", str(raw), "-frames:v", "1", "-vf", ",".join(filters), str(png)])
        ff(["-loop", "1", "-t", f"{length}", "-i", str(png), "-vf", "fps=30,format=yuv420p", "-c:v", "libx264", "-crf", "18", str(p)])
        parts.append(p)

    d = [s[0] for s in SCENES]
    # 1: the pool page, the question over it (first 2 s held still, then the page)
    cut(1, 0.0, d[0] - 2.0, [up, "tpad=start_mode=clone:start_duration=2", caption(SCENES[0][1])])
    # 2: zoomed on the pool's line
    cut(2, d[0] - 2.0, d[0] - 2.0 + d[1] - 1.0, [zoom(pool_line, 60), caption(SCENES[1][1])], hold=1.0)
    # 3: the click and the ranked results, then the hero card zoomed (the time it took)
    cut(3, t_click - 0.6, t_click + d[2] - 2.6, [up, caption(SCENES[2][1])])
    still("3b", t_back - 0.4, [zoom(hero, 30), caption(SCENES[2][1])], 2.0)
    # 4: back, three picks, More like these
    cut(4, t_back - 0.2, t_back - 0.2 + d[3], [zoom(pick_zone, 24), caption(SCENES[3][1])])
    # 5: Export, then the toast zoomed and frozen (the payoff)
    cut(5, t_export - 0.6, t_export + 3.4, [up, caption(SCENES[4][1])])
    still("5b", t_export + 7.0, [f"crop=960:540:{(W - 960) // 2}:{H - 540}", up, caption(SCENES[4][1], top=True)], d[4] - 4.0)
    lst = segs / "list.txt"
    lst.write_text("".join(f"file '{p}'\n" for p in parts))
    ff(["-f", "concat", "-safe", "0", "-i", str(lst), "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(out_mp4)])
    made = sorted(str(p) for p in exports.iterdir()) if exports.exists() else []
    starts, at = [], 0.0
    for s in d:
        starts.append(round(at, 1))
        at += s
    info = {"film": str(out_mp4), "scene_starts": starts, "length": at, "exports": made, "toast": toast.group(1) if toast else "", "same_task": same,
            "more_like_three": more_ok, "marks": marks,
            "boxes": {"pool_line": pool_line, "hero": hero}}
    (OUT / "cold.json").write_text(json.dumps(info, indent=1))
    print(json.dumps(info, indent=1))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else str(ROOT / "build/g71/cold-open.mp4"))
