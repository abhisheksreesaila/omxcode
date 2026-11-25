"""Real keys and a real pointer (XTEST on a headless X server, CPU drawing) in apps that aren't the one a change was made for
(review 6, M2: an input method on every canvas took the letters from all of them, and the test steps didn't go that way).
   pixi run python -B tests/realkeys.py        (builds it needs: scripts/build.sh kit|workbook|sketch|media|omxplorer|pnote linux)"""
import os, re, shutil, subprocess, sys, tempfile, time
from pathlib import Path
import numpy as np
from PIL import Image
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / "docs/goals/79"))
import xdrive
from xdrive import App, X
W = R / "build/realkeys"
shutil.rmtree(W, ignore_errors=True)
W.mkdir(parents=True)
bad = []


def note(ok, what):
    print(("ok   " if ok else "BAD  ") + what, flush=True)
    if not ok:
        bad.append(what)


class Run:
    def __init__(self, name, size=(1280, 820), **env):
        os.environ["XBIN"] = str(R / f"build/{name}/linux/{name}")
        self.name, self.w, self.n = name, W / name, 0
        self.w.mkdir()
        e = {"PNOTE_BOXES": str(self.w / "boxes.json"), "HOME": str(self.w), "OMX_CONFIG": str(self.w / "cfg"), "OMX_DATA": str(self.w / "data"), "MOJOUI_TRACE": "1", "G_DEBUG": "", **env}
        self.a = App(e, self.w / "log.txt", size)
        X.XSetInputFocus(self.a.d, self.a.win, 1, 0)
        X.XSync(self.a.d, 0)
        time.sleep(0.6)

    def keys(self):
        return re.findall(r"^TRACE: event key (.*?) [\d.]+ nodes", (self.w / "log.txt").read_text(), re.M)

    def lines(self):
        return len((self.w / "log.txt").read_text().splitlines())

    def shot(self):
        self.n += 1
        p = self.w / f"{self.n}.png"
        self.a.shot(p)
        return np.asarray(Image.open(p).convert("RGB")).astype(int)

    def close(self):
        self.a.p.terminate()
        try:
            self.a.p.wait(8)
        except subprocess.TimeoutExpired:
            self.a.p.kill()


def changed(a, b, box=None):
    d = np.abs(a - b).max(axis=2)
    if box:
        x0, y0, x1, y1 = box
        d = d[y0:y1, x0:x1]
    return int((d > 24).sum())


def kit():
    r = Run("kit")
    r.a.click(300, 330)
    r.a.type("ab1")
    r.a.key("space", wait=0.2)
    r.a.key("Down", wait=0.2)
    note(r.keys()[:5] == ["a", "b", "1", " ", "ArrowDown"], f"kit's canvas: letters, a digit, the space bar, an arrow are KEYs: {r.keys()[:5]}")
    n = len(r.keys())
    r.a.key("v", "Ctrl", wait=0.4)
    got = r.keys()[n:]
    note([k for k in got if not k.startswith("Control")] == ["v"] and not any("KeyUp" in k for k in r.keys()), f"Ctrl+V is its key alone, modifiers let go aren't keys: {got}")
    time.sleep(0.4)
    n = r.lines()
    for k in range(20):
        r.a.move(200 + k * 12, 300 + k % 3)
    time.sleep(0.5)
    note(r.lines() == n, "the pointer moving over it is no event (no hover it didn't ask for)")
    # a field keeps its own typing
    r.a.click(1020, 357)
    r.a.type("sum")
    s0 = r.shot()
    note(r.keys().count("s") == 0, "a field's typing doesn't reach the canvas")
    # a card dragged by its title ends where it is let go, to the pixel
    before = r.shot()
    r.a.path([(640, 165)] + [(640 - k * 2, 165 + k * 4) for k in range(1, 31)], wait=0.8)
    r.a.move(500, 700)
    time.sleep(0.5)
    after = r.shot()
    off = {dy: (np.abs(before[138:252, 640:770] - after[138 + dy:252 + dy, 580:710]) > 24).mean() for dy in (119, 120)}  # (119: the same before this goal, a kit built from its first commit's parent)
    note(min(off.values()) == 0, f"a card dragged -60, 120 lands there, pixel for pixel ({off})")
    r.close()


def workbook():
    r = Run("workbook")
    time.sleep(2)
    r.a.click(800, 247, wait=0.6)
    s0 = r.shot()
    r.a.type("77")
    time.sleep(0.6)
    s1 = r.shot()
    note(r.keys()[:2] == ["7", "7"] and changed(s0, s1, (750, 234, 860, 262)) > 30, f"a cell selected, 77 typed: its editor opens with it ({changed(s0, s1, (750, 234, 860, 262))} px)")
    r.a.key("Escape", wait=0.4)
    r.a.key("Down", wait=0.3)
    n = len(r.keys())
    r.a.type("x")
    time.sleep(0.4)
    note(r.keys()[n:][:1] == ["x"], "and a letter in the cell below")
    r.a.key("Escape", wait=0.4)
    note(not any("KeyUp" in k for k in r.keys()), "no KeyUp keys")
    r.close()


