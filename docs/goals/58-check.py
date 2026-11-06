"""Goal 58's proof: video and pictures on the Mac without ffmpeg (GOAL.md). Prints "Mn: PASS|FAIL  why".

    MAC_SSH=user@host pixi run python docs/goals/58-check.py [M0 M1 ...]      (default: every milestone)

Linux is the reference: the same test prints the same lines on Linux (ffmpeg) and on the owner's Mac (AVFoundation,
ImageIO; scripts/mac-ssh-test), and the lines are compared here cell by cell. M4 runs omxplorer on the Mac
(scripts/mac-ssh) and reads its view dumps and pictures.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g58"
FULL = ROOT / "build/g47/full"
CLIP = FULL / "clips/F00118.mp4"
_cache = {}


def run(cmd, timeout=3600, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def linux(test):
    if ("linux", test) not in _cache:
        r = run(["pixi", "run", "mojo", "run", "-I", ".", test], 1800, {"MEDIA_VIDEO": str(CLIP), "MEDIA_DIR": "tests/fixtures"})
        _cache[("linux", test)] = r.stdout + r.stderr
    return _cache[("linux", test)]


def mac(test):
    if ("mac", test) not in _cache:
        r = run(["scripts/mac-ssh-test", test, "MEDIA_VIDEO={data}/F00118.mp4", "MEDIA_DIR={src}/tests/fixtures", "--", str(CLIP)], 2400)
        _cache[("mac", test)] = r.stdout + r.stderr
    return _cache[("mac", test)]


def cells(line):
    return [tuple(int(c[i:i + 2], 16) for i in (0, 2, 4, 6)) for c in re.findall(r"\b[0-9a-f]{8}\b", line)]


def worst(a, b):
    ca, cb = cells(a), cells(b)
    if len(ca) != 64 or len(cb) != 64:
        return 999
    return max(abs(x - y) for p, q in zip(ca, cb) for x, y in zip(p, q))


def lines(out, prefix):
    return {m.group(1): m.group(0) for m in re.finditer(rf"^({prefix}[^:]*):.*$", out, re.M)}


def m0():
    a, b = linux("tests/test_media_same.mojo"), linux("tests/test_framefeed_same.mojo")
    ok = "MEDIA: done" in a and "WRITTEN: 1280 720 30 frames" in a and "FEED: frame 50 taken" in b
    return ok, ("Linux (ffmpeg): every frame, picture and the 30-frame write; the feed ready and frame 50 taken" if ok else (a + b)[-800:])


def m1():
    lx, mc = linux("tests/test_media_same.mojo"), mac("tests/test_media_same.mojo")
    probs = []
    il = re.search(r"^INFO: (\d+) (\d+) ([\d.]+) (\d+)", lx, re.M)
    im = re.search(r"^INFO: (\d+) (\d+) ([\d.]+) (\d+)", mc, re.M)
    if not il or not im:
        return False, "no INFO line: " + mc[-600:]
    if il.group(1, 2) != im.group(1, 2) or abs(float(il.group(3)) - float(im.group(3))) > 0.01 or abs(int(il.group(4)) - int(im.group(4))) > 1:
        probs.append(f"info Linux {il.group(1, 2, 3, 4)} vs Mac {im.group(1, 2, 3, 4)}")
    fl, fm = lines(lx, "FRAME "), lines(mc, "FRAME ")
    pl, pm = lines(lx, "PICTURE "), lines(mc, "PICTURE ")
    want = [f"FRAME {n}" for n in list(range(10)) + [30, 100, 12]]
    seen = {}
    for k in want + list(pl):
        a, b = (fl if k.startswith("FRAME") else pl).get(k), (fm if k.startswith("FRAME") else pm).get(k)
        if a is None or b is None:
            probs.append(f"{k} missing")
            continue
        d = worst(a, b)
        seen[k] = d
        if d > 8:
            probs.append(f"{k} differs by {d}")
    if len(pl) != 3:
        probs.append(f"pictures on Linux: {sorted(pl)}")
    return (not probs), ("; ".join(probs)[:900] if probs else
                         f"size, rate, length as Linux's; {len(seen)} frames and pictures within {max(seen.values())} levels (seeks included)")


def m2():
    probs = []
    for name, out in [("Linux", linux("tests/test_media_same.mojo")), ("Mac", mac("tests/test_media_same.mojo"))]:
        if "WRITTEN: 1280 720 30 frames" not in out:
            probs.append(f"{name}: no 30-frame read-back")
            continue
        w = re.search(r"^WRITTEN 10:.*$", out, re.M).group(0)
        s = re.search(r"^SOURCE 10:.*$", out, re.M).group(0)
        d = worst(w, s)
        if d > 10:
            probs.append(f"{name}: frame 10 differs by {d}")
    return (not probs), ("; ".join(probs) if probs else "30 frames written and read back on Linux (libx264) and the Mac (AVAssetWriter), frame 10 within 10 levels")


def m3():
    out = mac("tests/test_framefeed_same.mojo")
    ok = "FEED: ready 1280 720 244" in out and "FEED: frame 50 taken" in out
    return ok, ("the Mac's feed: ready 1280×720, 244 frames, frame 50 taken on its own thread" if ok else out[-600:])


def m4():
    from PIL import Image
    r = run(["scripts/mac-ssh", "omxplorer", "docs/goals/58/mac.steps", str(FULL / "fleet.csv"), str(CLIP), "tests/fixtures/vision/cat.jpg"], 2400)
    rep = Path(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else None
    if r.returncode or rep is None or not (ROOT / rep / "log.txt").exists():
        return False, "scripts/mac-ssh failed: " + (r.stdout + r.stderr)[-800:]
    rep = ROOT / rep
    probs = []
    dumps = sorted(rep.glob("[0-9]*.txt"))
    last = dumps[-1].read_text()
    alltext = "".join(d.read_text() for d in dumps)
    if "Couldn't open" in alltext:
        probs.append("something says Couldn't open")
    times = re.findall(r"Text '(\d+):(\d\d) / (\d+):(\d\d)' #time", last)
    if not times or times[-1][2:] != ("0", "16") or times[-1][:2] == ("0", "00"):
        probs.append(f"the video's clock after play: {times}")
    if "451×300 JPG" not in last:
        probs.append("no 451×300 JPG on the picture card")
    m = re.search(r"Canvas [^\n]*#video @ (\d+),(\d+) (\d+)x(\d+)", last)  # (the player's picture)
    png = sorted(rep.glob("[0-9]*.png"))[-1]
    im = Image.open(png).convert("L")
    if not m:
        return False, "no #video canvas in the last dump"
    x, y, w, h = map(int, m.groups())
    lo, hi = im.crop((x, y, x + w, y + h)).getextrema()
    if hi - lo < 60:
        probs.append(f"the video's picture is blank (lightness {lo}–{hi})")
    OUT.mkdir(parents=True, exist_ok=True)
    Image.open(png).save(OUT / "mac-media.png")
    return (not probs), ("; ".join(probs) if probs else f"{rep.name}: the video plays ({times[-1][0]}:{times[-1][1]} / 0:16), its picture drawn, cat.jpg 451×300; nothing says Couldn't open")


def m5():
    r = run([sys.executable, "docs/goals/54-check.py", "M1"], 3600)
    ok = "M1: PASS" in r.stdout
    return ok, ("goal 54 M1 PASS on Linux (the tiled board with the featured video)" if ok else (r.stdout + r.stderr)[-800:])


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5}

if __name__ == "__main__":
    wanted = sys.argv[1:] or list(MILESTONES)
    bad = 0
    for k in wanted:
        try:
            ok, why = MILESTONES[k]()
        except Exception as e:  # a crashing proof is a failing proof
            ok, why = False, f"crashed: {e!r}"
        print(f"{k}: {'PASS' if ok else 'FAIL'}  {why}", flush=True)
        bad += not ok
    sys.exit(1 if bad else 0)
