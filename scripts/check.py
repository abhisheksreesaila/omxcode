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
    want("REFUSED_SPLITS", lambda v: v == "ok", "targets, methods and header names that would split the request are refused (D-570)")
    forged = [r for r in seen if "evil" in r["path"].lower() or "x-evil" in r["headers"] or "evil" in r["method"].lower()]
    if forged:
        problems.append(f"the server got a request the transport should have refused: {forged[0]['method']} {forged[0]['path']!r}")
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
    ("Markdown", "markdown"), ("Sparkline", "sparkline"), ("Route", "route"), ("Paragraph", "paragraph"),
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
    "link:release notes",  # Paragraph: its link's tap sends on_link with the href and the run (D-470)
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
    if lv("link:") != "https://example.com/notes (run 3)":
        problems.append(f"{host}: Paragraph: tapping its link shows link {lv('link:')!r}, not 'https://example.com/notes (run 3)'")
    para = re.search(r"^PARAGRAPH: Shown as words: <b>not bold</b> & <i> then release notes \(4 runs, 1 links(, 4 elements)?\)$", out, re.M)
    if not para:  # (its words as the host shows them: markup-looking words stay words, one element per run)
        problems.append(f"{host}: Paragraph: shows {re.findall(r'^PARAGRAPH: Shown.*$', out, re.M)}, not its runs' words as written")
    for tag in ("breadcrumbs", "chip-1", "badge-ok", "pill", "skeleton", "code-block", "sample-markdown", "sample-paragraph", "sample-sparkline", "sample-timeline"):
        b = re.search(rf"^BOX: {re.escape(tag)} [\d.-]+ [\d.-]+ ([\d.]+) ([\d.]+)$", out, re.M)
        if not b or float(b.group(1)) < 4 or float(b.group(2)) < 4:
            problems.append(f"{host}: no visible view tagged {tag} ({b.group(0) if b else 'no BOX'})")
    return problems


# The app is a showcase that composes the framework (owner 2026-10-25, D-413): examples/console sets no sizes, spacing,
# padding, colours or fonts of its own and reaches no host or drawing module; the look is the theme's, the parts mojoui's.
APP_LINT = [
    (r"\.(padding|width|height|min_width|max_width)\(", "sizes or pads a view itself"),
    (r"\bspacing=\s*[1-9]", "spaces a stack in points (use the theme's SPACE_… tokens or a component)"),
    (r"\bheight=\s*[1-9]", "gives a view a height in points"),
    (r"0x[0-9A-Fa-f]{6,8}\b|\bhx\(|\brgba?\(|\"#[0-9a-fA-F]{3,8}\"", "writes a colour"),
    (r"\"(Geist|Inter|JetBrains)|\bfont\s*=", "names a font"),
    (r"mojoui\.hosts|mojoui\.draw\b", "imports a host or drawing module"),
]


def app_lint(folder="examples/console"):
    """examples/console composes mojoui and its theme only: [problems], one per line that breaks a rule (comments aside)."""
    import re
    out = []
    for f in sorted((ROOT / folder).glob("*.mojo")):
        for n, line in enumerate(f.read_text().splitlines(), 1):
            if line.lstrip().startswith(("\"\"\"", "'")):
                continue
            code = ""  # (the line with its comment cut and its strings blanked, but for a colour or a font name)
            for m in re.finditer(r'"[^"]*"|#.*$|[^"#]+', line):
                t = m.group(0)
                if t.startswith("#"):
                    break
                code += t if not t.startswith('"') or re.fullmatch(r'"(#[0-9a-fA-F]{3,8}|(Geist|Inter|JetBrains)[^"]*)"', t) else '""'

            for pat, why in APP_LINT:
                if re.search(pat, code):
                    out.append(f"{f.relative_to(ROOT)}:{n} {why}: {line.strip()[:90]}")
    return out


