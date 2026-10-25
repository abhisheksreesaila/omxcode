"""Milestone checker for GOAL.md (goal 33: OMX Console rebuilt in omxcode; goal 32's passing M0–M2 and goal 30's
M0–M5 run as M8, every earlier goal's inside them). Rebuilds from scratch, prints PASS/FAIL per milestone.

Run: scripts/check   (a subset without rebuilding: scripts/check M0 M1; earlier goals: through docs/goals/NN-check.py)
Each milestone's proof is written before its work starts (todo() until then: it fails), from GOAL.md's words.
The original console is read from MXCONSOLE_DIR (default ~/Projects/mxstudio/mxconsole/console), never written.
"""

import importlib.util
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
OUT = ROOT / "docs" / "goals" / "33"
FIXTURES = OUT / "fixtures"
MXCONSOLE_DIR = Path(os.environ.get("MXCONSOLE_DIR", Path.home() / "Projects/mxstudio/mxconsole/console"))
SIZES = [(1440, 900), (390, 844)]
SCREENS = ["models", "overview", "bench", "logs", "notebook", "add", "keys", "gateway", "security", "settings"]
POLLED = ["/admin/models", "/admin/metrics", "/admin/series", "/admin/requests", "/admin/info", "/admin/system",
          "/admin/pulls", "/admin/ports"]  # what the console asks every 0.7–15 s (core.js, system-data.js, beacon.js)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g32 = load("goal32", "docs/goals/32-check.py")
g30 = g32.g30


def todo(what):
    def fn():
        return False, f"not built yet: {what}"
    return fn


def m0():
    """The measure: recorded replies, the original's ten screens at two sizes, twice, and the noise floor."""
    problems = []
    if not (MXCONSOLE_DIR / "index.html").exists():
        return False, f"no original console at {MXCONSOLE_DIR} (set MXCONSOLE_DIR)"
    for path in POLLED:
        if not list(FIXTURES.glob(path.strip("/").replace("/", "_") + "*.json")):
            problems.append(f"no recorded reply for {path} in {FIXTURES.relative_to(ROOT)}")
    try:
        import console_side
    except ImportError as e:
        return False, f"scripts/console_side.py missing: {e}"
    if [s for s, _ in console_side.SCREENS] != SCREENS or list(console_side.SIZES) != SIZES:
        problems.append(f"console_side shoots {console_side.SCREENS} at {console_side.SIZES}, not GOAL.md's ten at {SIZES}")
    runs = []
    for run_id in ("a", "b"):
        shots, misses = console_side.shoot_original(run_id)  # {(screen, (w, h)): png path}, [paths not in the fixtures]
        if misses:
            problems.append(f"run {run_id}: the console asked for paths the fixtures don't hold: {sorted(set(misses))[:8]}")
        want = {(s, size) for s in SCREENS for size in SIZES}
        if set(shots) != want:
            problems.append(f"run {run_id} is missing {sorted(want - set(shots))[:6]}")
        runs.append(shots)
    if problems:
        return False, "; ".join(problems)
    floor = 0.0
    for key in runs[0]:
        floor = max(floor, console_side.differing(runs[0][key], runs[1][key]))  # share of pixels that differ, 0–1
    (OUT / "floor.txt").write_text(f"{floor:.5f}\n")
    if floor > 0.01:
        return False, f"the original differs from itself by {floor:.2%} of pixels on some screen (> 1 %): the measure is too noisy"
    return True, f"20 screens shot twice from {len(list(FIXTURES.glob('*.json')))} recorded replies; noise floor {floor:.3%}"


HTTP_MARK = "test_http: all passed"


_g5 = []


def g5():
    """Goal 5's gtk() and web(): an example run with MOJOUI_TEST steps (scripts/drive.py on the web), its state read back."""
    if not _g5:
        mod = load("goal5", "docs/goals/05-check.py")
        mod.ROOT, mod.BUILD = ROOT, ROOT / "build"  # (archived in docs/goals/: its own ROOT would be docs/, as goal 6 notes)
        _g5.append(mod)
    return _g5[0]


def build(example, *hosts):
    """scripts/build.sh for each host; the first failure's tail, or None."""
    for host in hosts:
        b = g30.run(["scripts/build.sh", example, host], timeout=1800)
        if b.returncode != 0:
            return f"{example} doesn't build for {host}: " + (b.stdout + b.stderr)[-600:]
    return None


def labels(out):
    return [l[len("LABEL: "):] for l in out.splitlines() if l.startswith("LABEL: ")]


def label_value(out, prefix):
    """The text after `prefix` in the first label that starts with it (None: no such label)."""
    for l in labels(out):
        if l.startswith(prefix):
            return l[len(prefix):].strip()
    return None


