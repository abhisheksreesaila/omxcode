"""Milestone checker for GOAL.md (goal 35: AG-UI, agents that build the screen). Prints PASS/FAIL per milestone.

Run: scripts/check   (a subset: scripts/check M0 M1)
Each milestone's proof was written before its work started, from GOAL.md's words (never weaker). M4 runs goal 34b's M0,
goal 34's M2 and goal 33's M1 through their archived checks.
"""

import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
BUILD = ROOT / "build"
OUT = ROOT / "docs" / "goals" / "35"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_old = {}


def old():
    """The archived checks (loaded on first use: they import a lot)."""
    if not _old:
        g34b = load("goal34b", "docs/goals/34b-check.py")
        _old.update(g34b=g34b, g34=g34b.g34, g33=g34b.g33)
    return _old


def run(cmd, env=None, timeout=1800, cwd=ROOT):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=dict(os.environ, **(env or {})), timeout=timeout)


def build_test(name):
    """tests/<name>.mojo built into build/<name>: (exe, None) or (None, why)."""
    BUILD.mkdir(exist_ok=True)
    exe = BUILD / name
    b = run(["pixi", "run", "mojo", "build", "-I", ".", "-I", "vendor", f"tests/{name}.mojo", "-o", str(exe)])
    if b.returncode != 0:
        return None, f"tests/{name}.mojo doesn't build: " + (b.stdout + b.stderr)[-700:]
    return exe, None


def keyed(out):
    """Lines 'KEY: value' (KEY in capitals) as {KEY: [values…]}."""
    got = {}
    for l in out.splitlines():
        m = re.match(r"^([A-Z][A-Z0-9_]*): (.*)$", l)
        if m:
            got.setdefault(m.group(1), []).append(m.group(2))
    return got


def labels(out):
    return [l[len("LABEL: "):] for l in out.splitlines() if l.startswith("LABEL: ")]


def label_value(out, prefix):
    for l in labels(out):
        if l.startswith(prefix):
            return l[len(prefix):].strip()
    return None


_g5 = []


def g5():
    """Goal 5's gtk() and web() runners (an example driven by MOJOUI_TEST steps; drive.py on the web)."""
    if not _g5:
        mod = load("goal5", "docs/goals/05-check.py")
        mod.ROOT, mod.BUILD = ROOT, BUILD
        _g5.append(mod)
    return _g5[0]


def build_example(example, *hosts):
    for host in hosts:
        b = run(["scripts/build.sh", example, host])
        if b.returncode != 0:
            return f"{example} doesn't build for {host}: " + (b.stdout + b.stderr)[-700:]
    return None


# ---------------------------------------------------------------------------------------------------------------------
# M0: streaming HTTP
# ---------------------------------------------------------------------------------------------------------------------

