"""Milestone checker for GOAL.md (goal 34b: JS widgets everywhere, and agents see them; goal 34's M0–M3 and goal 33's
M1, M4 run as M3, minimal regression by the owner's choice). Prints PASS/FAIL per milestone.

Run: scripts/check   (a subset: scripts/check M0 M1)
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


g34 = load("goal34", "docs/goals/34-check.py")
g33 = g34.g33


# ---- M0: agents see JS widgets (the agent host attached to a running web or GTK host) ----
import json
import os
import shutil
import socket as _socket
import subprocess
import tempfile

BUILD = ROOT / "build"
OUT = ROOT / "docs" / "goals" / "34b"
TYPED = "Agents can write here\nand on a second line"


def run(cmd, env=None, timeout=1800):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=dict(os.environ, **(env or {})), timeout=timeout)


def agent_socket():
    d = Path(tempfile.mkdtemp(prefix="mojoui-agent-"))
    return d / "agent.sock"


def wait_socket(path, proc, seconds=120):
    t0 = time.time()
    while time.time() - t0 < seconds:
        if proc is not None and proc.poll() is not None:
            return False
        if path.exists():
            try:
                with _socket.socket(_socket.AF_UNIX) as s:
                    s.connect(str(path))
                return True
            except OSError:
                pass
        time.sleep(0.2)
    return False


def agent_tools(c):
    return {t["name"]: t for t in c.tools()}


def widget_story(c, where):
    """What GOAL.md M0 asks of an attached agent, on one host: (problems, sample lines for the report)."""
    problems, samples = [], []
    tools = agent_tools(c)
    for need in ("editor-read", "editor-set", "counter-read", "counter-set"):
        if need not in tools:
            problems.append(f"{where}: no tool {need} (tools: {', '.join(sorted(tools))[:400]})")
    if problems:
        return problems, samples
    if "CodeMirror" not in tools["editor-read"]["description"] and "editor" not in tools["editor-read"]["description"].lower():
        problems.append(f"{where}: editor-read's description doesn't say what it is ({tools['editor-read']['description']!r})")
    ed_schema = tools["editor-set"]["inputSchema"]["properties"]
    ct_schema = tools["counter-set"]["inputSchema"]["properties"]
    if ed_schema.get("text", {}).get("type") != "string":
        problems.append(f"{where}: editor-set has no typed text argument ({ed_schema})")
    if ct_schema.get("count", {}).get("type") != "integer":
        problems.append(f"{where}: counter-set has no typed count argument ({ct_schema})")
    if "label" in ct_schema:
        problems.append(f"{where}: counter-set offers an undeclared field (label)")
    text, _, err = c.call("editor-set", text=TYPED)
    if err:
        problems.append(f"{where}: editor-set failed: {text[:300]}")
    text, _, err = c.call("editor-read")
    samples.append(f"{where} editor-read → {text[:200]}")
    try:
        said = json.loads(text[text.index("{"):])
    except ValueError:
        said = {}
        problems.append(f"{where}: editor-read isn't the widget's description as JSON ({text[:200]!r})")
    if said.get("value") != TYPED or said.get("lines") != 2:
        problems.append(f"{where}: editor-read says value {said.get('value')!r}, lines {said.get('lines')!r} after editor-set")
    screen_texts, _, _ = c.call("read")
    if "Words: 9" not in screen_texts:  # (the word count is Mojo's: the widget's own change event reached update())
        problems.append(f"{where}: update() didn't hear the editor's change (texts: {screen_texts[:300]!r})")
    text, _, err = c.call("counter-set", count=42)
    if err:
        problems.append(f"{where}: counter-set failed: {text[:300]}")
    text, _, err = c.call("counter-read")
    samples.append(f"{where} counter-read → {text[:160]}")
    if '"count": 42' not in text.replace('"count":42', '"count": 42'):
        problems.append(f"{where}: counter-read after counter-set 42 says {text[:200]!r}")
    screen_texts, _, _ = c.call("read")
    if "Last count: 42" not in screen_texts:
        problems.append(f"{where}: update() didn't hear the counter's change event ({screen_texts[:300]!r})")
    # security: only declared fields, only their JSON type
    text, _, err = c.call("counter-set", label="<img src=x onerror=alert(1)>")
    if not err:
        problems.append(f"{where}: counter-set took an undeclared field (label): {text[:200]}")
    text, _, err = c.call("editor-set", text=12)
    if not err:
        problems.append(f"{where}: editor-set took a number for its string field: {text[:200]}")
    screen, _, _ = c.call("screen")
    if "mx-editor" not in screen or "mx-counter" not in screen:
        problems.append(f"{where}: screen doesn't list the widgets by tag")
    return problems, samples


def raw_link(path, op):
    """One request straight to the host's agent link (bypassing the agent host's own checks): the reply."""
    with _socket.socket(_socket.AF_UNIX) as s:
        s.settimeout(10)
        s.connect(str(path))
        s.sendall((json.dumps(op) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf or b"{}")


def page_side_refusal(c, path, where):
    """The widget's runtime refuses what the agent host would: an undeclared field and a wrong type, sent raw."""
    problems = []
    raw_link(path, {"op": "set", "tag": "mx-counter", "id": 1, "field": "label", "value": json.dumps("pwned")})  # (value: JSON text)
    raw_link(path, {"op": "set", "tag": "mx-counter", "id": 1, "field": "count", "value": json.dumps("7")})
    bad = raw_link(path, {"op": "set", "tag": "mx-counter", "id": 1, "field": "count", "value": "alert(1)"})
    if bad.get("ok"):
        problems.append(f"{where}: the host's link took a value that isn't JSON ({bad})")
    time.sleep(1.0)
    text, _, _ = c.call("counter-read")
    if "pwned" in text or '"count": "7"' in text or '"count":"7"' in text or '"count": 42' not in text.replace('"count":42', '"count": 42'):
        problems.append(f"{where}: the widget took a raw undeclared or mistyped set ({text[:200]!r})")
    return problems