def m1():
    """HTTP, a component: requests as effects, replies as Events, off the main thread, against a real server."""
    import re
    import secrets
    import http_server
    problems = []
    for f in ("mojoui/http.mojo", "tests/test_http.mojo", "examples/httpcheck/app.mojo"):
        if not (ROOT / f).exists():
            problems.append(f"no {f}")
    if problems:
        return False, "; ".join(problems)
    token = secrets.token_hex(12)
    exe = g30.BUILD / "test_http"
    b = g30.run(["pixi", "run", "mojo", "build", "-I", ".", "-I", "vendor", "tests/test_http.mojo", "-o", str(exe)], timeout=1800)
    if b.returncode != 0:
        return False, "tests/test_http.mojo doesn't build: " + (b.stdout + b.stderr)[-600:]
    with http_server.TestServer() as srv:
        # the test is told the env var's NAME only; the server checks the value arrived
        t = g30.run([str(exe)], env={"HTTP_TEST_URL": srv.url, "HTTP_TEST_DEAD": srv.dead, "HTTP_TEST_SECRET": token}, timeout=120)
        seen = list(srv.seen)
    out = t.stdout + t.stderr
    if t.returncode != 0 or HTTP_MARK not in out:
        return False, "tests/test_http.mojo fails: " + out[-700:]
    lines = {l.split(":", 1)[0]: l.split(":", 1)[1].strip() for l in out.splitlines() if re.match(r"^[A-Z0-9]+: ", l)}

    def want(key, ok, why):
        if key not in lines:
            problems.append(f"the test printed no {key} line")
        elif not ok(lines[key]):
            problems.append(f"{key}: {lines[key][:160]!r} ({why})")

    import json as pyjson
    want("GET", lambda v: v.startswith("200 ") and pyjson.loads(v[4:]) == http_server.JSON_REPLY, "a GET of /json: status 200 and the server's JSON")
    want("POST", lambda v: v.startswith("200 ") and pyjson.loads(v[4:]) == {"method": "POST", "type": "application/json", "body": {"name": "Ada", "n": 3, "ok": True}},
         "a POST of JSON, echoed with its content type")
    want("HEADER", lambda v: v == "200 " + token, "the header's value read from $HTTP_TEST_SECRET, as the server got it")
    want("CHUNKED", lambda v: v == "200 " + b"".join(http_server.CHUNKS).decode(), "the chunked reply, joined")
    want("BIG", lambda v: v == f"200 {http_server.BIG_SIZE} {http_server.fnv1a(http_server.BIG)}", "1 MiB, every byte (FNV-1a)")
    want("TIMEOUT", lambda v: re.match(r"^(\d+) ", v) and 400 <= int(v.split()[0]) <= 1500 and "timed out" in v,
         "a 500 ms timeout on a 3 s reply: an error within 0.4–1.5 s")
    want("REFUSED", lambda v: "refused" in v, "connection refused, as an error")
    want("FAIL", lambda v: v == "500 boom", "a 500 is a reply (status and body), not an error")
    want("HTTPS", lambda v: "TLS" in v, "https:// with the socket backend: a clear error, not a crash")
    want("DISPATCH", lambda v: float(v.split()[0]) < 100, "update() that asks for a 3 s reply returns at once (ms)")
    asked = {(r["method"], r["path"].split("?")[0]) for r in seen}
    for m, path in [("GET", "/json"), ("POST", "/echo"), ("GET", "/header"), ("GET", "/chunked"), ("GET", "/big"), ("GET", "/slow"), ("GET", "/fail")]:
        if (m, path) not in asked:
            problems.append(f"the server never saw {m} {path}")
    if not any(r["path"].startswith("/header") and r["headers"].get("x-test-key") == token for r in seen):
        problems.append("the server never got X-Test-Key with $HTTP_TEST_SECRET's value")
    if not any(r["method"] == "POST" and r["headers"].get("content-type") == "application/json" for r in seen):
        problems.append("the POST didn't say Content-Type: application/json")
    if problems:
        return False, "; ".join(problems)
    # examples/httpcheck: frames keep coming on GTK and the web while one reply takes 2 s, then the reply shows
    err = build("httpcheck", "linux", "web", "mac")
    if err:
        return False, err
    host_notes = []
    for host in ("gtk", "web"):
        with http_server.TestServer() as srv:
            steps = f"type:URL={srv.url}slow?ms=2000;tap:Fetch;pause:3500"
            if host == "gtk":
                r, out = g5().gtk("httpcheck", steps, shot=str(OUT / "httpcheck-gtk.png"))
            else:
                r, out = g5().web("httpcheck", steps, shot=str(OUT / "httpcheck-web.png"))
            seen = list(srv.seen)
        if r is None:
            problems.append(f"{host}: {out[-400:]}")
            continue
        frames, waited, gap, reply = (label_value(out, p) for p in ("frames while waiting:", "waited:", "longest frame gap:", "reply:"))
        if None in (frames, waited, gap, reply):
            problems.append(f"{host}: httpcheck doesn't show frames/waited/gap/reply: {labels(out)[:8]}")
            continue
        frames, waited, gap = int(frames), float(waited.split()[0]), float(gap.split()[0])
        if not any(s["path"] == "/slow?ms=2000" for s in seen):
            problems.append(f"{host}: the server never saw GET /slow?ms=2000")
        if reply != "200 slept 2000 ms":
            problems.append(f"{host}: the reply shown is {reply!r}, not '200 slept 2000 ms'")
        if not 1900 <= waited <= 3400:
            problems.append(f"{host}: waited {waited} ms for a 2 s reply")
        if frames < 60:
            problems.append(f"{host}: {frames} frames while the reply took {waited:.0f} ms (< 60)")
        if gap > 250:
            problems.append(f"{host}: a {gap:.0f} ms gap between frames while waiting (something blocked)")
        host_notes.append(f"{host} {frames} frames in {waited:.0f} ms, longest gap {gap:.0f} ms")
    if problems:
        return False, "; ".join(problems)
    return True, "tests/test_http.mojo: GET, POST JSON, env header, chunked, 1 MiB, timeout, refused, 500, https refused; " + "; ".join(host_notes) + "; Mac builds"


JSON_CORPUS = ROOT / "tests" / "fixtures" / "json"  # edge cases beside the recorded replies (decimals, exponents, \u…)


def json_leaves(value, path="$"):
    """A JSON value as the lines tests/json_dump.mojo prints: one per container and leaf, keys and strings as UTF-8 hex,
    floats as their IEEE bits (value for value, nothing lost to formatting)."""
    import struct
    if isinstance(value, dict):
        yield f"{path}\tobj {len(value)}"
        for k, v in value.items():
            yield from json_leaves(v, path + "." + k.encode().hex())
    elif isinstance(value, list):
        yield f"{path}\tarr {len(value)}"
        for i, v in enumerate(value):
            yield from json_leaves(v, f"{path}[{i}]")
    elif value is None:
        yield f"{path}\tnull"
    elif value is True or value is False:
        yield f"{path}\t{'true' if value else 'false'}"
    elif isinstance(value, int):
        yield f"{path}\tint {value}"
    elif isinstance(value, float):
        yield f"{path}\tfloat {struct.pack('>d', value).hex()}"
    else:
        yield f"{path}\tstr {value.encode().hex()}"


