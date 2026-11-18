"""Goal 77's proof: omx shows and points (GOAL.md). Prints "Mn: PASS|FAIL|BLOCKED  why" per milestone.

    pixi run python docs/goals/77-check.py [M0 M1 M2 M5 ...]          (default: every milestone)

M0 ground, M1 she points (GTK headless, then the web host in headless Chromium), M2 the word card, M5 visual first. M3 (map), M4 (isometric),
M6 (camera) and M7 (polish) are other developers' and report BLOCKED("not built yet") until they land. The models run on GPU $G77_GPU
(default 0); the machinery is goal 72's (docs/goals/72-check.py: the app on the headless display, typed turns, the null sink). Numbers: build/g77;
pictures: docs/goals/77.
"""
import importlib.util
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

os.environ["G72_GPU"] = os.environ.get("G77_GPU", "0")  # (goal 72's helpers read it once, when they load)
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g77"
SHOTS = ROOT / "docs/goals/77"
sys.path.insert(0, str(ROOT / "scripts"))

_spec = importlib.util.spec_from_file_location("g72check", ROOT / "docs/goals/72-check.py")
g72 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(g72)

CTX = {"OMX_LLM_CTX": "32768"}  # (the context stays under 32768: one 3090 holds the brain and the voice)
LAG_LIMIT_MS = 250  # a point is shown within this of the audio that names it
TAG = re.compile(r"^card\d+\.(word|sounds|meaning|example|origin)$")
WORDS = {  # M2: the word, a reference meaning the card's is judged against
    "ephemeral": "lasting for only a very short time",
    "serendipity": "finding something good or valuable by happy chance, without looking for it",
    "ubiquitous": "present, appearing or found everywhere",
}
ROUTING = [  # M5: (what the person says, the kind of card that is right)
    ("What does the word ephemeral mean?", "word"),
    ("How do you pronounce serendipity and what does it mean?", "word"),
    ("Plan me a day in Lisbon, with the stops in order.", "map"),
    ("I'm taking a trip through Paris, Brussels and Amsterdam. Show me the route.", "map"),
    ("How does a refrigerator work?", "iso"),
    ("Explain how a bill becomes a law.", "iso"),
    ("Compare the three largest planets by diameter.", "table"),
    ("Add milk, eggs and bread to my shopping list.", "todo"),
    ("Good morning! How are you today?", ""),
    ("What is seven times eight?", ""),
]
STUB_KINDS = ("map", "iso")  # the cards other developers build (M3, M4): until they land, routing to their tool is all that can be proved


def build():
    """goal 72's build of examples/omx for Linux, skipped when the binary is newer than every source it is made from (a build is ten minutes)."""
    binary = ROOT / "build/omx/linux/omx"
    if binary.exists():
        newest = max(f.stat().st_mtime for d in ("mojoui", "examples/omx", "themes", "bridge") for f in (ROOT / d).rglob("*") if f.is_file() and f.suffix in (".mojo", ".py", ".cpp", ".c"))
        if binary.stat().st_mtime > newest:
            return None
    return g72.build()


def sentences(text):
    return len([s for s in re.split(r"(?<=[.!?])\s+", text.strip()) if s.strip()])


def typed_turns(turns, shots=None, extra_wait=0):
    """One app run with typed turns; shots: [(ms after the last turn is sent, file)]. Returns (events, run)."""
    steps = g72.TYPED_OPEN + "".join(f"enter:Type to omx={t};wait:800;waitfor:Listening=170000;wait:400;" for t in turns)
    return g72.run_app(g72.SILENT, steps, env=CTX, timeout=60 * 12 * max(1, len(turns)))


def of(ev, kind, turn=None):
    return g72.of(ev, kind, turn)


# ------------------------------------------------------------------------------------------------ M0