def m0_web():
    import agent_client
    import drive
    problems, samples = [], []
    sock = agent_socket()

    def during(page):
        nonlocal problems, samples
        if not wait_socket(sock, None, 30):
            problems.append("web: the host opened no agent link (MOJOUI_AGENT_SOCKET)")
            return ""
        c = agent_client.Client(attach=sock)
        try:
            p, s = widget_story(c, "web")
            problems += p
            samples += s
            problems += page_side_refusal(c, sock, "web")
            drive.settle(page)
            cm = page.evaluate("() => (e => e ? e.textContent : '')(document.querySelector('mx-editor .cm-content'))")
            if "Agents can write here" not in cm:
                problems.append(f"web: the page's CodeMirror doesn't show the agent's text ({cm[:120]!r})")
        finally:
            c.close()
        return ""

    OUT.mkdir(parents=True, exist_ok=True)
    try:
        r, out = drive.web_run(BUILD / "widgets" / "web", "", shot=str(OUT / "m0-agent-web.png"), viewport=(1280, 860), color_scheme="light",
                               env={"MOJOUI_AGENT_SOCKET": str(sock)}, during=during)
    finally:
        shutil.rmtree(sock.parent, ignore_errors=True)
    if r.returncode != 0:
        problems.append("web run failed: " + out[-500:])
    csp = [l for l in out.splitlines() if l.startswith("CSP: ")]
    if not csp or not csp[-1].startswith("CSP: 0 violations"):
        problems.append(f"web: CSP {csp[-1:] or 'not read'}")
    if "CONSOLE ERRORS: " in out or "PAGE ERRORS: " in out:
        problems.append("web: console errors " + "".join(l for l in out.splitlines() if "ERRORS: " in l)[:300])
    return problems, samples


def m0_gtk():
    import agent_client
    problems, samples = [], []
    sock = agent_socket()
    exe = BUILD / "widgets" / "linux" / "widgets"
    log = open(sock.parent / "app.log", "w+")
    app = subprocess.Popen([str(exe)], cwd=ROOT, env=dict(os.environ, MOJOUI_AGENT_SOCKET=str(sock), MOJOUI_WINDOW="1280x860"),
                           stdout=log, stderr=subprocess.STDOUT)
    try:
        if not wait_socket(sock, app, 120):
            log.seek(0)
            return [f"gtk: the app opened no agent link: {log.read()[-500:]}"], samples
        time.sleep(1.5)  # (its web views load their widgets)
        c = agent_client.Client(attach=sock)
        try:
            p, s = widget_story(c, "gtk")
            problems += p
            samples += s
            problems += page_side_refusal(c, sock, "gtk")
        finally:
            c.close()
    finally:
        app.terminate()
        try:
            app.wait(timeout=10)
        except subprocess.TimeoutExpired:
            app.kill()
        log.close()
        shutil.rmtree(sock.parent, ignore_errors=True)
    return problems, samples


NO_DESCRIBE_APP = """# A scratch app made by scripts/check.py M0 (a widget without describe); removed after the run.
from mojoui import App, Event, View, VStack, Text
from mojoui.webcomponent import WebComponent, Props

comptime PING = 1


struct Main(App):
    var pings: Int

    def __init__(out self):
        self.pings = 0

    def title(self) -> String:
        return "plain"

    @staticmethod
    def web_assets() -> List[String]:
        return ["plain-card.js"]

    def update(mut self, event: Event):
        if event.message == PING:
            self.pings += 1

    def view(self) -> View:
        return VStack(WebComponent("mx-plain-card", Props().text("label", "No words"), on_event=PING, id=1), Text("Pings: " + String(self.pings)))
"""