def ticks_ok(out, host):
    """App.every(100 ms) ten times: tick k lands k × 100 ms after the tap, ± 20 ms, and so does each gap."""
    shown = label_value(out, "ticks:")
    if shown is None:
        return f"{host}: httpcheck shows no ticks label: {labels(out)[:8]}"
    ticks = [int(t) for t in shown.split()]
    if len(ticks) != 10:
        return f"{host}: {len(ticks)} ticks, not 10: {ticks}"
    late = [(k + 1, t) for k, t in enumerate(ticks) if abs(t - 100 * (k + 1)) > 20]
    gaps = [b - a for a, b in zip([0] + ticks, ticks)]
    if late or any(abs(g - 100) > 20 for g in gaps):
        return f"{host}: ticks at {ticks} ms (gaps {gaps}): not within ±20 ms of every 100 ms"
    return None


def m2():
    """Timers and real JSON: App.every on GTK and the web; json.mojo equals Python's json.loads on every recorded reply."""
    import json as pyjson
    problems = []
    # json.mojo: its own tests still pass, then every recorded reply (and the edge-case corpus), value for value
    err = g30.g20.mojo_test("tests/test_json.mojo", "JSON TESTS PASSED", "test_json")
    if err:
        problems.append(err)
    exe = g30.BUILD / "json_dump"
    b = g30.run(["pixi", "run", "mojo", "build", "-I", ".", "tests/json_dump.mojo", "-o", str(exe)], timeout=1800)
    if b.returncode != 0:
        return False, "tests/json_dump.mojo doesn't build: " + (b.stdout + b.stderr)[-600:]
    recorded = sorted(FIXTURES.glob("*.json"))
    if not recorded:
        problems.append(f"no recorded replies in {FIXTURES.relative_to(ROOT)} (M0 records them)")
    corpus = sorted(JSON_CORPUS.glob("*.json"))
    if not corpus:
        problems.append(f"no edge-case corpus in {JSON_CORPUS.relative_to(ROOT)}")
    values = 0
    seen = {"decimals": 0, "negatives": 0, "exponents": 0, "\\u escapes": 0, "nulls": 0}
    for f in recorded + corpus:
        text = f.read_text(encoding="utf-8")
        want = list(json_leaves(pyjson.loads(text)))
        r = g30.run([str(exe), str(f)], timeout=120)
        got = r.stdout.splitlines()
        if r.returncode != 0 or got != want:
            first = next((i for i, (a, b) in enumerate(zip(got, want)) if a != b), min(len(got), len(want)))
            problems.append(f"{f.relative_to(ROOT)}: json.mojo differs from json.loads at line {first}: "
                            f"{got[first] if first < len(got) else '(missing)'!r} vs {want[first] if first < len(want) else '(extra)'!r} {r.stderr[-200:]}")
            continue
        values += len(want)
        seen["decimals"] += sum(1 for l in want if "\tfloat " in l)
        seen["negatives"] += sum(1 for l in want if "\tint -" in l) + sum(1 for l in want if "\tfloat " in l and int(l.split()[-1][0], 16) >= 8)
        seen["exponents"] += len(__import__("re").findall(r"\d[eE][-+]?\d", text))
        seen["\\u escapes"] += text.count("\\u")
        seen["nulls"] += sum(1 for l in want if l.endswith("\tnull"))
    missing = [k for k, n in seen.items() if n == 0]
    if missing:
        problems.append(f"nothing read had {', '.join(missing)}")
    # App.every on GTK and the web
    err = build("httpcheck", "linux", "web")
    if err:
        return False, "; ".join(problems + [err])
    for host in ("gtk", "web"):
        steps = "tap:Start ticks;pause:1600"
        r, out = g5().gtk("httpcheck", steps, shot=str(OUT / "ticks-gtk.png")) if host == "gtk" else g5().web("httpcheck", steps)
        if r is None:
            problems.append(f"{host}: {out[-400:]}")
            continue
        bad = ticks_ok(out, host)
        if bad:
            problems.append(bad)
    if problems:
        return False, "; ".join(problems)
    return True, (f"10 ticks of 100 ms within ±20 ms on GTK and the web; json.mojo = json.loads on {len(recorded)} recorded replies "
                  f"and {len(corpus)} edge-case files, {values} values (" + ", ".join(f"{n} {k}" for k, n in seen.items()) + ")")


OMXQUA_TOKENS = MXCONSOLE_DIR / "omxqua" / "src" / "tokens.css"  # the console's omxqua: the reference, read only


def css_vars(css, selector):
    """The --oq-* variables declared in the rule whose selector is exactly `selector` (later rules win)."""
    import re
    out = {}
    for m in re.finditer(r"(?:^|\n)\s*" + re.escape(selector) + r"\s*\{(.*?)\}", css, re.S):
        body = re.sub(r"/\*.*?\*/", "", m.group(1), flags=re.S)
        for name, value in re.findall(r"(--oq-[\w-]+)\s*:\s*([^;]+);", body):
            out[name] = value.strip()
    return out


def omxqua_tokens(dark):
    """What the console wears, from tokens.css: the root's type, shape and motion, the Developer family (D-330: the
    console's `oq-root oq-family-dev oq-light|oq-night`), the light or night shadows."""
    css = OMXQUA_TOKENS.read_text()
    mode = ".oq-night" if dark else ".oq-light"
    t = css_vars(css, ".oq-root")
    t.update(css_vars(css, ".oq-root" + mode))
    t.update(css_vars(css, ".oq-family-dev"))
    t.update(css_vars(css, ".oq-family-dev" + mode))
    return t


def rgb_of(text):
    """'#eeeef1', 'rgb(1, 2, 3)', 'rgba(1,2,3,.5)' → (r, g, b, a)."""
    import re
    text = text.strip()
    if text.startswith("#"):
        h = text[1:]
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 1.0)
    m = re.match(r"rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)", text)
    if not m:
        return None
    return (int(float(m.group(1))), int(float(m.group(2))), int(float(m.group(3))), float(m.group(4)) if m.group(4) else 1.0)


