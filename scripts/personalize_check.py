"""Personalize by asking, proved on GTK (D-8400…D-8411, round 2 D-8418…D-8425): examples/stage on the headless display, Settings
driven with MOJOUI_TEST steps, each change recorded with ffmpeg x11grab (the display's real pixels, 60 fps) and read frame by
frame: the pixels that change pass through in-between values (a blend) instead of jumping (a snap), and no frame leaves the
old..new range (a blank flash). A new scheme or accent (and a person whose look differs) morphs the whole window; the presence
and roomy / compact move on their own springs, with no window morph (D-8413): for those the check reads motion, frame by frame
(how many frames move, and that no single frame carries most of the change: a jump). Then the same switch with the morph off and
on, for the longest frame gap (the host's MORPH and GAPS lines).

Round 2 (D-8418…D-8425) adds what the owner asked for after the first pictures:
  the mascot on a desktop perches full-size under Pinned (the chat bar keeps the orb), on a phone it sits in the chat bar;
  an accent shows in the stage's ground and the active avatar's ring, not only the mic (pixels read before and after);
  the accent is a row of swatches (tap:Blue) in a popover about 300 pt wide, headed by whose look it is;
  the active person is ringed (All before, A after);
  the morph's fade passes the middle quickly: the frames that are mostly half-way ("mid-wash") are counted, and compared with
  the first round's frames when build/look-base/<change>/frames holds them.

    scripts/build.sh stage linux && pixi run python scripts/personalize_check.py        (frames in build/look/<change>/frames)
    pixi run python scripts/personalize_check.py accent person                          (only those changes, no frame-gap runs)

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
BASE = ROOT / "build/look-base"  # (the first round's frames, when kept: the mid-wash comparison)
OPEN = "gaps:start;wait:900;tap:Settings;wait:2500;"
DESK = "1280x820"
PHONE = "390x844"
# (name, steps, the region the change shows in (x0, y0, x1, y1 in the window), window)
CHANGES = [
    ("dark", OPEN + "segment:0=Dark;wait:1500", (600, 60, 1280, 820), DESK),
    ("accent", OPEN + "tap:Blue;wait:1500", (925, 745, 995, 802), DESK),  # (the mic; the ground and the ring are read as pixels)
    ("mascot", OPEN + "segment:1=Mascot;wait:1500", (40, 540, 250, 760), DESK),  # (the perch under Pinned, D-8421)
    ("mascot-phone", OPEN + "segment:1=Mascot;wait:1500", (14, 772, 80, 838), PHONE),  # (a phone: the chat bar's slot)
    ("roomy", OPEN + "segment:2=Roomy;wait:1800", (300, 70, 985, 715), DESK),  # (the stage's tiles)
    ("undo", OPEN + "segment:0=Dark;wait:2500;tap:Put it back;wait:1500", (600, 60, 1280, 820), DESK),
    ("person", OPEN + "segment:0=Dark;tap:Settings;wait:2500;tap:A;wait:1500", (600, 60, 1280, 820), DESK),
]
GROUND_AT = (297, 600)  # a pixel of the stage's ground (the panel's padding, left of the tiles, below the popover) at 1280 x 820
RING_ALL = (14, 33)  # the left edge of All's ring (the avatar is 18..55 at y 14..52; its ring 2 pt out, 2 pt wide)
RING_A = (60, 33)  # the left edge of A's ring
GROUND = {"light": (245, 245, 247)}  # tokens.css --oq-counter-ground
BLUE = (10, 127, 224)  # the Counter palette's series[1] by day (#0a7fe0)


def run(out, steps, size, extra=None, grab=False):
    w, h = size.split("x")
    env = dict(os.environ, MOJOUI_TEST=steps, MOJOUI_WINDOW=size, MOJOUI_MORPH_TRACE="1", STAGE_TRACE=str(out / "trace.txt"))
    env.update(extra or {})
    rec = None
    if grab:
        rec = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", "-f", "x11grab", "-framerate", "60", "-video_size", f"{w}x{h}",
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


def mid_wash(ims, after):
    """The morph's grey frames: how many frames have most (> 50 %) of the changing pixels between 30 % and 70 % of their way from
    old to new (light into dark: the flat mid-grey), and the time from the first changed frame to the last of those."""
    s = next((i for i in range(after, len(ims)) if (np.abs(ims[i] - ims[i - 1]).sum(axis=2) > 40).mean() > 0.05), None)
    if s is None:
        return None
    old, e = ims[s - 1].astype(np.float32), min(s + 72, len(ims) - 1)
    new = ims[e].astype(np.float32)
    d = (new - old).sum(axis=2)
    ch = np.abs(d) > 120  # (pixels that change a lot: the ground, the cards; a mic's edge doesn't count)
    if not ch.any():
        return None
    n = 0
    for k in range(s, e):
        t = ((ims[k].astype(np.float32) - old).sum(axis=2)[ch]) / d[ch]
        if ((t > 0.3) & (t < 0.7)).mean() > 0.5:
            n += 1
    return n


def px(d, k, at):
    """Pixel `at` of frame k (counting from 1) of a change's recording."""
    return tuple(int(v) for v in Image.open(d / "frames" / f"f{k:04d}.png").convert("RGB").getpixel(at))