def m0_no_describe():
    """A widget whose spec has no describe: listed by its tag, reading it says "no description"."""
    import agent_client
    import drive
    ex = "zz_plain_widget"
    d = ROOT / "examples" / ex
    shutil.rmtree(d, ignore_errors=True)
    shutil.rmtree(BUILD / ex, ignore_errors=True)
    problems = []
    sock = agent_socket()
    try:
        d.mkdir(parents=True)
        (d / "app.mojo").write_text(NO_DESCRIBE_APP)
        (d / "platforms").write_text("web\n")
        g = run(["scripts/new_widget.sh", "plain-card", ex])
        js = d / "web" / "widgets" / "plain-card.js"
        if g.returncode != 0 or not js.exists():
            return ["scripts/new_widget.sh plain-card failed: " + (g.stdout + g.stderr)[-300:]]
        js.write_text("\n".join(l for l in js.read_text().splitlines() if "describe(el)" not in l) + "\n")
        b = run(["scripts/build.sh", ex, "web"])
        if b.returncode != 0:
            return ["the no-describe app doesn't build: " + (b.stdout + b.stderr)[-400:]]

        def during(page):
            if not wait_socket(sock, None, 30):
                problems.append("no-describe: no agent link")
                return ""
            c = agent_client.Client(attach=sock)
            try:
                tools = agent_tools(c)
                name = next((n for n in tools if n.startswith("mx-plain-card") and n.endswith("-read")), None)
                if name is None:
                    problems.append(f"no-describe: the widget isn't listed by its tag ({sorted(tools)})")
                else:
                    if "no description" not in tools[name]["description"]:
                        problems.append(f"no-describe: its tool doesn't say no description ({tools[name]['description']!r})")
                    text, _, _ = c.call(name)
                    if "no description" not in text:
                        problems.append(f"no-describe: reading it says {text[:160]!r}")
                if any(n.startswith("mx-plain-card") and n.endswith("-set") for n in tools):
                    problems.append("no-describe: a set tool for a widget that declares no fields")
            finally:
                c.close()
            return ""

        r, out = drive.web_run(BUILD / ex / "web", "", viewport=(900, 600), env={"MOJOUI_AGENT_SOCKET": str(sock)}, during=during)
        if r.returncode != 0:
            problems.append("no-describe web run failed: " + out[-300:])
        return problems
    finally:
        shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(BUILD / ex, ignore_errors=True)
        shutil.rmtree(sock.parent, ignore_errors=True)


# ---- M1: a second library (Apache ECharts from npm) with no host changes ----
M0_PASSED = "a87c7cc"  # the commit where M0 passed: M0 legitimately changed host files, so M1 is diffed against it
# a real click on the chart's point 1 (the page's own coordinates: ECharts' convertToPixel), through ECharts' own events
CHART_POINT = ("(c => ((p, r) => [r.left + p[0], r.top + p[1]])(c.convertToPixel({seriesIndex: 0}, [1, c.getOption().series[0].data[1]]),"
               " c.getDom().getBoundingClientRect()))(document.querySelector('mx-chart').mojouiChart)")
# GTK has no pointer driver inside a widget's page: the same point clicked with the DOM events a mouse sends (no ";": a step)
GTK_CLICK = ("webjs:mx-chart#1=(([x, y]) => (['pointermove', 'pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(n =>"
             " document.elementFromPoint(x, y).dispatchEvent(new (n.startsWith('pointer') ? PointerEvent : MouseEvent)(n, {bubbles: true,"
             " cancelable: true, clientX: x, clientY: y, button: 0, pointerId: 1, pointerType: 'mouse', isPrimary: true, view: window}))),"
             " 'clicked ' + Math.round(x) + ',' + Math.round(y)))(" + CHART_POINT + ")")


def git(*args):
    return run(["git", *args]).stdout


M1_DONE = "760bb66"  # the commit where M1 passed: ECharts' whole change set is M0_PASSED..M1_DONE


def m1_hosts_unchanged():
    """No file in mojoui/hosts changed for M1: the change set that added ECharts (M0_PASSED, just before it, to M1_DONE,
    where M1 passed), pinned by SHA so later work and merges (M1b's theming, the Mac's AppKit web view) don't touch it."""
    where = f"{M0_PASSED}..{M1_DONE}"
    if run(["git", "cat-file", "-e", M1_DONE + "^{commit}"]).returncode != 0:
        return [f"no commit {M1_DONE} in this history"], where
    changed = git("diff", "--name-only", M0_PASSED, M1_DONE, "--", "mojoui/hosts").split()
    added = git("diff", "--name-only", M0_PASSED, M1_DONE, "--", "examples/widgets/web").split()
    problems = [f"M1 changed host files ({where}): {', '.join(changed)}"] if changed else []
    if "examples/widgets/web/widgets/chart.ts" not in added:
        problems.append(f"{where} isn't the change set that added the ECharts widget")
    return problems, where


def m1_series(widget_line):
    """The chart's own line (describe().text): 'N points: a, b, c'."""
    import re as _re
    m = _re.search(r"(\d+) points?: ([\d, ]*)", widget_line or "")
    return [int(x) for x in m.group(2).split(",") if x.strip()] if m else None