def m0():
    probs, said = [], []
    free = shutil.disk_usage(ROOT).free / 1e9
    (said if free >= 40 else probs).append(f"{free:.0f} GB free")
    smi = g72.sh(["nvidia-smi", "--query-gpu=index,memory.used,memory.total", "--format=csv,noheader,nounits"]).stdout.strip().splitlines()
    gpu = int(os.environ["G72_GPU"])
    if len(smi) <= gpu:
        probs.append(f"GPU {gpu} not seen ({len(smi)} GPUs)")
    else:
        used = int(smi[gpu].split(",")[1])
        (said if used < 4000 else probs).append(f"GPU {gpu}: {used} MiB used")
    r = g72.sh(["pixi", "run", "python", "-c", "from playwright.sync_api import sync_playwright as p\nwith p() as x:\n print(x.chromium.executable_path)"], 60)
    path = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    if r.returncode or not (Path(path).exists() or Path("/usr/bin/chromium").exists()):
        probs.append("playwright Chromium not found")
    else:
        said.append("playwright Chromium found")
    if not probs and not os.environ.get("G77_SKIP_72"):
        state, why = g72.m4()
        (said if state == "PASS" else probs).append("goal 72's M4 " + state + ((": " + why[:200]) if state != "PASS" else ""))
    return ("FAIL", "; ".join(probs)) if probs else ("PASS", " | ".join(said))


# ------------------------------------------------------------------------------------------------ M1: she points


def point_stats(ev):
    pts = of(ev, "POINT")
    sent = of(ev, "POINT_SENT")
    return pts, sent


def m1():
    why = build()
    if why:
        return "FAIL", why
    probs, said = [], []
    ask = "Show me the word ephemeral as a card, then walk me through it: the word, what it means, and an example."
    OUT.mkdir(parents=True, exist_ok=True)
    SHOTS.mkdir(parents=True, exist_ok=True)
    for old_shot in OUT.glob("m1_*.png"):
        old_shot.unlink()
    steps = g72.TYPED_OPEN + f"enter:Type to omx={ask};waitfor:meaning=120000;" + "".join(f"shot:{OUT}/m1_{k:02d}.png;wait:100;" for k in range(10)) + "waitfor:Listening=170000;wait:400;"
    with g72.NullSink():
        ev, r = g72.run_app(g72.SILENT, steps, env=CTX, timeout=900)
    pts, sent = point_stats(ev)
    best = ring_shot()
    if best:
        shutil.copy(best[0], SHOTS / "point_ring_on_target.png")
        said.append(f"screenshot with the ring on its target and the orb's eyes turned to it: docs/goals/77/point_ring_on_target.png ({best[1]} ring pixels)")
    else:
        probs.append("no screenshot shows the ring")
    cards = of(ev, "CARD")
    failed = [f for f in of(ev, "FAILED") if not f.get("raw", "").startswith("microphone")]  # (the recorded microphone of goal 72's scenarios is silent on purpose)
    if failed:
        probs.append("the app failed: " + failed[0].get("raw", ""))
    if not cards:
        probs.append("no card was shown: " + str((of(ev, "REPLY") or ev[-3:])))
    tags = []
    for p in pts:
        if p.get("tag") not in tags:
            tags.append(p.get("tag"))
    bad = [t for t in tags if not TAG.match(str(t))]
    if len(pts) < 3:
        probs.append(f"{len(pts)} points shown, need at least 3 (sent: {len(sent)}; reply: {(of(ev, 'REPLY') or [{}])[0].get('text')!r})")
    if bad:
        probs.append(f"points on parts that don't exist: {bad}")
    lags = [p["lag_ms"] for p in pts]
    if lags and max(abs(x) for x in lags) > LAG_LIMIT_MS:
        probs.append(f"a point was shown {max(lags, key=abs)} ms from its audio (limit {LAG_LIMIT_MS})")
    said.append(f"{len(pts)} points on {tags}, shown {lags} ms from the audio that names them (limit {LAG_LIMIT_MS})")
    bench(m1_points=len(pts), m1_lags_ms=lags, m1_tags=tags)
    if not probs and not os.environ.get("G77_SKIP_WEB"):  # the web host: the same app in headless Chromium, the ring round the part in the browser
        b = g72.sh(["scripts/build.sh", "omx", "web"], 3600)
        if b.returncode:
            probs.append("web build: " + g72.tail(b, 400))
        else:
            w = g72.sh(["pixi", "run", "python", "scripts/omx_point_web.py"], 1800)
            if w.returncode or "omx_point_web: ok" not in w.stdout:
                probs.append("web host: " + g72.tail(w, 600))
            else:
                rep = json.loads((OUT / "omx-point-web.json").read_text())
                said.append(f"web host: {len(rep['points'])} points, ring round {rep['ring_on']} in the browser (share {rep['ring_share']}), lags {rep['lag_ms']} ms; docs/goals/77/web_point.png")
    return ("FAIL", "; ".join(probs)) if probs else ("PASS", " | ".join(said))