def m4():
    """The console's components: in mojoui/, each with its own test, on GTK and the web, built for the Mac: Table (rows,
    tick boxes), CodeBlock with Copy, LogView (pinned to the end), Timeline (stages, elapsed), Breadcrumbs, Chip/Badge,
    Confirm (tap twice), Skeleton, Markdown, Sparkline, Route (#/models/<name>/<tab> deep links on the web), and (goal 33
    M7, D-470) Paragraph (styled runs the host wraps, a link's tap); docs/components.md regenerated; the debt table
    holds nothing from the console. Proof: every test passes; the sampler
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
                 "Markdown(", "SparklineView(", "Route(", "Paragraph(", "omxqua("):
        if ctor not in src:
            problems.append(f"the sampler doesn't use {ctor[:-1]}")
    roles, found = g32.lint()
    problems += [f"lint: {p}" for p in found]
    problems += [f"app lint: {p}" for p in app_lint()]
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


# M5: My models and the model page. examples/console against the fixture server (scripts/console_fixture.py), on GTK and
# the web: what the original shows from the recorded replies (computed by its own rules: blade-home.js modelView and
# cellsFor, model-page.js overviewView, blade-bench.js, blade-logs.js, blade-notebook.js), its writes (the requests the
# original sends, recorded by the fixture server), its poll intervals (core.js 3 s, system-data.js 5 s, beacon.js 3 s,
# blade-logs.js 2 s), a reply changed mid-run, Run in Jupyter (an iframe on the web, the browser on GTK).
CONSOLE = "console"
CONSOLE_MODEL = "qwen2.5-0.5b"
M5_SCREENS = ["models", "overview", "bench", "logs", "notebook"]
FORGED_LINK = "#/models/x%0d%0aX-Forged:%201/logs"  # (a name with a line break and a header in it, as a link would carry it)
FORGED_TARGET = "/admin/models/x%0D%0AX-Forged%3A%201/log"
CONSOLE_URL_ENV, CONSOLE_KEY_ENV, OPENER_ENV = "MXC_URL", "MXC_ADMIN_KEY", "MOJOUI_OPENER"
M5_NAMES = ["qwen2.5-0.5b", "all-minilm-l6", "llama3.2-1b"]
M5_TOP = ["omxconsole", "Pulling helper-7b", "35%"]  # the top bar on every screen: brand, the Beacon (pulls.json: helper-7b at 35.4 %)
M5_PLACES = ["Keys", "Gateway", "Security", "Settings"]
M5_WANT = {
    # blade-home.js: rows running first then by name; size, memory (system crew vram_gb), tok/s (the series' last p50),
    # first token and requests (metrics by_model), access; the heading's sub line
    "models": M5_NAMES + ["Qwen/Qwen2.5-0.5B-Instruct", "sentence-transformers/all-MiniLM-L6-v2", "meta-llama/Llama-3.2-1B-Instruct",
                          "988 MB", "91 MB", "2.5 GB", "3.1 GB", "158", "41 ms", "101", "This machine", "Running", "Idle",
                          "idle 1s of 5m", "Chat", "Embeddings", "#work", "#favorites", "My models",
                          "3 models · 1 running · 9.1 of 24 GB GPU · 127.0.0.1:11435/v1"],
    "cards": M5_NAMES + ["158", "3.1 GB", "101"],
    # model-page.js: the four tiles, About, GPU fit
    "overview": ["101", "158", "41", "3.1", "last 5 minutes", "decode, median", "time to first token", "GPU, this model",
                 "Qwen/Qwen2.5-0.5B-Instruct", "Qwen2", "huggingface", "after 5m idle", "http://127.0.0.1:11435/v1",
                 "3.1 GB · 13% of 24 GB", "this 3.1 GB", "others 0 GB", "free 14.9 GB of 24 GB", "#favorites", "#work"],
    # blade-bench.js: bars, the workload line (UTC, en-US), the history
    "benchmark": ["157.9 tok/s", "42 ms", "higher is better", "lower is better", "Decode speed · tokens/s", "Time to first token · p50",
                  "507 prompt tokens · 48 tokens out · batch 1 · 3 runs each · Oct 25, 21:34", "1 model", "qwen2.5-0.5b · 157.9 tok/s"],
    "logs": [l for l in (FIXTURES / "admin_models_qwen2.5-0.5b_log.txt").read_text().splitlines() if l.strip()] + ["10 lines", "qwen2.5-0.5b · max serve"],
    # blade-notebook.js: the chapters (levels 1–2), the cells, the architecture
    "notebook": ["qwen2.5-0.5b", "What it is", "Model card", "Qwen2.5-0.5B-Instruct", "Quickstart", "Evaluation", "Architecture",
                 "Where the parameters live", "See inside: MAX's implementation", "Try it", "Pipeline:", "text-generation",
                 "Qwen2ForCausalLM", "hidden_size", "896", "model running · 127.0.0.1:11435/v1", "Run in Jupyter"],
}
M5_TPS_NEW = 201.4  # the reply changed mid-run: the series' last decode p50 (shown as 201)
M5_CADENCE = {"/admin/models": 3000, "/admin/metrics": 3000, "/admin/series?range=5m": 3000, "/admin/requests?limit=40": 3000,
              "/admin/system": 5000, "/admin/pulls": 3000, "/admin/ports": 3000}


def texts(out):
    """Every label's and button's words (nbsp as a space, trimmed): what the screen says."""
    out_ = set()
    for l in out.splitlines():
        for head in ("LABEL: ", "BUTTON: "):
            if l.startswith(head):
                out_.add(l[len(head):].replace(" ", " ").strip())
    return out_


def missing(out, want):
    have = texts(out)
    return [w for w in want if w not in have]


def box_of(out, tag):
    import re
    m = re.findall(rf"^BOX: {re.escape(tag)} ([\d.-]+) ([\d.-]+) ([\d.]+) ([\d.]+)$", out, re.M)
    return [tuple(float(v) for v in b) for b in m]


def cadence(log, path, want_ms, problems, where):
    """GETs of `path` come every want_ms (median within 15 %), from the fixture server's log."""
    times = [r["t"] for r in log if r["method"] == "GET" and r["target"] == path]
    if len(times) < 3:
        problems.append(f"{where}: only {len(times)} GET {path} (it is polled every {want_ms / 1000:g} s)")
        return
    gaps = sorted((b - a) * 1000 for a, b in zip(times, times[1:]))
    med = gaps[len(gaps) // 2]
    if abs(med - want_ms) > 0.15 * want_ms:
        problems.append(f"{where}: GET {path} every {med:.0f} ms (median), not {want_ms} ms")


def console_env(url, token, extra=None):
    return dict({CONSOLE_URL_ENV: url, CONSOLE_KEY_ENV: token}, **(extra or {}))


def console_gtk(steps, env, shot=None, window="1440x900"):
    exe = g30.BUILD / CONSOLE / "linux" / CONSOLE
    e = dict(env, MOJOUI_TEST=steps, MOJOUI_WINDOW=window)
    if shot:
        e["MOJOUI_SHOT"] = str(shot)
    r = g30.run([str(exe)], env=e, timeout=300)
    out = r.stdout + r.stderr
    if r.returncode != 0 or "CRITICAL" in out or "TEST: " in out:
        return None, f"GTK run failed (exit {r.returncode}): {out[-500:]}"
    return r, out


def console_web(steps, env, shot=None, path="", viewport=(1440, 900), rects=None):
    import drive
    saved = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        r, out = drive.web_run(g30.BUILD / CONSOLE / "web", steps, shot=str(shot) if shot else None, viewport=viewport,
                               color_scheme="light", path=path, rects=str(rects) if rects else None)
    except Exception as e:
        return None, f"web run crashed: {e!r}"
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    if r.returncode != 0:
        return None, f"web: {out[-500:]}"
    return r, out


def m5_pixels(token, names=None, extra=None):
    """Information only (M7 holds the bar): each screen's share of pixels equal to the original's, both sizes (M5's, or
    `names`; `extra`: more env for the app, a None value replaced by the recording's time)."""
    names = names or M5_SCREENS
    px = web_pixels(token, names, extra)
    return [f"{name} {w}: {share:.1%}" for (name, (w, h)), share in sorted(px.items(), key=lambda kv: (names.index(kv[0][0]), -kv[0][1][0]))]


def web_pixels(token, names, extra=None):
    """{(screen, (w, h)): share of pixels equal to the original's docs/goals/33/orig/a shot}: examples/console's web build
    served against the fixture server, shot by console_side.shoot as the original was (fresh context, light, en-US in UTC,
    reduced motion, Date frozen at the recording, seeded Math.random, animations off), equality by console_side.differing
    (M0's per-channel tolerance). A missing original counts as 0."""
    import subprocess
    import console_fixture
    import console_side
    fx = console_fixture.Fixtures()
    server, url = console_fixture.serve(fx)
    port = drive_port()
    more = {k: (str(fx.recorded_at) if v is None else v) for k, v in (extra or {}).items()}
    web = subprocess.Popen([sys.executable, str(ROOT / "mojoui/hosts/web.py"), str(g30.BUILD / CONSOLE / "web"), str(port)], cwd=ROOT,
                           env=dict(os.environ, **console_env(url, token, more)), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        import urllib.request
        for _ in range(300):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/static/htmx.min.js", timeout=1)
                break
            except OSError:
                time.sleep(0.1)
        screens = [s for s in console_side.SCREENS if s[0] in names]
        shots = console_side.shoot(f"http://127.0.0.1:{port}/", OUT / "ours", frozen_at=fx.recorded_at, screens=screens, path="")
    finally:
        web.terminate()
        try:
            web.wait(timeout=10)
        except subprocess.TimeoutExpired:
            web.kill()
            web.wait(timeout=10)
        server.shutdown()
    px = {}
    for (name, (w, h)), png in shots.items():
        orig = OUT / "orig" / "a" / f"{name}-{w}x{h}.png"
        px[(name, (w, h))] = (1 - console_side.differing(orig, png)) if orig.exists() else 0.0
    return px


def drive_port():
    import drive
    return drive.free_port()


def forged_link(token):
    """A crafted deep link forges nothing (reviewer, D-570): a model name holding an escaped line break and a header goes
    into the log's path escaped (uri_component), and the daemon gets no extra header line. None, or the problem."""
    import console_fixture
    fx = console_fixture.Fixtures()
    server, url = console_fixture.serve(fx)
    try:
        r, out = console_web("pause:2500", console_env(url, token), path=FORGED_LINK)
    finally:
        server.shutdown()
    if r is None:
        return f"web forged link: {out}"
    forged = [x for x in fx.log if "x-forged" in x.get("names", []) or any(c in x["target"] for c in "\r\n\t ")]
    logs = [x["target"] for x in fx.log if x["target"].startswith("/admin/models/x")]
    if forged:
        return f"web forged link: the daemon got a forged header or path: {forged[0]}"
    if logs[:1] != [FORGED_TARGET]:
        return f"web forged link: the log's request went to {logs[:2]}, not {FORGED_TARGET} (the name escaped)"
    return None


def m5():
    """My models and the model page: examples/console runs against the fixture server on GTK and on the web: the model
    list shows the three recorded models with their numbers in a table and as cards (List/Cards); ticking two models and
    applying a label changes both (the app sends the original's POST /admin/labels/<label>/add, recorded by the fixture
    server); dragging a model onto a label applies it; the model page at #/models/qwen2.5-0.5b/<tab> for overview,
    benchmark, logs and notebook shows the recorded content (stats, sparkline, hardware, the bench runs and bars, the log
    pinned to its end, the notebook's chapters and cells); numbers follow the poll (a reply changed mid-run shows within
    one poll period; the original's endpoints at its intervals); Run in Jupyter is an iframe on the web and opens the
    browser on GTK (the open request logged through an opener override); the top bar (brand, crumbs, places, Beacon) on
    every screen; builds for the Mac. Prints each screen's pixel match against the original (information only)."""
    import json as pyjson
    import re
    import secrets
    import tempfile
    import threading
    import console_fixture
    problems = []
    app = ROOT / "examples" / CONSOLE / "app.mojo"
    if not app.exists():
        return False, "no examples/console/app.mojo"
    src = "".join(f.read_text() for f in (ROOT / "examples" / CONSOLE).glob("*.mojo"))
    if len(list((ROOT / "examples" / CONSOLE).glob("*.mojo"))) < 4:
        problems.append("examples/console isn't split by screen (app.mojo with routing, the top bar and the poll; a file per screen)")
    plat = ROOT / "examples" / CONSOLE / "platforms"
    if not plat.exists() or not {"linux", "web", "mac"} <= set(plat.read_text().split()):
        problems.append("examples/console/platforms doesn't list linux web mac")
    for need, why in [('"X-Mst-Admin"', "the original's admin header"), (f'"{CONSOLE_KEY_ENV}"', f"the admin key from ${CONSOLE_KEY_ENV}"),
                      (f'"{CONSOLE_URL_ENV}"', f"the base URL from ${CONSOLE_URL_ENV}"), ("Every(", "App.every polls")]:
        if need not in src:
            problems.append(f"examples/console has no {why} ({need})")
    for name in ("dragdrop", "embed", "shell", "header", "sidebar", "panel", "marks", "words", "buttons", "lists", "document"):  # the components M5 added to mojoui/, each with its own test (pagekit split into generic modules by M7, D-414)
        err = g30.g20.mojo_test(f"tests/test_{name}.mojo", f"{name}: ok", f"test_{name}")
        if err:
            problems.append(err[:300])
    if problems:
        return False, "; ".join(problems)
    err = build(CONSOLE, "linux", "web", "mac")
    if err:
        return False, err
    token = secrets.token_hex(8)
    notes = []
    opener_dir = Path(tempfile.mkdtemp(prefix="m5-opener-"))
    opened = opener_dir / "opened.txt"
    opener = opener_dir / "open.sh"
    opener.write_text(f"#!/bin/sh\necho \"$1\" >> {opened}\n")
    opener.chmod(0o755)

    def check_writes(fx, host, want):
        got = [(w["method"], w["path"], w["body"]) for w in fx.writes]
        for wmeth, wpath, wbody in want:
            if (wmeth, wpath, wbody) not in got:
                problems.append(f"{host}: the app never sent {wmeth} {wpath} {pyjson.dumps(wbody)} (sent: {got})")
        for w in fx.writes:
            if w["headers"].get("x-mst-admin") != token:
                problems.append(f"{host}: {w['method']} {w['path']} without X-Mst-Admin = ${CONSOLE_KEY_ENV}")
                break
        if any(r["admin"] != token for r in fx.log):
            problems.append(f"{host}: some /admin request went without X-Mst-Admin = ${CONSOLE_KEY_ENV}")
        if fx.misses:
            problems.append(f"{host}: asked for what the daemon doesn't answer: {sorted(set(fx.misses))[:6]}")

    def common(out, host, screen):
        lost = missing(out, M5_TOP + M5_PLACES)
        if lost:
            problems.append(f"{host} {screen}: the top bar lacks {lost}")

    for host in ("gtk", "web"):
        run = console_gtk if host == "gtk" else console_web
        # 1) the list: drag all-minilm-l6 onto #work; tick all-minilm-l6 and llama3.2-1b, tap #favorites in the bar
        fx = console_fixture.Fixtures()
        server, url = console_fixture.serve(fx)
        try:
            steps = "pause:1500;dragto:row-all-minilm-l6=label-work;pause:800;tick:tick-1;tick:tick-2;tap:#favorites;pause:4000"
            r, out = run(steps, console_env(url, token), shot=OUT / f"console-models-{host}.png")
        finally:
            server.shutdown()
        if r is None:
            problems.append(out)
            continue
        lost = missing(out, M5_WANT["models"])
        if lost:
            problems.append(f"{host} list: missing {lost[:10]}")
        if not re.search(r"^TABLE: models 3 rows, \d+ columns, \d+ selected$", out, re.M):
            problems.append(f"{host} list: no 3-row table tagged models ({re.findall(r'^TABLE: .*$', out, re.M)})")
        if out.count("LABEL: #favorites") < 3 or out.count("LABEL: #work") < 3:
            problems.append(f"{host} list: after the drag and the label, #favorites shows {out.count('LABEL: #favorites')}× and #work "
                            f"{out.count('LABEL: #work')}× (want 3 rows each)")
        check_writes(fx, f"{host} list", [("POST", "/admin/labels/work/add", {"models": ["all-minilm-l6"]}),
                                          ("POST", "/admin/labels/favorites/add", {"models": ["all-minilm-l6", "llama3.2-1b"]})])
        common(out, host, "list")
        # 2) cards
        fx = console_fixture.Fixtures()
        server, url = console_fixture.serve(fx)
        try:
            r, out = run("pause:1500;tap:Cards;pause:500", console_env(url, token), shot=OUT / f"console-cards-{host}.png")
        finally:
            server.shutdown()
        if r is None:
            problems.append(out)
            continue
        lost = missing(out, M5_WANT["cards"])
        if lost or re.search(r"^TABLE: models", out, re.M) or not box_of(out, "cards"):
            problems.append(f"{host} cards: missing {lost}, or the table still shows, or no view tagged cards")
        # 3) the model page, tab by tab (the web opens each by its link; GTK taps there)
        for tab, title in [("overview", "Overview"), ("benchmark", "Benchmark"), ("logs", "Logs"), ("notebook", "Notebook")]:
            fx = console_fixture.Fixtures()
            server, url = console_fixture.serve(fx)
            changed = {}
            if tab == "overview":  # the reply changes after the second series poll: the screen follows within one poll
                def change():
                    while sum(1 for x in fx.log if x["target"] == "/admin/series?range=5m") < 2:
                        time.sleep(0.05)
                    body = pyjson.loads((FIXTURES / "admin_series@range=5m.json").read_text())
                    body["models"][CONSOLE_MODEL][-1]["decode_tps_p50"] = M5_TPS_NEW
                    fx.override("GET /admin/series?range=5m", pyjson.dumps(body).encode())
                    changed["t"] = time.monotonic()
                threading.Thread(target=change, daemon=True).start()
            extra = {OPENER_ENV: str(opener)} if host == "gtk" and tab == "notebook" else {}
            if opened.exists():
                opened.unlink()
            pause = 11000 if tab == "overview" else (5000 if tab == "logs" else 2500)
            go = f"pause:1500;tap:{CONSOLE_MODEL};pause:600" + ("" if tab == "overview" else f";tap:{title}")
            # Jupyter replaces the saved view (as the original's does); Saved view brings the chapters and cells back
            jup = ";tap:Run in Jupyter;pause:1500;js:(document.querySelector('iframe') || {}).src || '';tap:Saved view;pause:500" if tab == "notebook" else ""
            if host == "web":
                go = "pause:1500"
            steps = f"{go};pause:{pause}" + (jup if host == "web" else (";tap:Run in Jupyter;pause:1500;tap:Saved view;pause:500" if tab == "notebook" else ""))
            try:
                r, out = run(steps, console_env(url, token, extra), shot=OUT / f"console-{tab}-{host}.png",
                             **({"path": f"#/models/{CONSOLE_MODEL}/{tab}"} if host == "web" else {}))
            finally:
                server.shutdown()
            if r is None:
                problems.append(out)
                continue
            want = list(M5_WANT[tab])
            if tab == "overview":
                want = [w for w in want if w != "158"] + ["201"]
            lost = missing(out, want)
            if lost:
                problems.append(f"{host} {tab}: missing {lost[:10]}")
            if host == "web" and not re.search(rf'^ROUTE: /models/{re.escape(CONSOLE_MODEL)}/{tab}$', out, re.M):
                problems.append(f"{host} {tab}: opened at #/models/{CONSOLE_MODEL}/{tab}, the route is {re.findall(r'^ROUTE: .*$', out, re.M)}")
            if host == "gtk" and not re.search(rf'^ROUTE: /models/{re.escape(CONSOLE_MODEL)}/{tab}$', out, re.M):
                problems.append(f"{host} {tab}: the route is {re.findall(r'^ROUTE: .*$', out, re.M)}")
            if missing(out, ["My models", CONSOLE_MODEL]):
                problems.append(f"{host} {tab}: no crumbs My models › {CONSOLE_MODEL}")
            common(out, host, tab)
            if tab == "overview":
                sp = box_of(out, "sparkline")
                if not sp or sp[0][2] < 200 or sp[0][3] < 40:
                    problems.append(f"{host} overview: no sparkline drawn ({sp})")
                if host == "web" and not re.search(r"^CANVAS: \d+x\d+ pt .* painted [1-9]", out, re.M):
                    problems.append(f"{host} overview: the sparkline's canvas is blank")
                if not box_of(out, "gpu-fit"):
                    problems.append(f"{host} overview: no GPU fit bar (tag gpu-fit)")
                after = [x["t"] for x in fx.log if x["target"] == "/admin/series?range=5m" and "t" in changed and x["t"] >= changed["t"]]
                if "t" not in changed or not after or after[0] - changed["t"] > 3.5:
                    problems.append(f"{host} overview: after the reply changed, the next series poll came "
                                    f"{(after[0] - changed['t']) if after else 'never'} s later (one poll: 3 s)")
                for path, ms in M5_CADENCE.items():  # (a run without writes: a write's own refresh comes between two ticks, as the original's does)
                    cadence(fx.log, path, ms, problems, f"{host} overview")
            if tab == "benchmark":
                bars = box_of(out, "bar")
                if len(bars) < 2 or min(b[2] for b in bars) < 200:
                    problems.append(f"{host} benchmark: want two drawn bars (tag bar), got {bars}")
            if tab == "logs":
                if not re.search(r"^PINNED: log at end$", out, re.M):
                    problems.append(f"{host} logs: the log isn't pinned to its end ({re.findall(r'^PINNED: .*$', out, re.M)})")
                cadence(fx.log, f"/admin/models/{CONSOLE_MODEL}/log", 2000, problems, f"{host} logs")
            if tab == "notebook":
                check_writes(fx, f"{host} notebook", [("POST", f"/admin/learn/{CONSOLE_MODEL}/open", None)])
                want_url = console_fixture.jupyter_urls(CONSOLE_MODEL, fx.jupyter_port)
                if host == "web":
                    js = [l[len("JS: "):] for l in out.splitlines() if l.startswith("JS: ")]
                    if not js or pyjson.loads(js[-1]) != want_url["embed_url"]:
                        problems.append(f"web notebook: Run in Jupyter shows no iframe of {want_url['embed_url']} ({js})")
                else:
                    got = opened.read_text().split() if opened.exists() else []
                    if got != [want_url["url"]]:
                        problems.append(f"gtk notebook: Run in Jupyter opened {got}, not the browser at {want_url['url']} (${OPENER_ENV})")
        notes.append(host)
    err = forged_link(token)
    if err:
        problems.append(err)
    else:
        notes.append("a forged deep link sends nothing forged")
    if problems:
        return False, "; ".join(dict.fromkeys(problems[:14]))
    try:
        px = m5_pixels(token)
    except Exception as e:
        px = [f"unmeasured ({e!r})"]
    return True, ("examples/console on " + " and ".join(notes) + " against the fixtures: the list (table, cards, drag onto #work, tick two "
                  "and #favorites: both POSTs sent with the admin key), the model page's four tabs with the recorded content, the poll at "
                  "the original's intervals and a changed reply shown within one poll, Jupyter as an iframe (web) and the browser (GTK); "
                  "Mac builds. Pixels equal to the original (info, M7 wants 99 %): " + ", ".join(px))


# M6: the other screens. examples/console against the fixture server, on GTK and the web, the clock at the recording's
# time ($MOJOUI_NOW: "84 s ago" reads as the original's shot): Add a model (blade-add.js), Keys (blade-keys.js), Gateway
# (blade-gateway.js), Security (blade-security.js), Settings (blade-settings.js, system-data.js). What each shows is the
# original's own rules over the recorded replies; its writes are the original's requests, read from the server's log.
NOW_ENV = "MOJOUI_NOW"
M6_SCREENS = ["add", "keys", "gateway", "security", "settings"]
M6_PLACES = {"add": "Add a model", "keys": "Keys", "gateway": "Gateway", "security": "Security", "settings": "Settings"}
M6_ENDPOINT = "http://127.0.0.1:11435/v1"
M6_LAN = "https://ablearn.local:8443/v1"
M6_CA = "/tmp/mxc-console-record/xdg-data/caddy/pki/authorities/local/root.crt"
M6_PULL = "qwen2.5-1.5b"  # Add a model picks it from a search for "qwen" (not one of My models yet)
M6_WANT = {
    # blade-add.js find view: the hint, the filters, the results for "qwen" with their fit badges and VRAM, the source line
    "add-search": ["Add a model", "Search the MAX catalog and Hugging Face · every result is checked against this machine's memory",
                   "Search the MAX catalog, or paste a Hugging Face repo id (owner/name)", "All", "Fits", "Needs porting", "3 results",
                   "qwen2.5-0.5b", M6_PULL, "qwen2.5-3b", "MAX", "fits", "~2.2 GB VRAM", "~4.6 GB VRAM", "~8.2 GB VRAM",
                   "Qwen/Qwen2.5-1.5B-Instruct · Qwen2 · 1.5B · 3 GB", "$ mxc search qwen",
                   "fit checked against NVIDIA GeForce RTX 4090 · 14.9 GB free of 24 GB"],
    # setupStages after a pull run to the end, the live log's head, showReady's card
    "add-ready": [f"{M6_PULL} is ready", "Check hardware", "Fetch the model", "Compile graph", "Serve on localhost", "Smoke test",
                  "needs ~4.6 GB · 14.9 GB free on NVIDIA GeForce RTX 4090", "1.5 GB on disk · files verified", "graph compiled",
                  f"answering at {M6_ENDPOINT}", "“Hello there, nice to meet you!”", f"mxc pull {M6_PULL}", f"mxc serve {M6_PULL}", "mxc ps",
                  "LIVE LOG", "Hide log", f"{M6_PULL} is serving.", "ready · localhost", M6_ENDPOINT, "Open", "Make it secure", "Add another",
                  f"$ mxc serve {M6_PULL}",
                  "It is on localhost only. Make it secure to reach it from your phone or another machine with HTTPS and an API key."],
    # blade-keys.js: the table (prefix only, dateTime, ago at the recording's time), the actions, the source line
    "keys": ["API keys", "shared by every model · requests without a valid key get 401", "New key", "Keys", "prefix only",
             "notes-app", "old-script", "zed-editor", "mst-vHApwU0D…", "mst-62ysDIJM…", "Oct 25, 21:34", "84 s ago", "2 min ago",
             "active", "revoked", "Rotate", "Revoke", "$ mxc keys ls", "ci-bot", "Key for ci-bot",
             "Copy it now. It is shown once and cannot be recovered; rotate it if you lose it.", "$ mxc keys new ci-bot", "never"],
    # blade-gateway.js with LiteLLM running: status, routes, recent requests (UTC clock), the safeguards' counters, the log
    "gateway": ["Gateway", "LiteLLM · one endpoint routes to every model", "Restart", "Status", "LiteLLM", "running · :4000",
                "Caddy (HTTPS)", "off", "Local endpoint", M6_ENDPOINT, "LAN endpoint", "Routes", "openai/all-minilm-l6", "openai/llama3.2-1b",
                "openai/qwen2.5-0.5b", ":40755", "idle", "37", f"↳ every route goes to {M6_ENDPOINT}", "$ mxc status", "copy",
                "Recent requests", "newest first · kept for 7 days", "21:36:33", "zed-editor", "notes-app", "chat", "200", "16 → 48",
                "42 ms", "340 ms", "$ mxc requests --limit 200", "Safeguards", "counted today", "Encrypted on your LAN",
                "off: nothing listens beyond this machine", "One key per app", "2 active · 1 revoked · 2 requests refused today (401)",
                "Only four doors open", "0 requests to other /v1 paths today", "Admin stays home", "0 refusals today", "LiteLLM log",
                "last lines", "↳ refreshed every few seconds", "API reference", "Open the API reference", "$ mxc console api",
                "From the terminal", "$ mxc expose", "$ mxc expose --stop"],
    # blade-security.js after Make it secure: the steps done, the endpoint, the CA and how to trust it, the curl
    "security-on": ["Security", "certificate, key and HTTPS on your LAN", "Secure on your network",
                    "HTTPS with a key. Other devices on your Wi-Fi can call it.", "secure", "Issue a local certificate", "for ablearn.local",
                    "Create the gateway key", "mxc gateway key", "Open HTTPS on your LAN", "port 8443", "Manage API keys", "Stop exposing",
                    "$ mxc expose --stop", "Endpoint", M6_LAN, "$ mxc status", "Trust the certificate",
                    "The CA file is created the first time Caddy starts; it is not there yet.", M6_CA, "Linux",
                    "sudo cp root.crt /usr/local/share/ca-certificates/mxconsole.crt && sudo update-ca-certificates", "macOS",
                    "Open root.crt in Keychain Access, then set it to Always Trust", "↳ trust it once on each device",
                    "From another device on your Wi-Fi", "↳ replace <model> with a model name", "What “Make it secure” does",
                    "↳ all three happen in one request"],
    "security-off": ["Localhost only", "Only this machine can call it. One click adds a certificate, a key and HTTPS.", "localhost only",
                     "Make it secure", "$ mxc expose", "Certificate", "a local CA, “mxconsole local”, signs a certificate for this machine's name",
                     "API key", "the gateway has its own key; requests without a valid app key get 401", "HTTPS",
                     "Caddy and LiteLLM listen on your LAN; localhost keeps working over HTTP"],
    # blade-settings.js: the theme, idle unload per model, the daemon (/admin/info, MXC_HOME from /admin/system), the ports
    "settings": ["Settings", "this browser and this daemon", "Appearance", "kept in this browser", "Light", "Dark",
                 "Until you pick one, the console follows your system.", "↳ kept in this browser", "Idle unload", "per model",
                 "A model unloads after 5m without a request unless you say otherwise. There is no single setting for all of them yet: it is kept per model.",
                 "all-minilm-l6", "llama3.2-1b", "qwen2.5-0.5b", "after 5m idle", "$ mxc set <model> --keep-alive 10m", "$ mxc set <model> --pin",
                 "Daemon", "Host", "ablearn", "Endpoint", M6_ENDPOINT, "LAN endpoint", "off: this machine only", "MAX version",
                 "26.7.0.dev2026100905", "Uptime", "2m 23s", "Active keys", "2", "MXC_HOME", "/tmp/mxc-console-record/mxc", "$ mxc stop --all",
                 "Ports & processes", "most listen on this machine only", "omxconsole daemon", "127.0.0.1:11435", "LiteLLM", "127.0.0.1:4000",
                 "Caddy", "0.0.0.0:8443", "Caddy admin", "127.0.0.1:2099", "max serve · qwen2.5-0.5b", "127.0.0.1:40755", "this machine",
                 "your LAN", "Listening", "Off", "the daemon only", "LAN clients over HTTPS, each with an app key",
                 "Apps talk to the daemon, which starts one max serve per model on a loopback port. Only Caddy listens beyond this machine, and only after you make a model secure.",
                 "$ mxc ps"],
}
M6_LITELLM_LOG = ["21:35:02 LiteLLM: Proxy initialized with Config", "21:35:02 LiteLLM: routes qwen2.5-0.5b, llama3.2-1b, all-minilm-l6",
                  "21:35:03 INFO: Uvicorn running on http://127.0.0.1:4000"]
M6_LITELLM_NEW = "21:36:40 INFO: POST /v1/chat/completions 200"  # the log grows mid-run: shown within one poll (4 s)
M6_CADENCE = {"/admin/network": 4000, "/admin/gateway": 4000, "/admin/litellm/log?bytes=8000": 4000}  # blade-gateway.js POLL (a chain)


def security_curl(url, ca):
    """blade-security.js securityView().curl."""
    return (f"curl --cacert {ca} {url}/chat/completions \\\n  -H \"Authorization: Bearer $MXC_API_KEY\" \\\n"
            f"  -H \"Content-Type: application/json\" \\\n  -d '{{\"model\":\"<model>\",\"messages\":[{{\"role\":\"user\",\"content\":\"hi\"}}]}}'")


def add_curl(endpoint, name):
    """blade-add.js curlFor."""
    import json as pyjson
    return (f"curl {endpoint}/chat/completions \\\n  -H \"Authorization: Bearer $MXC_API_KEY\" \\\n  -H \"Content-Type: application/json\" \\\n"
            f"  -d '{{\"model\": {pyjson.dumps(name)}, \"messages\": [{{\"role\": \"user\", \"content\": \"Hello\"}}]}}'")


def clipboard(out):
    import re
    m = re.findall(r"^CLIPBOARD: (.*)$", out, re.M)
    return m[-1].replace("\\n", "\n").replace("\\t", "\t") if m else None


def has_part(out, part):
    """Some label or button holds `part` (a live log line carries its time in front)."""
    return any(part in t for t in texts(out))


def m6():
    """The other screens: examples/console runs against the fixture server on GTK and on the web, the clock at the
    recording's time. Add a model: a search shows the original's results with fit badges and VRAM; picking one runs the
    original's requests (POST /admin/pulls, the job polled, load, the smoke test) through the stage timeline (five stages,
    elapsed times), the live log, and the Ready card whose curl copies. Keys: the table as the original shows it; Rotate
    and Revoke act only on the second tap (a single tap on another row's Revoke sends nothing); New key sends the
    original's POST and shows the new key once with Copy (the clipboard holds it). Gateway: status, routes, recent
    requests, the safeguards' counters, the LiteLLM log (a line added mid-run shows within one poll), the original's
    4 s poll; Restart sends POST /admin/litellm/restart. Security: Make it secure sends POST /admin/expose and shows the
    endpoint, the CA and the curl (Copy puts it on the clipboard); Stop exposing sends POST /admin/expose/stop on the
    second tap. Settings: the daemon's info from /admin/info and /admin/system, the ports, idle unload; Stop daemon sends
    POST /admin/shutdown only on the second tap. Every write carries the admin key; nothing asked misses the fixtures.
    Builds for the Mac. Prints each M6 screen's pixel match against the original (information only)."""
    import json as pyjson
    import re
    import secrets
    import threading
    import console_fixture
    problems = {s: [] for s in M6_SCREENS}
    pre = []
    folder = ROOT / "examples" / CONSOLE
    for name in ("keys", "gateway", "security", "settings"):
        if not (folder / f"{name}.mojo").exists():
            problems[name].append(f"no examples/console/{name}.mojo (a file per screen)")
    if not list(folder.glob("add*.mojo")):
        problems["add"].append("no examples/console/add*.mojo (a file per screen)")
    for name in M6_TESTS:  # the components M6 added to mojoui/, each with its own test
        err = g30.g20.mojo_test(f"tests/test_{name}.mojo", f"{name}: ok", f"test_{name}")
        if err:
            pre.append(err[:300])
    err = build(CONSOLE, "linux", "web", "mac")
    if err:
        return False, err
    token = secrets.token_hex(8)

    def run(host, screen, steps, fx, shot=None):
        server, url = console_fixture.serve(fx)
        env = console_env(url, token, {NOW_ENV: str(fx.recorded_at)})
        try:
            if host == "gtk":
                go = "pause:1500;tap:" + M6_PLACES[screen] + ";pause:1200;"
                return console_gtk(go + steps, env, shot=shot)
            return console_web("pause:1500;" + steps, env, shot=shot, path="#/" + screen)
        finally:
            server.shutdown()

    def writes_ok(fx, where, screen, want, never=()):
        got = [(w["method"], w["path"], w["body"]) for w in fx.writes]
        for item in want:
            if item not in got:
                problems[screen].append(f"{where}: the app never sent {item[0]} {item[1]} {pyjson.dumps(item[2])} (sent: {got[:6]})")
        for item in never:
            if any(g[:2] == item for g in got):
                problems[screen].append(f"{where}: sent {item[0]} {item[1]} after a single tap (the original asks for a second)")
        if any(r["admin"] != token for r in fx.log):
            problems[screen].append(f"{where}: some /admin request went without X-Mst-Admin = ${CONSOLE_KEY_ENV}")
        if fx.misses:
            problems[screen].append(f"{where}: asked for what the daemon doesn't answer: {sorted(set(fx.misses))[:6]}")

    def shown(out, where, screen, want):
        lost = missing(out, want)
        if lost:
            problems[screen].append(f"{where}: missing {lost[:10]}")
        lost = missing(out, M5_TOP + M5_PLACES)
        if lost:
            problems[screen].append(f"{where}: the top bar lacks {lost}")

    def got(r, out, screen):
        if r is None:
            problems[screen].append(out)
            return False
        return True

    for host in ("gtk", "web"):
        # -- Add a model: the search, then a pull run to the Ready card ---------------------------------------
        fx = console_fixture.Fixtures()
        r, out = run(host, "add", "type:Search models=qwen;pause:2000", fx, shot=OUT / f"console-add-{host}.png")
        if got(r, out, "add"):
            shown(out, f"{host} add (search)", "add", M6_WANT["add-search"])
            if not any(x["target"] == "/admin/search?q=qwen" for x in fx.log):
                problems["add"].append(f"{host} add: no GET /admin/search?q=qwen")
            writes_ok(fx, f"{host} add (search)", "add", [])
        fx = console_fixture.Fixtures()
        r, out = run(host, "add", f"type:Search models=qwen;pause:2000;tap:{M6_PULL};pause:9000;tap:Copy curl;pause:300", fx,
                     shot=OUT / f"console-add-ready-{host}.png")
        if got(r, out, "add"):
            shown(out, f"{host} add (ready)", "add", M6_WANT["add-ready"])
            for line in [f"hardware: needs ~4.6 GB", f"pull #100 started for {M6_PULL}",
                         f"loading {M6_PULL} · compiling the graph (mxc serve {M6_PULL})", f"serving on {M6_ENDPOINT}",
                         "reply: Hello there, nice to meet you!"]:
                if not has_part(out, line):
                    problems["add"].append(f"{host} add: the live log has no line with {line!r}")
            elapsed = [t for t in texts(out) if re.fullmatch(r"\d+\.\ds", t)]
            if len(elapsed) < 4:
                problems["add"].append(f"{host} add: the timeline shows {len(elapsed)} elapsed times (want one per finished stage, ≥ 4)")
            if clipboard(out) != add_curl(M6_ENDPOINT, M6_PULL):
                problems["add"].append(f"{host} add: Copy curl put {clipboard(out)!r} on the clipboard")
            writes_ok(fx, f"{host} add (ready)", "add", [("POST", "/admin/pulls", {"ref": M6_PULL}), ("POST", f"/admin/models/{M6_PULL}/load", None),
                      ("POST", "/admin/try/chat", {"model": M6_PULL, "messages": [{"role": "user", "content": "Say hello in five words."}], "max_tokens": 24})])
            polls = [x for x in fx.log if x["target"] == "/admin/pulls/100"]
            if len(polls) < 3:
                problems["add"].append(f"{host} add: the pull was polled {len(polls)}× (the job moves one step per poll)")
            else:
                cadence(fx.log, "/admin/pulls/100", 700, problems["add"], f"{host} add")
        # -- Keys: one tap on notes-app's Revoke, rotate zed-editor, a new key, copy it, revoke it ------------
        fx = console_fixture.Fixtures()
        steps = ("pause:800;tap:Revoke@0;tap:Rotate@2;tap:Click again to rotate: the old key stops working now;pause:1200;tap:New key;"
                 "type:App name, e.g. my-app=ci-bot;tap:Create key;pause:1500;tap:Copy;pause:300;tap:Revoke@0;tap:Click again to revoke;pause:1500")
        r, out = run(host, "keys", steps, fx, shot=OUT / f"console-keys-{host}.png")
        if got(r, out, "keys"):
            secret, rotated = fx.issued.get("ci-bot", "?"), fx.issued.get("zed-editor", "?")
            shown(out, f"{host} keys", "keys", M6_WANT["keys"] + [secret, rotated[:12] + "…", secret[:12] + "…"])
            if clipboard(out) != secret:
                problems["keys"].append(f"{host} keys: Copy put {clipboard(out)!r} on the clipboard, not the new key")
            if not re.search(r"^TABLE: keys 4 rows", out, re.M):
                problems["keys"].append(f"{host} keys: no 4-row table tagged keys ({re.findall(r'^TABLE: .*$', out, re.M)})")
            if out.count("revoked") < 2:
                problems["keys"].append(f"{host} keys: ci-bot isn't shown revoked after the second tap")
            writes_ok(fx, f"{host} keys", "keys", [("POST", "/admin/keys/zed-editor/rotate", None), ("POST", "/admin/keys", {"app": "ci-bot"}),
                                                   ("DELETE", "/admin/keys/ci-bot", None)], never=[("DELETE", "/admin/keys/notes-app")])
        # -- Gateway: LiteLLM running, its log growing mid-run, Restart ----------------------------------------
        fx = console_fixture.Fixtures()
        net = pyjson.loads(fx.replies["GET /admin/network"]["body"])
        net["expose"]["litellm"] = True
        fx.override("GET /admin/network", pyjson.dumps(net).encode())
        fx.override("GET /admin/litellm/log?bytes=8000", ("\n".join(M6_LITELLM_LOG) + "\n").encode(), ctype="text/plain; charset=utf-8")
        changed = {}

        def grow():
            while sum(1 for x in fx.log if x["target"] == "/admin/litellm/log?bytes=8000") < 2:
                time.sleep(0.05)
            fx.override("GET /admin/litellm/log?bytes=8000", ("\n".join(M6_LITELLM_LOG + [M6_LITELLM_NEW]) + "\n").encode(), ctype="text/plain; charset=utf-8")
            changed["t"] = time.monotonic()
        threading.Thread(target=grow, daemon=True).start()
        r, out = run(host, "gateway", "pause:500;tap:Restart;pause:14000", fx, shot=OUT / f"console-gateway-{host}.png")
        if got(r, out, "gateway"):
            shown(out, f"{host} gateway", "gateway", M6_WANT["gateway"] + M6_LITELLM_LOG + [M6_LITELLM_NEW])
            writes_ok(fx, f"{host} gateway", "gateway", [("POST", "/admin/litellm/restart", None)])
            after = [x["t"] for x in fx.log if x["target"] == "/admin/litellm/log?bytes=8000" and "t" in changed and x["t"] >= changed["t"]]
            if not after or after[0] - changed["t"] > 4.6:
                problems["gateway"].append(f"{host} gateway: after the log grew, the next read came {(after[0] - changed['t']) if after else 'never'} s later (one poll: 4 s)")
            for path, ms in M6_CADENCE.items():
                cadence(fx.log, path, ms, problems["gateway"], f"{host} gateway")
        # -- Security: Make it secure, copy the curl; then (shared already) Stop exposing on the second tap ------
        fx = console_fixture.Fixtures()
        r, out = run(host, "security", "pause:800;tap:Make it secure;pause:2500;tap:copy;pause:300", fx, shot=OUT / f"console-security-{host}.png")
        if got(r, out, "security"):
            shown(out, f"{host} security (on)", "security", M6_WANT["security-on"])
            if clipboard(out) != security_curl(M6_LAN, M6_CA):
                problems["security"].append(f"{host} security: copy put {clipboard(out)!r} on the clipboard, not the curl example")
            writes_ok(fx, f"{host} security (on)", "security", [("POST", "/admin/expose", {})])
            at = next((i for i, x in enumerate(fx.log) if x["method"] == "POST" and x["target"] == "/admin/expose"), None)
            if at is None or not any(x["target"] == "/admin/info" for x in fx.log[at:]) or not any(x["target"] == "/admin/network" for x in fx.log[at:]):
                problems["security"].append(f"{host} security: /admin/info and /admin/network weren't read again after the expose")
        fx = console_fixture.Fixtures()
        fx.set_exposed(True)
        r, out = run(host, "security", "pause:800;tap:Stop exposing;pause:600;tap:Click again to stop exposing;pause:2000", fx)
        if got(r, out, "security"):
            shown(out, f"{host} security (off)", "security", M6_WANT["security-off"])
            writes_ok(fx, f"{host} security (off)", "security", [("POST", "/admin/expose/stop", None)])
        # -- Settings: one tap on Stop daemon asks; the second sends -------------------------------------------
        fx = console_fixture.Fixtures()
        r, out = run(host, "settings", "pause:1500;tap:Stop daemon;pause:800", fx, shot=OUT / f"console-settings-{host}.png")
        if got(r, out, "settings"):
            shown(out, f"{host} settings", "settings", M6_WANT["settings"] + ["Cancel"])
            if not has_part(out, "Stop the daemon? Every model unloads and this console goes offline until you run"):
                problems["settings"].append(f"{host} settings: one tap on Stop daemon didn't ask (the warning box)")
            writes_ok(fx, f"{host} settings", "settings", [], never=[("POST", "/admin/shutdown")])
            for path in ("/admin/info", "/admin/system"):
                if not any(x["target"] == path for x in fx.log):
                    problems["settings"].append(f"{host} settings: never read {path}")
        fx = console_fixture.Fixtures()
        r, out = run(host, "settings", "pause:1500;tap:Stop daemon;pause:500;tap:Stop daemon;pause:1500", fx)
        if got(r, out, "settings"):
            shown(out, f"{host} settings (stop)", "settings", ["Stopping… the console goes offline in a moment."])
            writes_ok(fx, f"{host} settings (stop)", "settings", [("POST", "/admin/shutdown", None)])
    passing = [s for s in M6_SCREENS if not problems[s]]
    failing = [f"{s}: " + "; ".join(dict.fromkeys(problems[s]))[:900] for s in M6_SCREENS if problems[s]]
    try:
        px = m5_pixels(token, M6_SCREENS, {NOW_ENV: None})
    except Exception as e:
        px = [f"unmeasured ({e!r})"]
    tail = "Pixels equal to the original (info, M7 wants 99 %): " + ", ".join(px)
    if pre or failing:
        return False, "; ".join(pre + failing) + f" | passing: {', '.join(passing) or 'none'} | " + tail
    return True, ("examples/console on GTK and the web against the fixtures: Add a model (search with fit badges, a pull through the "
                  "five stages with elapsed times and the live log, the Ready card's curl copied), Keys (rotate and revoke on the second tap, "
                  "a new key shown once and copied), Gateway (counters, routes, requests, the LiteLLM log growing within one poll, Restart), "
                  "Security (expose and stop sent, the curl copied), Settings (info, ports, shutdown on the second tap); every write with the "
                  "admin key; Mac builds. " + tail)


M6_TESTS = ["copy", "fields", "results", "meter", "feedback"]  # the components M6 added to mojoui/ (tests/test_<name>.mojo; catalog and adminkit made generic by M7, D-414)


# M7: identical. The web in pixels against the original (M0's shots and tolerance); GTK and the Mac in boxes against the
# web (goal 32's parity: scripts/parity.py's tolerance, at goal 32's size, side.SIZE); a live daemon through the UI.
M7_PIXELS = 0.99  # GOAL.md: ≥ 99 % of pixels equal, per screen and size
# How GTK and the Mac reach each screen from the start (taps by text, as M5 and M6 drive them); the web opens the route.
M7_STEPS = {
    "models": "pause:2500",
    "overview": f"pause:1500;tap:{CONSOLE_MODEL};pause:2500",
    "bench": f"pause:1500;tap:{CONSOLE_MODEL};pause:800;tap:Benchmark;pause:2500",
    "logs": f"pause:1500;tap:{CONSOLE_MODEL};pause:800;tap:Logs;pause:2500",
    "notebook": f"pause:1500;tap:{CONSOLE_MODEL};pause:800;tap:Notebook;pause:2500",
    "add": "pause:1500;tap:Add a model;pause:2500",
    "keys": "pause:1500;tap:Keys;pause:2500",
    "gateway": "pause:1500;tap:Gateway;pause:2500",
    "security": "pause:1500;tap:Security;pause:2500",
    "settings": "pause:1500;tap:Settings;pause:2500",
}
M7_LIVE = ["load", "numbers", "key", "v1", "revoke", "stop"]  # scripts/console_live.py's facts, in GOAL.md's order


def boxes(out):
    """{key: (x, y, w, h)} from a run's BOX: lines (GTK's widgets in the window, the web's [data-tag] views in the page):
    a tag, or "tag/Button title"; a key's second use is "key 2" (parity._key). Views with no area (not laid out) left out."""
    import re
    import parity
    got, seen = {}, {}
    for m in re.finditer(r"^BOX: (.+) (-?[\d.]+) (-?[\d.]+) ([\d.]+) ([\d.]+)$", out, re.M):
        r = tuple(float(v) for v in m.groups()[1:])
        if r[2] <= 0 and r[3] <= 0:
            continue
        got[parity._key(seen, m.group(1))] = r
    return got


def box_rows(web, other):
    """[(key, web box or None, other box or None, ok)] over both sides' keys, parity.close's tolerance (4 pt or 3 %)."""
    import parity
    return [(k, web.get(k), other.get(k), k in web and k in other and parity.close(web[k], other[k]))
            for k in list(web) + [k for k in other if k not in web]]


def m7():
    """Identical. (1) The web: examples/console's web build against the fixture server, each of the ten screens at
    1440×900 and 390×844 shot by console_side.shoot as M0 shot the original, has ≥ 99 % of its pixels equal to
    docs/goals/33/orig/a's (console_side.differing: no channel off by more than M0's 8 of 255; no masking). (2) GTK and
    the Mac: on each of the ten screens every tagged view's box (and each button in a tagged view) is within goal 32's
    parity tolerance (scripts/parity.py: 4 pt or 3 %) of the web's, at goal 32's size (scripts/side.py SIZE, 1440×640: the
    Mac runner's screen is 1024×768 points and a taller window is cut to it; no phone size on desktop hosts). GTK's boxes
    are its BOX: report against the web's BOX: report (same steps' screen, the web by its route); the Mac's are the newest
    scripts/mac-ci run's view dumps (side.txt's console lines, whose steps must be M7_STEPS) against the web's tagged
    rects (drive.RECTS), and that run must be built from these sources (side.mac_fresh, a stamp that covers
    examples/console). (3) Live: scripts/console_live.py runs the console on GTK against a real mxconsole daemon on its
    fake max (temp state dirs): load, numbers update, create a key, /v1 with it is 200, revoke, /v1 is 401, stop; each
    read back from the daemon's admin API."""
    import json as pyjson
    import secrets
    import console_fixture
    import parity
    import side
    problems = []
    err = build(CONSOLE, "linux", "web")
    if err:
        return False, err
    token = secrets.token_hex(8)

    # (1) the web, in pixels; first, the host renders a tab's first page whole while its effects run (D-545: a torn
    # first page lost a deep link's route under load, and the shot showed the models page for the logs tab)
    # no answer carrying screen changes is dropped by the page (D-546: the logs tab stayed "Loading…"), and a phone's
    # page tells the app the screen's size whatever its content (D-547: the keys page at 390 laid out 780 wide)
    # GTK's and the Mac's labels break lines and drop their end spaces as the browser does (D-548, D-549)
    err = g30.g20.mojo_test("tests/test_linebreak.mojo", "linebreak: ok", "test_linebreak")
    if err:
        problems.append(err[:400])
    for test, args in (("web_first_page", [str(g30.BUILD / CONSOLE / "web")]), ("web_lanes", []),
                       ("web_viewport", [str(g30.BUILD / CONSOLE / "web")])):
        r = g30.run([sys.executable, str(ROOT / "tests" / f"test_{test}.py"), *args], timeout=180)
        if f"{test}: ok" not in r.stdout:
            problems.append(f"tests/test_{test}.py: {(r.stdout + r.stderr)[-300:]}")
    px = web_pixels(token, SCREENS, {NOW_ENV: None})
    notes = []
    for name in SCREENS:
        for w, h in SIZES:
            share = px.get((name, (w, h)))
            if share is None:
                problems.append(f"web {name} {w}×{h}: not shot")
                continue
            notes.append(f"{name} {w}: {share:.1%}")
            if share < M7_PIXELS:
                problems.append(f"web {name} {w}×{h}: {share:.2%} of pixels equal (want ≥ 99 %)")

    # (2) GTK and the Mac, in boxes, against the web at goal 32's size
    w, h = side.SIZE
    routes = dict(console_side_screens())
    side_lines = {s: steps for app, s, _, steps in side.screens() if app == CONSOLE}
    mac_dir = side.mac_dir()
    fresh, why = side.mac_fresh()
    if "examples/console" not in side.SOURCES:
        problems.append("Mac: scripts/side.py's stamp (SOURCES) doesn't cover examples/console, so no Mac run can be shown to be built from it")
    elif not fresh:
        problems.append(f"Mac: stale: {why}")
    off = {"gtk": 0, "mac": 0}
    total = {"gtk": 0, "mac": 0}
    report = []
    for name in SCREENS:
        fx = console_fixture.Fixtures()
        server, url = console_fixture.serve(fx)
        env = console_env(url, token, {NOW_ENV: str(fx.recorded_at)})
        rects = side.OUT / f"{CONSOLE}-{name}-web-rects.txt"
        rects.parent.mkdir(parents=True, exist_ok=True)
        try:
            rg, gtk_out = console_gtk(M7_STEPS[name], env, shot=side.OUT / f"{CONSOLE}-{name}-gtk.png", window=f"{w}x{h}")
            rw, web_out = console_web("pause:2500", env, path=routes[name], viewport=(w, h), rects=rects,
                                      shot=side.OUT / f"{CONSOLE}-{name}-web.png")
        finally:
            server.shutdown()
        if rg is None:
            problems.append(f"gtk {name}: {gtk_out[:300]}")
        if rw is None:
            problems.append(f"web {name} (boxes): {web_out[:300]}")
        if rg is None or rw is None:
            continue
        web_boxes, gtk_boxes = boxes(web_out), boxes(gtk_out)
        if not web_boxes:
            problems.append(f"web {name}: no tagged views")
        rows = box_rows(web_boxes, gtk_boxes)
        bad = [r for r in rows if not r[3]]
        total["gtk"] += len(rows)
        off["gtk"] += len(bad)
        report.append(f"== gtk · {name}: {len(rows) - len(bad)} of {len(rows)} close\n" + parity.table(rows).replace(" mac ", " gtk "))
        problems += [f"gtk {name} {k}: web {parity.fmt(a)} gtk {parity.fmt(b)}" for k, a, b, _ in bad[:3]]
        # the Mac: its view dump against the web's rects
        if name not in side_lines:
            problems.append(f"mac {name}: ci/mac/side.txt has no {CONSOLE}|{name} line")
            continue
        if side_lines[name] != M7_STEPS[name]:
            problems.append(f"mac {name}: side.txt's steps {side_lines[name]!r} aren't M7's {M7_STEPS[name]!r}")
        dump = mac_dir / f"{CONSOLE}-{name}-views.txt" if mac_dir else None
        if not dump or not dump.exists():
            problems.append(f"mac {name}: no view dump {CONSOLE}-{name}-views.txt in the newest mac-ci run ({mac_dir})")
            continue
        rows = parity.compare(rects.read_text(), dump.read_text())
        bad = [r for r in rows if not r[3]]
        total["mac"] += len(rows)
        off["mac"] += len(bad)
        report.append(f"== mac · {name}: {len(rows) - len(bad)} of {len(rows)} close\n" + parity.table(rows))
        problems += [f"mac {name} {k}: web {parity.fmt(a)} mac {parity.fmt(b)}" for k, a, b, _ in bad[:3]]
    (side.OUT / f"{CONSOLE}-parity.txt").write_text("\n".join(report) + "\n")
    box_note = (f"boxes off: GTK {off['gtk']} of {total['gtk']}, Mac {off['mac']} of {total['mac']} "
                f"(build/side/{CONSOLE}-parity.txt)")

    # (3) live: a real daemon on its fake max, through the console's buttons
    r = g30.run([sys.executable, str(ROOT / "scripts" / "console_live.py")], timeout=600)
    out = r.stdout + r.stderr
    summary = next((l[len("LIVE-SUMMARY: "):] for l in out.splitlines() if l.startswith("LIVE-SUMMARY: ")), None)
    if summary is None:
        problems.append(f"live: scripts/console_live.py gave no summary (exit {r.returncode}): {out[-400:]}")
        live_note = "live: no summary"
    else:
        facts = {f["fact"]: f for f in pyjson.loads(summary)}
        for f in facts.values():
            if not f["ok"]:
                problems.append(f"live {f['fact']}: {f['detail']}")
        for want in M7_LIVE:
            if want not in facts:
                problems.append(f"live: no {want} step")
        live_note = "live: " + ", ".join(f"{k} {'ok' if facts.get(k, {}).get('ok') else 'FAIL'}" for k in M7_LIVE)

    tail = f"Pixels equal (want ≥ 99 %): {', '.join(notes)} | {box_note} | {live_note}"
    if problems:
        return False, "; ".join(dict.fromkeys(problems))[:2400] + " | " + tail
    return True, "the web ≥ 99 % equal to the original on all 20 shots; GTK's and the Mac's tagged views within 4 pt or 3 % of the web's; a live daemon through the UI. " + tail


def console_side_screens():
    import console_side
    return console_side.SCREENS


_built_all = []  # (main built every example in this run)


def m8():
    """In the gallery, and nothing regressed: goal 32's M0–M2, goal 30's M0–M5 (goals 3–29 inside them)."""
    problems = []
    if not _built_all:  # (goal 30's checks inside goal 32's M7 run every example's builds: `check.py M8` alone builds them too)
        g30.build_all()
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
    ("M5", m5),
    ("M6", m6),
    ("M7", m7),
    ("M8", m8),
]


def main():
    import headless
    headless.ensure()
    only = sys.argv[1:]
    if not only:
        g30.build_all()
        _built_all.append(True)
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