def m1():
    """A second library, no host changes (GOAL.md M1): Apache ECharts from npm (pinned, lockfile) as a chart widget in
    examples/widgets, fed from Mojo (the word-count series as data), its click on a point reaching update(); no file in
    mojoui/hosts changed (diffed against the commit where M0 passed); the same CSP with zero violations; web and GTK."""
    problems = []
    web = ROOT / "examples" / "widgets" / "web"
    pkg = json.loads((web / "package.json").read_text())
    ver = pkg.get("dependencies", {}).get("echarts", "")
    import re as _re
    if not _re.fullmatch(r"\d+\.\d+\.\d+", ver):
        problems.append(f"package.json doesn't pin echarts to an exact version ({ver!r})")
    lock = json.loads((web / "package-lock.json").read_text())
    pk = lock.get("packages", {})
    if pk.get("node_modules/echarts", {}).get("version") != ver or not pk.get("node_modules/echarts", {}).get("integrity"):
        problems.append("package-lock.json doesn't pin echarts (version and integrity)")
    if not pk.get("node_modules/zrender", {}).get("integrity"):
        problems.append("package-lock.json doesn't pin zrender (ECharts' renderer)")
    src = next((f for f in (web / "widgets" / "chart.ts", web / "widgets" / "chart.js") if f.exists()), None)
    if src is None:
        return False, "; ".join(problems + ["no examples/widgets/web/widgets/chart.ts or chart.js"])
    code = src.read_text()
    if "from 'echarts/core'" not in code or not ("SVGRenderer" in code or "CanvasRenderer" in code) or _re.search(r"from 'echarts'", code):
        problems.append("the chart widget doesn't import ECharts tree-shaken (echarts/core + a renderer)")
    if "mx-chart" not in code or "emit(" not in code:
        problems.append("the chart widget doesn't define mx-chart and emit its clicks")
    app = (ROOT / "examples/widgets/app.mojo").read_text()
    placed = app[app.index('WebComponent("mx-chart"'):][:400] if 'WebComponent("mx-chart"' in app else ""
    fed = "self.history" in placed or ("self.series()" in placed and "self.history" in app[app.find("def series("):][:500])
    if '"chart.js"' not in app or not placed or not fed:
        problems.append("examples/widgets/app.mojo doesn't place mx-chart fed from the word-count series (self.history)")
    changed, where = m1_hosts_unchanged()
    problems += changed
    for host in ("web", "linux"):
        b = run(["scripts/build.sh", "widgets", host])
        if b.returncode != 0:
            return False, "; ".join(problems + [f"widgets doesn't build for {host}: " + (b.stdout + b.stderr)[-600:]])
    manifest = json.loads((BUILD / "widgets/web/assets/manifest.json").read_text())
    ch = manifest.get("chart.js", {})
    if not ch.get("source", "").startswith("widgets/chart."):
        problems.append(f"the build has no chart.js bundled from widgets/chart.* ({ch})")
    else:
        body = (BUILD / "widgets/web/assets" / ch["file"]).read_text()
        if _re.search(r"\beval\s*\(|new\s+Function\s*\(|\bFunction\s*\(\s*['\"]", body):
            problems.append("the chart bundle contains eval or new Function (the CSP forbids them)")
        if "\n  " in body[:3000]:
            problems.append("the chart bundle isn't minified")
        gtk = BUILD / "widgets/linux/webview/assets" / ch["file"]
        if not gtk.exists() or gtk.read_bytes() != (BUILD / "widgets/web/assets" / ch["file"]).read_bytes():
            problems.append("GTK's web views don't get the same chart bundle byte for byte")
    # web: Mojo feeds the series (Load sample twice, then typing), a real click on point 1 reaches update()
    import drive
    OUT.mkdir(parents=True, exist_ok=True)
    picked = {}

    def during(page):
        drive.settle(page)
        x, y = page.evaluate("() => " + CHART_POINT)
        page.mouse.move(x, y)
        page.mouse.click(x, y)
        drive.settle(page)
        picked["svg"] = page.evaluate("() => document.querySelectorAll('mx-chart svg path').length")
        return ""

    r, out = drive.web_run(BUILD / "widgets" / "web", "tap:Load sample;tap:Load sample;keys:mx-editor .cm-content= more", shot=str(OUT / "m1-chart-web.png"),
                           viewport=(1280, 860), color_scheme="light", during=during)
    if r.returncode != 0:
        problems.append("web run failed: " + out[-500:])
    labels = [l[len("LABEL: "):] for l in out.splitlines() if l.startswith("LABEL: ")]
    widgets = {l[len("WIDGET: "):].split(": ", 1)[0]: l.split(": ", 2)[2] if l.count(": ") >= 2 else "" for l in out.splitlines() if l.startswith("WIDGET: ")}
    series = m1_series(widgets.get("mx-chart#1"))
    edits = next((l for l in labels if " edits" in l), "")
    if not series or series[:2] != [9, 9] or series[-1] != 10:
        problems.append(f"web: the chart's series isn't Mojo's word counts (9, 9, …, 10): {widgets.get('mx-chart#1')!r}")
    elif f"{len(series)} edits" not in edits:
        problems.append(f"web: the chart has {len(series)} points but Mojo counts {edits!r}")
    if "Picked: edit 2, 9 words" not in labels:
        problems.append(f"web: a click on point 2 didn't reach update() ({[l for l in labels if 'Picked' in l]})")
    if picked.get("svg", 0) < 3:
        problems.append(f"web: the chart drew {picked.get('svg')} SVG paths")
    csp = [l for l in out.splitlines() if l.startswith("CSP: ")]
    if not csp or not csp[-1].startswith("CSP: 0 violations"):
        problems.append(f"web: CSP {csp[-1:] or 'not read'}")
    if "CONSOLE ERRORS: " in out or "PAGE ERRORS: " in out:
        problems.append("web: console errors " + " ".join(l for l in out.splitlines() if "ERRORS: " in l)[:300])
    # GTK: the same bundle in a WebKitGTK view, the same click, the host's own count of CSP violations
    steps = ";".join(["tap:Load sample", "tap:Load sample", GTK_CLICK])
    shot = OUT / "m1-chart-gtk.png"
    shot.unlink(missing_ok=True)
    r = run([str(BUILD / "widgets" / "linux" / "widgets")], env={"MOJOUI_TEST": steps, "MOJOUI_WINDOW": "1280x860", "MOJOUI_SHOT": str(shot)}, timeout=300)
    o = r.stdout + r.stderr
    glabels = [l[len("LABEL: "):] for l in o.splitlines() if l.startswith("LABEL: ")]
    gw = g34.widget_lines(o)
    gv = g34.webviews(o).get("mx-chart#1", {})
    if m1_series(gw.get("mx-chart#1"))[:2] != [9, 9] if m1_series(gw.get("mx-chart#1")) else True:
        problems.append(f"gtk: the chart's series isn't Mojo's (9, 9): {gw.get('mx-chart#1')!r}")
    if "Picked: edit 2, 9 words" not in glabels:
        problems.append(f"gtk: a click on point 2 didn't reach update() ({[l for l in glabels if 'Picked' in l]}; {[l for l in o.splitlines() if l.startswith('JS: ')]})")
    if gv.get("state") != "ready" or gv.get("csp", -1) != 0 or gv.get("refused", -1) != 0:
        problems.append(f"gtk: the chart's view {gv} (wants ready, csp=0, refused=0)")
    if not shot.exists():
        problems.append("gtk: no screenshot (" + " | ".join(l for l in o.splitlines() if l.startswith("SHOT")) + ")")
    return not problems, "; ".join(problems) or (f"ECharts {ver} from npm (lockfile, npm ci --ignore-scripts), tree-shaken (echarts/core, SVG renderer), "
                                                 f"no eval/new Function; fed Mojo's word counts {series}; a click on point 2 reaches update() on "
                                                 f"the web (real mouse) and GTK; no host file changed ({where}); 0 CSP violations on both; "
                                                 f"shots {OUT.relative_to(ROOT)}/m1-chart-web.png, m1-chart-gtk.png")