def m0():
    """GOAL.md M0: `mojoui.http` streams: a request may ask for a stream; each SSE event (or chunk) arrives as its own
    Event in update() while frames keep drawing, then an end Event; through the Transport seam (sockets today); tests
    against a Python SSE server: 200 events in order, a slow trickle, a dropped connection mid-stream, a timeout, cancel
    by the app."""
    import http_server
    problems = []
    http = (ROOT / "mojoui/http.mojo").read_text()
    effects = (ROOT / "mojoui/effects.mojo").read_text()
    app = (ROOT / "mojoui/app.mojo").read_text()
    # the seam: the trait carries streaming; the worker calls the trait, not sockets; the runtime knows no sockets
    trait = http[http.find("trait Transport"):http.find("struct Http")]
    if "def stream(" not in trait:
        problems.append("the Transport trait has no stream(): streaming isn't through the seam")
    if "T.stream(" not in effects:
        problems.append("mojoui/effects.mojo's worker doesn't stream through the Transport (T.stream)")
    if "http_socket" in app:
        problems.append("mojoui/app.mojo imports the socket transport (it must only see the seam)")
    if "def stream(" not in (ROOT / "mojoui/http_socket.mojo").read_text():
        problems.append("SocketTransport has no stream()")
    exe, err = build_test("test_stream")
    if err:
        return False, err
    with http_server.TestServer() as srv:
        t = run([str(exe)], env={"STREAM_TEST_URL": srv.url, "STREAM_TEST_DEAD": srv.dead}, timeout=180)
        seen = list(srv.seen)
        gone = dict(srv.httpd.gone)  # path -> monotonic time the server saw the client leave
    out = t.stdout + t.stderr
    if t.returncode != 0 or "test_stream: all passed" not in out:
        return False, "tests/test_stream.mojo fails: " + out[-900:]
    k = keyed(out)

    def one(key):
        v = k.get(key)
        if not v:
            problems.append(f"the test printed no {key} line")
            return None
        return v[0]

    # 200 events in order: each its own Event (one update each), then one end Event (status 200, no error)
    v = one("ORDER")
    if v is not None:
        want = f"200 events, each its own update, data 0..199 in order; end 200 ''"
        if v != want:
            problems.append(f"ORDER: {v!r} (want {want!r})")
    # chunks (not SSE): each chunk its own Event, joined = the body
    v = one("CHUNKS")
    if v is not None and v != f"{len(http_server.CHUNKS)} pieces {b''.join(http_server.CHUNKS).decode()!r}; end 200 ''":
        problems.append(f"CHUNKS: {v!r} (each of the {len(http_server.CHUNKS)} chunks its own Event, then the end)")
    # a slow trickle: events arrive as they're sent (gaps near the server's 150 ms), the loop keeps polling between them
    v = one("TRICKLE")
    if v is not None:
        m = re.match(r"^(\d+) events at ([\d ]+); polls between (\d+); end 200 ''$", v)
        if not m:
            problems.append(f"TRICKLE: {v!r}")
        else:
            n, at, polls = int(m.group(1)), [int(x) for x in m.group(2).split()], int(m.group(3))
            gaps = [b - a for a, b in zip(at, at[1:])]
            if n != 10 or len(at) != 10:
                problems.append(f"TRICKLE: {n} events (want 10)")
            elif not all(100 <= g <= 400 for g in gaps):
                problems.append(f"TRICKLE: events didn't arrive one by one as sent 150 ms apart: gaps {gaps}")
            if polls < 50:
                problems.append(f"TRICKLE: only {polls} polls of the runtime while it trickled (something waited)")
    # a dropped connection mid-stream: what arrived, then an end Event with an error
    v = one("DROP")
    if v is not None and not re.match(r"^3 events; end 0 '.*(ended early|dropped|broke).*'$", v):
        problems.append(f"DROP: {v!r} (want 3 events, then an end with an error saying it ended early)")
    # a timeout: the stream goes quiet; .timeout(500) ends it with an error 0.4–1.5 s after the last event
    v = one("TIMEOUT")
    if v is not None:
        m = re.match(r"^1 events; end 0 '(.*)' after (\d+) ms$", v)
        if not m or "timed out" not in m.group(1) or not 400 <= int(m.group(2)) <= 1500:
            problems.append(f"TIMEOUT: {v!r} (want 1 event, then 'timed out' 0.4–1.5 s after it)")
    # cancel by the app: after 5 events the app cancels; no event after the end; the server sees the client leave soon
    v = one("CANCEL")
    if v is not None:
        m = re.match(r"^(\d+) events; end 0 'cancelled'; after the end (\d+)$", v)
        if not m or int(m.group(2)) != 0 or not 5 <= int(m.group(1)) <= 7:
            problems.append(f"CANCEL: {v!r} (want 5–7 events, the end 'cancelled', nothing after it)")
    cancel_at = one("CANCEL_AT")
    forever = [s for s in seen if s["path"].startswith("/forever")]
    if not forever:
        problems.append("the server never saw GET /forever")
    elif cancel_at is not None:
        left = gone.get(forever[0]["path"])
        if left is None:
            problems.append("the server never saw the cancelled stream's client leave")
    # nothing waited: a stream's request returns from update() at once
    v = one("DISPATCH")
    if v is not None and float(v.split()[0]) >= 100:
        problems.append(f"DISPATCH: update() that opens a stream took {v}")
    # refused, and streams on a POST (the AG-UI shape: POST JSON, SSE back)
    v = one("REFUSED")
    if v is not None and not re.match(r"^0 events; end 0 '.*refused.*'$", v):
        problems.append(f"REFUSED: {v!r}")
    v = one("POST")
    if v is not None and v != "3 events, the last 'got {\"hello\": \"sse\"}'; end 200 ''":
        problems.append(f"POST: {v!r} (a POSTed JSON body, streamed back)")
    # an error status is a reply: no events, the body on the end Event
    v = one("STATUS")
    if v is not None and v != "0 events; end 500 '' 'boom'":
        problems.append(f"STATUS: {v!r} (a 500 to a stream: no events, the end carries status and body)")
    # bounds (reviewer, D-719): an event past 1 MB, a never-ending stream past its byte limit, one past its time limit,
    # a chunk size past any Int, a declared chunk past 4 MB: each ends with an error, nothing hangs
    for key, pattern in [("BIGEVENT", r"^0 events; end 0 '.*event larger than 1048576 bytes'$"),
                         ("FLOOD", r"^\d+ events; end 0 '.*larger than 1000000 bytes'$"),
                         ("LONG", r"^\d+ events; end 0 '.*lasted longer than 600 ms'$"),
                         ("HUGECHUNK", r"^0 events; end 0 '.*bad chunk size.*'$"),
                         ("BIGCHUNK", r"^0 events; end 0 '.*chunk larger than.*'$")]:
        v = one(key)
        if v is not None and not re.match(pattern, v):
            problems.append(f"{key}: {v!r}")
    if problems:
        return False, "; ".join(problems)
    # frames keep drawing on GTK and the web while a stream trickles (examples/httpcheck's Stream)
    err = build_example("httpcheck", "linux", "web")
    if err:
        return False, err
    OUT.mkdir(parents=True, exist_ok=True)
    notes = []
    for host in ("gtk", "web"):
        with http_server.TestServer() as srv:
            steps = f"type:URL={srv.url}trickle?n=20&ms=100;tap:Stream;pause:3500"
            shot = str(OUT / f"m0-stream-{host}.png")
            if host == "web":  # (and an unsized text field keeps the web's 70vw cap: reviewer item 9, D-713)
                steps += ";js:[getComputedStyle(document.querySelector('input[placeholder=URL]')).maxWidth, innerWidth]"
            r, o = g5().gtk("httpcheck", steps, shot=shot) if host == "gtk" else g5().web("httpcheck", steps, shot=shot)
        if r is None:
            problems.append(f"{host}: {o[-400:]}")
            continue
        events, frames, gap = (label_value(o, p) for p in ("stream events:", "frames while streaming:", "longest frame gap:"))
        if None in (events, frames, gap):
            problems.append(f"{host}: httpcheck doesn't show stream events/frames/gap: {labels(o)[:12]}")
            continue
        if events != "20, end 200":
            problems.append(f"{host}: stream events {events!r} (want '20, end 200')")
        if int(frames) < 60:
            problems.append(f"{host}: {frames} frames while 20 events trickled over 2 s (< 60)")
        if float(gap.split()[0]) > 250:
            problems.append(f"{host}: a {gap} gap between frames while streaming")
        if host == "web":
            vals = [json.loads(l[4:]) for l in o.splitlines() if l.startswith("JS: ")]
            cap = vals[-1] if vals else None
            if not cap or not cap[0].endswith("px") or abs(float(cap[0][:-2]) - 0.7 * cap[1]) > 2:
                problems.append(f"web: an unsized text field's max-width is {cap} (want 70vw of the window)")
        notes.append(f"{host} {frames} frames, gap {gap}")
    if problems:
        return False, "; ".join(problems)
    return True, ("tests/test_stream.mojo: 200 SSE events in order (one Event each, then the end), chunks, a trickle "
                  "arriving as sent, a drop, an idle timeout, cancel (server saw the client leave), refused, POST, a 500; "
                  "Transport.stream is the seam; while streaming: " + "; ".join(notes))


