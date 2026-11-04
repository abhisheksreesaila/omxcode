"""Milestone checker for GOAL.md (goal 48: AG-UI as good as CopilotKit, and faster). Prints PASS/FAIL per milestone.

Run: scripts/check   (a subset: scripts/check M0 M1)
Each milestone's proof was written before its work started, from GOAL.md's words (never weaker). The app runs use goal
35's harness: examples/agentchat on GTK (MOJOUI_TEST steps) and the web (scripts/drive.py) against the scripted agent
(scripts/agui_agent.py --scenario NAME). Mid-run pictures use a `shot:<path>` step on both hosts.
"""

import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
sys.path.insert(0, str(ROOT / "scripts"))
BUILD = ROOT / "build"
OUT = ROOT / "docs" / "goals" / "48"

# M0: the components an agent must be able to name (GOAL.md M0's list)
REQUIRED = [
    "Card", "VStack", "HStack", "Grid", "Tabs", "Divider", "Spacer",
    "Text", "Paragraph", "Markdown", "CodeBlock", "Chip", "Alert", "Skeleton",
    "Table", "DataGrid", "ChartView", "Sparkline", "KpiView", "Meter", "ProgressBar", "Timeline", "MapView", "Breadcrumbs", "Icon",
    "Button", "TextField", "TextArea", "Toggle", "Checkbox", "Dropdown", "Slider", "Segmented", "Radio", "DatePicker",
    "Confirm",
]

# M4: the example scenarios: (scenario, prompt, words that must be on screen)
EXAMPLES = [
    ("trip", "Plan a day in Lisbon", ["Lisbon", "Belém"]),
    ("dashboard", "Show me this quarter's sales", ["Revenue", "Orders"]),
    ("booking", "Book a table for dinner", ["Party size", "Book"]),
    ("approval", "Refund order 1042", ["Approve", "Reject", "1042"]),
    ("research", "Research home batteries", ["Plan", "Compare"]),
    ("release", "Write the release note for 2.4", ["2.4", "Changes"]),
]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_g35 = []


def g35():
    if not _g35:
        _g35.append(load("goal35", "docs/goals/35-check.py"))
    return _g35[0]


def run(cmd, env=None, timeout=1800):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=dict(os.environ, **(env or {})), timeout=timeout)


def codec_link():
    """What a program using the omxcore engine links (its Parquet codecs: scripts/mxlink.sh, as scripts/build.sh does)."""
    lib = ROOT / ".pixi/envs/default/lib"
    codecs = BUILD / "codecs"
    codecs.mkdir(parents=True, exist_ok=True)
    out = []
    for l in ("libzstd.so.1", "libsnappy.so.1"):
        dst = codecs / l
        if not dst.exists():
            dst.symlink_to((lib / l).resolve())
        out += ["-Xlinker", str(dst)]
    return out + ["-Xlinker", f"-rpath={codecs}"]


def build_test(name):
    BUILD.mkdir(exist_ok=True)
    exe = BUILD / name
    uses_engine = "omxcore" in (ROOT / f"tests/{name}.mojo").read_text() or "sheethub" in (ROOT / f"tests/{name}.mojo").read_text()
    b = run(["pixi", "run", "mojo", "build", "-I", ".", "-I", "vendor", f"tests/{name}.mojo", "-o", str(exe)] + (codec_link() if uses_engine else []))
    if b.returncode != 0:
        return None, f"tests/{name}.mojo doesn't build: " + (b.stdout + b.stderr)[-700:]
    return exe, None


def run_test(name, timeout=600):
    """(stdout lines, None) or (None, why)."""
    if not (ROOT / f"tests/{name}.mojo").exists():
        return None, f"no tests/{name}.mojo"
    exe, err = build_test(name)
    if err:
        return None, err
    r = run([str(exe)], timeout=timeout)
    if r.returncode != 0:
        return None, f"{name} exit {r.returncode}: {(r.stdout + r.stderr)[-600:]}"
    return [l.strip() for l in r.stdout.splitlines()], None


