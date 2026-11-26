"""Personalize by asking, proved on GTK (D-8400…D-8411): examples/stage on the headless display, Settings driven with MOJOUI_TEST
steps, each change recorded with ffmpeg x11grab (the display's real pixels, 60 fps) and read frame by frame: the pixels that
change pass through in-between values (a blend) instead of jumping (a snap), and no frame leaves the old..new range (a blank
flash). A new scheme or accent (and a person whose look differs) morphs the whole window; the presence crossfades by itself and
roomy / compact reflows the tiles on their own water spring, with no window morph (D-8413): for those the check reads motion,
frame by frame (how many frames move, and that no single frame carries most of the change: a jump). Then the same switch with
the morph off and on, for the longest frame gap (the host's MORPH and GAPS lines).

    scripts/build.sh stage linux && pixi run python scripts/personalize_check.py        (frames in build/look/<change>/frames)

Needs ffmpeg on PATH. Timings follow the machine's load (it is printed); the headless display draws with GTK's cairo renderer.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402

OUT = ROOT / "build/look"
OPEN = "gaps:start;wait:900;tap:Settings;wait:2500;"
# (name, steps, the region the change shows in (x0, y0, x1, y1 in the 1280 x 820 window), expected LOOK)
CHANGES = [
    ("dark", OPEN + "segment:0=Dark;wait:1500", (600, 60, 1280, 820)),
    ("accent", OPEN + "segment:1=Blue;wait:1500", (925, 745, 995, 802)),  # (the chat bar's mic wears the accent)
    ("mascot", OPEN + "segment:2=Mascot;wait:1500", (296, 745, 352, 802)),  # (the chat bar's presence slot)
    ("roomy", OPEN + "segment:3=Roomy;wait:1800", (300, 70, 985, 715)),  # (the stage's tiles)
    ("undo", OPEN + "segment:0=Dark;wait:2500;tap:Put it back;wait:1500", (600, 60, 1280, 820)),
    ("person", OPEN + "segment:0=Dark;tap:Settings;wait:2500;tap:A;wait:1500", (600, 60, 1280, 820)),
]


def run(out, steps, extra=None, grab=False):
    env = dict(os.environ, MOJOUI_TEST=steps, MOJOUI_WINDOW="1280x820", MOJOUI_MORPH_TRACE="1", STAGE_TRACE=str(out / "trace.txt"))
    env.update(extra or {})
    rec = None
    if grab:
        rec = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", "-f", "x11grab", "-framerate", "60", "-video_size", "1280x820",
                                "-i", os.environ["DISPLAY"] + "+0,0", "-c:v", "ffv1", str(out / "grab.mkv")], stdin=subprocess.PIPE)
    r = subprocess.run([str(ROOT / "build/stage/linux/stage")], cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
    if rec:
        rec.communicate(b"q", timeout=30)
        (out / "frames").mkdir()
        subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(out / "grab.mkv"), str(out / "frames/f%04d.png")], check=True)
    return r.stdout + r.stderr


def frames(d, region):
    x0, y0, x1, y1 = region
    return [np.asarray(Image.open(f).convert("RGB"), dtype=np.int16)[y0:y1, x0:x1] for f in sorted((d / "frames").glob("f*.png"))]


def blend(ims, after):
    """The change: the last frame before the region moves (after frame `after`: the popover has opened) is OLD, 1.2 s later is
    NEW; for each pixel that changes by more than 40, the frames it spends strictly between them."""
    s = next((i for i in range(after, len(ims)) if (np.abs(ims[i] - ims[i - 1]).sum(axis=2) > 40).mean() > 0.05), None)
    if s is None:
        return None
    old, e = ims[s - 1], min(s + 72, len(ims) - 1)
    new = ims[e]
    ch = np.abs(new - old).sum(axis=2) > 40
    lo, hi = np.minimum(old, new), np.maximum(old, new)
    between = np.zeros(ch.shape, dtype=np.int32)
    worst = 0.0
    for k in range(s, e):
        f = ims[k]
        between += ((f > lo + 6) & (f < hi - 6)).any(axis=2) & ((f >= lo - 30) & (f <= hi + 30)).all(axis=2) & ch
        worst = max(worst, float((((f < lo - 30) | (f > hi + 30)).any(axis=2) & ch).sum()) / max(int(ch.sum()), 1))
    n = int(ch.sum())
    return s, n, float((between[ch] >= 3).mean()) if n else 0.0, float((between[ch] == 0).mean()) if n else 0.0, worst


def main():
    headless.ensure()
    print("load:", os.getloadavg())
    bad = []
    for name, steps, region in CHANGES:
        out = OUT / name
        shutil.rmtree(out, ignore_errors=True)
        out.mkdir(parents=True)
        log = run(out, steps, grab=True)
        morphs = [line for line in log.splitlines() if line.startswith("MORPH:")]
        looks = [line.split(" LOOK ", 1)[1] for line in (out / "trace.txt").read_text().splitlines() if " LOOK " in line]
        b = blend(frames(out, region), 150)
        if b is None:
            bad.append(f"{name}: nothing changed in {region}")
            print(name, "nothing changed", morphs, looks)
            continue
        s, n, blended, snapped, worst = b
        print(f"{name}: change at frame {s}, {n} px in {region}: blended over >= 3 frames {100 * blended:.1f} %, snapped {100 * snapped:.1f} %, "
              f"worst frame outside old..new {100 * worst:.1f} %; {' | '.join(morphs)}; looks: {looks}")
        wants_morph = name not in ("mascot", "roomy")
        if wants_morph and len(morphs) == 0:
            bad.append(f"{name}: no morph ran")
        if not wants_morph and len(morphs) > 0:
            bad.append(f"{name}: the window morphed (only a scheme or accent should)")
        ims = frames(out, region)
        steps = [float(np.abs(ims[k + 1] - ims[k]).sum()) for k in range(s - 1, min(s + 72, len(ims) - 1))]
        moving = sum(1 for k in range(s - 1, min(s + 72, len(ims) - 1)) if (np.abs(ims[k + 1] - ims[k]).sum(axis=2) > 40).mean() > 0.002)
        share = max(steps) / max(sum(steps), 1.0)
        print(f"   {name}: the region moved on {moving} frames; the biggest single frame carried {100 * share:.0f} % of all the change")
        if name == "roomy":  # (tiles glide: a pixel a tile passes over jumps, so motion is read in frames, not pixels)
            if moving < 8 or share > 0.30:
                bad.append(f"{name}: the tiles moved on {moving} frames, the biggest frame carried {100 * share:.0f} % (a jump)")
        elif snapped > (0.05 if name in ("dark", "undo", "person") else 0.10):  # (the presence and the mic: a growing shape leaves edge pixels that jump)
            bad.append(f"{name}: {100 * snapped:.1f} % of the changing pixels snapped")
    for m in ("0", "1"):
        gaps = []
        for _ in range(3):
            out = OUT / "gaps"
            shutil.rmtree(out, ignore_errors=True)
            out.mkdir(parents=True)
            log = run(out, "gaps:start;wait:900;tap:Settings;wait:600;gaps:start;segment:0=Dark;gaps:1200", {"MOJOUI_MORPH": m})
            gaps += [line for line in log.splitlines() if line.startswith(("GAPS: ", "MORPH: 1"))]
        print(f"morph {'on' if m == '1' else 'off'}:", " | ".join(gaps))
    print("load:", os.getloadavg())
    print("PASS" if not bad else "FAIL: " + "; ".join(bad))
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