# ---------------------------------------------------------------------------------------------------------------------
# M1: the AG-UI client
# ---------------------------------------------------------------------------------------------------------------------

AGUI_TYPES = ["RUN_STARTED", "RUN_FINISHED", "RUN_ERROR", "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END",
              "TOOL_CALL_START", "TOOL_CALL_ARGS", "TOOL_CALL_END", "TOOL_CALL_RESULT", "STATE_SNAPSHOT", "STATE_DELTA",
              "MESSAGES_SNAPSHOT", "STEP_STARTED", "STEP_FINISHED", "CUSTOM"]
FIXTURES = ROOT / "tests" / "fixtures" / "agui"


def reference(events):
    """An independent reading of an AG-UI event list (this checker's, in Python): the conversation (messages with
    role, content, toolCalls, toolCallId) and the shared state (snapshots replace, deltas apply with the jsonpatch
    library), plus how the run ended."""
    import jsonpatch
    messages, state, ended, calls = [], None, None, {}

    def msg(mid):
        for m in messages:
            if m["id"] == mid:
                return m
        return None

    for e in events:
        t = e["type"]
        if t == "TEXT_MESSAGE_START":
            messages.append({"id": e["messageId"], "role": e.get("role", "assistant"), "content": ""})
        elif t == "TEXT_MESSAGE_CONTENT":
            msg(e["messageId"])["content"] += e["delta"]
        elif t == "TOOL_CALL_START":
            parent = e.get("parentMessageId")
            m = msg(parent) if parent else None
            if m is None:
                m = {"id": parent or e["toolCallId"], "role": "assistant", "content": ""}
                messages.append(m)
            call = {"id": e["toolCallId"], "type": "function", "function": {"name": e["toolCallName"], "arguments": ""}}
            m.setdefault("toolCalls", []).append(call)
            calls[e["toolCallId"]] = call
        elif t == "TOOL_CALL_ARGS":
            calls[e["toolCallId"]]["function"]["arguments"] += e["delta"]
        elif t == "TOOL_CALL_RESULT":
            messages.append({"id": e["messageId"], "role": "tool", "content": e["content"], "toolCallId": e["toolCallId"]})
        elif t == "STATE_SNAPSHOT":
            state = e["snapshot"]
        elif t == "STATE_DELTA":
            state = jsonpatch.apply_patch(state, e["delta"])
        elif t == "MESSAGES_SNAPSHOT":
            messages = [dict(m) for m in e["messages"]]
            calls = {c["id"]: c for m in messages for c in m.get("toolCalls", [])}
        elif t == "RUN_FINISHED":
            ended = "finished"
        elif t == "RUN_ERROR":
            ended = "error: " + e["message"]
    norm = []
    for m in messages:
        n = {"id": m["id"], "role": m["role"], "content": m.get("content") or ""}
        if m.get("toolCalls"):
            n["toolCalls"] = [{"id": c["id"], "name": c["function"]["name"], "arguments": c["function"]["arguments"]} for c in m["toolCalls"]]
        if m.get("toolCallId"):
            n["toolCallId"] = m["toolCallId"]
        norm.append(n)
    return norm, state, ended


def sse_events(text):
    out = []
    for block in text.split("\n\n"):
        data = "\n".join(l[5:].lstrip(" ") if l.startswith("data:") else "" for l in block.splitlines() if l.startswith("data:"))
        if data:
            out.append(json.loads(data))
    return out


