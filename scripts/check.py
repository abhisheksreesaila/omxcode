"""Milestone checker for GOAL.md (goal 34: first-class JS; goal 33's M1, M2, M4, M5 run as M4: the full chain waits
for the next stable point, owner 2026-10-27). Prints PASS/FAIL per milestone.

Run: scripts/check   (a subset: scripts/check M0 M1; earlier goals: through docs/goals/NN-check.py)
Each milestone's proof is written before its work starts (todo() until then: it fails), from GOAL.md's words.
"""

import importlib.util
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g33 = load("goal33", "docs/goals/33-check.py")


def todo(what):
    def fn():
        return False, f"not built yet: {what}"
    return fn


def m4():
    """Nothing regressed (minimal, owner): goal 33's M1, M2, M4, M5."""
    problems = []
    for name in ("m1", "m2", "m4", "m5"):
        ok, msg = getattr(g33, name)()
        if not ok:
            problems.append(f"33-{name.upper()}: {msg}")
    return not problems, "; ".join(problems) or "goal 33's M1, M2, M4, M5 pass"


# ---- goal 34: the widgets app (examples/widgets) on the web ----
import json
import os
import re
import subprocess

WIDGETS = "widgets"
BUILD = ROOT / "build"
OUT = ROOT / "docs" / "goals" / "34"


def run(cmd, env=None, timeout=1800, cwd=ROOT):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=dict(os.environ, **(env or {})), timeout=timeout)


def build(example, *hosts):
    for host in hosts:
        b = run(["scripts/build.sh", example, host])
        if b.returncode != 0:
            return f"{example} doesn't build for {host}: " + (b.stdout + b.stderr)[-900:]
    return None


def mojo_test(name, marker):
    exe = BUILD / f"test_{name}"
    b = run(["pixi", "run", "mojo", "build", "-I", ".", "-I", "vendor", f"tests/test_{name}.mojo", "-o", str(exe)])
    if b.returncode != 0:
        return f"tests/test_{name}.mojo doesn't build: " + (b.stdout + b.stderr)[-600:]
    t = run([str(exe)], timeout=300)
    if t.returncode != 0 or marker not in t.stdout:
        return f"tests/test_{name}.mojo fails: " + (t.stdout + t.stderr)[-600:]
    return None


def widgets_web(steps, shot=None, viewport=(1280, 860), example=WIDGETS):
    """The widgets app's web build in headless Chromium (scripts/drive.py: every run collects CSP violations and console
    errors): (ok, output)."""
    import drive
    OUT.mkdir(parents=True, exist_ok=True)
    r, out = drive.web_run(BUILD / example / "web", steps, shot=str(OUT / shot) if shot else None, viewport=viewport, color_scheme="light")
    return r.returncode == 0, out


def js_values(out):
    """Every `js:` step's value, in order (drive.py prints JS: <json>)."""
    return [json.loads(l[len("JS: "):]) for l in out.splitlines() if l.startswith("JS: ")]


def lines_with(out, prefix):
    return [l[len(prefix):] for l in out.splitlines() if l.startswith(prefix)]


def csp_clean(out, where):
    """Problems unless the run saw zero CSP violations and zero console errors (drive.py's CSP: and CONSOLE ERRORS: lines)."""
    problems = []
    csp = lines_with(out, "CSP: ")
    if not csp:
        problems.append(f"{where}: the run reported no CSP line (drive.py doesn't collect violations)")
    elif not csp[-1].startswith("0 violations"):
        problems.append(f"{where}: CSP {csp[-1][:300]}")
    errs = lines_with(out, "CONSOLE ERRORS: ")
    if errs:
        problems.append(f"{where}: console errors {errs[-1][:300]}")
    if "PAGE ERRORS: " in out:
        problems.append(f"{where}: page errors " + lines_with(out, "PAGE ERRORS: ")[-1][:300])
    return problems


# (probes: js: expressions without ";", which separates steps)
COUNTER_PROBE = "js:(w => w ? (w.mojouiProbe = 'kept', 'mounted') : 'none')(document.querySelector('[data-kind=webcomponent] mx-counter'))"
SAME_COUNTER = ("js:(w => [w ? (w.mojouiProbe || 'remounted') : 'none', (window.mojoui.mounts || {})['mx-counter'] || 0, w ? w.querySelector('.count').textContent : '',"
                " w ? w.querySelector('.label').textContent : '', w ? w.querySelectorAll('b, img, script').length : -1])(document.querySelector('[data-kind=webcomponent] mx-counter'))")