def same_colour(a, b, tol=0):
    x, y = rgb_of(a), rgb_of(b)
    return x is not None and y is not None and all(abs(p - q) <= tol for p, q in zip(x[:3], y[:3])) and abs(x[3] - y[3]) <= 0.006


def shadow_layers(text):
    """A box-shadow (tokens' or Chromium's computed form) as [(inset, (x, y, blur, spread), (r, g, b, a))]."""
    import re
    if text.strip() in ("", "none"):
        return []
    layers = []
    for part in re.split(r",(?![^(]*\))", text):
        colour = re.search(r"rgba?\([^)]*\)|#[0-9a-fA-F]{6}", part)
        rest = (part[:colour.start()] + part[colour.end():]) if colour else part
        nums = [float(v) for v in re.findall(r"-?[\d.]+(?=px|\b)", rest.replace("inset", ""))]
        nums += [0.0] * (4 - len(nums))
        layers.append(("inset" in part, tuple(nums[:4]), rgb_of(colour.group(0)) if colour else None))
    return layers


def same_shadow(computed, token):
    a, b = shadow_layers(computed), shadow_layers(token)
    if len(a) != len(b):
        return False
    key = lambda l: (l[0], l[1])  # (Chromium keeps the order; sort anyway so an inset written last still matches)
    for x, y in zip(sorted(a, key=key), sorted(b, key=key)):
        if x[0] != y[0] or x[1] != y[1] or x[2] is None or y[2] is None:
            return False
        if x[2][:3] != y[2][:3] or abs(x[2][3] - y[2][3]) > 0.006:  # (alpha is 8 bits: .045 is 11/255)
            return False
    return True


def spring_points(text):
    """linear(0, 0.02, …) or Chromium's linear(0 0%, 0.02 2.5%, …) → the outputs."""
    import re
    m = re.search(r"linear\((.*?)\)", text)
    return [float(p.strip().split()[0]) for p in m.group(1).split(",")] if m else []


def styles(log):
    """{(selector, property): value} from drive.py's STYLE: lines."""
    out = {}
    for line in log.splitlines():
        if line.startswith("STYLE: "):
            sel, prop, value = None, None, None
            body = line[len("STYLE: "):]
            for p in PROPS:
                marker = " " + p + " "
                if marker in body:
                    sel, value = body.split(marker, 1)
                    prop = p
                    break
            if sel is not None:
                out[(sel, prop)] = value.strip()
    return out


PROPS = ["background-color", "border-radius", "box-shadow", "font-family", "color", "height", "transition-timing-function",
         "transition-duration", "border-top-left-radius"]
THEMES_OMXQUA = "omxqua"  # its title in examples/themes' picker