def sketch():
    r = Run("sketch")
    s0 = r.shot()
    pts = [(300 + 4 * k, 400 + (60 if k % 2 else 0)) for k in range(120)]
    r.a.path(pts, wait=0.8)
    s1 = r.shot()
    d = np.abs(s1 - s0).max(axis=2) > 24
    cols = [d[380:480, x].any() for x in range(310, 770)]
    note(np.mean(cols) > 0.99, f"a stroke is where the pointer went, its whole length ({np.mean(cols):.3f} of its columns)")
    d2 = d[:, 790:].sum()
    note(d2 < 200, "and nothing past where it was let go")
    r.a.type("a")
    r.a.key("z", "Ctrl", wait=0.6)
    s2 = r.shot()
    note(any(k == "a" for k in r.keys()) and any(k == "z" for k in r.keys()), f"its canvas gets letters and Ctrl+Z as KEYs: {r.keys()}")
    note(changed(s2, s0, (300, 380, 780, 480)) < changed(s1, s0, (300, 380, 780, 480)) / 4, "Ctrl+Z takes the stroke back")
    r.close()


def player():
    media = W / "clips"
    media.mkdir()
    subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=8:size=320x180:rate=30", "-pix_fmt", "yuv420p", str(media / "drone_a.mp4")], check=True)
    (media / "telemetry_a.csv").write_text("t,lat,lon,alt_m,heading_deg,speed_ms,battery_pct\n" + "".join(f"{t / 10},1,2,{t % 30},{t % 360},{t % 7},{100 - t / 10}\n" for t in range(81)))
    r = Run("media", G39_MEDIA=str(media))
    time.sleep(2.5)
    s0 = r.shot()
    r.a.click(400, 330, wait=0.5)  # (a click toggles: playing)
    time.sleep(0.6)
    n = len(r.keys())
    r.a.key("space", wait=0.8)  # (and the space bar stops it)
    a = r.shot()
    time.sleep(0.8)
    b = r.shot()
    r.a.key("space", wait=1.2)
    c = r.shot()
    note(r.keys()[n:][:2] == [" ", " "], f"the player's Space is a KEY: {r.keys()[n:]}")
    note(changed(a, b) < 400 and changed(b, c) > 400, f"and it stops and starts the picture ({changed(a, b)} px moved while stopped, {changed(b, c)} after)")
    r.close()


GRID = (300, 400)


def omxplorer():
    csv = W / "t.csv"
    csv.write_text("name,amount\n" + "".join(f"row{k},{k * 3}\n" for k in range(50)))
    r = Run("omxplorer", OMX_OPEN=str(csv))
    time.sleep(5)
    r.a.click(1120, 763, wait=4)  # (Create table)
    s0 = r.shot()
    r.a.click(*GRID, wait=0.8)
    s1 = r.shot()
    r.a.type("z")
    time.sleep(0.8)
    s2 = r.shot()
    note("z" in r.keys(), f"omxplorer: a letter over its grid is a KEY: {r.keys()[:6]}")
    r.close()


def pnote():
    r = Run("pnote", (1200, 800))
    r.a.key("Escape", wait=0.3)
    n = len(r.keys())
    r.a.key("p", wait=0.3)  # (the pen: nothing is being written)
    note("p" in r.keys()[n:], f"pnote: a tool's letter is a KEY when no words are written: {r.keys()[n:]}")
    r.a.key("t", wait=0.3)
    r.a.click(600, 400, wait=0.5)
    n = len(r.keys())
    r.a.type("Hello é x")
    time.sleep(2.5)
    got = r.keys()[n:]
    import sqlite3
    db = next((r.w / "data").rglob("notes.db"))
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    t = " ".join(x[0] for x in c.execute("SELECT content FROM notes"))
    note("Hello é x" in t or "Hello \\u00e9 x" in t, f"words written are text, letters, spaces and accents, and reach the file (KEYs meanwhile: {[k for k in got if len(k) == 1]})")
    note(not [k for k in got if len(k) == 1], "and none of them came as a KEY too")
    r.a.key("Escape", wait=0.3)
    n = len(r.keys())
    r.a.key("v", wait=0.3)
    note("v" in r.keys()[n:], "after Escape a letter is a tool's again")
    r.close()


for f in [globals()[n] for n in (sys.argv[1:] or ["kit", "workbook", "sketch", "player", "omxplorer", "pnote"])]:
    try:
        f()
    except Exception as e:
        note(False, f"{f.__name__}: {type(e).__name__}: {e}")
print("realkeys:", "ok" if not bad else f"BAD {bad}")
sys.exit(1 if bad else 0)
