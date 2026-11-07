#!/usr/bin/env python3
"""omxplorer's page clips besides the robot story (goal 61), shot in the tiled shell at 2× and directed with
scripts/director.py: a title card, one idea per scene, the caption first, a push-in so one card fills the frame, the
payoff held, an end card. Every number on screen is read from the take (the app's own trace lines).

    pixi run python scripts/clipshots.py island|sentence|models|all [--compose]

  island    the 100M-row file opening in the background (the island counts), a chart, "median by region",
            "by month, as a line"                                         → docs/img/clip-island-100m.mp4 (+ .jpg)
  sentence  a chart over 1M orders edited through its ask field, three times → docs/img/clip-sentence-gtk.mp4 (+ .jpg)
  models    your own model as a script function: Apply scene on a robot clip → docs/img/clip-models.mp4 (+ .jpg)

Takes go to build/clips/<name>/ (raw.mp4, raw.log, timeline.json); a PNG per named frame and a contact sheet to
build/clips/<name>/check/. --compose re-renders from the last take.
"""
import json
import os
import re
import shutil
import socket
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import director  # noqa: E402
from director import *  # noqa: E402,F401,F403

SCALE = 2
WIN = (1920 * SCALE, 1080 * SCALE)
director.configure(WIN)
CLIPS = ROOT / "build/clips"
BIG = ROOT / "build/g20/big.parquet"
ORDERS = ROOT / "build/data/orders_1m.csv"
ROBOTS = ROOT / "build/g47/full"
HERO = "F00118"
URL = "abhisheksreesaila.github.io/omxcode"


# ------------------------------------------------------------------------------------------------------------ recording

