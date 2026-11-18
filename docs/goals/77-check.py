"""Goal 77's proof: omx shows and points (GOAL.md). Prints "Mn: PASS|FAIL|BLOCKED  why" per milestone.

    pixi run python docs/goals/77-check.py [M0 M1 M2 M5 ...]          (default: every milestone)

M0 ground, M1 she points (GTK headless, then the web host in headless Chromium), M2 the word card, M3 the map card (two trips on GTK at
tablet size, then on the web host in headless Chromium: stops within 25 km of hand-entered truth, points that fly the map and put the
ring on the marker, tiles in the browser), M5 visual first, M6 the camera. M4 (isometric) and M7 (polish) are other developers' and
report BLOCKED("not built yet") until they land. The language model of
M1, M2 and M5 runs on GPU $G77_GPU (default 0); M6's (the model, its vision projector and the voice) on GPU $G77_VISION_GPU (default 1),
PCI order as nvidia-smi counts. The machinery is goal 72's (docs/goals/72-check.py: the app on the headless display, typed turns, the null
sink). Numbers: build/g77; pictures: docs/goals/77.

M6 builds the shim with image input, draws (once) the scene's objects with the image model, runs the model's own tests
(tests/test_llm_vision: reading words and grounding with the real Qwen3.8-27B and its projector), the camera's (tests/test_camera: the
browser's hub, and this machine's webcam when there is one), genui's Sight component, and then the whole app: scripts/g77_camera_check.py
drives examples/omx on the web host with Chromium's fake camera; the reply that names the banana moves the pointer's ring onto the card's
banana box, and the ring's centre must be inside the banana's true box (as the app drew it and as its pixels show in the browser).
"""
import importlib.util
import json
import os
import re
import shutil
import subprocess
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

CTX = {"OMX_LLM_CTX": "32768", "MOJOUI_TODO": str(OUT / "todo.json")}  # (the context stays under 32768: one 3090 holds the brain and the voice; the to-do list is the checker's own file, emptied before each run)
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


def fresh_todo():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "todo.json").write_text('{"items":[]}')


def typed_turns(turns, shots=None, extra_wait=0):
    """One app run with typed turns; shots: [(ms after the last turn is sent, file)]. Returns (events, run)."""
    fresh_todo()
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
    fresh_todo()
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
        n = sum(1 for y in range(100, min(700, im.height)) for x in range(im.width) if px[x, y][0] < 90 and 120 < px[x, y][1] < 190 and 130 < px[x, y][2] < 200)
        if best is None or n > best[1]:
            best = (f, n)
    return best if best and best[1] > 1200 else None


def bench(**kv):
    OUT.mkdir(parents=True, exist_ok=True)
    f = OUT / "bench.json"
    data = json.loads(f.read_text()) if f.exists() else {}
    data.update(kv)
    f.write_text(json.dumps(data, indent=1))

# ------------------------------------------------------------------------------------------------ M3: the map card

TRIPS = [  # M3: what the person asks, the places it names (each must be a stop, within 25 km of its truth), and the truth for any stop
    ("Plan me a day in Lisbon: Belém Tower, the Alfama and LX Factory.", ["belem", "alfama", "lx factory"]),
    ("A trip through Rome, Florence and Venice.", ["rome", "florence", "venice"]),
]
TRUTH = {  # hand-entered (OpenStreetMap, checked by eye on osm.org), lower-case ASCII words a stop's name may carry -> (lat, lon)
    "belem": (38.6916, -9.2160), "alfama": (38.7114, -9.1301), "lx factory": (38.7036, -9.1784), "jeronimos": (38.6979, -9.2068),
    "sao jorge": (38.7139, -9.1335), "castle": (38.7139, -9.1335), "comercio": (38.7075, -9.1364), "baixa": (38.7110, -9.1370),
    "time out": (38.7069, -9.1459), "chiado": (38.7107, -9.1424), "bairro alto": (38.7126, -9.1457), "rossio": (38.7139, -9.1394),
    "pasteis": (38.6975, -9.2030), "maat": (38.6957, -9.1946), "monument to the discoveries": (38.6935, -9.2058), "padrao": (38.6935, -9.2058),
    "rome": (41.9028, 12.4964), "roma": (41.9028, 12.4964), "colosseum": (41.8902, 12.4922), "vatican": (41.9029, 12.4534),
    "florence": (43.7696, 11.2558), "firenze": (43.7696, 11.2558), "uffizi": (43.7678, 11.2553), "duomo": (43.7731, 11.2560),
    "venice": (45.4408, 12.3155), "venezia": (45.4408, 12.3155), "st mark": (45.4341, 12.3388), "san marco": (45.4341, 12.3388),
    "rialto": (45.4380, 12.3358), "pisa": (43.7230, 10.3966), "siena": (43.3188, 11.3308), "bologna": (44.4949, 11.3426),
}
STOP_KM = 25.0


