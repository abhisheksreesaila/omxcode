"""Goal 71 M3: omxplorer's Robot search driven like a person would, and read back from the view tree.

    pixi run python docs/goals/71/demo_drive.py <out-dir> <picks.json> <index.parquet>

Desktop (1440x900): GTK on the headless display with real pointer clicks (scripts/live.py, XTest). The page starts from
the clips the picks name (OMX_ROBOT_SAMPLE: picks["one"][0], then picks["three"][0]'s three): click the first poster,
read the ranking the screen shows (each result poster's tooltip names its episode and score), go back, press Pick on the
three, More like these, read that ranking, Export, read the toast. Click positions come from the report of a run that
stopped one step earlier (the layout is the same each run: same sample, same size). Phone (390x844): the web host in
Chromium (a GTK window can't be narrower than its menu bar), tap the first poster, the rects of every tagged view.
Writes <out-dir>/drive.json (docs/goals/71-check.py M3 reads it) and the shots.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
APP = ROOT / "build/omxplorer/linux/omxplorer"


def boxes(text):
    """BOX: tag x y w h -> {tag: (x, y, w, h)} (the last report's)."""
    out = {}
    for m in re.finditer(r"^BOX: (\S+) ([\d.-]+) ([\d.-]+) ([\d.-]+) ([\d.-]+)$", text, re.M):
        out[m.group(1)] = tuple(float(m.group(i)) for i in range(2, 6))
    return out


def reports(text):
    """The live run's reports, in order (each starts with the page's pool line box)."""
    parts = re.split(r"(?m)^(?=BOX: robot-pool-line )", text)
    return [p for p in parts if p.startswith("BOX: robot-pool-line ")]


def centre(b):
    x, y, w, h = b
    return f"{int(x + w / 2)},{int(y + h / 2)}"


def ranking(text):
    """The results as the screen shows them: each result poster's tooltip, in grid order."""
    got = {}
    for m in re.finditer(r"^TIP: robot-clip-(\d+) = Episodes like (\S+) #(\d+) · score ([\d.]+)$", text, re.M):
        got[int(m.group(1))] = [f"{m.group(2)}:{m.group(3)}", float(m.group(4))]
    return [got[i] for i in sorted(got)]


def overflow(bx, width):
    """Texts and controls outside their tile or card, or past the window's right edge."""
    bad = []
    for tag, (x, y, w, h) in bx.items():
        if x + w > width + 1:
            bad.append(f"{tag} ends at {x + w:.0f} > {width}")
        m = re.match(r"robot-clip-(?:title-|pick-)?(\d+)$", tag)
        card = bx.get(f"robot-clip-tile-{m.group(1)}") if m else (bx.get("robot-hero-card") if tag in ("robot-hero", "robot-hero-title", "robot-took", "robot-back", "robot-hero-pick") else None)
        if card:
            cx, cy, cw, ch = card
            if x < cx - 1 or y < cy - 1 or x + w > cx + cw + 1 or y + h > cy + ch + 1:
                bad.append(f"{tag} {x:.0f},{y:.0f} {w:.0f}x{h:.0f} outside its card {cx:.0f},{cy:.0f} {cw:.0f}x{ch:.0f}")
    return bad


def live(cmds, env, out):
    r = subprocess.run(["pixi", "run", "python", "scripts/live.py", str(APP), ";".join(cmds), "--size", "1440x900",
                        *sum((["--env", f"{k}={v}"] for k, v in env.items()), [])], cwd=ROOT, capture_output=True, text=True, timeout=600)
    text = r.stdout + r.stderr
    Path(out).write_text(text)
    return text


def light(png):
    """Liquid light: the page's background (a strip under the menu bar) is bright."""
    from PIL import Image

    im = Image.open(png).convert("L")
    w, _ = im.size
    px = [im.getpixel((x, 60)) for x in range(w // 3, 2 * w // 3, 7)]
    return sum(px) / len(px) > 200


def main(out, picks_path, index):
    out = Path(out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    pk = json.loads(Path(picks_path).read_text())
    for p in ("linux", "web"):
        b = subprocess.run(["scripts/build.sh", "omxplorer", p], cwd=ROOT, capture_output=True, text=True, timeout=3600)
        if b.returncode:
            sys.exit(f"build {p}: {(b.stdout + b.stderr)[-500:]}")
    cfg = out / "config"
    cfg.mkdir(exist_ok=True)
    (cfg / "settings.txt").write_text("appearance=light\n")
    exports = out / "exports"
    if exports.exists():
        subprocess.run(["rm", "-r", str(exports)])  # (this run's own folder under build/g71: a fresh export each run)
    sample = [pk["one"][0]] + pk["three"][0]
    env = {"OMX_ROBOT_POOL": index, "OMX_CONFIG": str(cfg), "OMX_ROBOT_SAMPLE": ",".join(sample), "OMX_ROBOT_EXPORTS": str(exports),
           "OMX_DOCUMENTS": str(out / "docs")}
    (out / "docs").mkdir(exist_ok=True)
    start = ["wait:5000", "report"]
    # learn each step's click position from a run that stops just before it
    t = live(start, env, out / "run1.txt")
    clip0 = boxes(t)["robot-clip-0"]
    steps = start + [f"click:{centre(clip0)}", "wait:3000", "report", f"shot:{out / 'desktop-one.png'}"]
    t = live(steps, env, out / "run2.txt")
    back = boxes(reports(t)[-1])["robot-back"]
    steps += [f"click:{centre(back)}", "wait:1500", "report"]
    t = live(steps, env, out / "run3.txt")
    b3 = boxes(reports(t)[-1])
    steps += [f"click:{centre(b3[f'robot-clip-pick-{i}'])}" for i in (1, 2, 3)] + ["wait:800", "report"]
    t = live(steps, env, out / "run4.txt")
    more = boxes(reports(t)[-1])["robot-more"]
    steps += [f"click:{centre(more)}", "wait:3000", "report", f"shot:{out / 'desktop-more.png'}"]
    t = live(steps, env, out / "run5.txt")
    exp = boxes(reports(t)[-1])["robot-export"]
    steps += [f"click:{centre(exp)}", "wait:5000", "report", f"shot:{out / 'desktop.png'}"]
    t = live(steps, env, out / "run6.txt")
    rs = reports(t)
    if len(rs) < 6:  # (start, the clip, back, the picks, More like these, Export; live.py's own report when the app ends comes after)
        sys.exit(f"the final run made {len(rs)} reports, want 6: {t[-800:]}")
    r0, r1, _, _, r3, r4 = rs[:6]  # (r3: after More like these; r4: after Export)
    line = next((m.group(1) for m in re.finditer(r"^LABEL: (\S+ episodes · .*)$", r0, re.M)), "")
    took = re.search(r"^LABEL: Ranked [\d,]+ episodes in ([\d.]+) ms", r1, re.M)
    hero = re.search(r"^TIP: robot-clip-0 = Episodes like (\S+) #(\d+)", r0, re.M)
    toast = re.search(r"^TOAST: (.*)$", r4, re.M)
    folders = sorted(str(p) for p in exports.iterdir()) if exports.exists() else []
    theme = re.search(r"^THEME: (\S+)", t, re.M)
    d = {"line": {"episodes": int(line.split()[0].replace(",", "")) if line else 0, "text": line},
         "clip": f"{hero.group(1)}:{hero.group(2)}" if hero else None,
         "like_one": ranking(r1), "search_ms": float(took.group(1)) if took else None,
         "like_three": ranking(r3), "export": folders, "toast": toast.group(1) if toast else "",
         "theme": (theme.group(1) + "-light") if theme and theme.group(1) == "liquid" and light(out / "desktop.png") else (theme.group(1) if theme else None),
         "shots": {"desktop": {"path": str(out / "desktop-one.png"), "size": "1440x900", "overflow": overflow(boxes(r1), 1440) + overflow(boxes(r3), 1440)}}}
    # phone: the web host at 390 x 844
    import drive

    rects = out / "phone-rects.txt"
    r, wout = drive.web_run(ROOT / "build/omxplorer/web", "wait:6000;tap:robot-clip-0;wait:4000", shot=str(out / "phone.png"), viewport=(390, 844),
                            rects=str(rects), env=env)
    (out / "phone.txt").write_text(wout)
    pb = {}
    for m in re.finditer(r"^\S+ #(\S+) @ (-?\d+),(-?\d+) (\d+)x(\d+)$", rects.read_text() if rects.exists() else "", re.M):
        pb[m.group(1)] = tuple(float(m.group(i)) for i in range(2, 6))
    ok = r.returncode == 0 and "robot-hero" in pb
    d["shots"]["phone"] = {"path": str(out / "phone.png"), "size": "390x844",
                           "overflow": overflow(pb, 390) if ok else [f"the phone run didn't show a result (exit {r.returncode}): {wout[-300:]}"]}
    (out / "drive.json").write_text(json.dumps(d, indent=1))
    print(json.dumps({k: (v if k not in ("like_one", "like_three") else v[:3]) for k, v in d.items()}, indent=1))


if __name__ == "__main__":
    main(*sys.argv[1:4])