def need_ok(lines, labels_):
    return [lab for lab in labels_ if not any(l.startswith(f"{lab}: ok") for l in lines)]


def labels(out):
    """The words on screen: texts (LABEL:) and button titles (BUTTON:), as both hosts report them."""
    return [l.split(": ", 1)[1] for l in out.splitlines() if l.startswith("LABEL: ") or l.startswith("BUTTON: ")]


def chat(host, scenario, steps, shot=None):
    return g35().chat_run(host, scenario, steps, shot=shot)


def tool_messages(inputs):
    from ag_ui.core import RunAgentInput
    return [m for i in inputs for m in RunAgentInput.model_validate(i).messages if m.role == "tool"]


def validate_inputs(inputs):
    from ag_ui.core import RunAgentInput
    bad = []
    for i in inputs:
        try:
            RunAgentInput.model_validate(i)
        except Exception as e:
            bad.append(repr(e)[:200])
    return bad


def picture_ok(path, min_std=6.0):
    """A shot exists and isn't blank (pixel spread)."""
    p = Path(path)
    if not p.exists() or p.stat().st_size < 2000:
        return False
    from PIL import Image, ImageStat
    im = Image.open(p).convert("L")
    return ImageStat.Stat(im).stddev[0] >= min_std


def same_picture(a, b):
    from PIL import Image, ImageChops
    ia, ib = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
    if ia.size != ib.size:
        return False
    return ImageChops.difference(ia, ib).getbbox() is None


def build_chat():
    return g35().build_example("agentchat", "linux", "web")


# ---------------------------------------------------------------------------------------------------------------------

def m0():
    """Every general component, by data: ≥ 36 catalogued, the schema regenerated, each rendered and each refused."""
    problems = []
    gen = (ROOT / "mojoui/genui.mojo").read_text()
    for bad in ("WebComponent(", "WebFrame(", "external_call", "eval("):
        if bad in gen:
            problems.append(f"mojoui/genui.mojo uses {bad}")
    r = run(["pixi", "run", "python", "scripts/genui_schema.py", "--check"]) if (ROOT / "scripts/genui_schema.py").exists() else None
    schema = json.loads((ROOT / "docs/genui.schema.json").read_text())
    comps = set(schema.get("$defs", {}).get("components", {}).keys())
    if r is not None and r.returncode != 0:
        problems.append(f"docs/genui.schema.json is stale: {(r.stdout + r.stderr)[-300:]}")
    missing = [c for c in REQUIRED if c not in comps]
    if missing:
        problems.append(f"the schema lacks {missing}")
    lines, err = run_test("test_genui")
    if err:
        return False, "; ".join(problems + [err])
    m = next((re.match(r"catalog: ok (\d+)", l) for l in lines if l.startswith("catalog: ok")), None)
    if not m or int(m.group(1)) < 36:
        problems.append(f"test_genui prints no 'catalog: ok N' with N ≥ 36: {lines[-5:]}")
    for c in REQUIRED:
        if f"render: {c}" not in lines:
            problems.append(f"test_genui didn't render {c}")
        if f"refuse: {c}" not in lines:
            problems.append(f"test_genui didn't refuse a bad prop for {c}")
    agui = (ROOT / "docs/agui.md").read_text()
    if "Not for agents" not in agui:
        problems.append("docs/agui.md doesn't list the app-only components (a 'Not for agents' section)")
    err = build_chat()
    if err:
        problems.append(err)
    if problems:
        return False, "; ".join(problems[:12])
    return True, f"{len(comps)} components in docs/genui.schema.json; test_genui rendered and refused each ({m.group(0)}); agentchat builds"