def ascii_words(s):
    import unicodedata
    t = unicodedata.normalize("NFKD", str(s)).encode("ascii", "ignore").decode().lower()
    return " " + re.sub(r"[^a-z0-9]+", " ", t).strip() + " "


def truth_of(name):
    """The truth entry a stop's name names (the longest key found in it as whole words), or None."""
    words = ascii_words(name)
    keys = [k for k in TRUTH if f" {k} " in words]
    return max(keys, key=len) if keys else None


def km_between(a, b):
    import math
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 6371 * 2 * math.asin(min(1, math.sqrt(h)))


def map_stops(maps):
    """The settled stops of the newest map card in OMX MAP lines: [{n, name, lat, lon, how, geocoder_km, cached}] in order."""
    rows = {}
    card = None
    for m in maps:
        if "stop" in m and "lat" in m:
            if card != m.get("card"):
                card, rows = m.get("card"), {}
            rows[int(m["stop"])] = {"n": int(m["stop"]), "name": m.get("text", ""), "lat": float(m["lat"]), "lon": float(m["lon"]), "how": m.get("how"),
                                   "geocoder_km": float(m.get("geocoder_km", -1)), "cached": m.get("cached")}
    return card, [rows[k] for k in sorted(rows)]


def judge_trip(ask, wanted, stops, points, flights):
    """(problems, the stops with their distance to the truth) for one trip."""
    probs = []
    for st in stops:
        key = truth_of(st["name"])
        if key is None:  # (a stop the checker has no truth for by name: the nearest truth of this trip's places)
            near = min(wanted, key=lambda k: km_between((st["lat"], st["lon"]), TRUTH[k]))
            st["truth"], st["km"], st["by"] = near, round(km_between((st["lat"], st["lon"]), TRUTH[near]), 2), "nearest"
        else:
            st["truth"], st["km"], st["by"] = key, round(km_between((st["lat"], st["lon"]), TRUTH[key]), 2), "name"
        if st["km"] > STOP_KM:
            probs.append(f"{ask!r}: stop {st['n']} {st['name']!r} is {st['km']} km from {st['truth']} (limit {STOP_KM})")
    if len(stops) < 3:
        probs.append(f"{ask!r}: {len(stops)} stops, need 3")
    for w in wanted:
        if not any(st["truth"] == w and st["by"] == "name" for st in stops):
            probs.append(f"{ask!r}: no stop named for {w} (stops {[st['name'] for st in stops]})")
    on_stops = [p for p in points if re.match(r"^card\d+\.stop\d+$", str(p.get("tag")))]
    if len(on_stops) < 3:
        probs.append(f"{ask!r}: {len(on_stops)} points on stops, need 3 (all points: {[p.get('tag') for p in points]})")
    lags = [p["lag_ms"] for p in on_stops]
    if lags and max(abs(x) for x in lags) > LAG_LIMIT_MS:
        probs.append(f"{ask!r}: a point was shown {max(lags, key=abs)} ms from its audio (limit {LAG_LIMIT_MS})")
    if len(flights) < min(3, len(on_stops)):
        probs.append(f"{ask!r}: the map flew {len(flights)} times for {len(on_stops)} points")
    for p in on_stops:  # (the ring is drawn round the marker: a marker-sized rect)
        ring = [int(v) for v in str(p.get("ring", "-")).split(",")] if p.get("ring", "-") != "-" else []
        if len(ring) != 4 or not (16 <= ring[2] <= 36 and 16 <= ring[3] <= 36):
            probs.append(f"{ask!r}: point {p.get('tag')} ring {p.get('ring')} isn't round a marker")
    return probs, stops