def ring_shot():
    """The screenshot of the run with the most ring-coloured pixels on the card (the ring is the theme's teal accent): (path, count), or None
    when none has more than the card's own teal (its underline)."""
    from PIL import Image

    best = None
    for f in sorted(OUT.glob("m1_*.png")):
        im = Image.open(f).convert("RGB")
        px = im.load()
        n = sum(1 for y in range(140, min(420, im.height)) for x in range(im.width) if px[x, y][0] < 90 and 120 < px[x, y][1] < 190 and 130 < px[x, y][2] < 200)
        if best is None or n > best[1]:
            best = (f, n)
    return best if best and best[1] > 1200 else None


def bench(**kv):
    OUT.mkdir(parents=True, exist_ok=True)
    f = OUT / "bench.json"
    data = json.loads(f.read_text()) if f.exists() else {}
    data.update(kv)
    f.write_text(json.dumps(data, indent=1))


# ------------------------------------------------------------------------------------------------ M2, M5, the rest


def card_args(ev, turn):
    """The arguments of the turn's render_ui calls, as dicts (what the model put on the card)."""
    out = []
    for e in of(ev, "CARD", turn):  # (the CARD line carries the card as the agent built it)
        try:
            out.append(json.loads(e.get("text", "")))
        except ValueError:
            pass
    return out


def subsequence(want, got):
    it = iter(got)
    return all(any(w == g for g in it) for w in want)


def m2():
    why = build()
    if why:
        return "FAIL", why
    probs, said = [], []
    words = list(WORDS)
    SHOTS.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    steps = g72.TYPED_OPEN
    for w in words:
        steps += f"enter:Type to omx=What does the word {w} mean?;wait:3000;shot:{OUT}/m2_{w}_mid.png;wait:2500;shot:{OUT}/m2_{w}_mid2.png;waitfor:Listening=170000;wait:600;shot:{OUT}/m2_{w}.png;"
    with g72.NullSink():
        ev, r = g72.run_app(g72.SILENT, steps, window="390x844", env=CTX, timeout=1500)
    cards = []
    for i, w in enumerate(words, 1):
        kinds = [re.search(r"cardkind=(\w+)", e.get("raw", "")).group(1) for e in of(ev, "CARD", i)]
        args = [a for a in card_args(ev, i) if a.get("component") == "WordCard"]
        pts = [str(e.get("tag")) for e in of(ev, "POINT", i)]
        order = [t.split(".")[1] for t in pts if TAG.match(t)]
        lags = [e["lag_ms"] for e in of(ev, "POINT", i)]
        c = {"word": w, "card": args[0] if args else None, "points": order, "lags": lags, "reply": (of(ev, "REPLY", i) or [{}])[0].get("text")}
        cards.append(c)
        if not args:
            probs.append(f"{w}: no WordCard (cards: {kinds}; reply {c['reply']!r})")
            continue
        if str(args[0].get("word", "")).strip().lower() != w:
            probs.append(f"{w}: the card's word is {args[0].get('word')!r}")
        if not subsequence(["word", "meaning", "example"], order):
            probs.append(f"{w}: points {order} are not word, meaning, example in that order (reply {c['reply']!r})")
        if lags and max(abs(x) for x in lags) > LAG_LIMIT_MS:
            probs.append(f"{w}: a point was {max(lags, key=abs)} ms from its audio")
    # the meaning, judged by the model against a reference (a second session: the judge's turns are not the conversation's)
    judged = {}
    if all(c["card"] for c in cards):
        jt = []
        for c in cards:
            got = str(c["card"].get("meaning", "")).replace(";", ",").replace("=", " is ")
            jt.append(f"Judge this. A dictionary says the word {c['word']} means: {WORDS[c['word']]}. A card says it means: {got} Do they mean the same thing? Answer with one word only, yes or no.")
        with g72.NullSink():
            jev, _ = typed_turns(jt)
        for i, c in enumerate(cards, 1):
            reply = (of(jev, "REPLY", i) or [{}])[0].get("text", "")
            judged[c["word"]] = reply
            if not reply.strip().lower().startswith("yes"):
                probs.append(f"{c['word']}: the model judged the card's meaning {c['card'].get('meaning')!r} against {WORDS[c['word']]!r}: {reply!r}")
    for w in words:
        for k in ("", "_mid", "_mid2"):
            src = OUT / f"m2_{w}{k}.png"
            if src.exists():
                shutil.copy(src, SHOTS / f"phone_word_{w}{k}.png")
    said.append(f"{len(words)} words: " + "; ".join(f"{c['word']}: {(c['card'] or {}).get('meaning')!r} points {c['points']} lags {c['lags']} judged {judged.get(c['word'])!r}" for c in cards))
    bench(m2=cards, m2_judged=judged)
    return ("FAIL", "; ".join(probs)) if probs else ("PASS", " | ".join(said) + " | phone screenshots docs/goals/77/phone_word_*.png")