LABEL_PROP = "Clicks & <b>counts</b> <img src=x>"  # (the counter's label prop from Mojo: shown as text, never as HTML)


def m0():
    """The seam, in a simple app: WebComponent, commands and replies, App.web_assets(); defineWidget in the web host;
    examples/widgets on the web: a vendored counter widget mounts, takes props from Mojo, its clicks reach update(), a props
    change reaches it without remounting (its own count survives, and survives a rebuild of the whole screen), a command
    gets a reply; the note (a placeholder editor, a word count, a small chart) works; its own test."""
    problems = []
    for f in ("mojoui/webcomponent.mojo", "tests/test_webcomponent.mojo", "examples/widgets/app.mojo",
              "examples/widgets/web/widgets/counter.js", "mojoui/hosts/static/mojoui-widgets.js"):
        if not (ROOT / f).exists():
            problems.append(f"no {f}")
    if problems:
        return False, "; ".join(problems)
    src = (ROOT / "mojoui/webcomponent.mojo").read_text() + (ROOT / "mojoui/app.mojo").read_text()
    for need in ("def WebComponent(", "struct Command", "def web_assets(", "def commands("):
        if need not in src:
            problems.append(f"mojoui has no {need}")
    js = (ROOT / "mojoui/hosts/static/mojoui-widgets.js").read_text()
    if "defineWidget" not in js or "customElements.define" not in js:
        problems.append("the web host's mojoui-widgets.js doesn't define widgets as custom elements (defineWidget)")
    err = mojo_test("webcomponent", "webcomponent: ok")
    if err:
        problems.append(err)
    err = build(WIDGETS, "web")
    if err:
        return False, "; ".join(problems + [err])
    steps = ";".join([
        COUNTER_PROBE,
        "click:mx-counter button.inc", "click:mx-counter button.inc", "click:mx-counter button.inc",
        "tap:Bigger steps",            # props: step 2 (Mojo) → the same widget, its own count kept
        "click:mx-counter button.inc",
        "tap:Ask the counter",         # a command (read) → its reply comes back as an Event
        "tap:Show details",            # the screen's shape changes: the whole page is rebuilt around the widget
        "click:mx-counter button.inc",
        SAME_COUNTER,
    ])
    ok, out = widgets_web(steps, shot="m0-widgets-web.png")
    if not ok:
        return False, "; ".join(problems + ["web run failed: " + out[-700:]])
    vals = js_values(out)
    want_labels = ["Clicks seen by Mojo: 5", "Last count: 7", "Step: 2", "Counter replied: count 5", "Details shown"]
    labels = lines_with(out, "LABEL: ")
    for w in want_labels:
        if w not in labels:
            problems.append(f"no label {w!r} (labels: {labels[:14]})")
    if not vals or vals[0] != "mounted":
        problems.append(f"the counter widget didn't mount ({vals[:1]})")
    if len(vals) < 2 or vals[-1][:2] != ["kept", 1]:
        problems.append(f"the counter was remounted (identity, mount() calls: {vals[-1][:2] if vals else None}): a props change or a rebuild must keep it")
    elif vals[-1][2] != "7":
        problems.append(f"the counter's own count is {vals[-1][2]!r}, not 7 (3 clicks of 1, then 2 clicks of 2: its state was lost)")
    if len(vals) >= 2 and vals[-1][3] != LABEL_PROP:
        problems.append(f"the counter's label prop shows {vals[-1][3]!r}, not Mojo's {LABEL_PROP!r}")
    if len(vals) >= 2 and vals[-1][4] != 0:
        problems.append("the counter's label prop became HTML (elements inside the widget)")
    if not any(l.startswith("mx-counter#1: count 7, step 2") for l in lines_with(out, "WIDGET: ")):
        problems.append(f"the dump doesn't describe the widget as count 7, step 2 ({lines_with(out, 'WIDGET: ')})")
    # the note: a placeholder editor (a text area), a word count, a small chart drawn by mojoui
    # (M0 typed into a text area standing in for the editor; since M1 it's the editor itself)
    ok2, out2 = widgets_web("keys:mx-editor .cm-content=one two three four" if (ROOT / "examples/widgets/web/widgets/editor.ts").exists()
                            else "textarea:0=one two three four", shot="m0-note-web.png")
    if not ok2:
        problems.append("note run failed: " + out2[-400:])
    elif "Words: 4" not in lines_with(out2, "LABEL: ") or not re.search(r"^CANVAS: ", out2, re.M) and "[data-kind=canvas]" not in out2:
        problems.append(f"the note's word count didn't follow the text (labels {lines_with(out2, 'LABEL: ')[:10]})")
    return not problems, "; ".join(problems) or ("WebComponent + commands + web_assets(); the counter mounts, shows Mojo's props as text, "
                                                 "5 clicks reach update(), a props change and a full rebuild keep it (count 7, one mount), "
                                                 "a command's reply reaches update(); the note counts words; tests/test_webcomponent.mojo passes; "
                                                 f"shots {OUT.relative_to(ROOT)}/m0-*.png")