def m3():
    """The omxqua theme: themes/omxqua.mojo declares a Look from omxqua's tokens.css (Geist and Geist Mono, its accent,
    surfaces, one soft shadow, the press spring), light and dark; only framework tags styled (goal 32's lint). Proof:
    examples/themes in omxqua on the web, light and dark, every value read back from Chromium's computed styles and
    compared with tokens.css (the fonts loaded, not just named); on GTK the theme builds and its shots wear the same
    page, card and accent colours."""
    import re
    from PIL import Image
    problems = []
    src = ROOT / "themes" / "omxqua.mojo"
    if not src.exists():
        return False, "no themes/omxqua.mojo"
    if not OMXQUA_TOKENS.exists():
        return False, f"no omxqua tokens at {OMXQUA_TOKENS} (set MXCONSOLE_DIR)"
    text = src.read_text()
    for need, why in [("Look(", "a Look"), ("Motion(", "the press spring as data (a Motion)"), ("Geist Mono", "Geist Mono"),
                      ("\"Geist\"", "Geist")]:
        if need not in text:
            problems.append(f"themes/omxqua.mojo declares no {why}")
    if THEMES_OMXQUA not in (ROOT / "examples/themes/app.mojo").read_text():
        problems.append("examples/themes can't switch to omxqua")
    # goal 32's lint: every theme styles only the framework's tags, and no role is shaped by hand
    roles, found = g32.lint()
    problems += [f"lint: {p}" for p in found]
    # the fonts are the app's own, with their licence (D-155)
    fonts = ROOT / "mojoui/hosts/static/fonts"
    for f in ("Geist-Variable.ttf", "GeistMono-Variable.ttf", "LICENSE-Geist.txt"):
        if not (fonts / f).exists():
            problems.append(f"no mojoui/hosts/static/fonts/{f}")
    if problems:
        return False, "; ".join(problems[:8])
    err = build("themes", "linux", "web")
    if err:
        return False, err
    import drive
    notes = []
    for dark in (False, True):
        mode = "dark" if dark else "light"
        t = omxqua_tokens(dark)
        steps = ";".join([
            f"segment:0={THEMES_OMXQUA}", "pause:400",
            "style:body=background-color", "style:body=color", "style:body=font-family",
            "style:[data-tag=profile]=background-color", "style:[data-tag=profile]=border-top-left-radius", "style:[data-tag=profile]=box-shadow",
            "style:button.prominent=background-color", "style:button.prominent=color", "style:button.prominent=border-top-left-radius",
            "style:button.prominent=height", "style:button.prominent=transition-timing-function", "style:button.prominent=transition-duration",
            "style:input[type=text]=border-top-left-radius", "style:input[type=text]=height",
            "style:.segmented input:checked + span=background-color", "style:.segmented input:checked + span=box-shadow",
            "js:document.fonts.load(\"14px 'Geist'\").then(l => l.map(f => f.family + ' ' + f.status).join('|'))",
            "js:document.fonts.load(\"14px 'Geist Mono'\").then(l => l.map(f => f.family + ' ' + f.status).join('|'))",
            "hold:Save=500",
        ])
        shot = OUT / f"omxqua-themes-web-{mode}.png"
        try:
            r, log = drive.web_run(g30.BUILD / "themes" / "web", steps, shot=str(shot), viewport=(900, 760), color_scheme=mode)
        except Exception as e:
            problems.append(f"web {mode}: the run crashed: {e!r}")
            continue
        if r.returncode != 0:
            problems.append(f"web {mode}: {log[-300:]}")
            continue
        st = styles(log)
        want = [
            (("body", "background-color"), t["--oq-surface-0"], "colour", "the page: surface-0"),
            (("body", "color"), t["--oq-ink"], "colour", "the ink"),
            (("[data-tag=profile]", "background-color"), t["--oq-surface-1"], "colour", "a card: surface-1"),
            (("[data-tag=profile]", "border-top-left-radius"), t["--oq-radius-card"], "exact", "a card's corners: radius-card"),
            (("[data-tag=profile]", "box-shadow"), t["--oq-shadow-1"], "shadow", "a card's one soft shadow: shadow-1"),
            (("button.prominent", "background-color"), t["--oq-accent"], "colour", "the loud button: the accent"),
            (("button.prominent", "color"), t["--oq-on-accent"], "colour", "its title: on-accent"),
            (("button.prominent", "border-top-left-radius"), t["--oq-radius-full"], "exact", "buttons are pills: radius-full"),
            (("button.prominent", "height"), t["--oq-target"], "exact", "a button is the family's target high"),
            (("input[type=text]", "border-top-left-radius"), t["--oq-radius-in"], "exact", "a field's corners: radius-in"),
            (("input[type=text]", "height"), t["--oq-target"], "exact", "a field is the target high"),
            ((".segmented input:checked + span", "background-color"), t["--oq-surface-2"], "colour", "the chosen segment: surface-2"),
            ((".segmented input:checked + span", "box-shadow"), t["--oq-shadow-1"], "shadow", "the chosen segment's shadow-1"),
        ]
        for key, token, how, what in want:
            got = st.get(key)
            ok = got is not None and (same_colour(got, token) if how == "colour" else same_shadow(got, token) if how == "shadow" else got == token)
            if not ok:
                problems.append(f"web {mode}: {what}: {key[0]} {key[1]} is {got!r}, tokens.css says {token!r}")
        family = st.get(("body", "font-family"), "")
        if not family.replace('"', "").startswith("Geist"):
            problems.append(f"web {mode}: the body's font is {family!r}, not Geist first")
        js = [l[len("JS: "):] for l in log.splitlines() if l.startswith("JS: ")]
        if len(js) < 2 or "Geist loaded" not in js[0] or "Geist Mono loaded" not in js[1]:
            problems.append(f"web {mode}: Geist and Geist Mono didn't load from the app's own fonts: {js}")
        spring = spring_points(st.get(("button.prominent", "transition-timing-function"), ""))
        token_spring = spring_points(t["--oq-spring-fast"])
        if not spring or len(spring) != len(token_spring) or any(abs(a - b) > 1e-3 for a, b in zip(spring, token_spring)):
            problems.append(f"web {mode}: a button's transform doesn't settle on --oq-spring-fast ({st.get(('button.prominent', 'transition-timing-function'), '')[:60]!r})")
        dur = float(t["--oq-spring-fast-dur"].rstrip("ms")) / 1000
        if f"{dur:g}s" not in st.get(("button.prominent", "transition-duration"), ""):
            problems.append(f"web {mode}: the press doesn't take --oq-spring-fast-dur ({st.get(('button.prominent', 'transition-duration'))!r})")
        held = re.search(r"^HOLD: Save (.*)$", log, re.M)
        scale = float(t["--oq-press-scale"])
        m = re.match(r"matrix\(([-\d.]+), 0, 0, ([-\d.]+), [-\d.]+, [-\d.]+\)", held.group(1).strip()) if held else None
        if not m or abs(float(m.group(1)) - scale) > 0.002 or abs(float(m.group(2)) - scale) > 0.002:
            problems.append(f"web {mode}: Save held down is {held.group(1) if held else 'unread'}, not scale({scale})")
        notes.append(f"web {mode} {shot.name}")
    # GTK: the theme builds, Geist is handed to fontconfig, and the shots wear the tokens' page, card and accent
    exe = g30.BUILD / "themes" / "linux" / "themes"
    for f in ("Geist-Variable.ttf", "GeistMono-Variable.ttf"):
        if not (exe.parent / "fonts" / f).exists():
            problems.append(f"GTK: no fonts/{f} beside the binary")
        if f not in (ROOT / "mojoui/hosts/gtk.mojo").read_text():
            problems.append(f"GTK: the host doesn't hand {f} to fontconfig")
    for dark in (False, True):
        mode = "dark" if dark else "light"
        t = omxqua_tokens(dark)
        shot = OUT / f"omxqua-themes-gtk-{mode}.png"
        env = {"MOJOUI_TEST": f"segment:0={THEMES_OMXQUA}", "MOJOUI_WINDOW": "900x760", "MOJOUI_SHOT": str(shot)}
        env["ADW_DEBUG_COLOR_SCHEME"] = "force-dark" if dark else "prefer-light"  # (libadwaita has no force-light; the system's own mode must not decide)
        r = g30.run([str(exe)], env=env, timeout=300)
        out = r.stdout + r.stderr
        if r.returncode != 0 or "TEST: " in out or not shot.exists():
            problems.append(f"GTK {mode}: the run failed: {out[-300:]}")
            continue
        img = Image.open(shot).convert("RGB")
        k = img.size[0] / 900  # (the shot is at the display's scale)

        def px(x, y):
            return "#%02x%02x%02x" % img.getpixel((int(x * k), int(y * k)))
        if not same_colour(px(6, 750), t["--oq-surface-0"], 3):
            problems.append(f"GTK {mode}: the page is {px(6, 750)}, not surface-0 {t['--oq-surface-0']}")
        box = re.search(r"^BOX: profile ([\d.-]+) ([\d.-]+) ([\d.-]+) ([\d.-]+)$", out, re.M)
        save = re.search(r"^BOX: profile/Save ([\d.-]+) ([\d.-]+) ([\d.-]+) ([\d.-]+)$", out, re.M)
        if not box or not save:
            problems.append(f"GTK {mode}: no BOX for the profile card or its Save button")
            continue
        x, y, w, h = (float(v) for v in box.groups())
        if not same_colour(px(x + 6, y + h / 2), t["--oq-surface-1"], 3):
            problems.append(f"GTK {mode}: the card is {px(x + 6, y + h / 2)}, not surface-1 {t['--oq-surface-1']}")
        x, y, w, h = (float(v) for v in save.groups())
        if not same_colour(px(x + w / 2, y + 4), t["--oq-accent"], 3):
            problems.append(f"GTK {mode}: Save is {px(x + w / 2, y + 4)}, not the accent {t['--oq-accent']}")
        notes.append(f"GTK {mode} {shot.name}")
    if problems:
        return False, "; ".join(problems[:10])
    return True, (f"themes/omxqua.mojo: a Look (Geist, Geist Mono, accent, surfaces, shadow-1, press spring); the web light and dark "
                  f"read back equal to tokens.css (13 values, the fonts loaded, the spring, scale {scale}); GTK light and dark wear "
                  f"surface-0, surface-1 and the accent; goal 32's lint passes ({len(roles)} roles); shots: " + ", ".join(notes))