# ---- M1b: widgets as first-class citizens: the Look's tokens live, Tab order across native and widgets, matrix, gallery ----
# What each widget shows of the theme, read from its page (the same expression on the web and in GTK's views; no ";")
THEME_PROBE = ("((t, e, x, w) => ((cs) => [t, e ? getComputedStyle(e).backgroundColor : null, e ? getComputedStyle(e).color : null,"
               " x ? x.getAttribute('fill') : null, cs ? cs.getPropertyValue('--o-radius-card').trim() : '', cs ? cs.getPropertyValue('--o-font').trim() : '',"
               " window.mojoui.mounts || {}])(w ? getComputedStyle(w) : null))(window.mojoui.tokens || null, document.querySelector('mx-editor .cm-editor'),"
               " document.querySelector('mx-chart svg text'), document.querySelector('[data-kind=webcomponent]'))")
TAB_STOPS = ["button:Load sample", "mx-counter#1", "button:Bigger steps", "button:Ask the counter", "button:Show details", "mx-chart#1"]


def rgb(color):
    """'#rrggbb', 'rgb(r, g, b)' or 'rgba(…)' as (r, g, b); None if neither."""
    import re as _re
    c = (color or "").strip().lower()
    m = _re.fullmatch(r"#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})", c)
    if m:
        return tuple(int(g, 16) for g in m.groups())
    m = _re.match(r"rgba?\((\d+),\s*(\d+),\s*(\d+)", c)
    return tuple(int(g) for g in m.groups()) if m else None