def m3():
    why = build()
    if why:
        return "FAIL", why
    probs, said, numbers = [], [], {}
    OUT.mkdir(parents=True, exist_ok=True)
    SHOTS.mkdir(parents=True, exist_ok=True)
    # the framework's own: PNG decoding, the map offline, tiles and the geocoder against the real web
    for name, how in (("test_pngread", "scripts/mxbuild.sh"), ("test_tripmap", "scripts/mxbuild.sh"), ("test_mapweb", "flare")):
        cmd = ["scripts/mojo_flare.sh", "build", f"tests/{name}.mojo", "-o", f"build/{name}"] if how == "flare" else [how, f"tests/{name}.mojo", "-o", f"build/{name}"]
        b = g72.sh(cmd, 1800)
        if b.returncode:
            return "FAIL", f"{name} doesn't build: {g72.tail(b, 900)}"
        r = g72.sh([f"build/{name}"], 600)
        if r.returncode:
            return "FAIL", f"{name}: {g72.tail(r, 900)}"
        numbers[name] = [l for l in r.stdout.splitlines() if re.match(r"(pngread|tripmap|tiles|geocode)\b", l)]
    tl = next((l for l in numbers["test_mapweb"] if l.startswith("tiles cold_ms")), "")
    m = re.search(r"cold_ms ([\d.]+) cached_ms ([\d.]+)", tl)
    tile_cold, tile_cached = (float(m.group(1)), float(m.group(2))) if m else (None, None)
    # the app on GTK (the headless display): both trips typed, the replies spoken to the null sink
    g72.ensure_wavs()  # (the recorded microphone the app starts with: silent until after the run)
    env = dict(CTX, CUDA_DEVICE_ORDER="PCI_BUS_ID", MOJOUI_GEO_CACHE=str(OUT / "geo"))
    for old in OUT.glob("m3_gtk_*.png"):
        old.unlink()
    fresh_todo()
    steps = g72.TYPED_OPEN
    for k, (ask, _) in enumerate(TRIPS, 1):
        steps += f"enter:Type to omx={ask};waitfor:Speaking=150000;" + "".join(f"shot:{OUT}/m3_gtk_{k}_{i:02d}.png;wait:350;" for i in range(14)) + "waitfor:Listening=170000;wait:2500;"
    with g72.NullSink():
        ev, r = g72.run_app(g72.SILENT, steps, window="820x1180", env=env, timeout=1800)
    failed = [f for f in of(ev, "FAILED") if not f.get("raw", "").startswith("microphone")]
    if failed:
        probs.append("the app failed: " + failed[0].get("raw", ""))
    trips = []
    for k, (ask, wanted) in enumerate(TRIPS, 1):
        calls = [str(e.get("name")) for e in of(ev, "CALL", k)]
        maps = [e for e in ev if e["kind"] == "MAP"]
        card = next((e for e in of(ev, "CARD", k) if "cardkind=map" in e.get("raw", "")), None)
        if "show_map" not in calls or card is None:
            probs.append(f"{ask!r}: no map card (calls {calls}; reply {(of(ev, 'REPLY', k) or [{}])[0].get('text')!r})")
            trips.append({"ask": ask, "calls": calls})
            continue
        cardname = re.search(r"cards=(\d+)", card.get("raw", ""))
        cname = f"card{cardname.group(1)}" if cardname else None
        mine = [m_ for m_ in maps if m_.get("card") == cname]
        _, stops = map_stops(mine)
        points = of(ev, "POINT", k)
        flights = [m_ for m_ in mine if "fly" in m_]
        tiles = next((m_ for m_ in mine if "tiles" in m_), {})
        p_, stops = judge_trip(ask, wanted, stops, points, flights)
        probs += p_
        trips.append({"ask": ask, "card": cname, "stops": stops, "points": [(p.get("tag"), p.get("lag_ms"), p.get("ring")) for p in points],
                      "flights": len(flights), "tiles": {x: tiles.get(x) for x in ("tiles", "net", "net_ms", "disk", "disk_ms", "full_ms")},
                      "reply": (of(ev, "REPLY", k) or [{}])[0].get("text")})
    shot = max(OUT.glob("m3_gtk_1_*.png"), key=lambda f: f.stat().st_size, default=None)
    if shot:
        shutil.copy(shot, SHOTS / "m3-map-gtk.png")
    bench(m3_gtk=trips, m3_tests=numbers, m3_tile_cold_ms=tile_cold, m3_tile_cached_ms=tile_cached)
    for t in trips:
        if "stops" in t:
            said.append(f"GTK {t['ask']!r}: " + ", ".join(f"{st['n']} {st['name']} {st['km']} km ({st['how']})" for st in t["stops"])
                        + f"; {len(t['points'])} points lags {[p[1] for p in t['points']]} ms, {t['flights']} flights")
    # the web host at tablet size: both trips again, the ring round the marker and the tiles in the browser
    if not probs and not os.environ.get("G77_SKIP_WEB"):
        b = g72.sh(["scripts/build.sh", "omx", "web"], 3600)
        if b.returncode:
            probs.append("web build: " + g72.tail(b, 400))
        else:
            w = g72.sh(["pixi", "run", "python", "scripts/omx_map_web.py"], 2400)
            if w.returncode or "omx_map_web: ok" not in w.stdout:
                probs.append("web host: " + g72.tail(w, 900))
            else:
                rep = json.loads((OUT / "omx-map-web.json").read_text())
                web = []
                for (ask, wanted), t in zip(TRIPS, rep["trips"]):
                    wev = g72.parse_omx("\n".join(t["maps"] + t["points"]))
                    _, stops = map_stops([e for e in wev if e["kind"] == "MAP"])
                    p_, stops = judge_trip(ask, wanted, stops, [e for e in wev if e["kind"] == "POINT"], [e for e in wev if e["kind"] == "MAP" and "fly" in e])
                    probs += ["web: " + x for x in p_]
                    web.append({"ask": ask, "stops": stops, "ring_share": t["ring_share"], "tile_colours": t["tile_colours"], "shot": t["shot"]})
                    said.append(f"web {ask!r}: " + ", ".join(f"{st['n']} {st['name']} {st['km']} km" for st in stops)
                                + f"; ring share {t['ring_share']}, {t['tile_colours']} colours of tiles; {t['shot']}")
                bench(m3_web=web)
    said.append(f"tiles: {tile_cold:.0f} ms a tile from the web (request + decode, median), {tile_cached:.2f} ms from the disk cache" if tile_cold else "tiles: no numbers")
    said.append("GTK screenshot docs/goals/77/m3-map-gtk.png")
    return ("FAIL", "; ".join(probs)) if probs else ("PASS", " | ".join(said))