# M4: the console's components. Each has its own test (tests/test_<name>.mojo printing "<name>: ok"); the sampler
# (examples/consolekit) shows all eleven under omxqua and the drive steps exercise them on GTK and the web.
M4_PARTS = [  # (matrix row, test name)
    ("Table", "table"), ("CodeBlock", "codeblock"), ("LogView", "logview"), ("Timeline", "timeline"),
    ("Breadcrumbs", "breadcrumbs"), ("Chip · Badge", "chip"), ("Confirm", "confirm"), ("Skeleton", "skeleton"),
    ("Markdown", "markdown"), ("Sparkline", "sparkline"), ("Route", "route"),
]
KIT = "consolekit"
KIT_CODE = "curl http://127.0.0.1:11435/v1/models"  # what the sampler's CodeBlock holds (its Copy must put exactly this on the clipboard)
KIT_DEEP = "#/models/qwen2.5-0.5b/logs"  # the web opens here: the app's state must show that route
KIT_STEPS = ";".join([
    "tick:tick-0", "tick:tick-2",  # Table: two rows ticked
    "tap:Copy",  # CodeBlock: the clipboard holds the code; the button says Copied
    "tap:Revoke", "say:confirm-state", "tap:Click again to revoke",  # Confirm: the first tap only arms, the second acts
    "tap:Add log lines", "tap:Add log lines",  # LogView: 40 new lines, still pinned to the end
    "tap:Next stage",  # Timeline: the running stage is done, the next one runs
])


def m4_tests():
    """Builds and runs each component's own test (in parallel); [problems]."""
    from concurrent.futures import ThreadPoolExecutor
    problems = []

    def one(name):
        src = f"tests/test_{name}.mojo"
        if not (ROOT / src).exists():
            return f"no {src}"
        return g30.g20.mojo_test(src, f"{name}: ok", f"test_{name}")
    with ThreadPoolExecutor(max_workers=4) as pool:
        for name, err in zip([t for _, t in M4_PARTS], pool.map(one, [t for _, t in M4_PARTS])):
            if err:
                problems.append(err[:400])
    return problems


def m4_state(out, host):
    """What the sampler's run left on screen, against what the steps did; [problems]."""
    problems = []
    lv = lambda p: label_value(out, p)
    if lv("ticked:") != "qwen2.5-0.5b, llama3.2-1b":
        problems.append(f"{host}: Table: ticking rows 0 and 2 shows ticked {lv('ticked:')!r}")
    import re
    t = re.search(r"^TABLE: models (\d+) rows, (\d+) columns, (\d+) selected$", out, re.M)
    if not t or t.groups() != ("3", "8", "2"):
        problems.append(f"{host}: Table: no 'TABLE: models 3 rows, 8 columns, 2 selected' line ({t.group(0) if t else 'none'})")
    clip = re.search(r"^CLIPBOARD: (.*)$", out, re.M)
    if not clip or clip.group(1) != KIT_CODE:
        problems.append(f"{host}: CodeBlock: Copy put {clip.group(1) if clip else 'nothing'!r} on the clipboard, not {KIT_CODE!r}")
    if "BUTTON: Copied" not in out:
        problems.append(f"{host}: CodeBlock: its button doesn't say Copied after the tap")
    said = re.search(r"^SAYS: confirm-state = (.*)$", out, re.M)
    if not said or said.group(1) != "armed, revoked none":
        problems.append(f"{host}: Confirm: after one tap the state is {said.group(1) if said else 'unread'!r}, not 'armed, revoked none'")
    if lv("revoked:") != "notes-app (1 time)":
        problems.append(f"{host}: Confirm: after the second tap revoked is {lv('revoked:')!r}, not 'notes-app (1 time)'")
    if lv("log:") != "50 lines":
        problems.append(f"{host}: LogView: {lv('log:')!r} after two Add log lines, not '50 lines'")
    if lv("timeline:") != "2 of 4 done":
        problems.append(f"{host}: Timeline: after Next stage it says {lv('timeline:')!r}, not '2 of 4 done'")
    if not re.search(r"^PINNED: log at end$", out, re.M):
        problems.append(f"{host}: LogView: not at the end after new lines ({re.findall(r'^PINNED: .*$', out, re.M)})")
    for tag in ("breadcrumbs", "chip-1", "badge-ok", "pill", "skeleton", "code-block", "sample-markdown", "sample-sparkline", "sample-timeline"):
        b = re.search(rf"^BOX: {re.escape(tag)} [\d.-]+ [\d.-]+ ([\d.]+) ([\d.]+)$", out, re.M)
        if not b or float(b.group(1)) < 4 or float(b.group(2)) < 4:
            problems.append(f"{host}: no visible view tagged {tag} ({b.group(0) if b else 'no BOX'})")
    return problems


