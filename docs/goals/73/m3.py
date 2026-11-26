"""Goal 73 M3, cards with depth: Liquid's canvas a clear step off the cards, in light and dark, and its text readable.

    pixi run python docs/goals/73-check.py M3
    pixi run python docs/goals/73/m3.py before <linux-build-dir> <web-build-dir>     (shots of an older build, for the report)

check(): (1) tests/test_liquid_contrast.mojo: every text colour >= 4.5:1 on the cards, the canvas (both gradient ends) and the
chrome, the step between card and canvas (light: canvas darker; dark: cards lighter); (2) omxplorer built from this tree and
shown on /.../fleet.csv with two charts (GTK headless 1440x900 with real clicks, and the web host in headless Chromium), light
and dark: the colour of the canvas (the Board's backdrop beside the cards) and of a card measured from the shots, the step
as L* in the right direction, and a shadow under a card (the pixel under its bottom edge is darker/lighter than the canvas
further down).  Shots go to build/g73/m3/<gtk|web>-<light|dark>[-before].png.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build/g73/m3"
FLEET = os.environ.get("G73_DATA", str(ROOT / "build/g47/full")) + "/fleet.csv"  # (goal 47's DROID folder: scripts/robot_data.py)
sys.path.insert(0, str(ROOT / "scripts"))

# the page: import dialog -> Create table, then two charts (the Chart tool), as a person would
GTK_STEPS = "wait:3000;click:1201,843;wait:2500;click:278,21;wait:600;click:525,60;wait:2500;click:525,60;wait:2000;shot:{shot}"  # (goal 76: Chart is on the ribbon's Insert tab: the tab at 278,21, then its Chart at 525,60)
WEB_STEPS = "wait:3000;tap:Create table;wait:2500;tap:Chart;wait:2500;tap:Chart;wait:2000"


def run(cmd, timeout=900):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)


def lstar(rgb):
    def ch(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    y = 0.2126 * ch(rgb[0]) + 0.7152 * ch(rgb[1]) + 0.0722 * ch(rgb[2])
    return 116 * y ** (1 / 3) - 16 if y > 0.008856 else 903.3 * y


def config(mode):
    d = OUT / f"cfg-{mode}"
    d.mkdir(parents=True, exist_ok=True)
    (d / "settings.txt").write_text(f"appearance={mode}\n")
    return d


def gtk_shot(exe, mode, png):
    r = run(["pixi", "run", "python", "scripts/live.py", str(exe), GTK_STEPS.format(shot=png), "--size", "1440x900",
             "--env", f"OMX_CONFIG={config(mode)}", "--env", f"OMX_OPEN={FLEET}"], 300)
    return Path(png).exists(), (r.stdout + r.stderr)[-400:]


def web_shot(web_dir, mode, png):
    import drive
    r, out = drive.web_run(web_dir, WEB_STEPS, shot=str(png), viewport=(1440, 900),
                           env={"OMX_CONFIG": str(config(mode)), "OMX_OPEN": FLEET})
    return Path(png).exists() and r.returncode == 0, out[-400:]


# where the first card's title row is, and the canvas margin beside it (goal 76: the ribbon is taller than the old bars and there
# is no rail, so the title row moved from y=162 to 219 on GTK, 205 on the web, and the margin from x=54 to x=6; both points
# are the same features as before: the board's padding left of the card, the blank of the card's title row)
TITLE_Y = {"gtk": 219, "web": 205}
MARGIN_X = 6


def step_of(png, mode, host="gtk"):
    """(canvas rgb, card rgb): the canvas in the margin between the window's edge and the first card, the card in the blank of
    its title row (both at the height of the title, where nothing else is drawn)."""
    from PIL import Image
    im = Image.open(png).convert("RGB")
    return im.getpixel((MARGIN_X, TITLE_Y[host])), im.getpixel((420, TITLE_Y[host]))


def edge_of(png, mode, host="gtk"):
    """The first card's bottom edge and what lies under it: (rim dL*, shadow dL*). The edge is found at x=300: the last row, scanning up from the
    window's bottom, that is the card's own colour. Rim: how far the edge pixels are from the card and the
    canvas. Shadow: the canvas 1 px under the edge against 10 px under it (light: darker next to the card)."""
    from PIL import Image
    im = Image.open(png).convert("RGB")
    H = im.size[1]
    card = im.getpixel((420, TITLE_Y[host]))
    y = 1 + next(y for y in range(H - 68, 700, -1) if max(abs(a - b) for a, b in zip(im.getpixel((300, y)), card)) <= 3)
    rim = max(abs(lstar(im.getpixel((300, y + k))) - lstar(card)) for k in (0, 1))
    near, far = lstar(im.getpixel((300, y + 1))), lstar(im.getpixel((300, y + 10)))
    return rim, far - near


def check():
    os.environ["OMX_CANVAS"] = "tiled"  # (goal 78: the card edges are found where the tiling puts the cards; the free canvas is the default now)
    OUT.mkdir(parents=True, exist_ok=True)
    notes = []
    # 1. the contrast test
    r = run(["pixi", "run", "mojo", "build", "-I", ".", "tests/test_liquid_contrast.mojo", "-o", "build/test_liquid_contrast"], 600)
    if r.returncode != 0:
        return False, "tests/test_liquid_contrast.mojo did not build: " + (r.stdout + r.stderr)[-300:]
    t = run(["build/test_liquid_contrast"])
    pairs = re.findall(r"^CONTRAST: .* = ([\d.]+)$", t.stdout, re.M)
    if t.returncode != 0 or not t.stdout.rstrip().endswith("OK") or not pairs:
        return False, "contrast test failed: " + (t.stdout + t.stderr)[-400:]
    notes.append(f"{len(pairs)} text/background pairs, lowest {min(float(p) for p in pairs):.2f}:1")
    steps = re.findall(r"^STEP: (.*)$", t.stdout, re.M)
    notes.append("; ".join(steps))
    # 2. the real app on both hosts
    exe = ROOT / "build/omxplorer/linux/omxplorer"
    web = ROOT / "build/omxplorer/web"
    if not exe.exists() or not web.exists():
        return None, "build omxplorer first: scripts/build.sh omxplorer linux; scripts/build.sh omxplorer web"
    for host in ("gtk", "web"):
        for mode in ("light", "dark"):
            png = OUT / f"{host}-{mode}.png"
            ok, tail = gtk_shot(exe, mode, png) if host == "gtk" else web_shot(web, mode, png)
            if not ok:
                return False, f"{host} {mode}: no shot: {tail}"
            canvas, card = step_of(png, mode, host)
            if card is None:
                return False, f"{host} {mode}: no card pixel found beside the canvas {canvas}"
            lc, lk = lstar(canvas), lstar(card)
            d = lk - lc  # (light: the cards lighter than a darker canvas; dark: the cards lifted lighter than the canvas)
            want = d >= (8 if mode == "light" else 5)
            rim, sh = edge_of(png, mode, host)
            notes.append(f"{host} {mode}: canvas {canvas} L*{lc:.1f}, card {card} L*{lk:.1f}, step {d:+.1f}, rim dL* {rim:.1f}, shadow dL* {sh:.1f}")
            if not want:
                return False, f"{host} {mode}: canvas L*{lc:.1f} card L*{lk:.1f} (card must be lighter by >= {8 if mode == 'light' else 5}): " + "; ".join(notes)
            if rim < 3 or (mode == "light" and sh < 1.5):
                return False, f"{host} {mode}: no visible edge or shadow (rim dL* {rim:.1f}, shadow {sh:.1f}): " + "; ".join(notes)
    return True, "; ".join(notes) + f"; shots {OUT}"


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "before":
    OUT.mkdir(parents=True, exist_ok=True)
    lin, wb = Path(sys.argv[2]), Path(sys.argv[3])
    for host in ("gtk", "web"):
        for mode in ("light", "dark"):
            png = OUT / f"{host}-{mode}-before.png"
            ok, tail = gtk_shot(lin / "omxplorer", mode, png) if host == "gtk" else web_shot(wb, mode, png)
            canvas, card = step_of(png, mode, host)
            print(host, mode, ok, canvas, card, f"L* {lstar(canvas):.1f} vs {lstar(card) if card else None}", tail if not ok else "")