def m1_patch():
    """JSON Patch exactly: RFC 6902's Appendix A and more, against the expected results and the jsonpatch library."""
    import jsonpatch
    problems = []
    cases = json.loads((ROOT / "tests/fixtures/jsonpatch/cases.json").read_text())
    names = {c.get("comment", "") for c in cases}
    rfc = [c for c in cases if c.get("comment", "").startswith("A.")]
    if len({c["comment"].split()[0] for c in rfc}) < 16:
        problems.append(f"the cases hold {len(rfc)} of RFC 6902's 16 Appendix A examples")
    exe, err = build_test("test_jsonpatch")
    if err:
        return [err], 0
    t = run([str(exe), str(ROOT / "tests/fixtures/jsonpatch/cases.json")], timeout=120)
    out = t.stdout + t.stderr
    if t.returncode != 0 or "test_jsonpatch: done" not in out:
        return [f"tests/test_jsonpatch.mojo fails: " + out[-600:]], 0
    got = {int(m.group(1)): m.group(2) for m in re.finditer(r"^CASE (\d+): (.*)$", out, re.M)}
    for i, c in enumerate(cases):
        if i not in got:
            problems.append(f"case {i} ({c.get('comment', '')}): no result")
            continue
        line = got[i]
        try:
            lib = jsonpatch.apply_patch(c["doc"], c["patch"] if "patch" in c else json.loads(c["patch_text"]))
            lib_err = None
        except Exception as e:
            lib, lib_err = None, e
        if "error" in c:  # must refuse, and leave the document as it was (atomic)
            if lib_err is None:
                problems.append(f"case {i}: the case says error, the jsonpatch library applies it")
            if not line.startswith("ERROR "):
                problems.append(f"case {i} ({c.get('comment', '')}): applied {line[:80]!r}, should refuse ({c['error']})")
            continue
        if line.startswith("ERROR "):
            problems.append(f"case {i} ({c.get('comment', '')}): refused ({line[6:80]}), should give {json.dumps(c['expected'])[:80]}")
            continue
        try:
            value = json.loads(line)
        except ValueError:
            problems.append(f"case {i}: not JSON: {line[:80]!r}")
            continue
        if value != c["expected"] or value != lib:
            problems.append(f"case {i} ({c.get('comment', '')}): {line[:80]} (want {json.dumps(c['expected'])[:80]})")
    k = keyed(out)
    if k.get("ATOMIC", [""])[0] != "ok":
        problems.append("the test didn't prove a failing patch leaves the document unchanged (ATOMIC: ok)")
    if k.get("BOUNDS", [""])[0] != "ok":  # (reviewer, D-717: copy bombs, deep adds, 1e999, binds on arrays)
        problems.append("the test didn't prove the document's bounds (BOUNDS: ok)")
    return problems, len(cases)


def m1():
    """GOAL.md M1: mojoui/agui.mojo runs an agent (POST RunAgentInput: thread, run, messages, state, tools), reads the AG-UI
    event stream (RUN_STARTED/FINISHED/ERROR, TEXT_MESSAGE_START/CONTENT/END, TOOL_CALL_START/ARGS/END/RESULT,
    STATE_SNAPSHOT, STATE_DELTA as JSON Patch, MESSAGES_SNAPSHOT, STEP_*, CUSTOM), keeps the conversation and the shared
    state, applies JSON Patch exactly (RFC 6902 tests), lets the app answer frontend tool calls; its own tests against
    recorded streams from the official AG-UI Python SDK."""
    import tempfile
    from ag_ui.core import RunAgentInput
    from pydantic import TypeAdapter
    from ag_ui.core import Event as AguiEvent
    problems = []
    for f in ("mojoui/agui.mojo", "mojoui/jsonpatch.mojo", "scripts/agui_agent.py", "tests/test_agui.mojo"):
        if not (ROOT / f).exists():
            problems.append(f"no {f}")
    if problems:
        return False, "; ".join(problems)
    p, ncases = m1_patch()
    problems += p
    # the recorded streams: made by the official SDK (regenerated now, byte for byte), every listed type among them
    with tempfile.TemporaryDirectory() as d:
        r = run([sys.executable, "scripts/agui_agent.py", "--record", d])
        if r.returncode != 0:
            return False, "scripts/agui_agent.py --record fails: " + (r.stdout + r.stderr)[-500:]
        fresh = {p.name: p.read_text() for p in Path(d).glob("*.sse")}
    kept = {p.name: p.read_text() for p in FIXTURES.glob("*.sse")}
    if not kept:
        return False, "no recorded streams in tests/fixtures/agui/"
    if fresh != kept:
        problems.append(f"tests/fixtures/agui/ isn't what the SDK records now: {sorted(set(fresh) ^ set(kept)) or [n for n in kept if fresh.get(n) != kept[n]]}")
    adapter = TypeAdapter(AguiEvent)
    seen_types = set()
    expected = {}
    for name, text in kept.items():
        evs = sse_events(text)
        for e in evs:
            adapter.validate_python(e)  # (each one an AG-UI event by the SDK's own models)
            seen_types.add(e["type"])
        expected[name] = reference(evs)
    missing = [t for t in AGUI_TYPES if t not in seen_types]
    if missing:
        problems.append(f"the recorded streams never send {missing}")
    # the Mojo client reads each recording (offline, through its own SSE reader) and live from the scripted agent
    exe, err = build_test("test_agui")
    if err:
        return False, "; ".join(problems + [err])
    import agui_agent
    with agui_agent.Server(scenario="tools", record=True) as srv:
        t = run([str(exe), str(FIXTURES)], env={"AGUI_TEST_URL": srv.url}, timeout=180)
        inputs = list(srv.inputs)
    out = t.stdout + t.stderr
    if t.returncode != 0 or "test_agui: all passed" not in out:
        return False, "; ".join(problems + ["tests/test_agui.mojo fails: " + out[-900:]])
    for name, (msgs, state, ended) in expected.items():
        got = {m.group(1): m.group(2) for m in re.finditer(r"^" + re.escape(name) + r" (MESSAGES|STATE|ENDED|TYPES): (.*)$", out, re.M)}
        if set(got) != {"MESSAGES", "STATE", "ENDED", "TYPES"}:
            problems.append(f"{name}: the test printed {sorted(got)} (want MESSAGES, STATE, ENDED, TYPES)")
            continue
        if json.loads(got["MESSAGES"]) != msgs:
            problems.append(f"{name}: the conversation differs: {got['MESSAGES'][:200]} vs {json.dumps(msgs)[:200]}")
        if json.loads(got["STATE"]) != state:
            problems.append(f"{name}: the state differs: {got['STATE'][:160]} vs {json.dumps(state)[:160]}")
        if got["ENDED"] != (ended or "open"):
            problems.append(f"{name}: ended {got['ENDED']!r}, want {ended!r}")
        want_types = {}
        for e in sse_events(kept[name]):
            want_types[e["type"]] = want_types.get(e["type"], 0) + 1
        if json.loads(got["TYPES"]) != want_types:
            problems.append(f"{name}: the client counted {got['TYPES']} events by type, the stream has {want_types}")
    # live: what the client POSTed is a RunAgentInput by the SDK's models (thread, run, messages, state, tools), and its
    # second run carries the app's answer to the frontend tool call as a tool message, plus the state it kept
    if len(inputs) < 2:
        problems.append(f"the scripted agent got {len(inputs)} runs (want the first, then the answer to its tool call)")
    else:
        try:
            first, second = (RunAgentInput.model_validate(i) for i in inputs[:2])
        except Exception as e:
            problems.append(f"the client's POST isn't a RunAgentInput: {e!r}"[:400])
        else:
            if not first.tools or not any(tl.name == "ask_user" for tl in first.tools):
                problems.append(f"the first run lists no frontend tool ask_user: {[tl.name for tl in first.tools or []]}")
            if first.thread_id != second.thread_id or first.run_id == second.run_id:
                problems.append("the second run isn't a new run in the same thread")
            tool_msgs = [m for m in second.messages if m.role == "tool"]
            calls = [c for m in second.messages if m.role == "assistant" for c in (m.tool_calls or [])]
            if not calls or not tool_msgs or tool_msgs[-1].tool_call_id != calls[-1].id:
                problems.append("the second run doesn't carry the assistant's tool call and the app's tool message answering it")
            elif "blue" not in tool_msgs[-1].content:
                problems.append(f"the tool message isn't the app's answer: {tool_msgs[-1].content!r}")
            if not isinstance(second.state, dict) or second.state.get("count") != 3:
                problems.append(f"the second run's state isn't the state the client kept (snapshot + deltas): {second.state!r}")
    k = keyed(out)
    if k.get("BOUNDS", [""])[0] != "ok":  # (reviewer, D-718: snapshots, forged roles, caps)
        problems.append("tests/test_agui.mojo didn't prove the client's bounds (BOUNDS: ok)")
    if not k.get("BUDGET", [""])[0].startswith("ok (trimmed "):  # (round 2, D-724: a 2 MB state through, a long chat trimmed)
        problems.append(f"tests/test_agui.mojo didn't prove the client's budget (BUDGET: {k.get('BUDGET')})")
    if k.get("LIVE", [""])[0] != "answered ask_user; agent said 'You picked blue.'":
        problems.append(f"LIVE: {k.get('LIVE')} (the live round trip)")
    if problems:
        return False, "; ".join(problems)
    return True, (f"JSON Patch: {ncases} cases (RFC 6902 Appendix A and more) agree with the expected results and the "
                  f"jsonpatch library, failures atomic; {len(kept)} streams recorded by the AG-UI SDK ({len(seen_types)} event "
                  "types) read into the same conversation and state as this checker's reference; live: RunAgentInput "
                  "valid by the SDK's models, a frontend tool call answered in the next run")