# ------------------------------------------------------------------------------------------------ M2, M5, the rest


def card_args(ev, turn):
    """Every component on the turn's cards, as dicts (what the model put on the card): the root and everything inside it, since
    the visual-first prompt puts each card's content in a Card (D-7716, D-7734)."""
    out = []

    def walk(node):
        if isinstance(node, dict):
            out.append(node)
            for child in node.get("children", []) or []:
                walk(child)
            if isinstance(node.get("child"), dict):
                walk(node["child"])

    for e in of(ev, "CARD", turn):  # (the CARD line carries the card as the agent built it)
        try:
            walk(json.loads(e.get("text", "")))
        except ValueError:
            pass
    return out


def subsequence(want, got):
    it = iter(got)
    return all(any(w == g for g in it) for w in want)


WRONG_MEANINGS = [("ubiquitous", "rare and hard to find."), ("ephemeral", "lasting forever; permanent.")]


def judge_question(word, meaning):
    """Is a card's meaning right for the word, against a dictionary's (D-7734): the same sense, however it is worded or how much it
    adds; the controls (WRONG_MEANINGS) must come back "no"."""
    return (f"Judge this. A dictionary says the word {word} means: {WORDS[word]}. A card says it means: {meaning} "
            f"Is the card's meaning a correct meaning of {word}, the same sense as the dictionary's even if it is worded differently "
            f"or says a little more? Answer with one word only, yes or no.")


def m2():
    why = build()
    if why:
        return "FAIL", why
    probs, said = [], []
    words = list(WORDS)
    SHOTS.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    fresh_todo()
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
            jt.append(judge_question(c["word"], got))
        for w, wrong in WRONG_MEANINGS:  # (controls: a wrong meaning must be judged wrong, or a "yes" proves nothing)
            jt.append(judge_question(w, wrong))
        with g72.NullSink():
            jev, _ = typed_turns(jt)
        for i, c in enumerate(cards, 1):
            reply = (of(jev, "REPLY", i) or [{}])[0].get("text", "")
            judged[c["word"]] = reply
            if not reply.strip().lower().startswith("yes"):
                probs.append(f"{c['word']}: the model judged the card's meaning {c['card'].get('meaning')!r} against {WORDS[c['word']]!r}: {reply!r}")
        for j, (w, wrong) in enumerate(WRONG_MEANINGS, len(cards) + 1):
            reply = (of(jev, "REPLY", j) or [{}])[0].get("text", "")
            judged[f"control {w}: {wrong}"] = reply
            if not reply.strip().lower().startswith("no"):
                probs.append(f"the judge passed a wrong meaning of {w} ({wrong!r}): {reply!r}, so its yes proves nothing")
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