def last_lit(d):
    """The last frame (counting from 1) recorded while the app was still on screen, a few frames before it closed (the recording
    runs on over a black display until it is stopped)."""
    files = sorted((d / "frames").glob("f*.png"))
    for k in range(len(files), 0, -1):
        if np.asarray(Image.open(files[k - 1]).convert("L"), dtype=np.int16).mean() > 8:
            return max(k - 6, 1)
    return 1


def near(a, b, tol=6):
    return max(abs(x - y) for x, y in zip(a, b)) <= tol


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def popover_width(d, k):
    """The open popover's width in frame k: its near-white panel's columns inside the black box Xvfb draws round a popover
    (no compositor: the popover surface's margin is black), so the white tiles beside it don't count."""
    im = np.asarray(Image.open(d / "frames" / f"f{k:04d}.png").convert("RGB"), dtype=np.int16)
    black = (im == 0).all(axis=2)
    rows, cols = np.where(black.sum(axis=1) > 50)[0], np.where(black.sum(axis=0) > 50)[0]
    if len(rows) == 0 or len(cols) == 0:
        return 0
    box = im[rows[0]:rows[-1] + 1, cols[0]:cols[-1] + 1]
    white = np.where(((box >= 250).all(axis=2)).sum(axis=0) > 40)[0]
    return int(white[-1] - white[0] + 1) if len(white) else 0