# ---------------------------------------------------------------------------------------------------------------------
# M2: generative UI
# ---------------------------------------------------------------------------------------------------------------------

def catalog_components():
    """Every component name the component catalog knows (docs/components.md's matrix)."""
    text = (ROOT / "docs/components.md").read_text()
    return set(re.findall(r"^\| `([A-Za-z]+)[ `]", text, re.M))  # ("`Meter (meter, usage bar, chart rows)`" too)


def m2_schema():
    """The schema: generated from the catalog (docs/genui.schema.json is what the generator prints now), a valid JSON
    Schema, naming only catalogued components; and the Mojo validator's verdicts agree with jsonschema's on every case."""
    import jsonschema
    problems = []
    exe, err = build_test("test_genui")
    if err:
        return [err], None
    t = run([str(exe), str(ROOT / "tests/fixtures/genui/cases.json")], timeout=120)
    out = t.stdout + t.stderr
    if t.returncode != 0 or "test_genui: done" not in out:
        return ["tests/test_genui.mojo fails: " + out[-700:]], None
    k = keyed(out)
    if k.get("SCREENS", [""])[0] != "ok":  # (reviewer item 6: screens capped, refusals told in JSON)
        problems.append("tests/test_genui.mojo didn't prove Screens (SCREENS: ok)")
    try:
        schema = json.loads(k["SCHEMA"][0])
    except Exception as e:
        return [f"the generator printed no SCHEMA JSON: {e!r}"], None
    kept = json.loads((ROOT / "docs/genui.schema.json").read_text())
    if kept != schema:
        problems.append("docs/genui.schema.json isn't what the generator prints now (regenerate it)")
    try:
        jsonschema.Draft202012Validator.check_schema(schema)
    except Exception as e:
        problems.append(f"not a valid JSON Schema: {e}"[:300])
    names = sorted(schema.get("$defs", {}).get("components", {}).keys()) or sorted(
        d.removeprefix("c_") for d in schema.get("$defs", {}) if d.startswith("c_"))
    known = catalog_components()
    if len(names) < 10:
        problems.append(f"the schema offers {len(names)} components (want the catalog's: Text, Card, Table, Sparkline, Button, TextField, Toggle, Segmented, Meter, Paragraph…)")
    for n in names:
        if n not in known:
            problems.append(f"the schema offers {n}, which isn't in the component catalog (docs/components.md)")
    for need in ("Text", "Card", "Table", "Button", "TextField", "Toggle", "Segmented", "Meter", "Paragraph"):
        if need not in names:
            problems.append(f"the schema has no {need}")
    if "Sparkline" not in names and "Chart" not in names:
        problems.append("the schema has no chart (Sparkline or Chart)")
    for banned in ("WebComponent", "WebFrame", "Canvas", "Clipboard", "Image"):
        if banned in names:
            problems.append(f"the schema offers {banned}: agent UI must be data drawn natively, never code, pages or pixels it brings")
    cases = json.loads((ROOT / "tests/fixtures/genui/cases.json").read_text())
    verdicts = {int(m.group(1)): m.group(2) for m in re.finditer(r"^CASE (\d+): (.*)$", out, re.M)}
    validator = jsonschema.Draft202012Validator(schema)
    kinds = set()
    for i, c in enumerate(cases):
        v = verdicts.get(i)
        if v is None:
            problems.append(f"case {i}: no verdict")
            continue
        schema_ok = validator.is_valid(c["ui"] if "ui" in c else json.loads(c["args_text"]))  # (args_text: exact bytes)
        if c["expect"] == "ok":
            if not v.startswith("OK "):
                problems.append(f"case {i} ({c['why']}): refused: {v[:160]}")
            if not schema_ok:
                problems.append(f"case {i} ({c['why']}): the schema refuses what the app accepts")
            elif v.startswith("OK ") and c.get("renders") and v[3:] != c["renders"]:
                problems.append(f"case {i} ({c['why']}): rendered {v[3:]!r}, want {c['renders']!r}")
        else:
            kinds.add(c["expect"])
            if not v.startswith("REFUSED "):
                problems.append(f"case {i} ({c['why']}): accepted, should be refused ({c['expect']})")
            elif c["expect"] not in v.lower():
                problems.append(f"case {i} ({c['why']}): refused without saying '{c['expect']}': {v[:160]}")
            if c.get("schema_refuses", True) and schema_ok:
                problems.append(f"case {i} ({c['why']}): the schema accepts what the app refuses")
    for need in ("unknown component", "bad prop", "too deep", "too big"):
        if need not in kinds:
            problems.append(f"no case for '{need}'")
    return problems, schema