EDITOR_STATE = ("js:((w, v) => v ? [v.state.doc.toString(), v.state.selection.main.anchor, v.state.selection.main.head, v.hasFocus, w.mojouiProbe || 'remounted',"
                " (window.mojoui.mounts || {})['mx-editor'] || 0] : ['none'])(document.querySelector('[data-kind=webcomponent] mx-editor'),"
                " (document.querySelector('[data-kind=webcomponent] mx-editor') || {}).mojouiView)")
EDITOR_PROBE = "js:(w => w && w.mojouiView ? (w.mojouiProbe = 'kept', 'mounted') : 'none')(document.querySelector('[data-kind=webcomponent] mx-editor'))"


def m1():
    """npm and TypeScript: examples/widgets/web/package.json + its lockfile (node_modules never in git); CodeMirror 6 from
    npm bundled offline by esbuild at build time; the editor widget written in TypeScript compiles in the same build;
    typing in the editor reaches update() (the word count follows), Mojo sets the text (Load sample) and the editor shows
    it, the cursor survives an unrelated rebuild; scripts/new_widget.sh makes a working widget from a template (generated,
    built, mounted); docs/js.md walks it; build.sh runs the npm/esbuild step for any app with a web/package.json."""
    problems = []
    web = ROOT / "examples" / WIDGETS / "web"
    for f in ("package.json", "package-lock.json", "widgets/editor.ts"):
        if not (web / f).exists():
            problems.append(f"no examples/widgets/web/{f}")
    for f in ("scripts/new_widget.sh", "docs/js.md", "scripts/web_assets.py"):
        if not (ROOT / f).exists():
            problems.append(f"no {f}")
    if problems:
        return False, "; ".join(problems)
    pkg = json.loads((web / "package.json").read_text())
    deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
    if not any(d.startswith("@codemirror/") or d == "codemirror" for d in deps):
        problems.append("package.json doesn't depend on CodeMirror 6")
    lock = json.loads((web / "package-lock.json").read_text())
    if lock.get("lockfileVersion", 0) < 2 or not any("codemirror" in k for k in lock.get("packages", {})):
        problems.append("package-lock.json doesn't pin CodeMirror's packages")
    tracked = run(["git", "ls-files"]).stdout.splitlines()
    if any("node_modules" in t for t in tracked):
        problems.append("node_modules is in git")
    for f in ("examples/widgets/web/package.json", "examples/widgets/web/package-lock.json", "examples/widgets/web/widgets/editor.ts"):
        if f not in tracked:
            problems.append(f"{f} isn't committed")
    bs = (ROOT / "scripts/build.sh").read_text()
    if "web/package.json" not in bs or "web_assets.py" not in bs or re.search(r"examples/widgets|\bwidgets\b(?!/)", bs):  # (no app named: web/widgets/ is every app's folder)
        problems.append("scripts/build.sh doesn't run the npm/esbuild step generically (for any app with a web/package.json)")
    doc = (ROOT / "docs/js.md").read_text().lower()
    for topic in ("package.json", "definewidget", "webcomponent(", "command", "security", "content-security-policy", "new_widget.sh"):
        if topic not in doc:
            problems.append(f"docs/js.md doesn't cover {topic}")
    err = build(WIDGETS, "web")
    if err:
        return False, "; ".join(problems + [err])
    assets = BUILD / WIDGETS / "web" / "assets"
    manifest = json.loads((assets / "manifest.json").read_text()) if (assets / "manifest.json").exists() else {}
    ed = manifest.get("editor.js", {})
    if not ed or ed.get("source") != "widgets/editor.ts":
        problems.append(f"the build's manifest has no editor.js bundled from widgets/editor.ts ({ed})")
    else:
        body = (assets / ed["file"]).read_text()
        if "cm-content" not in body or "\n  " in body[:2000]:
            problems.append("editor.js isn't a minified bundle with CodeMirror in it")
        if (BUILD / WIDGETS / "web" / "node_modules").exists() or (assets / "node_modules").exists():
            problems.append("node_modules sits next to the app (it belongs in the build's npm folder only)")
    sample = "The quick brown fox jumps over the lazy dog"
    steps = ";".join([
        EDITOR_PROBE,
        "keys:mx-editor .cm-content=one two three",          # typing: each change reaches update()
        EDITOR_STATE,
        "keys:mx-editor .cm-content= four five six",         # past five words the screen grows a line: a rebuild mid-typing
        EDITOR_STATE,
        "press:Home", "press:x",                             # the editor still has the keyboard and its cursor
        EDITOR_STATE,
        "tap:Load sample",                                   # Mojo sets the text
        EDITOR_STATE,
    ])
    ok, out = widgets_web(steps, shot="m1-editor-web.png")
    if not ok:
        return False, "; ".join(problems + ["web run failed: " + out[-700:]])
    vals = js_values(out)
    if len(vals) != 5 or vals[0] != "mounted":
        problems.append(f"the editor didn't mount ({vals[:1]})")
    else:
        typed, grown, homed, loaded = vals[1], vals[2], vals[3], vals[4]
        if typed[0] != "one two three":
            problems.append(f"the editor holds {typed[0]!r} after typing")
        if grown[0] != "one two three four five six" or grown[2] != len(grown[0]) or not grown[3]:
            problems.append(f"after a rebuild mid-typing the editor holds {grown[0]!r}, cursor {grown[2]}, focus {grown[3]}")
        if homed[0] != "xone two three four five six" or homed[2] != 1 or homed[4:] != ["kept", 1]:
            problems.append(f"Home then x gave {homed}: the cursor or the editor didn't survive the rebuild")
        if loaded[0] != sample or loaded[4:] != ["kept", 1]:
            problems.append(f"Load sample shows {loaded[0]!r} (identity {loaded[4:]})")
    labels = lines_with(out, "LABEL: ")
    if "Words: 9" not in labels:  # (the sample's words: the count follows Mojo's own text too)
        problems.append(f"the word count didn't follow (labels {labels[:12]})")
    if "Long note" not in labels:
        problems.append("the rebuild-making line (Long note) never showed")
    problems += csp_clean(out, "editor run")
    problems += new_widget_probe()
    return not problems, "; ".join(problems) or ("CodeMirror 6 from npm (lockfile), bundled and minified offline by esbuild, its widget in "
                                                 "TypeScript; typing reaches update() (word count), a rebuild mid-typing keeps the text, cursor, "
                                                 "focus and the one mount; Load sample sets the text from Mojo; new_widget.sh's widget builds and "
                                                 f"mounts; docs/js.md; shots {OUT.relative_to(ROOT)}/m1-*.png")