def m1():
    """Streaming generative UI: partial args build the UI piece by piece (Skeleton for what hasn't arrived), tool-call
    status, backend tool cards, STEP progress, state re-render; a GTK + web run with ≥ 3 different mid-stream shots."""
    lines, err = run_test("test_agui_stream")
    if err:
        return False, err
    miss = need_ok(lines, ["partial", "status", "steps", "state", "skeleton"])
    if miss:
        return False, f"test_agui_stream has no ok for {miss}: {lines[-6:]}"
    err = build_chat()
    if err:
        return False, err
    OUT.mkdir(parents=True, exist_ok=True)
    problems, notes = [], []
    for host in ("gtk", "web"):
        shots = [OUT / f"m1-stream-{host}-{k}.png" for k in range(3)]
        for s in shots:
            s.unlink(missing_ok=True)
        steps = ("type:Message=Build me a dashboard;tap:Send;pause:350;shot:" + str(shots[0]) + ";pause:500;shot:" + str(shots[1])
                 + ";pause:3500;shot:" + str(shots[2]))
        try:
            out, inputs = chat(host, "stream", steps)
        except RuntimeError as e:
            problems.append(str(e)[:400])
            continue
        if not all(picture_ok(s) for s in shots):
            problems.append(f"{host}: the mid-stream shots are missing or blank")
            continue
        if same_picture(shots[0], shots[1]) or same_picture(shots[1], shots[2]):
            problems.append(f"{host}: the mid-stream shots don't differ (the UI didn't build piece by piece)")
        ls = labels(out)
        for want in ("complete", "search_sales"):  # a finished call's status; the backend tool's card
            if not any(want in l for l in ls):
                problems.append(f"{host}: no '{want}' on screen")
        if not any(l.startswith("Revenue") or "Revenue" in l for l in ls):
            problems.append(f"{host}: the streamed dashboard didn't finish (no Revenue)")
        if validate_inputs(inputs):
            problems.append(f"{host}: a POST isn't a RunAgentInput")
        notes.append(f"{host}: 3 mid-stream shots differ")
    if problems:
        return False, "; ".join(problems)
    return True, "test_agui_stream ok (partial, status, steps, state, skeleton); " + "; ".join(notes)


def m2():
    """Human in the loop: a `confirm` tool's approve/reject card runs nothing until answered, the answer is the tool
    result; an interrupt's choice card resumes the run with the pick; GTK + web."""
    err = build_chat()
    if err:
        return False, err
    OUT.mkdir(parents=True, exist_ok=True)
    problems, notes = [], []
    for host in ("gtk", "web"):
        for verdict, button in (("approved", "Approve"), ("rejected", "Reject")):
            try:
                out, inputs = chat(host, "approval", f"type:Message=Refund order 1042;tap:Send;pause:1200;tap:{button};pause:1500",
                                   shot=str(OUT / f"m2-{verdict}-{host}.png"))
            except RuntimeError as e:
                problems.append(str(e)[:400])
                continue
            tm = tool_messages(inputs)
            if not tm or verdict not in tm[-1].content:
                problems.append(f"{host}: {button} didn't reach the agent as the tool result: {[m.content[:80] for m in tm]}")
            if len(inputs) < 2:
                problems.append(f"{host}: no run after {button}")
            if verdict == "rejected" and any("Refunded" in l for l in labels(out)):
                problems.append(f"{host}: a rejected refund still ran")
        try:
            out, inputs = chat(host, "interrupt", "type:Message=Deploy the site;tap:Send;pause:1200;tap:Staging;pause:1500",
                               shot=str(OUT / f"m2-interrupt-{host}.png"))
        except RuntimeError as e:
            problems.append(str(e)[:400])
            continue
        from ag_ui.core import RunAgentInput
        runs = [RunAgentInput.model_validate(i) for i in inputs]
        fp = (runs[-1].forwarded_props or {}) if runs else {}
        resume = (fp.get("command") or {}).get("resume") if isinstance(fp, dict) else None
        if len(runs) < 2 or resume != "Staging":
            problems.append(f"{host}: the interrupt didn't resume with the pick (forwardedProps {fp!r})")
        if not any("Deployed to Staging" in l for l in labels(out)):
            problems.append(f"{host}: the resumed run's answer isn't on screen")
        notes.append(f"{host}: approve, reject and an interrupt answered")
    if problems:
        return False, "; ".join(problems)
    return True, "; ".join(notes)