# ------------------------------------------------------------------------------------------------ M6: the camera

VGPU = os.environ.get("G77_VISION_GPU", "1")
VENV = {"CUDA_DEVICE_ORDER": "PCI_BUS_ID", "LLM_GPU": VGPU, "G77_VISION_GPU": VGPU}


def vsh(cmd, timeout=3600, env=None, **kw):
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(cmd, cwd=ROOT, env=e, capture_output=True, text=True, timeout=timeout, **kw)


def vtail(r, n=700):
    return (r.stdout + r.stderr)[-n:]


def free_mib(index):
    out = vsh(["nvidia-smi", "--query-gpu=index,memory.free", "--format=csv,noheader,nounits"]).stdout.splitlines()
    for line in out:
        i, _, free = line.partition(",")
        if i.strip() == str(index):
            return int(free)
    return 0


def m6():
    need_mib = 21000
    if free_mib(VGPU) < need_mib:
        return "BLOCKED", f"GPU {VGPU} has {free_mib(VGPU)} MiB free; the 27B model, its projector and the voice need {need_mib}"
    for step in (["scripts/build_llm_shim.sh"], ["pixi", "run", "python", "scripts/g77_scene.py"]):
        r = vsh(step)
        if r.returncode:
            return "FAIL", f"{' '.join(step)}: {vtail(r)}"
    numbers = {}
    # the framework's own tests
    for name, extra in (("test_grounding", {}), ("test_camera", {}), ("test_llm_vision", VENV), ("test_genui", {}), ("test_pointer", {})):
        b = vsh(["scripts/mxbuild.sh", f"tests/{name}.mojo", "-o", f"build/{name}"])
        if b.returncode:
            return "FAIL", f"{name} doesn't build: {vtail(b, 900)}"
        r = vsh([f"build/{name}"], env=extra, timeout=1800)
        if r.returncode:
            return "FAIL", f"{name}: {vtail(r, 900)}"
        numbers[name] = [l for l in r.stdout.splitlines() if re.match(r"(vision|camera|grounding|sight|picture|pointer)\b", l)]
    desk = [l for l in numbers["test_camera"] if l.startswith("camera desktop")]
    desk_note = "" if desk and ": ok" in desk[0] else " (the desktop camera: BLOCKED, " + (desk[0] if desk else "no camera on this machine") + ")"
    # the whole app, on the web host
    b = vsh(["scripts/build.sh", "omx", "web"], 3600)
    if b.returncode:
        return "FAIL", "build omx web: " + vtail(b, 900)
    r = vsh(["pixi", "run", "python", "scripts/g77_camera_check.py", "all"], 3600, VENV)
    if r.returncode or "camera: all ok" not in r.stdout:
        return "FAIL", vtail(r, 1200)
    rep = json.loads((OUT / "camera.json").read_text())
    s, t = rep["scene"], rep["text"]
    vision = " ".join(numbers["test_llm_vision"])
    m = re.search(r"worst IoU ([\d.]+) , mean answer time ([\d.]+) ms, mean image encode ([\d.]+) ms", vision)
    (OUT / "m6.json").write_text(json.dumps({"camera": rep, "tests": numbers}, indent=1))
    return "PASS", (f"\"Where is the banana?\" through the tablet's fake camera: the card's banana box IoU {s['iou']} (limit 0.4) with the truth, "
                    f"the reply \"{s['reply']}\", the pointer's ring on the banana while it was said (centre {s['ring_app_px'][0]:.0f},{s['ring_app_px'][1]:.0f} by the app, "
                    f"{s['ring_pixels_px'][0]:.0f},{s['ring_pixels_px'][1]:.0f} by its pixels, inside the true box {[round(v) for v in s['truth_px']]}, {s['point_lag_ms']} ms after its audio); look {s['ms']} ms "
                    f"(frame {s['frame_ms']}, image encode {s['image_ms']} for {s['image_tokens']} tokens, model {s['read_ms']}); "
                    f"{s['outward_bytes_sent']} bytes outward; the sign read \"{t['reply']}\"; in-process grounding on all three objects "
                    f"(worst IoU {float(m.group(1)):.2f}, {float(m.group(2)):.0f} ms an answer); docs/goals/77/m6-camera-banana.png" + desk_note)


def blocked(what):
    return lambda: ("BLOCKED", f"{what}: not built yet")


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": blocked("the isometric explainer (goal 77 M4)"),
              "M5": m5, "M6": m6, "M7": blocked("the polish (goal 77 M7)")}


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