PROBE_APP = '''# A scratch app made by scripts/check.py M1 (scripts/new_widget.sh's proof); removed after the run.
from mojoui import App, Event, View, VStack, Text
from mojoui.webcomponent import WebComponent, Props

comptime PING = 1


struct Main(App):
    var pings: Int

    def __init__(out self):
        self.pings = 0

    def title(self) -> String:
        return "probe"

    @staticmethod
    def web_assets() -> List[String]:
        return ["probe-card.js"]

    def update(mut self, event: Event):
        if event.message == PING:
            self.pings += 1

    def view(self) -> View:
        return VStack(WebComponent("mx-probe-card", Props().text("label", "Hello from Mojo"), on_event=PING, id=1),
                      Text("Pings: " + String(self.pings)))
'''


def new_widget_probe():
    """scripts/new_widget.sh probe-card <scratch app>: the template builds and mounts, shows its prop, its event reaches update()."""
    import shutil
    ex = "zz_probe_widget"
    d = ROOT / "examples" / ex
    shutil.rmtree(d, ignore_errors=True)
    shutil.rmtree(BUILD / ex, ignore_errors=True)
    try:
        d.mkdir(parents=True)
        (d / "app.mojo").write_text(PROBE_APP)
        (d / "platforms").write_text("web\n")
        g = run(["scripts/new_widget.sh", "probe-card", ex])
        if g.returncode != 0 or not (d / "web" / "widgets" / "probe-card.js").exists():
            return ["scripts/new_widget.sh probe-card failed: " + (g.stdout + g.stderr)[-400:]]
        err = build(ex, "web")
        if err:
            return [err]
        ok, out = widgets_web("click:mx-probe-card button;click:mx-probe-card button", example=ex)
        if not ok:
            return ["the generated widget's app failed: " + out[-400:]]
        problems = []
        if "Pings: 2" not in lines_with(out, "LABEL: "):
            problems.append(f"the generated widget's clicks didn't reach update() ({lines_with(out, 'LABEL: ')})")
        if not any("Hello from Mojo" in w for w in lines_with(out, "WIDGET: ")):
            problems.append(f"the generated widget doesn't show its prop ({lines_with(out, 'WIDGET: ')})")
        return problems
    finally:
        shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(BUILD / ex, ignore_errors=True)