def m3():
    """The chat, polished: mojoui.agentchat's AgentChat (panel, sidebar, popup), Markdown + code + copy, typing
    indicator, Stop, auto-scroll that yields, suggestion chips, copy and regenerate, an error with Retry, cards on a
    spring; examples/agentchat a thin app over it; GTK + web shots in light and dark."""
    if not (ROOT / "mojoui/agentchat.mojo").exists():
        return False, "no mojoui/agentchat.mojo"
    src = (ROOT / "mojoui/agentchat.mojo").read_text()
    if "struct AgentChat" not in src:
        return False, "mojoui/agentchat.mojo has no AgentChat"
    lines, err = run_test("test_agentchat")
    if err:
        return False, err
    miss = need_ok(lines, ["markdown", "copy", "typing", "stop", "scroll", "suggestions", "regenerate", "retry", "spring", "layouts"])
    if miss:
        return False, f"test_agentchat has no ok for {miss}"
    app = (ROOT / "examples/agentchat/app.mojo").read_text()
    if "AgentChat" not in app or len(app.splitlines()) > 90:
        return False, f"examples/agentchat isn't a thin app over AgentChat ({len(app.splitlines())} lines)"
    err = build_chat()
    if err:
        return False, err
    OUT.mkdir(parents=True, exist_ok=True)
    problems, notes = [], []
    for host in ("gtk", "web"):
        # a suggestion chip sends; Regenerate runs the same question again
        try:
            out, inputs = chat(host, "chat", "pause:600;tap:Show me sales as a chart;pause:1800;tap:Regenerate;pause:1800",
                               shot=str(OUT / f"m3-chat-{host}.png"))
        except RuntimeError as e:
            problems.append(str(e)[:400])
            continue
        from ag_ui.core import RunAgentInput
        users = [[m.content for m in RunAgentInput.model_validate(i).messages if m.role == "user"] for i in inputs]
        if len(inputs) < 2 or not users or "Show me sales as a chart" not in (users[0] or [""])[-1]:
            problems.append(f"{host}: the suggestion chip didn't send its words ({users[:1]})")
        elif users[-1].count("Show me sales as a chart") != 1:
            problems.append(f"{host}: Regenerate didn't rerun the same question once: {users[-1]}")
        # an error, then Retry
        try:
            out, inputs = chat(host, "error", "type:Message=Hello;tap:Send;pause:1200;tap:Retry;pause:1500")
        except RuntimeError as e:
            problems.append(str(e)[:400])
            continue
        if len(inputs) < 2:
            problems.append(f"{host}: Retry didn't run again")
        # Markdown with a code block, in light and dark
        for scheme in ("light", "dark"):
            shot = OUT / f"m3-markdown-{scheme}-{host}.png"
            pre = "scheme:dark;" if scheme == "dark" else ""
            try:
                if host == "web" and scheme == "dark":
                    out, _ = chat_dark_web("type:Message=Write the release note for 2.4;tap:Send;pause:2500", shot)
                else:
                    out, _ = chat(host, "release", pre + "type:Message=Write the release note for 2.4;tap:Send;pause:2500", shot=str(shot))
            except RuntimeError as e:
                problems.append(str(e)[:400])
                continue
            if not picture_ok(shot):
                problems.append(f"{host}: {scheme} shot missing or blank")
            if not any("Copy" in l for l in labels(out)):
                problems.append(f"{host}: no Copy action on the code block / message ({scheme})")
        notes.append(f"{host}: chip, regenerate, retry, markdown light + dark")
    if problems:
        return False, "; ".join(problems)
    return True, "test_agentchat ok (10 behaviours); examples/agentchat is " + str(len(app.splitlines())) + " lines; " + "; ".join(notes)