def stubbed():
    """The card tools that are still the stubs of mojoui.visual (nothing else registers show_map or explain)."""
    found = set()
    for f in list((ROOT / "mojoui").rglob("*.mojo")) + list((ROOT / "examples/omx").rglob("*.mojo")):
        if f.name == "visual.mojo":
            continue
        t = f.read_text()
        for name, const in (("show_map", "SHOW_MAP"), ("explain", "EXPLAIN")):
            if re.search(r'(ToolFn|add_function|add_deferred)\(\s*("%s"|%s)' % (name, const), t):
                found.add(name)
    return [n for n in ("show_map", "explain") if n not in found]


def card_kind_of(ev, turn):
    for e in ev:
        if e["kind"] == "CARD" and e.get("turn") == turn:
            m = re.search(r"cardkind=(\w+)", e.get("raw", ""))
            return m.group(1) if m else "other"
    return ""


def turn_kind(ev, turn):
    """The kind of card the turn went for: its first card tool (show_map, explain, to-do, news), or render_ui and what it built."""
    for e in of(ev, "CALL", turn):
        name = str(e.get("name", ""))
        if name == "show_map":
            return "map"
        if name == "explain":
            return "iso"
        if name.startswith("todo_"):
            return "todo"
        if name == "news":
            return "news"
        if name == "render_ui":
            return card_kind_of(ev, turn)
    return ""


def m5():
    why = build()
    if why:
        return "FAIL", why
    with g72.NullSink():
        ev, r = typed_turns([u for u, _ in ROUTING])
    rows, probs = [], []
    for i, (said_, want) in enumerate(ROUTING, 1):
        got = turn_kind(ev, i)
        reply = (of(ev, "REPLY", i) or [{}])[0].get("text", "")
        n = sentences(reply)
        rows.append({"said": said_, "want": want, "got": got, "sentences": n, "reply": reply})
        if got != "" and n > 2:
            probs.append(f"turn {i} spoke {n} sentences on a card: {reply!r}")
    right = [x for x in rows if x["want"] == x["got"]]
    stubs = stubbed()
    bench(m5=rows, m5_stubs=stubs)
    wrong = "; ".join(f"{x['said']!r} wanted {x['want'] or 'none'}, got {x['got'] or 'none'}" for x in rows if x["want"] != x["got"])
    real = [x for x in rows if not (x["want"] == "map" and "show_map" in stubs) and not (x["want"] == "iso" and "explain" in stubs)]
    real_right = [x for x in real if x["want"] == x["got"]]
    line = f"{len(right)} of {len(rows)} routed to the right card ({len(real_right)} of {len(real)} on the cards that exist)" + (f"; wrong: {wrong}" if wrong else "")
    if probs or len(right) < 9:
        return "FAIL", line + ("; " + "; ".join(probs) if probs else "")
    if stubs:
        return "BLOCKED", line + f"; speech on card turns at most 2 sentences. Only the missing tools block it: {', '.join(stubs)} still answer 'not available yet' (map: M3, isometric: M4), so those cards cannot be proved"
    return "PASS", line + "; speech on card turns at most 2 sentences"


def blocked(what):
    return lambda: ("BLOCKED", f"{what}: not built yet")


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": blocked("the map card (goal 77 M3)"), "M4": blocked("the isometric explainer (goal 77 M4)"),
              "M5": m5, "M6": blocked("the camera (goal 77 M6)"), "M7": blocked("the polish (goal 77 M7)")}


def main():
    want = [a.upper() for a in sys.argv[1:]] or list(MILESTONES)
    bad = 0
    for k in want:
        t0 = time.time()
        try:
            state, why = MILESTONES[k]()
        except Exception as e:  # shown, never swallowed
            state, why = "FAIL", f"{type(e).__name__}: {e}"
        print(f"{k}: {state}  {why}  ({time.time() - t0:.0f} s)", flush=True)
        bad += state == "FAIL"
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