def fetch(url):
    import urllib.request
    with urllib.request.urlopen(url, timeout=10) as r:
        return r.status, dict(r.headers), r.read()


def serve(module_dir, env=None):
    """mojoui/hosts/web.py on a free port: (process, base url)."""
    import time as _t
    import urllib.request
    import drive
    port = drive.free_port()
    p = subprocess.Popen([sys.executable, str(ROOT / "mojoui/hosts/web.py"), str(module_dir), str(port)], cwd=ROOT,
                         env=dict(os.environ, **(env or {})), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    url = f"http://127.0.0.1:{port}/"
    for _ in range(600):
        try:
            urllib.request.urlopen(url + "static/htmx.min.js", timeout=1)
            return p, url
        except OSError:
            _t.sleep(0.1)
    p.terminate()
    raise RuntimeError("web host didn't start")


def page_problems(url, where):
    """The page's headers and HTML: a strict CSP; no inline script, handler or eval-needing attribute; every script, style
    sheet and font served by its content hash from our origin with a year-long immutable cache."""
    import hashlib
    problems = []
    status, headers, body = fetch(url)
    html = body.decode()
    csp = headers.get("Content-Security-Policy", "")
    rules = {r.split()[0]: r.split()[1:] for r in csp.split(";") if r.strip()}
    if rules.get("default-src") != ["'self'"]:
        problems.append(f"{where}: default-src is {rules.get('default-src')}")
    if rules.get("script-src") != ["'self'"]:
        problems.append(f"{where}: script-src is {rules.get('script-src')} (only 'self': our hashed files)")
    for d in ("object-src", "base-uri", "frame-ancestors", "form-action"):
        if d not in rules:
            problems.append(f"{where}: the CSP has no {d}")
    if "'unsafe-eval'" in csp:
        problems.append(f"{where}: the CSP allows eval")
    for h in ("X-Content-Type-Options", "Referrer-Policy"):
        if h not in headers:
            problems.append(f"{where}: no {h} header")
    if re.search(r"<script(?![^>]*\bsrc=)[^>]*>", html):
        problems.append(f"{where}: an inline <script> in the page")
    if re.search(r"\son[a-z]+=", html):
        problems.append(f"{where}: an inline on…= handler: " + re.search(r"\son[a-z]+=\"[^\"]{0,60}", html).group(0))
    if re.search(r"hx-vals=\"js:|hx-on|javascript:", html):
        problems.append(f"{where}: an eval-needing htmx attribute or a javascript: URL")
    refs = re.findall(r'<script[^>]*\bsrc="([^"]+)"', html) + re.findall(r'<link[^>]*\bhref="(/[^"]+)"', html)
    refs += re.findall(r"url\((/[^)]+)\)", html)
    if not refs:
        problems.append(f"{where}: no scripts found in the page")
    for ref in refs:
        m = re.search(r"\.([0-9a-f]{16})\.[a-z0-9]+$", ref.split("?")[0])
        if not ref.startswith("/") or ref.startswith("//") or not m:
            problems.append(f"{where}: {ref} isn't served by its content hash from our origin")
            continue
        st, hd, data = fetch(url.rstrip("/") + ref)
        if hashlib.sha256(data).hexdigest()[:16] != m.group(1):
            problems.append(f"{where}: {ref}'s bytes don't match its hash")
        if "immutable" not in hd.get("Cache-Control", "") or "max-age=31536000" not in hd.get("Cache-Control", ""):
            problems.append(f"{where}: {ref} has Cache-Control {hd.get('Cache-Control')!r}")
    return problems


INJECT = ("js:(before => (window.pwned = 0,"
          " document.body.append(Object.assign(document.createElement('script'), { textContent: 'window.pwned = 1' })),"
          " document.body.append(Object.assign(document.createElement('div'), { innerHTML: '<img src=\"/nothing.png\" onerror=\"window.pwned = 2\">' })),"
          " setTimeout('window.pwned = 3', 0),"
          " new Promise(ok => setTimeout(() => ok([window.pwned, window.mojouiCsp.length - before,"
          " window.mojouiCsp.slice(before).map(v => v.directive).sort().join(' ')]), 400))))(window.mojouiCsp.length)")


def m2():
    """Secure by default: a strict CSP (no inline script, no eval; script-src only our hashed files); every asset served by
    its content hash from our origin; the widgets app and the console run with zero CSP violations and zero console errors
    (read from the browser); an injected inline script, inline handler and string-eval are blocked; props and events are
    JSON data only; a build lint fails on an asset not listed by web_assets() or not bundled; WebFrame is sandboxed by
    default (no allow-same-origin), http(s) only."""
    import shutil
    import tempfile
    problems = []
    err = build(WIDGETS, "web")
    if err:
        return False, err
    # 1) headers and HTML of the widgets app and the console
    for where, mod in (("widgets", BUILD / WIDGETS / "web"), ("console", BUILD / "console" / "web")):
        if not (mod / "mojoui_app.so").exists():
            e = build(mod.parent.name, "web")
            if e:
                problems.append(e)
                continue
        p, url = serve(mod)
        try:
            problems += page_problems(url, where)
            # props and events are JSON only: a widget event that isn't JSON, or a name that isn't a word, does nothing
            import urllib.request
            import urllib.parse
            sid = re.search(r'data-sid="([0-9a-f]+)"', fetch(url)[2].decode())
            if where == "widgets" and sid:
                for form, why in (({"tag": "mx-counter", "id": "1", "name": "click", "data": "{not json"}, "a payload that isn't JSON"),
                                  ({"tag": "mx-counter", "id": "1", "name": "click()<x>", "data": "{}"}, "an event name that isn't a word")):
                    req = urllib.request.Request(url + f"w/{sid.group(1)}", data=urllib.parse.urlencode(form).encode(), method="POST")
                    with urllib.request.urlopen(req, timeout=10) as r:
                        if r.status not in (200, 204) or r.read().strip():
                            problems.append(f"widgets: {why} changed the screen")
        finally:
            p.terminate()
            p.wait(timeout=10)
    # 2) zero violations, real runs: the widgets app and the console (its notebook frames Jupyter)
    ok, out = widgets_web("click:mx-counter button.inc;tap:Ask the counter;tap:Show details;keys:mx-editor .cm-content=hello there;tap:Load sample;" + INJECT,
                          shot="m2-widgets-web.png")
    if not ok:
        problems.append("widgets run failed: " + out[-500:])
    else:
        problems += csp_clean_but_injected(out, "widgets")
    problems += console_runs()
    # 3) the asset lint: a stray file, or a listed name the bundler didn't make, fails it
    lint = [sys.executable, "scripts/web_assets.py", "--lint", WIDGETS]
    base = run(lint)
    if base.returncode != 0:
        problems.append("the asset lint fails on the real build: " + (base.stdout + base.stderr)[-300:])
    assets = BUILD / WIDGETS / "web" / "assets"
    stray = assets / "stray.0123456789abcdef.js"
    stray.write_text("window.stray = 1\n")
    try:
        r = run(lint)
        if r.returncode == 0 or "stray" not in r.stdout + r.stderr:
            problems.append("the asset lint passes a file the bundler didn't make")
    finally:
        stray.unlink()
    tmp = Path(tempfile.mkdtemp(prefix="g34-lint-"))
    try:
        r = run(lint, env={"MOJOUI_ASSETS_LISTED": json.dumps(["counter.js", "editor.js", "missing.js"])})
        if r.returncode == 0 or "missing.js" not in r.stdout + r.stderr:
            problems.append("the asset lint passes a listed asset nobody bundled (missing.js)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    # 4) WebFrame: sandboxed by default, http(s) only (the web host's own test)
    wl = run([sys.executable, "tests/test_web_links.py"], timeout=120)
    if wl.returncode != 0 or "web_links: ok" not in wl.stdout:
        problems.append("tests/test_web_links.py fails: " + (wl.stdout + wl.stderr)[-300:])
    src = (ROOT / "tests/test_web_links.py").read_text()
    if "allow-scripts allow-forms" not in src or "allow-same-origin" not in src:
        problems.append("tests/test_web_links.py doesn't prove WebFrame's default sandbox")
    return not problems, "; ".join(problems[:8]) or ("strict CSP (script-src 'self', no eval, no inline script or handler), every asset by its "
                                                     "content hash with immutable caching; the widgets app and the console ran with 0 CSP "
                                                     "violations and 0 console errors; injected script, handler and string-eval blocked; "
                                                     "non-JSON events refused; the asset lint fails a stray or unbundled asset; WebFrame "
                                                     "sandboxed (allow-scripts allow-forms), http(s) only")


def csp_clean_but_injected(out, where):
    """The run's only violations are the three the INJECT step made on purpose, and none of them ran."""
    problems = []
    vals = js_values(out)
    if not vals:
        return [f"{where}: the injection probe returned nothing"]
    pwned, made, directives = vals[-1]
    if pwned != 0:
        problems.append(f"{where}: injected code ran (window.pwned = {pwned})")
    if made < 3 or "script-src-attr" not in directives or "script-src-elem" not in directives or "script-src" not in directives.split():
        problems.append(f"{where}: the injections weren't all reported as blocked ({made}: {directives})")
    csp = lines_with(out, "CSP: ")
    if not csp:
        problems.append(f"{where}: no CSP line")
    else:
        m = re.match(r"(\d+) violations", csp[-1])
        if not m or int(m.group(1)) != made:
            problems.append(f"{where}: violations besides the injected ones: {csp[-1][:300]}")
    errs = [e for e in lines_with(out, "CONSOLE ERRORS: ")]
    if errs and not all("Content Security Policy" in x or "Content-Security-Policy" in x for x in errs[-1].split(" | ")):
        problems.append(f"{where}: console errors besides the blocked injections: {errs[-1][:300]}")
    return problems


def console_runs():
    """examples/console on the web against goal 33's fixture server: its models, a model's tabs and Run in Jupyter,
    with zero CSP violations and zero console errors."""
    import secrets
    import console_fixture
    problems = []
    token = secrets.token_hex(8)
    for path, steps in (("", "pause:1500;tap:Cards;pause:600;tap:List;pause:400"),
                        (f"#/models/{g33.CONSOLE_MODEL}/notebook", "pause:1500;tap:Run in Jupyter;pause:1500;tap:Saved view;pause:500"),
                        (f"#/models/{g33.CONSOLE_MODEL}/logs", "pause:2500")):
        fx = console_fixture.Fixtures()
        server, url = console_fixture.serve(fx)
        try:
            r, out = g33.console_web(steps, g33.console_env(url, token), shot=OUT / f"m2-console{path.replace('/', '-').replace('#', '')}.png", path=path)
        finally:
            server.shutdown()
        if r is None:
            problems.append(f"console {path or '/'}: {out[-300:]}")
            continue
        problems += csp_clean(out, f"console {path or '/'}")
    return problems


MILESTONES = [
    ("M0", m0),
    ("M1", m1),
    ("M2", m2),
    ("M3", todo("the widget in a WebKitGTK view on GTK (GOAL.md M3)")),
    ("M4", m4),
]


def main():
    import headless
    headless.ensure()
    only = sys.argv[1:]
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
