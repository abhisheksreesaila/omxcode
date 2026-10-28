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
    ("M1", todo("ECharts from npm with no host changes (GOAL.md M1)")),
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