def chat_run(host, scenario, steps, shot=None, log=None):
    """examples/agentchat on GTK or the web against the scripted agent: (output, the runs the agent got) or raises."""
    import agui_agent
    with agui_agent.Server(scenario=scenario, record=True) as srv:
        env_steps = f"type:Agent URL={srv.url};" + steps
        os.environ["AGUI_URL"] = srv.url  # (the app reads it at start; the test step sets it too)
        try:
            r, out = g5().gtk("agentchat", env_steps, shot=shot) if host == "gtk" else g5().web("agentchat", env_steps, shot=shot)
        finally:
            os.environ.pop("AGUI_URL", None)
        inputs = list(srv.inputs)
    if r is None:
        raise RuntimeError(f"{host}: {out[-700:]}")
    return out, inputs


def m2():
    """GOAL.md M2: the agent sends UI as data, never code: a frontend tool (render_ui) whose arguments are a view
    description built only from catalogued components (a JSON schema generated from the component catalog); the app
    validates it against the schema (unknown component, bad prop, too deep or too big → refused with a message to the
    agent) and renders it natively; a button in agent-built UI reports back to the agent as a tool result; shared state
    edited in the UI reaches the agent as state."""
    from ag_ui.core import RunAgentInput
    problems = []
    if not (ROOT / "mojoui/genui.mojo").exists():
        return False, "no mojoui/genui.mojo"
    gen = (ROOT / "mojoui/genui.mojo").read_text()
    for bad in ("WebComponent(", "WebFrame(", "external_call", "eval"):
        if bad in gen:
            problems.append(f"mojoui/genui.mojo uses {bad}: agent UI is data rendered by native components only")
    p, schema = m2_schema()
    problems += p
    if problems:
        return False, "; ".join(problems)
    app = (ROOT / "examples/agentchat/app.mojo").read_text() if (ROOT / "examples/agentchat/app.mojo").exists() else ""
    if not app:
        return False, "no examples/agentchat/app.mojo"
    if "from mojoui.genui import" not in app or "from mojoui.agui import" not in app:
        problems.append("agentchat doesn't compose mojoui.genui and mojoui.agui")
    err = build_example("agentchat", "linux", "web")
    if err:
        return False, err
    OUT.mkdir(parents=True, exist_ok=True)
    notes = []
    for host in ("gtk", "web"):
        # a form the agent builds: type into its field, flip its toggle, press its button
        steps = ("type:Message=Make me a signup form;tap:Send;pause:1500;"
                 "type:Your name=Ada;toggle:Subscribe;tap:Submit;pause:1500")
        try:
            out, inputs = chat_run(host, "ui", steps, shot=str(OUT / f"m2-form-{host}.png"))
        except RuntimeError as e:
            problems.append(str(e))
            continue
        ls = labels(out)
        if not any("Signup" in l for l in ls):
            problems.append(f"{host}: the agent's form (Card 'Signup') isn't on screen: {ls[:14]}")
        if not any("Thanks, Ada" in l for l in ls):
            problems.append(f"{host}: the agent's answer to the submit isn't on screen: {ls[-10:]}")
        runs = []
        for i in inputs:
            try:
                runs.append(RunAgentInput.model_validate(i))
            except Exception as e:
                problems.append(f"{host}: a POST isn't a RunAgentInput: {e!r}"[:300])
        if any(not r.tools or not any(t.name == "render_ui" for t in r.tools) for r in runs):
            problems.append(f"{host}: a run doesn't offer the render_ui frontend tool")
        else:
            params = next(t.parameters for t in runs[0].tools if t.name == "render_ui")
            if json.dumps(params, sort_keys=True).find('"$defs"') < 0 or params.get("properties", {}).get("ui") is None:
                problems.append(f"{host}: render_ui's parameters aren't the generated schema")
        answered = [m for r in runs for m in r.messages if m.role == "tool"]
        submit = [m for m in answered if '"action"' in m.content and "submit" in m.content]
        if not submit:
            problems.append(f"{host}: the Submit button never reached the agent as a tool result: {[m.content[:80] for m in answered]}")
        last = runs[-1].state if runs else None
        form = (last or {}).get("form", {}) if isinstance(last, dict) else {}
        if form.get("name") != "Ada" or form.get("subscribe") is not True:
            problems.append(f"{host}: the state the agent got after the edits is {last!r} (want form.name 'Ada', form.subscribe true)")
        # refused: the agent sends a component outside the catalog; the app says why, to the agent, and shows nothing of it
        try:
            out, inputs = chat_run(host, "bad", "type:Message=Try something odd;tap:Send;pause:1500", shot=str(OUT / f"m2-refused-{host}.png"))
        except RuntimeError as e:
            problems.append(str(e))
            continue
        tool_msgs = [m for i in inputs for m in RunAgentInput.model_validate(i).messages if m.role == "tool"]
        if not tool_msgs or "refused" not in tool_msgs[-1].content or "unknown component" not in tool_msgs[-1].content:
            problems.append(f"{host}: the agent wasn't told its UI was refused (unknown component): {[m.content[:120] for m in tool_msgs]}")
        if any(l.startswith("Script") or "EVIL" in l for l in labels(out)):
            problems.append(f"{host}: something of the refused UI is on screen")
        if not any("couldn't show" in l.lower() or "refused" in l.lower() for l in labels(out)):
            problems.append(f"{host}: the chat doesn't say the agent's UI was refused")
        notes.append(f"{host}: form built, edited, submitted; refused UI reported")
    # the web shows agent text as text: a <script> the agent writes into a Text adds no script element and runs nothing
    if not problems:
        try:
            out, _ = chat_run("web", "ui", "type:Message=Show some markup;tap:Send;pause:1500;"
                              "js:document.querySelectorAll('#mojoui-root script').length;js:window.__agui_pwned === undefined")
            vals = [json.loads(l[4:]) for l in out.splitlines() if l.startswith("JS: ")]
            if vals != [0, True] or not any("<script>" in l for l in labels(out)):
                problems.append(f"web: agent markup didn't stay text (JS {vals}; labels {labels(out)[-6:]})")
        except RuntimeError as e:
            problems.append(str(e))
    if problems:
        return False, "; ".join(problems)
    ncomp = len(schema.get("$defs", {}).get("components", {}))
    return True, (f"docs/genui.schema.json generated from the catalog ({ncomp} components), a valid JSON Schema whose verdicts "
                  "match the app's on every case (unknown component, bad prop, too deep, too big refused with a message); "
                  + "; ".join(notes) + "; agent markup stays text on the web")