class Take:
    """omxplorer on the headless display at 2×, driven through its agent tools, recorded; scenes with rectangles from
    the app (bounds and regions, in recorded pixels) and the trace lines each one printed."""

    def __init__(self, name):
        import covers
        self.dir = CLIPS / name
        shutil.rmtree(self.dir, ignore_errors=True)
        docs = self.dir / "docs"
        (docs / "config").mkdir(parents=True)
        (docs / "config" / "settings.txt").write_text("inspector=no\n")
        os.environ.setdefault("MOJOUI_HEADLESS_SCREEN", f"{WIN[0]}x{WIN[1] + 200}")
        self.r = covers.Rec(covers.copy_app("omxplorer", self.dir), {"OMX_DOCUMENTS": str(docs), "OMX_CONFIG": str(docs / "config"),
                                                                       "MOJOUI_BUDGET_MS": "50", "GDK_SCALE": str(SCALE),
                                                                       "OMX_PACKS": str(ROOT / "build/packs")},
                            self.dir / "raw.mp4", size=WIN, window=(WIN[0] // SCALE, WIN[1] // SCALE))
        self.scenes = []
        self.docs = docs

    def now(self):
        return time.time() - self.r.t0

    def link(self, op):
        s = socket.socket(socket.AF_UNIX)
        s.connect(str(self.r.sock))
        s.sendall((json.dumps(op) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            buf += s.recv(1 << 20)
        s.close()
        return json.loads(buf)

    def bounds(self, tag):
        b = self.link({"op": "bounds", "tag": tag})
        return [b["x"] * SCALE, b["y"] * SCALE, b["w"] * SCALE, b["h"] * SCALE] if b.get("ok") else None

    def regions(self):
        return [(g["name"], [g["x"] * SCALE, g["y"] * SCALE, g["w"] * SCALE, g["h"] * SCALE]) for g in self.link({"op": "regions"})["regions"]]

    def card_of(self, rect):
        """The smallest card region holding rect: the card a tag sits on, wherever the tiles put it."""
        if not rect:
            return None
        hold = [(r[2] * r[3], r) for n, r in self.regions() if n.startswith("card:")
                and r[0] <= rect[0] + 2 and r[1] <= rect[1] + 2 and r[0] + r[2] >= rect[0] + rect[2] - 2 and r[1] + r[3] >= rect[1] + rect[3] - 2]
        return min(hold)[1] if hold else None

    def until(self, tool, timeout=300):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if tool in self.r.tools():
                return
            time.sleep(0.2)
        raise SystemExit(f"{tool} never appeared")

    def log(self):
        return (self.dir / "raw.log").read_text(errors="replace")

    def wait_log(self, pattern, since, timeout=120):
        """The first trace line matching pattern after byte `since` of the log (waits for it)."""
        t0 = time.time()
        while time.time() - t0 < timeout:
            m = re.search(pattern, self.log()[since:], re.M)
            if m:
                return m
            time.sleep(0.2)
        raise SystemExit(f"never printed {pattern!r}")

    def read(self, tag):
        """The card's text as an agent reads it (its title sentence, its 'answered in … ms on …' line)."""
        got = self.r.c.call("read", name=tag)
        return got[0] if isinstance(got, (list, tuple)) else str(got)

    def answered(self, tag, before, since, timeout=600):
        """The answer to what was just asked, once it has landed: (the card's text, its time as the app measured it).
        A big file's chart runs as a job ("JOB: start chart0 …", then "JOB: landed chart0 1,409.9 ms"): its time is that
        line's, and the card has drawn it; a small one answers at once: the time under the card's sentence ("0.8 ms")."""
        t0 = time.time()
        while time.time() - t0 < timeout:
            log = self.log()[since:]
            start = re.search(r"^JOB: start (chart\d+) .*$", log, re.M)
            if start:
                done = re.search(rf"^JOB: landed {start.group(1)} ([\d.,]+) ms", log[start.end():], re.M)
                if done:
                    time.sleep(0.8)  # (the card draws what landed)
                    return self.read(tag), f"{done.group(1)} ms"
            elif time.time() - t0 > 1.5:  # (no job: the answer came at once)
                text = self.read(tag)
                if text != before:
                    time.sleep(0.4)
                    screen = self.r.c.call("screen")[0]
                    (self.dir / "screens.txt").open("a").write(f"=== {tag}\n{screen}\n")
                    m = re.search(r'^\s+"([\d.,]+ ms)"\s*$', screen, re.M)  # (the line under the chart's sentence)
                    return text, (m.group(1) if m else "")
            time.sleep(0.25)
        raise SystemExit(f"{tag} never answered: {self.read(tag)[:300]!r}")

    def scene(self, name, secs, **rects):
        t = self.now()
        time.sleep(secs)
        self.scenes.append(dict(name=name, t0=t, t1=self.now(), **rects))

    def keys(self, rect, text, enter=False):
        """text typed with real keys (XTest) into the field at rect (recorded pixels), then Return when asked."""
        from Xlib import X, XK, display
        from Xlib.ext import xtest
        d = display.Display(os.environ["DISPLAY"])
        xtest.fake_input(d, X.MotionNotify, x=int(rect[0] + rect[2] / 2), y=int(rect[1] + rect[3] / 2))
        d.sync()
        time.sleep(0.15)
        xtest.fake_input(d, X.ButtonPress, 1)
        xtest.fake_input(d, X.ButtonRelease, 1)
        d.sync()
        time.sleep(0.2)
        names = {" ": "space", ",": "comma", ".": "period", "-": "minus", "'": "apostrophe", "(": "parenleft", ")": "parenright",
                 ";": "semicolon", "=": "equal", "_": "underscore"}
        shift = d.keysym_to_keycode(XK.string_to_keysym("Shift_L"))
        for ch in text + ("\r" if enter else ""):
            name = "Return" if ch == "\r" else names.get(ch, ch.lower())
            k = d.keysym_to_keycode(XK.string_to_keysym(name))
            up = ch.isupper() or ch in "()_"
            if up:
                xtest.fake_input(d, X.KeyPress, shift)
            xtest.fake_input(d, X.KeyPress, k)
            xtest.fake_input(d, X.KeyRelease, k)
            if up:
                xtest.fake_input(d, X.KeyRelease, shift)
            d.sync()
            time.sleep(0.045)
        xtest.fake_input(d, X.MotionNotify, x=WIN[0] + 100, y=WIN[1] + 100)  # (the pointer off the window: no hover)
        d.sync()
        d.close()

    def save(self, **extra):
        t = dict(raw=str(self.r.raw), win=WIN, scenes=self.scenes, **extra)
        (self.dir / "timeline.json").write_text(json.dumps(t, indent=1))
        return t


def record_island():
    k = Take("island")
    r = k.r
    try:
        r.record()
        mark = len(k.log())
        t_open = k.now()
        r.call("open-file", 0.0, path=str(BIG))  # (the 100M-row file opens in a job: the island counts, the window stays live)
        opened = k.wait_log(r"^JOB: landed open \S+ ([\d.,]+) ms.*$", mark, 600)
        k.scenes.append(dict(name="opening", t0=t_open, t1=k.now() + 0.3, island=None))  # (from the call to the landing)
        k.until("create-table", 600)
        r.call("create-table", 1.0)
        r.call("chart", 1.2)
        chart = k.card_of(k.bounds("chart-1")) or k.bounds("chart-1")
        k.scene("chart", 2.2, card=chart)
        answers = []
        for q in ("median by region", "by month, as a line"):
            before, since = k.read("chart-1"), len(k.log())
            t_ask = k.now()
            k.keys(k.bounds("ask"), q, enter=True)
            text, line = k.answered("chart-1", before, since)
            time.sleep(2.6)  # (the payoff held: the chart drawn, the island saying where it ran)
            answers.append(line)
            k.scenes.append(dict(name="ask:" + q, t0=t_ask - 0.3, t1=k.now(), card=k.card_of(k.bounds("chart-1")) or chart,
                                 island=k.bounds("island"), ask=k.bounds("ask")))
        time.sleep(0.6)
    finally:
        r.close()
    return k.save(opened=opened.group(0), answers=answers, rows_line=next((l for l in k.log().splitlines() if "100,000,000" in l), ""))


def record_sentence():
    k = Take("sentence")
    r = k.r
    try:
        r.record()
        r.call("open-file", 0.0, path=str(ORDERS))
        k.until("create-table", 300)
        r.call("create-table", 1.0)
        r.call("chart", 1.5)
        chart = k.card_of(k.bounds("chart-1"))
        k.scene("chart", 2.0, card=chart)
        answers = []
        for q in ("by product, largest first, top 5", "median", "sum by month, every month, in data order, as a line"):
            before, since = k.read("chart-1"), len(k.log())
            t0 = k.now()
            k.keys(k.bounds("ask"), q, enter=True)
            text, line = k.answered("chart-1", before, since)
            time.sleep(2.2)
            answers.append(line)
            k.scenes.append(dict(name="ask:" + q, t0=t0, t1=k.now(), card=k.card_of(k.bounds("chart-1")) or chart, ask=k.bounds("ask")))
    finally:
        r.close()
    return k.save(answers=answers)


def record_models():
    import csv
    k = Take("models")
    r = k.r
    rows = list(csv.DictReader(open(ROBOTS / "fleet.csv")))
    hero_row = [x["episode"] for x in rows].index(HERO) + 1
    try:
        r.record()
        r.call("open-file", 0.0, path=str(ROBOTS / "fleet.csv"))
        k.until("create-table", 300)
        r.call("create-table", 0.6)
        import scenario
        r.call("links", 0.2)
        r.call("link", 0.1, text=scenario.ROBOT_LINKS[1], submit=True)  # (the clip link: a row opens its video)
        r.call("links", 0.2)
        r.call("grid", 0.0, value=float(hero_row))
        k.until("video", 120)
        time.sleep(1.2)
        r.call("seek", 0.4, value=3.0)
        k.scene("video", 2.4, card=k.card_of(k.bounds("video")), video=k.bounds("video"))
        r.call("script", 0.8)
        k.scene("script", 2.6, panel=k.bounds("script-text"), apply=k.bounds("apply-scene"))
        r.call("range-from", 0.2, text="3")
        r.call("range-to", 0.4, text="8")
        mark = len(k.log())
        t0 = k.now()
        r.call("apply-scene", 0.0)
        line = k.wait_log(r"^SCRIPT: apply_\d+ = scene\(.*$", mark, 300)
        k.scenes.append(dict(name="apply", t0=t0 - 1.0, t1=k.now() + 0.4, apply=k.bounds("apply-scene"), panel=k.bounds("script-text")))
        time.sleep(0.4)
        r.call("script-close", 1.2)
        card = next((rr for n, rr in k.regions() if n.startswith("card:apply")), None)
        k.scene("labels", 3.2, card=card)
    finally:
        r.close()
    return k.save(applied=line.group(0))


# ------------------------------------------------------------------------------------------------------------ composing

def frames_of(t, name, secs=None):
    s = next(x for x in t["scenes"] if x["name"] == name)
    b = s["t1"] if secs is None else min(s["t1"], s["t0"] + secs)
    return list(raw_frames(t["raw"], s["t0"], b)), s


def shot(frames, fs, cam_from, cam_to, cap, lead=0.5, move=1.0, lift=True, check=None, extra=None):
    """One scene: the caption first (lead s on its first frame), then an eased push from cam_from to cam_to; lift fits
    any shape of card above the caption (director.STAGE)."""
    total = int(lead * FPS) + len(fs)
    for i in range(total):
        f = fs[max(i - int(lead * FPS), 0)]
        u = ease((i - lead * FPS) / (move * FPS)) if i >= lead * FPS else 0.0
        c = Canvas(f, lerp_rect(cam_from, cam_to, u), lerp_stage(u) if lift else None)
        if extra:
            extra(c, u, i)
        frames.append((caption(c.im, cap, alpha=ease(i / (FPS * 0.35))), check if i == total * 3 // 4 else None))


def still(frames, im, secs, cap=None, check=None, fade_in=0.0):
    n = int(secs * FPS)
    for i in range(n):
        out = caption(im, cap, alpha=ease(i / max(1, FPS * 0.35))) if cap else im
        if fade_in and i < fade_in * FPS:
            out = Image.blend(Image.new("RGBA", OUT, PAGE + (255,)), out, i / (fade_in * FPS))
        frames.append((out, check if i == n * 2 // 3 else None))


def timing(line):
    """The chart's own time as it shows it ("51.0 ms"), or "" when the take didn't read one."""
    m = re.fullmatch(r"([\d.,]+) ms", line or "")
    return f"{m.group(1)} ms" if m else ""


def compose_island(t):
    full = [0, 0, WIN[0], WIN[1]]
    fr = []
    still(fr, card("100 million rows.", sub="Opened on your GPU while the window stays live"), 2.4, check="01-title", fade_in=0.4)
    fs, s = frames_of(t, "opening")
    # (the island lives in the title bar, one place for the whole take: during the opening its bounds can't be asked yet,
    # so the take's first measured one)
    isl = s["island"] or next((x["island"] for x in t["scenes"] if x.get("island")), None)
    if not isl:
        raise SystemExit("the take has no island bounds")
    shot(fr, fs, full, fit169(grown(isl, 160 * SCALE), pad=0.0), "It opens in the background: the island counts.", lift=False, check="02-opening")
    fs, s = frames_of(t, "chart")
    shot(fr, fs, full, card_top(s["card"]), "A chart over all 100M rows.", check="03-chart")
    asked(fr, t, ("median by region", "by month, as a line"), 4)
    still(fr, card("omxplorer", sub="built on omxcode · one Mojo app, on your GPU", small=URL), 3.0, check="09-end")
    return fr


def sentence_strip(card, ask):
    """The card's top down to its ask field: the chart's sentence (its title) and what's being typed, wide and short, so a
    lifted view makes the words big."""
    bottom = (ask[1] + ask[3] + 14 * SCALE) if ask else card[1] + card[2] * 0.3
    return [card[0], card[1], card[2], bottom - card[1]]


def card_top(card):
    """The card from its top, as tall as 0.85 of its width: the sentence and the bars, at a size that reads."""
    return [card[0], card[1], card[2], min(card[3], card[2] * 0.85)]


SHORT = {"by product, largest first, top 5": "top 5 products", "sum by month, every month, in data order, as a line": "by month, as a line"}


def asked(fr, t, questions, first_check):
    """Each question: typed into the chart's ask field (the sentence strip held), then the answer (eased down to the
    card's top: the bars)."""
    for n, (q, line) in enumerate(zip(questions, t["answers"])):
        fs, s = frames_of(t, "ask:" + q)
        strip, top = sentence_strip(s["card"], s.get("ask")), card_top(s["card"])
        typing = int(min(len(fs) * 0.45, (len(q) * 0.045 + 0.6) * FPS))
        words = "\u201c" + SHORT.get(q, q) + "\u201d"
        cap = words + (" \u00b7 " + timing(line) if timing(line) else "")
        shot(fr, fs[:typing], strip, strip, "Type what you want:", lead=0.15)
        shot(fr, fs[typing:], strip, top, cap, lead=0.0, move=0.9, check=f"{first_check + n:02d}-ask")


def compose_sentence(t):
    fr = []
    still(fr, card("The title is the chart.", sub="Type what you want; the sentence and the bars follow"), 2.4, check="01-title", fade_in=0.4)
    fs, s = frames_of(t, "chart")
    shot(fr, fs, [0, 0, WIN[0], WIN[1]], card_top(s["card"]), "A chart over 1,000,000 orders.", check="02-chart")
    asked(fr, t, ("by product, largest first, top 5", "median", "sum by month, every month, in data order, as a line"), 3)
    still(fr, card("omxplorer", sub="built on omxcode \u00b7 one Mojo app, on your GPU", small=URL), 3.0, check="09-end")
    return fr


def compose_models(t):
    fr = []
    still(fr, card("Your model, as a function.", sub="A PyTorch network, converted, called from a script"), 2.6, check="01-title", fade_in=0.4)
    fs, s = frames_of(t, "video")
    shot(fr, fs, [0, 0, WIN[0], WIN[1]], grown(s["card"], 10 * SCALE), "A robot's camera, 15 frames a second.", check="02-video")
    fs, s = frames_of(t, "script")
    panel = union(*[x for x in (s["panel"], s["apply"]) if x])
    shot(fr, fs, [0, 0, WIN[0], WIN[1]], grown(panel, 30 * SCALE),
         "The Script window offers every model in the packs folder.", check="03-script")
    fs, s = frames_of(t, "apply")
    shot(fr, fs, grown(panel, 30 * SCALE), grown(panel, 30 * SCALE), "Apply scene(): ResNet-18, from PyTorch, on the GPU.", lead=0.2, check="04-apply")
    fs, s = frames_of(t, "labels")
    rows = re.search(r"→ ([\d,]+) rows in ([\d.,]+) ms", t["applied"])
    # (the first call of a session loads the pack onto the GPU: its time includes that, and the caption says so)
    cap = f"A label for every frame: {rows.group(1)} rows, {rows.group(2)} ms with the model's load" if rows else "A label for every frame."
    shot(fr, fs, [0, 0, WIN[0], WIN[1]], grown(s["card"], 10 * SCALE) if s["card"] else [0, 0, WIN[0], WIN[1]], cap, check="05-labels")
    still(fr, card(["Any PyTorch image network:", "one command, no Mojo to write."], sub=URL + "/models.html"), 3.2, check="09-end")
    return fr


def contact(check):
    shots = sorted(check.glob("*.png"))
    if not shots:
        return
    w, h = 480, 270
    cols = 4
    sheet = Image.new("RGB", (w * cols, h * ((len(shots) + cols - 1) // cols)), PAGE)
    for i, p in enumerate(shots):
        sheet.paste(Image.open(p).convert("RGB").resize((w, h)), ((i % cols) * w, (i // cols) * h))
    sheet.save(check / "contact-sheet.png")


OUTPUTS = {"island": ("clip-island-100m", record_island, compose_island), "sentence": ("clip-sentence-gtk", record_sentence, compose_sentence),
           "models": ("clip-models", record_models, compose_models)}


def run(name, compose_only=False):
    out, rec, comp = OUTPUTS[name]
    t = json.loads((CLIPS / name / "timeline.json").read_text()) if compose_only else rec()
    check = CLIPS / name / "check"
    shutil.rmtree(check, ignore_errors=True)
    check.mkdir(parents=True)
    write(comp(t), ROOT / "docs/img" / f"{out}.mp4", check)
    poster = sorted(p for p in check.glob("*.png") if "title" not in p.name and "end" not in p.name)
    if poster:
        Image.open(poster[-1]).convert("RGB").save(ROOT / "docs/img" / f"{out}.jpg", quality=88)
    contact(check)


if __name__ == "__main__":
    what = [a for a in sys.argv[1:] if not a.startswith("--")] or ["all"]
    for n in (list(OUTPUTS) if what == ["all"] else what):
        run(n, "--compose" in sys.argv)