def theme_problems(where, got, dark, mounts_by_tag=None):
    """A THEME_PROBE answer (from the editor's page and the chart's page, or the one web page) against the tokens it carries."""
    problems = []
    t = got.get("tokens")
    if not isinstance(t, dict):
        return [f"{where}: the widgets got no tokens ({str(got)[:200]})"]
    for key in ("palette", "font", "corners", "dark"):
        if key not in t:
            problems.append(f"{where}: the tokens have no {key} ({sorted(t)})")
    if problems:
        return problems
    pal = t["palette"]
    if t["dark"] is not dark:
        problems.append(f"{where}: tokens say dark={t['dark']}, the app is {'dark' if dark else 'light'}")
    if rgb(got.get("editor_bg")) != rgb(pal.get("card")) or rgb(got.get("editor_ink")) != rgb(pal.get("ink")):
        problems.append(f"{where}: CodeMirror shows {got.get('editor_bg')} on {got.get('editor_ink')}, the tokens' card {pal.get('card')} and ink {pal.get('ink')}")
    if rgb(got.get("chart_ink")) != rgb(pal.get("ink2")):
        problems.append(f"{where}: ECharts' labels are {got.get('chart_ink')}, the tokens' ink2 is {pal.get('ink2')}")
    if not got.get("radius") or not got.get("font"):
        problems.append(f"{where}: the widget's CSS variables lack --o-radius-card / --o-font ({got.get('radius')!r}, {got.get('font')!r})")
    for tag, n in (mounts_by_tag or {}).items():
        if n != 1:
            problems.append(f"{where}: {tag} mounted {n} times (a live switch must not remount)")
    return problems


def web_probe(page):
    v = page.evaluate("() => " + THEME_PROBE)
    return {"tokens": v[0], "editor_bg": v[1], "editor_ink": v[2], "chart_ink": v[3], "radius": v[4], "font": v[5], "mounts": v[6]}


def focus_label_web(page):
    return page.evaluate("""() => { const a = document.activeElement; if (!a) return 'none';
      const w = a.closest('[data-kind=webcomponent]'); if (w) return w.dataset.widget + '#' + w.dataset.widgetId;
      if (a.matches('button')) return 'button:' + a.textContent.trim(); return (a.dataset && a.dataset.kind) || a.tagName.toLowerCase(); }""")


def m1b_web():
    import drive
    problems, light, dark = [], {}, {}
    order = {}

    def during(page):
        light.update(web_probe(page))
        page.screenshot(path=str(OUT / "m1b-web-light.png"), full_page=True)
        # Tab order: from inside the editor, forward through native controls and widgets, then back
        page.click("mx-editor .cm-content")
        fwd, back = [], []
        for _ in TAB_STOPS:
            page.keyboard.press("Tab")
            page.wait_for_timeout(60)
            fwd.append(focus_label_web(page))
        for _ in TAB_STOPS:
            page.keyboard.press("Shift+Tab")
            page.wait_for_timeout(60)
            back.append(focus_label_web(page))
        order["fwd"], order["back"] = fwd, back
        page.keyboard.press("Escape")
        # light → dark live: the system's scheme changes; the app, its theme and its widgets follow without a reload
        page.emulate_media(color_scheme="dark")
        page.wait_for_timeout(400)
        drive.settle(page)
        page.wait_for_timeout(500)
        dark.update(web_probe(page))
        return ""

    r, out = drive.web_run(BUILD / "widgets" / "web", "tap:Load sample;tap:Load sample", shot=str(OUT / "m1b-web-dark.png"), viewport=(1280, 860),
                           color_scheme="light", during=during)
    if r.returncode != 0:
        problems.append("web run failed: " + out[-400:])
    problems += theme_problems("web light", light, False)
    problems += theme_problems("web dark", dark, True, {k: v for k, v in (dark.get("mounts") or {}).items()})
    if light.get("tokens") and dark.get("tokens") and light["tokens"]["palette"].get("card") == dark["tokens"]["palette"].get("card"):
        problems.append("web: light and dark tokens have the same card colour")
    if order.get("fwd") != TAB_STOPS:
        problems.append(f"web: Tab from the editor goes {order.get('fwd')}, not {TAB_STOPS}")
    want_back = list(reversed(TAB_STOPS[:-1])) + ["mx-editor#1"]
    if order.get("back") != want_back:
        problems.append(f"web: Shift+Tab back goes {order.get('back')}, not {want_back}")
    csp = [l for l in out.splitlines() if l.startswith("CSP: ")]
    if not csp or not csp[-1].startswith("CSP: 0 violations"):
        problems.append(f"web: CSP {csp[-1:] or 'not read'}")
    return problems, order


def gtk_probe(out_lines, k):
    """The k-th pair of webjs probes (editor's page, then chart's page) from a GTK test run's JS: lines."""
    vals = [json.loads(l[len("JS: "):]) for l in out_lines if l.startswith("JS: ")]
    if len(vals) < 2 * k + 2:
        return {}
    ed, ch = vals[2 * k], vals[2 * k + 1]
    if not isinstance(ed, list) or not isinstance(ch, list):
        return {"tokens": None, "raw": [ed, ch]}
    return {"tokens": ed[0], "editor_bg": ed[1], "editor_ink": ed[2], "chart_ink": ch[3], "radius": ed[4], "font": ch[5],
            "chart_tokens": ch[0]}