def main():
    headless.ensure()
    print("load:", os.getloadavg())
    bad = []
    only = sys.argv[1:]
    for name, steps, region, size in CHANGES:
        if only and name not in only:
            continue
        out = OUT / name
        shutil.rmtree(out, ignore_errors=True)
        out.mkdir(parents=True)
        log = run(out, steps, size, grab=True)
        morphs = [line for line in log.splitlines() if line.startswith("MORPH:")]
        trace = (out / "trace.txt").read_text().splitlines() if (out / "trace.txt").exists() else []
        looks = [line.split(" LOOK ", 1)[1] for line in trace if " LOOK " in line]
        perches = [line.split(" PERCH ", 1)[1] for line in trace if " PERCH " in line]
        b = blend(frames(out, region), 150)
        if b is None:
            bad.append(f"{name}: nothing changed in {region}")
            print(name, "nothing changed", morphs, looks)
            continue
        s, n, blended, snapped, worst = b
        print(f"{name}: change at frame {s}, {n} px in {region}: blended over >= 3 frames {100 * blended:.1f} %, snapped {100 * snapped:.1f} %, "
              f"worst frame outside old..new {100 * worst:.1f} %; {' | '.join(morphs)}; looks: {looks}" + (f"; perch: {perches}" if perches else ""))
        wants_morph = name not in ("mascot", "mascot-phone", "roomy")
        if wants_morph and len(morphs) == 0:
            bad.append(f"{name}: no morph ran")
        if not wants_morph and len(morphs) > 0:
            bad.append(f"{name}: the window morphed (only a scheme or accent should)")
        ims = frames(out, region)
        steps_ = [float(np.abs(ims[k + 1] - ims[k]).sum()) for k in range(s - 1, min(s + 72, len(ims) - 1))]
        moving = sum(1 for k in range(s - 1, min(s + 72, len(ims) - 1)) if (np.abs(ims[k + 1] - ims[k]).sum(axis=2) > 40).mean() > 0.002)
        share = max(steps_) / max(sum(steps_), 1.0)
        print(f"   {name}: the region moved on {moving} frames; the biggest single frame carried {100 * share:.0f} % of all the change")
        if name == "roomy":  # (tiles glide: a pixel a tile passes over jumps, so motion is read in frames, not pixels)
            if moving < 8 or share > 0.30:
                bad.append(f"{name}: the tiles moved on {moving} frames, the biggest frame carried {100 * share:.0f} % (a jump)")
        elif snapped > (0.05 if name in ("dark", "undo", "person") else 0.10):  # (the presence and the mic: a growing shape leaves edge pixels that jump)
            bad.append(f"{name}: {100 * snapped:.1f} % of the changing pixels snapped")
        last = last_lit(out)
        if name in ("dark", "undo", "person"):
            w = mid_wash(ims, 150)
            base = mid_wash(frames(BASE / name, region), 150) if (BASE / name / "frames").exists() else None
            print(f"   {name}: mid-wash frames {w}" + (f" (the first round's standard ease: {base})" if base is not None else ""))
        if name == "accent":  # (D-8419: the ground and the active ring wear the accent, not only the mic)
            g0, g1 = px(out, max(s - 2, 1), GROUND_AT), px(out, last, GROUND_AT)
            r0, r1 = px(out, max(s - 2, 1), RING_ALL), px(out, last, RING_ALL)
            want = mix(GROUND["light"], BLUE, 0.06)
            print(f"   accent: the stage's ground {g0} -> {g1} (want {want}); All's ring {r0} -> {r1} (want {BLUE})")
            if not near(g0, GROUND["light"], 3) or not near(g1, want, 4):
                bad.append(f"accent: the stage's ground {g0} -> {g1}, want {GROUND['light']} -> {want}")
            if not near(r1, BLUE, 30) or near(r0, BLUE, 30):
                bad.append(f"accent: All's ring {r0} -> {r1}, want the ink -> {BLUE}")
            pw = popover_width(out, max(s - 2, 1))
            print(f"   accent: the Settings popover is {pw} px wide (swatches; the seven words made it 478)")
            if not (240 <= pw <= 330):
                bad.append(f"accent: the popover is {pw} px wide (want about 300)")
        if name == "mascot":  # (a desktop: perched full-size, the chat bar keeps the orb)
            if not any(p.startswith("on w=1280") for p in perches):
                bad.append(f"mascot: no perch on a 1280 window ({perches})")
            full = np.asarray(Image.open(out / "frames" / f"f{last:04d}.png").convert("RGB"), dtype=np.int16)[540:760, 40:250]
            dark_px = int(((full.sum(axis=2) < 200)).sum())  # (the mascot's dark fur on the light shade)
            print(f"   mascot: {dark_px} dark pixels on the perch (a 52 pt mascot would have under 1500)")
            if dark_px < 4000:
                bad.append(f"mascot: the perch shows {dark_px} dark pixels (no full-size mascot)")
        if name == "mascot-phone" and perches:
            bad.append(f"mascot-phone: a phone perched the mascot ({perches})")
        if name == "person":  # (the active person ringed: A after, All no longer)
            ra, rall = px(out, last, RING_A), px(out, last, RING_ALL)
            print(f"   person: A's ring {ra}, All's {rall}")
            if not near(ra, (29, 29, 31), 25) or near(rall, (29, 29, 31), 60):
                bad.append(f"person: A's ring {ra}, All's {rall} (want A ringed in the ink, All not)")
    for m in (("0", "1") if not only else ()):
        gaps = []
        for _ in range(3):
            out = OUT / "gaps"
            shutil.rmtree(out, ignore_errors=True)
            out.mkdir(parents=True)
            log = run(out, "gaps:start;wait:900;tap:Settings;wait:600;gaps:start;segment:0=Dark;gaps:1200", DESK, {"MOJOUI_MORPH": m})
            gaps += [line for line in log.splitlines() if line.startswith(("GAPS: ", "MORPH: 1"))]
        print(f"morph {'on' if m == '1' else 'off'}:", " | ".join(gaps))
    print("load:", os.getloadavg())
    print("PASS" if not bad else "FAIL: " + "; ".join(bad))
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