def chat_dark_web(steps, shot):
    import agui_agent
    import drive
    with agui_agent.Server(scenario="release", record=True) as srv:
        r, out = drive.web_run(BUILD / "agentchat" / "web", f"type:Agent URL={srv.url};" + steps, shot=str(shot),
                               color_scheme="dark", env={"AGUI_URL": srv.url})
        inputs = list(srv.inputs)
    if r.returncode != 0:
        raise RuntimeError("web dark: " + out[-500:])
    return out, inputs


def m4():
    """Examples worth showing: ≥ 6 scenarios from catalogued components only, GTK + web shots, the booking's values reach
    the agent, docs/agui.md's gallery shows them."""
    err = build_chat()
    if err:
        return False, err
    OUT.mkdir(parents=True, exist_ok=True)
    problems, done = [], 0
    for scenario, prompt, words in EXAMPLES:
        for host in ("gtk", "web"):
            shot = OUT / f"ex-{scenario}-{host}.png"
            steps = f"type:Message={prompt};tap:Send;pause:2500"
            if scenario == "booking":
                steps += ";type:Name=Ada;slide:0=33;select:0=19:30;radio:0=Terrace;tap:Book;pause:1500"  # (party 1–10: 33% is 4)
            try:
                out, inputs = chat(host, scenario, steps, shot=str(shot))
            except RuntimeError as e:
                problems.append(f"{scenario}/{host}: {str(e)[:300]}")
                continue
            ls = labels(out)
            for w in words:
                if not any(w in l for l in ls):
                    problems.append(f"{scenario}/{host}: '{w}' isn't on screen")
            if any("refused" in m.content for m in tool_messages(inputs)):
                problems.append(f"{scenario}/{host}: the app refused the scenario's UI")
            if not picture_ok(shot):
                problems.append(f"{scenario}/{host}: shot missing or blank")
            if scenario == "booking":
                from ag_ui.core import RunAgentInput
                st = RunAgentInput.model_validate(inputs[-1]).state if inputs else None
                b = (st or {}).get("booking", {}) if isinstance(st, dict) else {}
                if b.get("name") != "Ada" or b.get("party") != 4 or b.get("seating") != "Terrace" or b.get("time") != "19:30":
                    problems.append(f"booking/{host}: the agent got {b!r}")
            done += 1
    agent_src = (ROOT / "scripts/agui_agent.py").read_text() + ((ROOT / "scripts/agui_scenarios.py").read_text() if (ROOT / "scripts/agui_scenarios.py").exists() else "")
    if "MapView" not in agent_src:
        problems.append("the trip scenario doesn't use MapView")
    agui = (ROOT / "docs/agui.md").read_text()
    for scenario, _, _ in EXAMPLES:
        if f"goals/48/ex-{scenario}-" not in agui:
            problems.append(f"docs/agui.md's gallery doesn't show {scenario}")
    if problems:
        return False, "; ".join(problems[:12])
    return True, f"{len(EXAMPLES)} scenarios × 2 hosts ({done} runs): words on screen, nothing refused, shots; booking's values reached the agent"