def m1b_gtk():
    problems = []
    exe = str(BUILD / "widgets" / "linux" / "widgets")
    probes = f"webjs:mx-editor#1={THEME_PROBE};webjs:mx-chart#1={THEME_PROBE}"
    steps = ";".join(["tap:Load sample", "tap:Load sample", "scheme:light", probes, "scheme:dark", probes])
    shot = OUT / "m1b-gtk-dark.png"
    shot.unlink(missing_ok=True)
    r = run([exe], env={"MOJOUI_TEST": steps, "MOJOUI_WINDOW": "1280x860", "MOJOUI_SHOT": str(shot)}, timeout=300)
    o = (r.stdout + r.stderr).splitlines()
    light, dark = gtk_probe(o, 0), gtk_probe(o, 1)
    problems += theme_problems("gtk light", light, False)
    problems += theme_problems("gtk dark", dark, True)
    if light.get("chart_tokens") != light.get("tokens") or dark.get("chart_tokens") != dark.get("tokens"):
        problems.append("gtk: the editor's and the chart's views got different tokens")
    v = g34.webviews("\n".join(o))
    for key in ("mx-editor#1", "mx-chart#1", "mx-counter#1"):
        if v.get(key, {}).get("mounts") != 1 or v.get(key, {}).get("csp", -1) != 0:
            problems.append(f"gtk: {key}'s view after the switch: {v.get(key)} (one mount, no CSP violation)")
    if not shot.exists():
        problems.append("gtk: no dark screenshot")
    lshot = OUT / "m1b-gtk-light.png"
    lshot.unlink(missing_ok=True)
    run([exe], env={"MOJOUI_TEST": "tap:Load sample;tap:Load sample;scheme:light", "MOJOUI_WINDOW": "1280x860", "MOJOUI_SHOT": str(lshot)}, timeout=300)
    if not lshot.exists():
        problems.append("gtk: no light screenshot")
    # Tab order with real keys (XTest on the headless display): from inside the editor, forward, then back
    first = g34.gtk_live("wait:1500;report")
    box = g33.boxes(first).get("editor")
    if not box:
        return problems + [f"gtk: no box for the editor ({first[-300:]})"], {}
    keys = [f"click:{g34.center(box, 30)}", "wait:400"]
    for _ in TAB_STOPS:
        keys += ["key:Tab", "wait:350", "report"]
    for _ in TAB_STOPS:
        keys += ["key:Shift+Tab", "wait:350", "report"]
    out = g34.gtk_live(";".join(keys))
    focus = [next((l[len("FOCUS: "):] for l in part.splitlines() if l.startswith("FOCUS: ")), "none") for part in g34.reports(out)]
    order = {"fwd": focus[:len(TAB_STOPS)], "back": focus[len(TAB_STOPS):]}
    if order["fwd"] != TAB_STOPS:
        problems.append(f"gtk: Tab from the editor goes {order['fwd']}, not {TAB_STOPS}")
    want_back = list(reversed(TAB_STOPS[:-1])) + ["mx-editor#1"]
    if order["back"] != want_back:
        problems.append(f"gtk: Shift+Tab back goes {order['back']}, not {want_back}")
    return problems, order