def m4():
    """The console's components: in mojoui/, each with its own test, on GTK and the web, built for the Mac: Table (rows,
    tick boxes), CodeBlock with Copy, LogView (pinned to the end), Timeline (stages, elapsed), Breadcrumbs, Chip/Badge,
    Confirm (tap twice), Skeleton, Markdown, Sparkline, Route (#/models/<name>/<tab> deep links on the web);
    docs/components.md regenerated; the debt table holds nothing from the console. Proof: every test passes; the sampler
    (examples/consolekit, omxqua) driven on GTK and the web: rows ticked, Copy read back from the clipboard, Confirm
    acting only on its second tap, the log still at its end after new lines, the web opened at a deep link showing that
    route, a route change writing the URL, Back going back; omxqua's values read back on the web (uppercase mono headers,
    hue chips, pill badges, mono code, the shimmer and motion off); builds for the Mac; the matrix current; the lint."""
    import re
    import subprocess
    problems = m4_tests()
    app = ROOT / "examples" / KIT / "app.mojo"
    if not app.exists():
        return False, "; ".join(problems + [f"no examples/{KIT}/app.mojo"])
    src = app.read_text()
    for ctor in ("Table(", "CodeBlock(", "LogView(", "Timeline(", "Breadcrumbs(", "Chip(", "Badge(", "ConfirmButton(", "Skeleton(",
                 "Markdown(", "SparklineView(", "Route(", "omxqua("):
        if ctor not in src:
            problems.append(f"the sampler doesn't use {ctor[:-1]}")
    roles, found = g32.lint()
    problems += [f"lint: {p}" for p in found]
    c = g30.run([sys.executable, "scripts/components.py", "--check"])
    if c.returncode != 0:
        problems.append(c.stdout.strip()[-200:])
    matrix = (ROOT / "docs" / "components.md").read_text()
    for name, _ in M4_PARTS:
        row = next((l for l in matrix.splitlines() if l.startswith(f"| `{name}` |")), None)
        if row is None:
            problems.append(f"docs/components.md has no row for {name}")
            continue
        cells = [x.strip() for x in row.split("|")[1:-1]]
        head = next(l for l in matrix.splitlines() if l.startswith("| Component |") and ("Module" in l) == ("mojoui/" in row))
        cols = [x.strip() for x in head.split("|")[1:-1]]
        get = lambda h: cells[cols.index(h)] if h in cols and cols.index(h) < len(cells) else "?"
        if get("Linux (GTK)") != "✅" or get("Web") != "✅" or get("Mac (AppKit)") == "❌":
            problems.append(f"matrix: {name} is GTK {get('Linux (GTK)')} web {get('Web')} Mac {get('Mac (AppKit)')} (want ✅ ✅ and not ❌)")
    debt = matrix.split("## Inside one app", 1)[-1].split("## The rule", 1)[0]
    if re.search(r"console", debt, re.I):
        problems.append("the debt table holds something from the console")
    if problems:
        return False, "; ".join(problems[:12])
    err = build(KIT, "linux", "web", "mac")
    if err:
        return False, err
    notes = []
    # GTK: the steps, then the route as state (a tap changes it; there's no URL)
    r, out = g5().gtk(KIT, KIT_STEPS + ";tap:Open keys;say:route-state;tap:Open qwen logs;say:route-state;tap:My models@0", shot=str(OUT / "consolekit-gtk.png"))
    if r is None:
        problems.append(f"GTK: {out[-400:]}")
    else:
        problems += m4_state(out, "GTK")
        says = re.findall(r"^SAYS: route-state = (.*)$", out, re.M)
        if says != ["/keys: keys", "/models/qwen2.5-0.5b/logs: model qwen2.5-0.5b, tab logs"] or not re.search(r"^ROUTE: /$", out, re.M) or label_value(out, "route:") != "/":
            problems.append(f"GTK: Route as state: Open keys, Open qwen logs, then the My models crumb went {says} → {label_value(out, 'route:')!r} ({re.findall(r'^ROUTE: .*$', out, re.M)})")
        notes.append("GTK")
    # the web: opened at a deep link; the steps; a route change writes the URL; Back goes back; the crumb goes home
    import drive
    t = omxqua_tokens(False)
    probes = [
        "style:[data-role=table-head] .text=font-family", "style:[data-role=table-head] .text=font-size", "style:[data-role=table-head] .text=letter-spacing",
        "style:[data-role=table-head] .text=color", "style:[data-role=table-head]=padding-left", "style:[data-role=table-cell]=padding-top",
        "style:[data-role=table-cell]=border-bottom-color", "style:[data-tag=chip-1]=border-radius", "style:[data-tag=chip-1]=color",
        "style:[data-tag=badge-ok]=border-radius", "style:[data-tag=badge-ok] .text=font-family", "style:[data-tag=pill]=border-radius",
        "style:[data-tag=code-block]=background-color", "style:[data-tag=code-block] .text=font-family", "style:[data-tag=skeleton]=animation-name",
    ]
    steps = ";".join(["js:location.hash", "say:route-state"] + KIT_STEPS.split(";") + probes
                     + ["tap:Open keys", "js:location.hash", "js:history.back()", "pause:300", "js:location.hash", "say:route-state", "tap:My models@0", "js:location.hash"])
    try:
        r, log = drive.web_run(g30.BUILD / KIT / "web", steps, shot=str(OUT / "consolekit-web.png"), viewport=(1440, 900), color_scheme="light", path=KIT_DEEP)
    except Exception as e:
        r, log = None, f"crashed: {e!r}"
    if r is None or r.returncode != 0:
        problems.append(f"web: {log[-400:]}")
    else:
        problems += m4_state(log, "web")
        js = [l[len("JS: "):] for l in log.splitlines() if l.startswith("JS: ")]
        says = re.findall(r"^SAYS: route-state = (.*)$", log, re.M)
        want_js = ['"' + KIT_DEEP + '"', '"#/keys"', None, '"' + KIT_DEEP + '"', '"#/"']
        if len(js) != 5 or any(w is not None and j != w for j, w in zip(js, want_js)):
            problems.append(f"web: Route: the URL went {js}, not {KIT_DEEP} → #/keys → (Back) {KIT_DEEP} → #/")
        if says[:2] != ["/models/qwen2.5-0.5b/logs: model qwen2.5-0.5b, tab logs"] * 2:
            problems.append(f"web: Route: opened at {KIT_DEEP} (and after Back) the app says {says}")
        st = styles_for(log, probes)
        want = [
            ("[data-role=table-head] .text", "font-family", lambda v: v.replace('"', "").startswith("Geist Mono"), "the table's headers in Geist Mono"),
            ("[data-role=table-head] .text", "font-size", lambda v: v == "11px", "headers 11 px (.tbl th)"),
            ("[data-role=table-head] .text", "letter-spacing", lambda v: v == "0.66px", "headers .06em apart"),
            ("[data-role=table-head] .text", "color", lambda v: same_colour(v, t["--oq-ink-2"]), "headers in ink-2"),
            ("[data-role=table-head]", "padding-left", lambda v: v == "16px", "headers 16 px in"),
            ("[data-role=table-cell]", "padding-top", lambda v: v == "10px", "cells 10 px high padding"),
            ("[data-role=table-cell]", "border-bottom-color", lambda v: same_colour(v, t["--oq-line-2"]), "a line-2 rule under each row"),
            ("[data-tag=chip-1]", "border-radius", lambda v: v == "999px", "chips are pills"),
            ("[data-tag=chip-1]", "color", lambda v: same_colour(v, t["--oq-data-1"]), "a hue chip wears its hue (data-1)"),
            ("[data-tag=badge-ok]", "border-radius", lambda v: v == t["--oq-radius-xs"], "badges: radius-xs"),
            ("[data-tag=badge-ok] .text", "font-family", lambda v: v.replace('"', "").startswith("Geist Mono"), "badges in Geist Mono"),
            ("[data-tag=pill]", "border-radius", lambda v: v == "999px", "pill badges"),
            ("[data-tag=code-block]", "background-color", lambda v: same_colour(v, "#0b0b0d"), "code on --code #0b0b0d"),
            ("[data-tag=code-block] .text", "font-family", lambda v: v.replace('"', "").startswith("Geist Mono"), "code in Geist Mono"),
            ("[data-tag=skeleton]", "animation-name", lambda v: v not in ("", "none"), "the skeleton shimmers"),
        ]
        for sel, prop, ok, what in want:
            got = st.get((sel, prop))
            if got is None or not ok(got):
                problems.append(f"web: {what}: {sel} {prop} is {got!r}")
        notes.append("web (opened at " + KIT_DEEP + ")")
    # motion off: the skeleton holds still
    try:
        r, log = drive.web_run(g30.BUILD / KIT / "web", "style:[data-tag=skeleton]=animation-name", viewport=(1440, 900), color_scheme="light", reduced_motion=True)
        got = styles_for(log, ["style:[data-tag=skeleton]=animation-name"]).get(("[data-tag=skeleton]", "animation-name"))
        if r.returncode != 0 or got != "none":
            problems.append(f"web, motion off: the skeleton's animation is {got!r}, not none")
    except Exception as e:
        problems.append(f"web, motion off: crashed {e!r}")
    if problems:
        return False, "; ".join(problems[:12])
    return True, (f"{len(M4_PARTS)} components' tests pass; the sampler on " + " and ".join(notes) + ": rows ticked, Copy read back, Confirm acts on "
                  "the second tap, the log pinned to its end, routes as state and as the URL (deep link, change, Back); omxqua's table, chip, "
                  "badge, code and shimmer values read back, motion off holds still; Mac builds; matrix current, no console debt, lint passes")


