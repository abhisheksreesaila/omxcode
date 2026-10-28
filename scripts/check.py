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


def raw_lines(path, chunks, want):
    """Raw bytes to the host's agent link, sent in pieces (a pause between them): its first `want` answer lines."""
    with _socket.socket(_socket.AF_UNIX) as s:
        s.settimeout(10)
        s.connect(str(path))
        for chunk in chunks:
            s.sendall(chunk)
            time.sleep(0.3)
        buf = b""
        while buf.count(b"\n") < want:
            got = s.recv(65536)
            if not got:
                break
            buf += got
    return [json.loads(l) for l in buf.split(b"\n")[:want]]


def link_bytes_problems(path, where):
    """(D-677) A UTF-8 character split across two reads is read whole; a line that isn't UTF-8 is refused as one line
    (the link answers it and the next), never a crash."""
    problems = []
    whole = '{"op":"view","note":"café"}\n'.encode()
    cut = whole.index(0xC3) + 1
    bad = b'{"op":"view","note":"\xff\xfe"}\n'
    try:
        a, b, c = raw_lines(path, [whole[:cut], whole[cut:] + bad, b'{"op":"view"}\n'], 3)
    except (OSError, ValueError) as e:
        return [f"{where}: the agent link broke on split or invalid UTF-8 ({e})"]
    if not a.get("ok"):
        problems.append(f"{where}: a request with a character split across reads was refused ({str(a)[:160]})")
    if b.get("ok") or "UTF-8" not in str(b.get("error", "")):
        problems.append(f"{where}: a line that isn't UTF-8 wasn't refused as such ({str(b)[:160]})")
    if not c.get("ok"):
        problems.append(f"{where}: the line after an invalid one wasn't answered ({str(c)[:160]})")
    return problems


def socket_mode_problems(path, where):
    """(D-677) The agent link's socket file is the user's alone: mode 0600."""
    import stat
    mode = stat.S_IMODE(os.stat(path).st_mode)
    return [] if mode == 0o600 else [f"{where}: the agent socket's mode is {oct(mode)}, not 0o600"]


def listening_unix_paths(pid):
    """Unix sockets with a path that process `pid` listens on (/proc: its descriptors' inodes against /proc/net/unix)."""
    inodes = set()
    for fd in Path(f"/proc/{pid}/fd").iterdir():
        try:
            t = os.readlink(fd)
        except OSError:
            continue
        if t.startswith("socket:["):
            inodes.add(t[8:-1])
    out = []
    for line in Path("/proc/net/unix").read_text().splitlines()[1:]:
        f = line.split()
        if len(f) >= 8 and f[6] in inodes and int(f[3], 16) & 0x10000 and not f[7].startswith("@"):  # (__SO_ACCEPTCON, a path)
            out.append(f[7])
    return out