def m1b():
    """First-class citizens (GOAL.md M1b): widgets wear the theme (the host hands every widget the Look's tokens: palette,
    fonts, corners, light or dark, as CSS variables and a theme(el, tokens) call; CodeMirror and ECharts follow omxqua and
    switch light/dark live with the app, pictures on the web and GTK in both); keyboard focus moves between native
    controls and widgets with Tab and Shift+Tab, in order, both ways; widgets in docs/components.md and the gallery."""
    problems = []
    js = (ROOT / "mojoui/hosts/static/mojoui-widgets.js").read_text()
    if "spec.theme(" not in js or "tokens" not in js:
        problems.append("mojoui-widgets.js doesn't call a widget's theme(el, tokens)")
    if "theme?(" not in (ROOT / "mojoui/hosts/static/mojoui-widgets.d.ts").read_text():
        problems.append("mojoui-widgets.d.ts doesn't type theme(el, tokens)")
    for f, lib in (("editor.ts", "CodeMirror"), ("chart.ts", "ECharts")):
        if "theme(el" not in (ROOT / "examples/widgets/web/widgets" / f).read_text():
            problems.append(f"{lib}'s widget ({f}) has no theme(el, tokens)")
    err = g34.mojo_test("theme_tokens", "theme_tokens: ok")
    if err:
        problems.append(err)
    for host in ("web", "linux"):
        b = run(["scripts/build.sh", "widgets", host])
        if b.returncode != 0:
            return False, "; ".join(problems + [f"widgets doesn't build for {host}: " + (b.stdout + b.stderr)[-600:]])
    p, web_order = m1b_web()
    problems += p
    p, gtk_order = m1b_gtk()
    problems += p
    # the matrix and the gallery
    c = run([sys.executable, "scripts/components.py", "--check"])
    if c.returncode != 0:
        problems.append("docs/components.md is stale: " + (c.stdout + c.stderr)[-200:])
    mat = (ROOT / "docs/components.md").read_text()
    for tag, lib in (("mx-editor", "CodeMirror"), ("mx-chart", "ECharts"), ("mx-counter", "")):
        row = next((l for l in mat.splitlines() if l.startswith("|") and f"`{tag}`" in l), "")
        if not row or (lib and lib not in row) or "✅" not in row:
            problems.append(f"docs/components.md has no JS widget row for {tag} ({row[:120]!r})")
    gal = (ROOT / "docs/gallery/index.html").read_text()
    for img in ("widgets-web-light.png", "widgets-web-dark.png", "widgets-gtk-light.png", "widgets-gtk-dark.png"):
        if img not in gal or not (ROOT / "docs/gallery/img" / img).exists():
            problems.append(f"the gallery doesn't show {img}")
    if "CodeMirror" not in gal or "ECharts" not in gal:
        problems.append("the gallery's widgets section doesn't name CodeMirror and ECharts")
    return not problems, "; ".join(problems[:14]) or (
        "the host hands every widget the Look's tokens (palette, fonts, corners, dark) as CSS variables and theme(el, tokens); "
        "CodeMirror and ECharts match them in light and dark, switched live (one mount) on the web and GTK; Tab/Shift+Tab "
        f"cross native controls and widgets in order both ways on the web and GTK ({' → '.join(TAB_STOPS)}); widgets in "
        f"docs/components.md and the gallery; shots {OUT.relative_to(ROOT)}/m1b-*.png")


M0_SAMPLES = []


def m0():
    """Agents see JS widgets (GOAL.md M0): describe(el) -> {text, value, …} and declared settable fields in defineWidget;
    the agent host lists every WebComponent as tools (read: what it describes; set: a typed argument, through a command to
    the widget, its change reaching update() as the widget's own event); a widget without describe is listed by tag with
    "no description"; JSON only, declared fields only; proven through the agent client against the widgets app attached to
    the web host and to the GTK host."""
    problems = []
    js = (ROOT / "mojoui/hosts/static/mojoui-widgets.js").read_text()
    for need in ("fields", "mojoui.set", "no description"):
        if need not in js:
            problems.append(f"mojoui-widgets.js has no {need!r}")
    dts = (ROOT / "mojoui/hosts/static/mojoui-widgets.d.ts").read_text()
    if "fields" not in dts or "describe" not in dts:
        problems.append("mojoui-widgets.d.ts doesn't type describe and fields")
    t = run([sys.executable, "tests/test_agent_widgets.py"], timeout=300)
    if t.returncode != 0 or "agent_widgets: ok" not in t.stdout:
        problems.append("tests/test_agent_widgets.py: " + (t.stdout + t.stderr)[-500:])
    for host in ("web", "linux"):
        b = run(["scripts/build.sh", "widgets", host])
        if b.returncode != 0:
            return False, "; ".join(problems + [f"widgets doesn't build for {host}: " + (b.stdout + b.stderr)[-600:]])
    err = g34.mojo_test("webcomponent", "webcomponent: ok")  # (Runtime.set_widget: declared-looking names, JSON values only)
    if err:
        problems.append(err)
    p, web_samples = m0_web()
    problems += p
    p, gtk_samples = m0_gtk()
    problems += p
    problems += m0_no_describe()
    M0_SAMPLES[:] = web_samples + gtk_samples
    for line in M0_SAMPLES:
        print("AGENT: " + line.replace("\n", "\\n"), flush=True)
    return not problems, "; ".join(problems) or ("the agent host lists each WebComponent as <name>-read/<name>-set tools (typed fields only), "
                                                 "reads describe() JSON and sets through the widget's own event on the web and GTK; "
                                                 "undeclared or mistyped sets refused by both the agent host and the page; a widget "
                                                 f"without describe reads \"no description\"; shot {OUT.relative_to(ROOT)}/m0-agent-web.png")


def todo(what):
    def fn():
        return False, f"not built yet: {what}"
    return fn


def m3():
    """Nothing regressed (minimal, owner): goal 34's M0–M3, goal 33's M1 and M4."""
    problems = []
    for label, fn in [("34-M0", g34.m0), ("34-M1", g34.m1), ("34-M2", g34.m2), ("34-M3", g34.m3), ("33-M1", g33.m1), ("33-M4", g33.m4)]:
        ok, msg = fn()
        if not ok:
            problems.append(f"{label}: {msg}")
    return not problems, "; ".join(problems) or "goal 34's M0–M3 and goal 33's M1, M4 pass"


MILESTONES = [
    ("M0", m0),
    ("M1", m1),
    ("M1b", m1b),
    ("M2", todo("WKWebView on the Mac via mac-ci (GOAL.md M2)")),
    ("M3", m3),
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