# ---------------------------------------------------------------------------------------------------------------------
# M3: the chat app on the web and Linux
# ---------------------------------------------------------------------------------------------------------------------

def m3_live():
    """The live agent path, proved with a stand-in OpenAI-compatible server (the OMX Console's API shape): the key is read
    from the env var named, sent as a Bearer token, never logged; a model's broken tool-call JSON is repaired into a valid
    AG-UI stream (each event valid by the SDK's models)."""
    import secrets
    import fake_llm
    from pydantic import TypeAdapter
    from ag_ui.core import Event as AguiEvent
    import agui_agent
    problems = []
    token = "sk-test-" + secrets.token_hex(10)
    with fake_llm.Server() as llm:
        env = {"AGUI_LLM_BASE_URL": llm.url, "AGUI_LLM_MODEL": "qwen2.5-0.5b", "AGUI_LLM_KEY_VAR": "AGUI_TEST_KEY", "AGUI_TEST_KEY": token}
        r = run([sys.executable, "scripts/agui_agent.py", "--live", "--once", "Show me sales as a chart"], env=env, timeout=120)
        seen = list(llm.seen)
    out = r.stdout + r.stderr
    if r.returncode != 0:
        return [f"agui_agent.py --live --once fails: {out[-500:]}"]
    if token in out:
        problems.append("the live agent printed the key")
    if not seen or seen[0]["auth"] != "Bearer " + token:
        problems.append("the OpenAI-compatible server didn't get the key from $AGUI_TEST_KEY as a Bearer token")
    elif seen[0]["body"].get("model") != "qwen2.5-0.5b" or not seen[0]["body"].get("tools"):
        problems.append(f"the request named no model or offered no tools: {str(seen[0]['body'])[:200]}")
    evs = sse_events(out)
    adapter = TypeAdapter(AguiEvent)
    try:
        for e in evs:
            adapter.validate_python(e)
    except Exception as e:
        problems.append(f"the live agent's stream isn't AG-UI: {e!r}"[:300])
    args = "".join(e["delta"] for e in evs if e["type"] == "TOOL_CALL_ARGS")
    try:
        ui = json.loads(args)["ui"]
        if ui.get("component") not in ("Card", "Sparkline"):
            problems.append(f"the repaired render_ui isn't the model's chart: {args[:160]}")
    except Exception:
        problems.append(f"the model's broken tool JSON wasn't repaired: {args[:200]!r}")
    if not any(e["type"] == "TEXT_MESSAGE_CONTENT" for e in evs) or evs[-1]["type"] != "RUN_FINISHED":
        problems.append("the live stream has no words or doesn't finish")
    for f in ("docs/agui.md",):
        text = (ROOT / f).read_text() if (ROOT / f).exists() else ""
        for need in ("AGUI_LLM_BASE_URL", "11435", "MXC_API_KEY", "ANTHROPIC_API_KEY", "qwen"):
            if need not in text:
                problems.append(f"{f} doesn't say how to run the live demo ({need})")
    if "ANTHROPIC_API_KEY" in (ROOT / "scripts/agui_agent.py").read_text() and "os.environ[\"ANTHROPIC_API_KEY\"]" in (ROOT / "scripts/agui_agent.py").read_text():
        problems.append("agui_agent.py reads ANTHROPIC_API_KEY's value itself (leave it to the SDK, by name)")
    return problems