def m5():
    """Faster, in process, GPU: (a) LocalAgent, no HTTP or Python; (b) a dataset reference bound to a DataGrid/ChartView
    (1M rows not sent); (c) the benchmark against CopilotKit (or a stated stand-in), every loss stated."""
    problems, notes = [], []
    agui = (ROOT / "mojoui/agui.mojo").read_text()
    if "LocalAgent" not in agui:
        problems.append("mojoui.agui has no LocalAgent")
    lines, err = run_test("test_local_agent")
    if err:
        problems.append(err)
    else:
        miss = need_ok(lines, ["local", "dataref"])
        if miss:
            problems.append(f"test_local_agent has no ok for {miss}")
        else:
            m = next((l for l in lines if l.startswith("dataref: ok")), "")
            if "1000000" not in m.replace(",", ""):
                problems.append(f"the data reference didn't bind 1M rows: {m}")
            notes += [next(l for l in lines if l.startswith("local: ok")), m]
    src = (ROOT / "tests/test_local_agent.mojo").read_text() if (ROOT / "tests/test_local_agent.mojo").exists() else ""
    if "mojoui.http" in src or "python" in src.lower():
        problems.append("test_local_agent uses HTTP or Python")
    if not (ROOT / "scripts/agui_bench.py").exists():
        problems.append("no scripts/agui_bench.py")
    else:
        r = run(["pixi", "run", "python", "scripts/agui_bench.py"], timeout=3600)
        if r.returncode != 0:
            problems.append(f"agui_bench.py failed: {(r.stdout + r.stderr)[-500:]}")
        else:
            b = json.loads((OUT / "bench.json").read_text())
            if b.get("events", 0) < 2000:
                problems.append(f"the bench stream has {b.get('events')} events (< 2,000)")
            runners = b.get("runners", {})
            for name in ("omxcode-gtk", "omxcode-web"):
                if name not in runners:
                    problems.append(f"bench.json lacks {name}")
            react = [k for k in runners if k.startswith("copilotkit") or k.startswith("react")]
            if not react:
                problems.append("bench.json has no CopilotKit (or stated React stand-in) row")
            for name, row in runners.items():
                for f in ("first_ui_ms", "last_event_ms", "frames_over_16ms", "peak_mb"):
                    if not isinstance(row.get(f), (int, float)):
                        problems.append(f"bench.json {name} lacks {f}")
            notes.append("bench: " + ", ".join(f"{k} first UI {v.get('first_ui_ms')} ms, done {v.get('last_event_ms')} ms" for k, v in runners.items()))
    import re as _re  # (D-4747: one timer per swapped element and hook dropped a third of the web host's frames)
    if _re.search(r"htmx:oobAfterSwap', \(\) => setTimeout\(", (ROOT / "mojoui/hosts/web.py").read_text()):
        problems.append("mojoui/hosts/web.py runs a hook per out-of-band swap again: use afterSwaps(fn) (once per answer)")
    for hook in ("whole", "pin", "syncRoute", "copyAsked", "menus.place"):
        if f"afterSwaps({hook})" not in (ROOT / "mojoui/hosts/web.py").read_text():
            problems.append(f"mojoui/hosts/web.py no longer runs {hook} after out-of-band swaps (afterSwaps)")
    doc = (ROOT / "docs/agui.md").read_text()
    if "## Benchmark" not in doc:
        problems.append("docs/agui.md has no '## Benchmark' section")
    elif (OUT / "bench.json").exists() and json.loads((OUT / "bench.json").read_text()).get("when", "?") not in doc:
        problems.append("docs/agui.md's Benchmark section isn't the numbers in bench.json (scripts/agui_bench.py writes both)")
    if problems:
        return False, "; ".join(problems[:10])
    return True, "; ".join(notes)


def m6():
    """Nothing regressed: goal 35's M0–M3, the components matrix fresh with the Agent column, docs/agui.md rewritten."""
    problems = []
    g = g35()
    for label, fn in (("35-M0", g.m0), ("35-M1", g.m1), ("35-M2", g.m2), ("35-M3", g.m3)):
        ok, msg = fn()
        if not ok:
            problems.append(f"{label}: {msg[:300]}")
    r = run(["pixi", "run", "python", "scripts/components.py", "--check"])
    if r.returncode != 0:
        problems.append("docs/components.md is stale: " + (r.stdout + r.stderr)[-200:])
    doc = (ROOT / "docs/agui.md").read_text()
    for need in ("AgentChat", "LocalAgent", "Confirm", "interrupt", "Skeleton", "goal 48"):
        if need not in doc:
            problems.append(f"docs/agui.md doesn't cover {need}")
    return not problems, "; ".join(problems) or "goal 35's M0–M3 pass; the matrix is fresh; docs/agui.md covers goal 48"


MILESTONES = [("M0", m0), ("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4), ("M5", m5), ("M6", m6)]


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