def styles_for(log, probes):
    """{(selector, property): value} from drive.py's STYLE: lines, for the asked probes ("style:sel=prop")."""
    out = {}
    for probe in probes:
        sel, prop = probe[len("style:"):].rsplit("=", 1)
        head = f"STYLE: {sel} {prop} "
        for line in log.splitlines():
            if line.startswith(head) or line == head.rstrip():
                out[(sel, prop)] = line[len(head):].strip()
    return out


def m8():
    """In the gallery, and nothing regressed: goal 32's M0–M2, goal 30's M0–M5 (goals 3–29 inside them)."""
    problems = []
    gallery = (ROOT / "docs" / "gallery" / "index.html").read_text()
    if "console" not in gallery.lower():
        problems.append("docs/gallery/index.html doesn't show the console")
    for host in ("gtk", "web", "mac"):
        if not list((ROOT / "docs" / "gallery" / "img").glob(f"console*{host}*")):
            problems.append(f"no console shot from {host} in docs/gallery/img")
    for name, fn in [("32-M0", g32.m0), ("32-M1", g32.m1), ("32-M2", g32.m2), ("32-M7", g32.m7)]:
        ok, msg = fn()
        if not ok:
            problems.append(f"{name}: {msg}")
    return not problems, "; ".join(problems) or "in the gallery; goal 32's M0–M2 and goal 30's M0–M5 pass"


MILESTONES = [
    ("M0", m0),
    ("M1", m1),
    ("M2", m2),
    ("M3", m3),
    ("M4", m4),
    ("M5", todo("examples/console: My models and the model page (GOAL.md M5)")),
    ("M6", todo("examples/console: Add, Keys, Gateway, Security, Settings (GOAL.md M6)")),
    ("M7", todo("identical: web ≥ 99 % of pixels, GTK and Mac boxes, a live daemon (GOAL.md M7)")),
    ("M8", m8),
]


def main():
    import headless
    headless.ensure()
    only = sys.argv[1:]
    if not only:
        g30.build_all()
    results = []
    for name, fn in MILESTONES:
        if only and name not in only:
            continue
        t0 = time.time()
        try:
            ok, msg = fn()
        except Exception as e:
            import traceback
            traceback.print_exc()
            ok, msg = False, f"crashed: {e!r}"
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {msg}  ({time.time() - t0:.0f} s)", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