def m3():
    """GOAL.md M3: examples/agentchat: a chat panel; the agent streams its words, builds a chart or a form in the
    conversation, the user edits it and the agent sees the change; a scripted AG-UI agent (Python, official SDK,
    deterministic) makes the checks repeatable; a live agent (owner, 2026-10-27: OpenAI-compatible, the OMX Console by
    default, Claude optional) runs when configured by env var names (never stored or logged); on GTK and the web;
    screenshots."""
    problems = []
    agent = (ROOT / "scripts/agui_agent.py").read_text() if (ROOT / "scripts/agui_agent.py").exists() else ""
    if "from ag_ui" not in agent or "EventEncoder" not in agent:
        problems.append("the scripted agent doesn't use the official AG-UI SDK (ag_ui.core events, EventEncoder)")
    err = build_example("agentchat", "linux", "web")
    if err:
        return False, err
    OUT.mkdir(parents=True, exist_ok=True)
    notes = []
    for host in ("gtk", "web"):
        steps = ("type:Message=Hello there;tap:Send;pause:2500;"
                 "type:Message=Show me sales as a chart;tap:Send;pause:1500;"
                 "segment:0=Year;pause:1500")  # (the hosts' grammar: segment:<index>=<option>)
        if host == "web":  # (the composer, a field told to grow, fills its row: reviewer item 9, D-713)
            steps += (";js:[document.querySelector('input[placeholder=Message]').getBoundingClientRect().width, "
                      "document.querySelector('input[placeholder=Message]').parentElement.getBoundingClientRect().width, innerWidth]")
        try:
            out, inputs = chat_run(host, "chat", steps, shot=str(OUT / f"agentchat-{host}.png"))
        except RuntimeError as e:
            problems.append(str(e))
            continue
        ls = labels(out)
        greeting = "Hello! I'm a scripted AG-UI agent. My words arrive a few at a time."
        if greeting not in ls:
            problems.append(f"{host}: the streamed greeting isn't in the chat: {ls[:10]}")
        pieces = label_value(out, "streamed:")
        if pieces is None or int(pieces.split()[0]) < 8:
            problems.append(f"{host}: the words didn't arrive as a stream (streamed: {pieces!r}, want ≥ 8 pieces)")
        if not any(l.startswith("Sales") for l in ls):
            problems.append(f"{host}: the agent's chart card isn't in the conversation: {ls[-12:]}")
        if not any("Year" in l and "sales" in l.lower() for l in ls if "range" in l.lower() or "see" in l.lower()):
            problems.append(f"{host}: the agent didn't answer the edited range (state): {ls[-8:]}")
        if inputs and (inputs[-1].get("state") or {}).get("range") != "Year":
            problems.append(f"{host}: the agent's last run got state {inputs[-1].get('state')!r} (want range 'Year')")
        shot = OUT / f"agentchat-{host}.png"
        if not shot.exists() or time.time() - shot.stat().st_mtime > 600 or shot.stat().st_size < 20_000:
            problems.append(f"{host}: no fresh screenshot {shot.relative_to(ROOT)}")
        if host == "web":
            vals = [json.loads(l[4:]) for l in out.splitlines() if l.startswith("JS: ")]
            row = vals[-1] if vals else None
            if not row or row[0] < row[1] - 2 or row[0] < 0.7 * row[2]:
                problems.append(f"web: the composer doesn't fill its row (field, its box, window: {row})")
        notes.append(f"{host}: streamed {pieces}, chart built, range edit seen")
    problems += m3_live()
    t = run([sys.executable, "tests/test_agui_agent.py"], timeout=300)  # (reviewer item 4: only a local app starts a run)
    if t.returncode != 0 or "agui_agent: ok" not in t.stdout:
        problems.append("tests/test_agui_agent.py: " + (t.stdout + t.stderr)[-600:])
    th = (ROOT / "examples/agentchat/app.mojo").read_text()
    if "omxqua" not in th:
        problems.append("agentchat doesn't wear the omxqua theme")
    if problems:
        return False, "; ".join(problems)
    return True, ("; ".join(notes) + "; live agent: OpenAI-compatible (OMX Console shape), key by env var name, sent as "
                  "Bearer, never printed; broken tool JSON repaired into a valid AG-UI stream; shots docs/goals/35/agentchat-{gtk,web}.png")


# ---------------------------------------------------------------------------------------------------------------------
# M4: nothing regressed (minimal)
# ---------------------------------------------------------------------------------------------------------------------

def m4():
    """GOAL.md M4: goal 34b's M0, goal 34's M2 and goal 33's M1 pass."""
    o = old()
    problems = []
    for label, fn in [("34b-M0", o["g34b"].m0), ("34-M2", o["g34"].m2), ("33-M1", o["g33"].m1)]:
        ok, msg = fn()
        if not ok:
            problems.append(f"{label}: {msg}")
    return not problems, "; ".join(problems) or "goal 34b's M0, goal 34's M2 and goal 33's M1 pass"


def todo(what):
    def fn():
        return False, f"not built yet: {what}"
    return fn


MILESTONES = [
    ("M0", m0),
    ("M1", m1),
    ("M2", m2),
    ("M3", m3),
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