def no_socket_unset(cmd, where, env=None, ready=None, seconds=8):
    """(D-677) With MOJOUI_AGENT_SOCKET unset the host opens no agent link: no listening Unix socket with a path."""
    e = {k: v for k, v in os.environ.items() if k != "MOJOUI_AGENT_SOCKET"}
    e.update(env or {})
    proc = subprocess.Popen(cmd, cwd=ROOT, env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        time.sleep(seconds)
        if proc.poll() is not None:
            return [f"{where}: the host ended before it could be looked at: {proc.stdout.read()[-300:]}"]
        paths = []
        for pid in [proc.pid] + [int(c) for c in Path(f"/proc/{proc.pid}/task/{proc.pid}/children").read_text().split()]:
            paths += listening_unix_paths(pid)
        return [f"{where}: with MOJOUI_AGENT_SOCKET unset the host listens on {paths}"] if paths else []
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


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
        problems += socket_mode_problems(sock, "web")
        problems += link_bytes_problems(sock, "web")
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
        problems += socket_mode_problems(sock, "gtk")
        problems += link_bytes_problems(sock, "gtk")
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


def gtk_shots_reliable(n=10):
    """The GTK host's screenshot never skips (D-649): the widgets app shot n times in a row (the M1 steps: its web views
    resize as the chart fills), every run writes its picture. Problems, and how many runs had to wait for a frame."""
    problems, waited = [], 0
    for k in range(n):
        shot = OUT / f"m1-repeat-{k}.png"
        shot.unlink(missing_ok=True)
        r = run([str(BUILD / "widgets" / "linux" / "widgets")], env={"MOJOUI_TEST": "tap:Load sample;tap:Load sample", "MOJOUI_WINDOW": "1280x860",
                                                                     "MOJOUI_SHOT": str(shot)}, timeout=300)
        lines = [l for l in (r.stdout + r.stderr).splitlines() if l.startswith("SHOT")]
        waited += any("waited" in l for l in lines)
        if not shot.exists() or shot.stat().st_size < 10000:
            problems.append(f"gtk shot {k + 1}/{n} missing ({' | '.join(lines)})")
        shot.unlink(missing_ok=True)
    return problems, waited


def m1():
    """A second library, no host changes (GOAL.md M1): Apache ECharts from npm (pinned, lockfile) as a chart widget in
    examples/widgets, fed from Mojo (the word-count series as data), its click on a point reaching update(); no file in
    mojoui/hosts changed (diffed against the commit where M0 passed); the same CSP with zero violations; web and GTK."""
    problems = []
    # (since D-675 the chart is a shared widget: mojoui/widgets/ with its own package.json and lockfile, which the
    # widgets app picks in web/shared.json; the same pins and code are required there)
    web = ROOT / "mojoui" / "widgets"
    try:
        picks = json.loads((ROOT / "examples/widgets/web/shared.json").read_text()).get("widgets", [])
    except (OSError, ValueError):
        picks = []
    if "chart" not in picks:
        problems.append("examples/widgets/web/shared.json doesn't pick the shared chart widget")
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
    src = next((f for f in (web / "chart.ts", web / "chart.js") if f.exists()), None)
    if src is None:
        return False, "; ".join(problems + ["no mojoui/widgets/chart.ts or chart.js"])
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
    if not ch.get("source", "").startswith("mojoui/widgets/chart."):
        problems.append(f"the build has no chart.js bundled from mojoui/widgets/chart.* (the shared widget, D-675) ({ch})")
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
    p, waited = gtk_shots_reliable()
    problems += p
    return not problems, "; ".join(problems) or (f"ECharts {ver} from npm (lockfile, npm ci --ignore-scripts), tree-shaken (echarts/core, SVG renderer), "
                                                 f"no eval/new Function; fed Mojo's word counts {series}; a click on point 2 reaches update() on "
                                                 f"the web (real mouse) and GTK; no host file changed ({where}); 0 CSP violations on both; "
                                                 f"10 more GTK shots all written ({waited} waited for a frame); shots {OUT.relative_to(ROOT)}/m1-chart-web.png, m1-chart-gtk.png")


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


SPARK_JS = "() => (e => e ? (r => [r.left + scrollX, r.top + scrollY, r.width, r.height])(e.getBoundingClientRect()) : null)(document.querySelector('[data-tag=sparkline]'))"


def spark_problems(where, shot, box, dark, width=1280):
    """mojoui's own drawn view (the sparkline under the note, a Canvas) in a picture: it must wear the mode the app is in
    (its median tone dark in dark mode, light in light), drawn again on a live switch even though its version didn't
    move (D-673)."""
    from PIL import Image
    if not box or not Path(shot).exists():
        return [f"{where}: no sparkline box ({box}) or picture ({shot})"]
    im = Image.open(shot).convert("RGB")
    sx = im.width / float(width)
    x, y, w, h = (int(round(v * sx)) for v in box)
    crop = im.crop((x + 3, y + 3, x + w - 3, y + h - 3))
    px = crop.tobytes()
    tones = sorted((px[i] + px[i + 1] + px[i + 2]) // 3 for i in range(0, len(px), 3))
    if not tones:
        return [f"{where}: the sparkline's box is empty ({box})"]
    median = tones[len(tones) // 2]
    if dark and median > 90:
        return [f"{where}: the sparkline stayed light in dark mode (median tone {median} of 255): a drawn view didn't redraw on the switch"]
    if not dark and median < 170:
        return [f"{where}: the sparkline is dark in light mode (median tone {median} of 255)"]
    return []


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
    boxes = {}

    def during(page):
        light.update(web_probe(page))
        boxes["light"] = page.evaluate(SPARK_JS)
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
        page.wait_for_timeout(600)  # (the canvas's next frame, if its theme moved on)
        boxes["dark"] = page.evaluate(SPARK_JS)
        return ""

    r, out = drive.web_run(BUILD / "widgets" / "web", "tap:Load sample;tap:Load sample", shot=str(OUT / "m1b-web-dark.png"), viewport=(1280, 860),
                           color_scheme="light", during=during)
    if r.returncode != 0:
        problems.append("web run failed: " + out[-400:])
    problems += theme_problems("web light", light, False)
    problems += theme_problems("web dark", dark, True, {k: v for k, v in (dark.get("mounts") or {}).items()})
    problems += spark_problems("web light", OUT / "m1b-web-light.png", boxes.get("light"), False)
    problems += spark_problems("web dark", OUT / "m1b-web-dark.png", boxes.get("dark"), True)
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
    else:  # (light first, then the live switch: the sparkline drawn in light must be drawn again in dark)
        problems += spark_problems("gtk dark", shot, g33.boxes("\n".join(o)).get("sparkline"), True)
    lshot = OUT / "m1b-gtk-light.png"
    lshot.unlink(missing_ok=True)
    rl = run([exe], env={"MOJOUI_TEST": "tap:Load sample;tap:Load sample;scheme:light", "MOJOUI_WINDOW": "1280x860", "MOJOUI_SHOT": str(lshot)}, timeout=300)
    if not lshot.exists():
        problems.append("gtk: no light screenshot")
    else:
        problems += spark_problems("gtk light", lshot, g33.boxes(rl.stdout + rl.stderr).get("sparkline"), False)
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
        if "theme(el" not in (ROOT / "mojoui/widgets" / f).read_text():
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
        "CodeMirror and ECharts match them in light and dark, switched live (one mount) on the web and GTK, and mojoui's own "
        "drawn sparkline is drawn again in the new mode (dark in dark, light in light); Tab/Shift+Tab "
        f"cross native controls and widgets in order both ways on the web and GTK ({' → '.join(TAB_STOPS)}); widgets in "
        f"docs/components.md and the gallery; shots {OUT.relative_to(ROOT)}/m1b-*.png")


# ---- M1c: the developer loop (scripts/dev.sh: watch, rebuild, reload keeping Mojo's state; source-mapped JS errors; inspector in debug builds) ----
DEV_APP = "zz_dev_widgets"  # a scratch copy of examples/widgets the proof edits (removed after)
THROW_LINE = "      if (el.count >= 2) throw new Error('boom from the counter');  // (M1c's proof: a widget's error, by file and line)"


def free_port():
    with _socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def dev_copy():
    d = ROOT / "examples" / DEV_APP
    shutil.rmtree(d, ignore_errors=True)
    shutil.rmtree(BUILD / DEV_APP, ignore_errors=True)
    shutil.copytree(ROOT / "examples" / "widgets", d, ignore=shutil.ignore_patterns("node_modules"))
    # the shared editor as the copy's own (its .ts the proof edits, with the shared packages beside it): the scratch
    # app edits its own files, never mojoui/widgets/ (D-675)
    for f in ("editor.ts", "editor.css"):
        (d / "web/widgets" / f).write_text((ROOT / "mojoui/widgets" / f).read_text().replace("../hosts/static/", "../../../../mojoui/hosts/static/"))
    for f in ("package.json", "package-lock.json"):
        shutil.copy(ROOT / "mojoui/widgets" / f, d / "web" / f)
    shared = json.loads((d / "web/shared.json").read_text())
    shared["widgets"] = [w for w in shared["widgets"] if w != "editor"]
    (d / "web/shared.json").write_text(json.dumps(shared) + "\n")
    return d


def add_throw(counter_js):
    """Puts THROW_LINE as the first line of the counter's click handler; returns its 1-based line number."""
    lines = counter_js.read_text().splitlines()
    at = next(i for i, l in enumerate(lines) if "inc.addEventListener('click'" in l) + 1
    lines.insert(at, THROW_LINE)
    counter_js.write_text("\n".join(lines) + "\n")
    return at + 1


def listen_addresses(port):
    """(D-678) The local addresses something listens on at TCP `port` (/proc/net/tcp and tcp6, state LISTEN): what the
    server really bound, not what a script says."""
    out = []
    for table in ("tcp", "tcp6"):
        for line in Path(f"/proc/net/{table}").read_text().splitlines()[1:]:
            f = line.split()
            addr, p = f[1].split(":")
            if f[3] == "0A" and int(p, 16) == port:
                if table == "tcp":
                    out.append(".".join(str(int(addr[i:i + 2], 16)) for i in (6, 4, 2, 0)))
                else:
                    out.append("v6:" + addr)
    return out


def dev_endpoint_problems(url, port):
    """(D-678) The running dev server: bound to 127.0.0.1 only; /dev/reload with a wrong token or none is refused."""
    import urllib.error
    import urllib.parse
    import urllib.request
    problems = []
    bound = listen_addresses(port)
    if bound != ["127.0.0.1"]:
        problems.append(f"the dev server listens on {bound}, not 127.0.0.1 alone")
    for token in ("wrong-token", ""):
        try:
            code = urllib.request.urlopen(urllib.request.Request(url + "dev/reload", data=urllib.parse.urlencode({"token": token}).encode()), timeout=10).status
        except urllib.error.HTTPError as e:
            code = e.code
        if code != 403:
            problems.append(f"/dev/reload with token {token!r} answered {code}, not 403")
    return problems


def m1c_web(d):
    """dev.sh on the scratch app: edits to a .js, a .css and a .ts reach the open page without a page load, Mojo's state
    and the typed note stay; the counter's thrown error reaches the server's log as widgets/counter.js:<line>."""
    from playwright.sync_api import sync_playwright
    import drive
    problems = []
    port = free_port()
    log = open(BUILD / f"{DEV_APP}-dev.log", "w+")
    dev = subprocess.Popen(["scripts/dev.sh", DEV_APP, "--port", str(port)], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                           start_new_session=True)  # (its own process group: stopping it stops its server, nothing else)
    url = f"http://127.0.0.1:{port}/"
    try:
        t0 = time.time()
        while time.time() - t0 < 600 and "dev: watching" not in open(log.name).read():
            if dev.poll() is not None:
                return [f"dev.sh ended: {open(log.name).read()[-600:]}"], ""
            time.sleep(0.5)
        if "dev: watching" not in open(log.name).read():
            return ["dev.sh never started watching"], ""
        problems += dev_endpoint_problems(url, port)
        t = run([sys.executable, "tests/test_web_dev.py", str(BUILD / DEV_APP / "web"), str(BUILD / "widgets" / "web")], timeout=600)
        if t.returncode != 0 or "web_dev: ok" not in t.stdout:  # (MOJOUI_DEV refused on a release build; /dev/* local only)
            problems.append("tests/test_web_dev.py: " + (t.stdout + t.stderr)[-500:])
        with sync_playwright() as pw:
            b = pw.chromium.launch(executable_path=drive.CHROMIUM, headless=True)
            page = b.new_page(viewport={"width": 1280, "height": 860}, color_scheme="light")
            console = []
            page.on("console", lambda m: console.append(m.text) if m.type == "error" else None)
            page.add_init_script(drive.CSP_PROBE)
            page.goto(url)
            drive.settle(page)
            csp_dev = page.evaluate("() => fetch('/').then(r => r.headers.get('Content-Security-Policy'))")
            page.evaluate("() => { window.mojouiKeep = 'same page' }")
            page.click("mx-editor .cm-content")
            page.keyboard.type("dev loop keeps this")
            drive.settle(page)
            # 1) .js: the counter's button says "plus N" and throws on its third click
            cj = d / "web/widgets/counter.js"
            cj.write_text(cj.read_text().replace("inc.textContent = `+${el.step}`;", "inc.textContent = `plus ${el.step}`;"))
            line = add_throw(cj)
            try:
                page.wait_for_function("() => (document.querySelector('mx-counter .inc') || {}).textContent === 'plus 1'", timeout=60000)
            except Exception:
                problems.append("web: saving counter.js didn't reach the open page in 60 s")
            # 2) .css: the counter's count gets letter spacing
            cc = d / "web/widgets/counter.css"
            cc.write_text(cc.read_text() + "\nmx-counter .count { letter-spacing: 3px; }\n")
            try:
                page.wait_for_function("() => getComputedStyle(document.querySelector('mx-counter .count')).letterSpacing === '3px'", timeout=60000)
            except Exception:
                problems.append("web: saving counter.css didn't restyle the open page")
            # 3) .ts: the editor's label changes; the editor remounts with the note Mojo kept
            et = d / "web/widgets/editor.ts"
            et.write_text(et.read_text().replace("'aria-label': 'Note'", "'aria-label': 'Note (dev)'"))
            try:
                page.wait_for_function("() => (document.querySelector('mx-editor .cm-content') || {getAttribute: () => ''}).getAttribute('aria-label') === 'Note (dev)'", timeout=60000)
            except Exception:
                problems.append("web: saving editor.ts didn't reach the open page")
            drive.settle(page)
            state = page.evaluate("""() => [window.mojouiKeep || 'reloaded', (document.querySelector('mx-editor .cm-content') || {}).textContent,
              [...document.querySelectorAll('[data-kind=label]')].map(e => e.textContent).filter(t => t.startsWith('Words:'))[0], window.mojoui.mounts]""")
            if state[0] != "same page":
                problems.append("web: the page itself reloaded (its window state is gone)")
            if state[1] != "dev loop keeps this" or state[2] != "Words: 4":
                problems.append(f"web: after the reloads the editor holds {state[1]!r}, Mojo says {state[2]!r} (the typed note must survive)")
            if (state[3] or {}).get("mx-counter", 0) < 2 or (state[3] or {}).get("mx-editor", 0) < 2:
                problems.append(f"web: the widgets weren't mounted again from their new bundles (mounts {state[3]})")
            for _ in range(3):
                page.click("mx-counter .inc")
            page.wait_for_timeout(1500)
            csp_seen = page.evaluate("() => window.mojouiCsp || []")
            b.close()
        logged = open(log.name).read()
        want = f"widgets/counter.js:{line}:"
        if not any(l.startswith("JS ERROR: ") and want in l and "boom from the counter" in l for l in logged.splitlines()):
            problems.append(f"web: the counter's error didn't reach the log as {want} ({[l for l in logged.splitlines() if 'JS ERROR' in l][-3:]})")
        if csp_seen:
            problems.append(f"web dev: CSP violations {csp_seen[:3]}")
        if "rebuilt" not in logged:
            problems.append("dev.sh didn't say it rebuilt")
        return problems, csp_dev
    finally:
        import signal
        try:
            os.killpg(dev.pid, signal.SIGTERM)  # (the group this proof started: dev.sh, pixi, dev.py, its web server)
            dev.wait(timeout=15)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(dev.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        log.close()


def m1c_release_web():
    """A release build (examples/widgets, as scripts/build.sh makes it) has no source maps and no dev endpoints."""
    import drive
    problems = []
    found = {}

    def during(page):
        found["csp"] = page.evaluate("() => fetch('/').then(r => r.headers.get('Content-Security-Policy'))")
        found["dev"] = page.evaluate("() => fetch('/dev/assets').then(r => r.status)")
        files = page.evaluate("() => [...document.scripts].map(s => s.src).filter(s => s.includes('/assets/'))")
        found["maps"] = [page.evaluate(f"() => fetch('{f}.map').then(r => r.status)") for f in files]
        found["urls"] = page.evaluate("() => Promise.all([...document.scripts].filter(s => s.src.includes('/assets/')).map(s => fetch(s.src).then(r => r.text()))).then(ts => ts.filter(t => t.includes('sourceMappingURL')).length)")
        return ""
    r, out = drive.web_run(BUILD / "widgets" / "web", "", viewport=(900, 600), during=during)
    if found.get("dev") != 404:
        problems.append(f"release web: /dev/assets answers {found.get('dev')}")
    if any(m != 404 for m in found.get("maps", [1])) or found.get("urls"):
        problems.append(f"release web: source maps served or named ({found.get('maps')}, {found.get('urls')} bundles name one)")
    if list((BUILD / "widgets/web/assets").glob("*.map")):
        problems.append("release web: the build has .map files")
    return problems, found.get("csp")


def m1c_gtk(d, line):
    """GTK: the debug build (MOJOUI_DEBUG=1) reports the counter's error as widgets/counter.js:<line> and opens WebKit's
    inspector for a widget's view; the release build (examples/widgets) can't."""
    problems = []
    b = run(["scripts/build.sh", DEV_APP, "linux"], env={"MOJOUI_DEBUG": "1"})
    if b.returncode != 0:
        return [f"the debug GTK build failed: {(b.stdout + b.stderr)[-500:]}"]
    click = "webjs:mx-counter#1=(b => (b.click(), b.click(), setTimeout(() => b.click(), 0), 'clicked'))(document.querySelector('.inc'))"
    r = run([str(BUILD / DEV_APP / "linux" / DEV_APP)], env={"MOJOUI_TEST": click + ";pause:1500;inspect:mx-counter#1;pause:500", "MOJOUI_WINDOW": "1280x860"}, timeout=300)
    o = r.stdout + r.stderr
    want = f"widgets/counter.js:{line}:"
    if not any(l.startswith("JS ERROR: ") and want in l and "boom from the counter" in l for l in o.splitlines()):
        problems.append(f"gtk debug: the counter's error didn't reach the log as {want} ({[l for l in o.splitlines() if 'JS ERROR' in l][-3:]})")
    if "INSPECTOR: shown mx-counter#1" not in o or "DEVTOOLS: on" not in o:
        problems.append(f"gtk debug: no inspector ({[l for l in o.splitlines() if l.startswith(('INSPECTOR', 'DEVTOOLS'))]})")
    r = run([str(BUILD / "widgets" / "linux" / "widgets")], env={"MOJOUI_TEST": "inspect:mx-counter#1", "MOJOUI_WINDOW": "1280x860"}, timeout=300)
    o = r.stdout + r.stderr
    if "INSPECTOR: unavailable" not in o or "DEVTOOLS: off" not in o:
        problems.append(f"gtk release: the inspector isn't refused ({[l for l in o.splitlines() if l.startswith(('INSPECTOR', 'DEVTOOLS'))]})")
    if list((BUILD / "widgets/linux/webview/assets").glob("*.map")):
        problems.append("gtk release: the build has .map files")
    return problems


def m1c_mac(d):
    """(D-679) The Mac's debug build compiles its inspector branch: MOJOUI_DEBUG=1 scripts/build.sh <app> mac names
    setInspectable: and ships source maps; the release build has neither. Built here (cross-compiled), run on GitHub's
    Macs only by M2 (release)."""
    problems = []
    for debug in (True, False):
        b = run(["scripts/build.sh", DEV_APP, "mac"], env={"MOJOUI_DEBUG": "1" if debug else ""})
        what = "debug" if debug else "release"
        if b.returncode != 0:
            return [f"the {what} Mac build failed: {(b.stdout + b.stderr)[-400:]}"]
        obj = (BUILD / DEV_APP / "mac" / "app.o").read_bytes()
        maps = list((BUILD / DEV_APP / "mac").glob("*.app/Contents/Resources/webview/assets/*.map"))
        if (b"setInspectable:" in obj) != debug or bool(maps) != debug:
            problems.append(f"mac {what}: setInspectable: {'named' if b'setInspectable:' in obj else 'absent'}, {len(maps)} source maps")
    return problems


def m1c():
    """The developer loop (GOAL.md M1c): scripts/dev.sh <app> watches the app's web/ sources: saving a .ts/.js/.css file
    rebuilds the bundle and the open page reloads its widgets while the Mojo app keeps its state (a typed note
    survives); a widget's thrown JS error reaches the app's log with its original file and line (source maps), on the web
    and GTK; debug builds can open WebKit's inspector for widget views on GTK (a marked hook for the Mac), release builds
    can't; docs/js.md walks the loop. Local only (127.0.0.1), out of release builds, the CSP unchanged."""
    problems = []
    if not (ROOT / "scripts/dev.sh").exists():
        return False, "no scripts/dev.sh"
    hook = (ROOT / "mojoui/hosts/devtools.mojo")
    if not hook.exists() or "Mac" not in hook.read_text() or "MOJOUI_DEBUG" not in hook.read_text():
        problems.append("no marked devtools hook for the Mac (mojoui/hosts/devtools.mojo)")
    doc = (ROOT / "docs/js.md").read_text()
    for topic in ("scripts/dev.sh", "source map", "inspector", "MOJOUI_DEBUG", "deployed host"):
        if topic not in doc:
            problems.append(f"docs/js.md doesn't walk {topic}")
    for host in ("web", "linux"):  # (the release builds the other milestones use)
        b = run(["scripts/build.sh", "widgets", host])
        if b.returncode != 0:
            return False, f"widgets doesn't build for {host}: " + (b.stdout + b.stderr)[-400:]
    d = dev_copy()
    try:
        p, csp_dev = m1c_web(d)
        problems += p
        line = next(i + 1 for i, l in enumerate((d / "web/widgets/counter.js").read_text().splitlines()) if "boom from the counter" in l)
        problems += m1c_gtk(d, line)
        problems += m1c_mac(d)
        problems += gtk_jslog_limit()
    finally:
        shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(BUILD / DEV_APP, ignore_errors=True)
    p, csp_rel = m1c_release_web()
    problems += p
    if not csp_dev or csp_dev != csp_rel:
        problems.append(f"the dev server's CSP differs from release ({csp_dev!r} vs {csp_rel!r})")
    return not problems, "; ".join(problems[:12]) or (
        "scripts/dev.sh rebuilt .js, .css and .ts edits into the open page (same page, the typed note and Words: 4 kept, widgets "
        "mounted again); the counter's error logged as widgets/counter.js:<line> on the web and GTK (source maps, dev only); "
        "GTK debug build opens WebKit's inspector, release refuses; the Mac's debug build names setInspectable: and maps, release "
        "neither; the dev server binds 127.0.0.1 alone, refuses a wrong token, a non-local client and a release build; release "
        "builds carry no maps or dev endpoints; CSP unchanged")


M0_SAMPLES = []


CRASH_STEPS = ("pause:2500;webjs:mx-counter#1=(mojoui.native.receive = () => true, 'deaf');tap:Ask the counter;pause:800;"
               "webkill:mx-counter#1;pause:1500;tap:Bigger steps;pause:500")


def gtk_lost_commands():
    """(D-680) GTK: a command the page never answered (its page made deaf, then its web process killed) is answered with
    an error once the process ends: update() hears it ("Counter replied: error: …"), the runtime's waiting entry ends."""
    r = run([str(BUILD / "widgets" / "linux" / "widgets")], env={"MOJOUI_TEST": CRASH_STEPS, "MOJOUI_WINDOW": "1280x860"}, timeout=300)
    o = r.stdout + r.stderr
    if '"deaf"' not in o:
        return [f"gtk crash: the page wasn't made deaf ({[l for l in o.splitlines() if l.startswith('JS:')][-2:]})"]
    if "1 command(s) answered with an error" not in o or "Counter replied: error: the widget's web process ended" not in o:
        return [f"gtk crash: the lost command wasn't answered ({[l for l in o.splitlines() if 'web process' in l or 'replied' in l][-3:]})"]
    return []


FLOOD = ("webjs:mx-counter#1=(Array.from({ length: 150 }, (_, i) => dispatchEvent(new ErrorEvent('error', { message: 'flood ' + i }))), "
         "'flooded');pause:2500")  # (each one the page's own error listener reports, as an uncaught error; steps split on ';')


def gtk_jslog_limit():
    """(D-681) GTK logs at most 100 widget errors per window, as the web logs 100 per page; it says the rest were dropped."""
    r = run([str(BUILD / "widgets" / "linux" / "widgets")], env={"MOJOUI_TEST": "pause:2500;" + FLOOD, "MOJOUI_WINDOW": "1280x860"}, timeout=300)
    o = r.stdout + r.stderr
    n = sum(1 for l in o.splitlines() if l.startswith("JS ERROR: ") and "flood " in l)
    other = [l for l in o.splitlines() if l.startswith("JS ERROR: ") and "flood " not in l]
    problems = [f"gtk jslog: errors besides the flood: {other[:2]}"] if other else []
    if n != 100 or "the rest aren't logged" not in o:
        problems.append(f"gtk jslog: {n} flood errors logged (want 100, then a note)")
    return problems


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
    for name in ("agent_link", "gtk_webview"):  # (the link's bytes: split characters, invalid UTF-8; the views' rules)
        err = g34.mojo_test(name, name + ": ok")
        if err:
            problems.append(err)
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
    problems += gtk_lost_commands()
    problems += no_socket_unset([str(BUILD / "widgets" / "linux" / "widgets")], "gtk", env={"MOJOUI_WINDOW": "1280x860"})
    problems += no_socket_unset([sys.executable, "mojoui/hosts/web.py", str(BUILD / "widgets" / "web"), str(free_port())], "web")
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

# ---- M2: the Mac, the same widgets (WKWebView), proven on GitHub's Mac runner ----
# The widgets app's side.txt lines (ci/mac/side.txt): one launch each at side.SIZE on GitHub's Macs (ci/mac/run.sh);
# their view dumps (WEBVIEW:/WIDGET: lines, the tree with each view's box) and logs (JS: lines) come back with the run.
MAC_PROBES = [(n, js) for n, js in g34.GTK_PROBES]  # (the same probes GTK's view passed: WKWebView offers the same handler API)
MAC_STEPS = {
    "start": "pause:3000",
    "typed": "pause:3000;webtype:mx-editor#1=one two three;pause:2000",
    "sample": "pause:3000;tap:Load sample;pause:2000",
    "counter": ("pause:3000;webclick:mx-counter#1=.inc;pause:600;webclick:mx-counter#1=.inc;pause:600;webclick:mx-counter#1=.inc;pause:800;"
                "tap:Bigger steps;pause:800;webclick:mx-counter#1=.inc;pause:800;tap:Ask the counter;pause:1500;tap:Show details;pause:2000"),
    "security": "pause:3000;" + ";".join(f"webjs:mx-counter#1={js}" for _, js in MAC_PROBES) + ";pause:1000",
    "crash1": "pause:3000;webkill:mx-counter#1;pause:4000",
    "crash2": "pause:3000;webkill:mx-counter#1;pause:4000;webkill:mx-counter#1;pause:3000",
    # M0's and M1b's features on the Mac (D-674): the theme's tokens and a live light → dark switch (CodeMirror, ECharts and
    # mojoui's drawn sparkline follow, nothing remounts); an agent's set through the runtime (Runtime.set_widget → the
    # page's "mojoui.set") reaching update() as the widget's own event, and describe()'s facts read back
    "light": "pause:3000;tap:Load sample;tap:Load sample;scheme:light;pause:1500",
    "theme": (f"pause:3000;tap:Load sample;tap:Load sample;scheme:light;webjs:mx-editor#1={THEME_PROBE};webjs:mx-chart#1={THEME_PROBE};"
              'set:mx-counter#1.count=42;pause:800;set:mx-editor#1.text="Agents can write here";pause:1500;'
              f"scheme:dark;pause:1000;webjs:mx-editor#1={THEME_PROBE};webjs:mx-chart#1={THEME_PROBE};pause:1500"),
}
M2_OUT = ROOT / "docs" / "goals" / "34b"


def mac_webviews(text):
    return g34.webviews(text)


def mac_labels(dump):
    """The texts the Mac's screen shows (the view dump's Text lines, not hidden)."""
    import re
    return [m.group(1) for m in re.finditer(r"^\s*Text '(.*?)'(?: \[[^\]]*\])?(?: #\S+)? @ [^\n]*$", dump, re.M)
            if " hidden" not in m.group(0)]


def m2():
    """The Mac, the same widgets: on the Mac each WebComponent runs in a WKWebView with the same bundle (the web's files,
    byte for byte), runtime (mojoui-widgets.js) and CSP (the web's, frame-src 'none'), served by a URL scheme handler
    that serves only the bundle; no network, no navigation away, no popups; JS↔native through a script message handler,
    JSON only, with GTK's owner/seq checks; the view kept across rebuilds; a crashed web content process reloads once,
    then the WebComponent shows `instead`. Proven on GitHub's Mac runner (scripts/mac-ci, fresh against these sources:
    side.mac_fresh, a stamp covering examples/widgets): typing in the editor reaches update() (Words: 3, the editor
    holds the words), Mojo sets its text (Load sample: Words: 9, the editor shows it), the counter's real clicks reach
    Mojo and its command gets its reply (count 5), a rebuild keeps one mount; the chart draws (any other WebComponent
    the app shows: ready, mounted once, no CSP violation; skipped only while the app has none); the boxes are within
    goal 32's parity (4 pt or 3 %) of the web's at side.SIZE; the security probes give GTK's answers; a picture."""
    import json
    import re
    import side
    import parity
    problems, notes = [], []
    host = ROOT / "mojoui/hosts/appkit_webview.mojo"
    if not host.exists():
        return False, "no mojoui/hosts/appkit_webview.mojo"
    src = host.read_text() + (ROOT / "mojoui/hosts/appkit.mojo").read_text()
    for need in ("WKWebView", "setURLSchemeHandler:forURLScheme:", "addScriptMessageHandler:", "decidePolicyForNavigationAction",
                 "webViewWebContentProcessDidTerminate:", "callAsyncJavaScript:"):
        if need not in src:
            problems.append(f"the Mac host doesn't use {need}")
    for name in ("mx-editor", "mx-counter", "examples/widgets", "Load sample"):
        if name in src:
            problems.append(f"the Mac host names {name!r}: it must work for any WebComponent in any app")
    if "WKWebView" not in (ROOT / "docs/js.md").read_text():
        problems.append("docs/js.md doesn't say how widgets run on the Mac (WKWebView)")
    if "examples/widgets" not in side.SOURCES:
        problems.append("scripts/side.py's stamp doesn't cover examples/widgets: no Mac run can be shown to be built from it")
    if "mac" not in (ROOT / "examples/widgets/platforms").read_text().split():
        problems.append("examples/widgets/platforms doesn't list mac")
    err = g34.build(g34.WIDGETS, "web", "mac")
    if err:
        return False, "; ".join(problems + [err])
    # the same bundle and runtime in the app
    app = next((g34.BUILD / g34.WIDGETS / "mac").glob("*.app"), None)
    res = app / "Contents" / "Resources" / "webview" if app else None
    web_assets = g34.BUILD / g34.WIDGETS / "web" / "assets"
    wm = json.loads((web_assets / "manifest.json").read_text())
    mm = json.loads((res / "assets" / "manifest.json").read_text()) if res and (res / "assets" / "manifest.json").exists() else {}
    if {k: v["file"] for k, v in wm.items()} != {k: v["file"] for k, v in mm.items()}:
        problems.append(f"the Mac app's bundles aren't the web's ({sorted(v['file'] for v in mm.values())})")
    else:
        for v in wm.values():
            if (web_assets / v["file"]).read_bytes() != (res / "assets" / v["file"]).read_bytes():
                problems.append(f"{v['file']} differs between the web and Mac builds")
    if not res or (res / "mojoui-widgets.js").read_bytes() != (ROOT / "mojoui/hosts/static/mojoui-widgets.js").read_bytes():
        problems.append("the Mac app's mojoui-widgets.js isn't the web host's runtime")
    # every C function the Mac binary needs is in apple/sdk's stubs (Objective-C goes by name at run time)
    exe = next((app / "Contents" / "MacOS").iterdir()) if app else None
    nm = g34.run(["pixi", "run", "llvm-nm", "-u", str(exe)]) if exe else None
    undefined = {l.split()[-1] for l in nm.stdout.splitlines() if l.strip()} if nm and nm.returncode == 0 else None
    stubs = " ".join(f.read_text() for f in (ROOT / "apple/sdk/macos").glob("*.tbd"))
    if undefined is None:
        problems.append("llvm-nm -u failed on the Mac binary")
    else:
        missing = sorted(s for s in undefined if not re.search(r"[\[\s,]" + re.escape(s) + r"[\],\s]", stubs))
        if missing:
            problems.append(f"undefined symbols not in apple/sdk/macos: {missing[:10]}")
        notes.append(f"{len(undefined)} undefined symbols, all stubbed")
    # side.txt's widgets lines are M2's steps
    lines = {s: steps for a, s, _, steps in side.screens() if a == g34.WIDGETS}
    for name, steps in MAC_STEPS.items():
        if lines.get(name) != steps:
            problems.append(f"ci/mac/side.txt's widgets|{name} steps aren't M2's")
    if problems:
        return False, "; ".join(problems[:10])
    # the run: fresh, from GitHub's macOS 26
    fresh, why = side.mac_fresh()
    if not fresh:
        return False, f"Mac: stale: {why} (scripts/build.sh widgets mac; scripts/mac-ci widgets)"
    mac = side.mac_dir()
    run_id = mac.parent.parent.name
    def got(screen, what):
        f = mac / f"{g34.WIDGETS}-{screen}-{what}.txt"
        return f.read_text() if f.exists() else None
    dumps = {s: got(s, "views") for s in MAC_STEPS}
    logs = {s: got(s, "log") for s in MAC_STEPS}
    for s, d in dumps.items():
        if d is None:
            problems.append(f"run {run_id}: no view dump for widgets|{s} (its log: {(logs[s] or '')[-300:]})")
    if problems:
        return False, "; ".join(problems[:8])
    tags = sorted(set(re.findall(r'WebComponent\("([a-z][a-z0-9._-]*)"', (ROOT / "examples/widgets/app.mojo").read_text())))
    # start: every view ready, mounted once, no CSP violation; the boxes against the web's
    v0 = mac_webviews(dumps["start"])
    for tag in tags:
        v = v0.get(f"{tag}#1")
        if not v or v["state"] != "ready" or v.get("mounts") != 1 or v.get("csp") != 0:
            problems.append(f"{tag}#1's WKWebView: {v} (wants ready, mounts=1, csp=0)")
    others = [t for t in tags if t not in ("mx-editor", "mx-counter")]
    if "mx-chart" not in others:  # (required since the merge: M1's ECharts runs on the Mac too, D-674)
        problems.append(f"the widgets app shows no chart widget (mx-chart) for the Mac to draw ({tags})")
    notes.append(f"chart: {', '.join(others)} drawn")
    rects = side.OUT / "widgets-start-web-rects.txt"
    rects.parent.mkdir(parents=True, exist_ok=True)
    ok, wout = True, ""
    try:
        import drive
        r, wout = drive.web_run(g34.BUILD / g34.WIDGETS / "web", "pause:1500", viewport=side.SIZE, rects=str(rects), color_scheme="light")
        ok = r.returncode == 0
    except Exception as e:
        ok, wout = False, repr(e)
    if not ok or not rects.exists():
        problems.append("the web run for the boxes failed: " + wout[-300:])
    else:
        rows = {k: (w, m, good) for k, w, m, good in parity.compare(rects.read_text(), dumps["start"])}
        for key in ["editor", "counter", "note-bar/Load sample", "counter-bar/Ask the counter"] + [t for t in others]:
            if key in others:
                continue
            w, m, good = rows.get(key, (None, None, False))
            if not good:
                problems.append(f"{key}: web {w} vs Mac {m} (beyond 4 pt / 3 %)")
    # typing reaches update(); Mojo sets the text
    lt, wt = mac_labels(dumps["typed"]), g34.widget_lines(dumps["typed"])
    if "Words: 3" not in lt or '"one two three"' not in wt.get("mx-editor#1", ""):
        problems.append(f"typing on the Mac: labels {[l for l in lt if l.startswith('Words')]}, editor {wt.get('mx-editor#1')}: {(logs['typed'] or '')[-300:]}")
    ls, ws = mac_labels(dumps["sample"]), g34.widget_lines(dumps["sample"])
    if "Words: 9" not in ls or json.dumps(g34.SAMPLE) not in ws.get("mx-editor#1", ""):
        problems.append(f"Load sample on the Mac: labels {[l for l in ls if l.startswith('Words')]}, editor {ws.get('mx-editor#1')}")
    # the counter: real clicks, props, a command's reply, a rebuild
    lc, wc, vc = mac_labels(dumps["counter"]), g34.widget_lines(dumps["counter"]), mac_webviews(dumps["counter"])
    for want in ("Clicks seen by Mojo: 4", "Last count: 5", "Step: 2", "Counter replied: count 5", "Details shown"):
        if want not in lc:
            problems.append(f"the counter on the Mac: no label {want!r} ({[l for l in lc if ':' in l][:8]})")
    if not wc.get("mx-counter#1", "").startswith("count 5, step 2"):
        problems.append(f"the counter's own state on the Mac: {wc.get('mx-counter#1')} (wants count 5, step 2)")
    for key in ("mx-editor#1", "mx-counter#1"):
        v = vc.get(key, {})
        if v.get("mounts") != 1 or v.get("csp") != 0 or v.get("refused") != 0:
            problems.append(f"{key} after the counter run: {v} (wants mounts=1, csp=0, refused=0)")
    # security: GTK's probes, GTK's answers
    vals = [json.loads(l[len("JS: "):]) for l in (logs["security"] or "").splitlines() if l.startswith("JS: ")]
    if len(vals) != len(MAC_PROBES):
        problems.append(f"the security probes returned {len(vals)} of {len(MAC_PROBES)} values: {(logs['security'] or '')[-400:]}")
    else:
        got_p = dict(zip([n for n, _ in MAC_PROBES], vals))
        want_csp = g34.CSP_WEB().replace("frame-src 'self' http: https:", "frame-src 'none'")
        if got_p["csp"] != want_csp:
            problems.append(f"the WKWebView's CSP is {got_p['csp']!r}, not the web's (frame-src 'none')")
        for k, v in g34.GTK_PROBE_WANT.items():
            if got_p[k] != v:
                problems.append(f"probe {k}: {got_p[k]!r} (wants {v!r})")
        for k in ("outside", "unlisted"):
            if got_p[k] == "loaded":
                problems.append(f"probe {k}: a file outside the bundle was served")
        if not str(got_p["where"]).startswith("mojoui://"):
            problems.append(f"the WKWebView navigated away: {got_p['where']!r}")
        l4 = mac_labels(dumps["security"])
        if "Clicks seen by Mojo: 0" not in l4 or "Words: 0" not in l4:
            problems.append(f"a refused message reached update() ({[l for l in l4 if 'Clicks' in l or 'Words' in l]})")
        v4 = mac_webviews(dumps["security"]).get("mx-counter#1", {})
        if v4.get("refused", 0) < 4 or v4.get("blocked", 0) < 2:
            problems.append(f"the Mac host didn't count the refused messages and blocked navigations: {v4}")
    # a crashed web content process: reload once (Mojo's props again), then `instead`
    for screen, kills, want in (("crash1", 1, "ready"), ("crash2", 2, "gone")):
        v = mac_webviews(dumps[screen]).get("mx-counter#1", {})
        if v.get("state") != want or v.get("crashes") != kills:
            problems.append(f"after {kills} ended web process(es) the counter's view is {v} (wants {want}, crashes={kills})")
        elif want == "ready" and not g34.widget_lines(dumps[screen]).get("mx-counter#1", "").startswith("count 0, step 1, label " + g34.LABEL_PROP):
            problems.append(f"the reloaded counter didn't get Mojo's props again: {g34.widget_lines(dumps[screen]).get('mx-counter#1')}")
        elif v.get("instead") != (1 if want == "gone" else 0):
            problems.append(f"after {kills} ended web process(es) the counter's `instead` view is {'hidden' if want == 'gone' else 'shown'} ({v})")
    # M1b on the Mac: the tokens, a live light → dark switch (CodeMirror, ECharts, the drawn sparkline), one mount each
    tlog = (logs["theme"] or "").splitlines()
    light_t, dark_t = gtk_probe(tlog, 0), gtk_probe(tlog, 1)
    problems += [p.replace("gtk", "mac") for p in theme_problems("mac light", light_t, False) + theme_problems("mac dark", dark_t, True)]
    if light_t.get("chart_ink") is None or dark_t.get("chart_ink") is None:
        problems.append("mac: the ECharts chart drew no labels (no svg text)")
    if light_t.get("chart_tokens") != light_t.get("tokens") or dark_t.get("chart_tokens") != dark_t.get("tokens"):
        problems.append("mac: the editor's and the chart's views got different tokens")
    vt = mac_webviews(dumps["theme"])
    for key in ("mx-editor#1", "mx-chart#1", "mx-counter#1"):
        if vt.get(key, {}).get("mounts") != 1 or vt.get(key, {}).get("csp", -1) != 0:
            problems.append(f"mac: {key}'s view after the switch: {vt.get(key)} (one mount, no CSP violation)")
    for screen, dark in (("light", False), ("theme", True)):
        pic = mac / f"{g34.WIDGETS}-{screen}.png"
        box = parity.mac_rects(dumps[screen]).get("sparkline")
        wm_ = re.search(r"window content (\d+)", dumps[screen])
        problems += spark_problems(f"mac {'dark' if dark else 'light'}", pic, box, dark, int(wm_.group(1)) if wm_ else 1440)
        if pic.exists():
            import shutil
            M2_OUT.mkdir(parents=True, exist_ok=True)
            shutil.copy(pic, M2_OUT / f"m2-widgets-mac-{'dark' if dark else 'light'}.png")
    # M0 on the Mac: an agent's set (the runtime's mojoui.set) reaches the widget and update(); describe()'s facts come back
    lt2 = mac_labels(dumps["theme"])
    if "Last count: 42" not in lt2 or "Words: 4" not in lt2:
        problems.append(f"mac: the sets didn't reach update() as the widgets' own events ({[l for l in lt2 if 'count' in l or 'Words' in l][:6]})")
    fl = next((l[len("WIDGETFACTS: "):] for l in dumps["theme"].splitlines() if l.startswith("WIDGETFACTS: ")), "")
    try:
        facts = {f"{f['tag']}#{f['id']}": f for f in json.loads(fl or "[]")}
    except (ValueError, KeyError, TypeError):
        facts = {}
    ct, ed = facts.get("mx-counter#1", {}), facts.get("mx-editor#1", {})
    if (ct.get("said") or {}).get("count") != 42 or ct.get("fields", {}).get("count") != "integer":
        problems.append(f"mac: the counter's facts after the set: {str(ct)[:200]} (said count 42, field count: integer)")
    if (ed.get("said") or {}).get("value") != "Agents can write here" or "text" not in ed.get("fields", {}):
        problems.append(f"mac: the editor's facts after the set: {str(ed)[:200]}")
    insp = re.findall(r"^WEBINSPECT: (\S+) (\d)$", dumps["theme"], re.M)
    if not insp or any(v != "0" for _, v in insp):
        problems.append(f"mac: a release build's widget views must not be inspectable ({insp})")
    # a picture: the typed screen, with words in the editor's box
    shot = mac / f"{g34.WIDGETS}-typed.png"
    if not shot.exists():
        problems.append(f"run {run_id}: no picture widgets-typed.png")
    else:
        import shutil
        from PIL import Image
        M2_OUT.mkdir(parents=True, exist_ok=True)
        shutil.copy(shot, M2_OUT / "m2-widgets-mac.png")
        m = parity.mac_rects(dumps["typed"]).get("editor")
        im = Image.open(shot).convert("RGB")
        if m:
            sx = im.width / float(re.search(r"window content (\d+)", dumps["typed"]).group(1))
            x, y, w, h = (int(v * sx) for v in m)
            px = im.crop((x + 4, y + 4, x + w - 4, min(y + int(60 * sx), y + h - 4))).tobytes()
            dark = sum(1 for i in range(0, len(px), 3) if px[i] + px[i + 1] + px[i + 2] < 300)
            if dark < 80:
                problems.append(f"the Mac picture shows no text in the editor's box ({dark} dark pixels)")
        else:
            problems.append("no editor box in the typed screen's dump")
    tail = f"run {run_id}; " + "; ".join(notes)
    return not problems, ("; ".join(problems[:12]) + " | " + tail) if problems else (
        "each WebComponent in a WKWebView of its own (mojoui:// scheme handler serving only the bundle, the web's files byte "
        "for byte, the web's CSP with frame-src 'none', no network): typing reaches update() (Words: 3), Load sample shows "
        "Mojo's text, 4 real clicks reach Mojo, a command's reply arrives (count 5), one mount across a rebuild; boxes "
        "within parity of the web's; GTK's security probes pass; a crash reloads once, then `instead`; the chart draws; "
        "the theme's tokens and a live light → dark switch (CodeMirror, ECharts and the drawn sparkline follow, one mount); "
        "an agent's set (mojoui.set) reaches update() and describe()'s facts come back; release views not inspectable; picture "
        f"{(M2_OUT / 'm2-widgets-mac.png').relative_to(ROOT)}; " + tail)


MILESTONES = [
    ("M0", m0),
    ("M1", m1),
    ("M1b", m1b),
    ("M1c", m1c),
    ("M2", m2),
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
