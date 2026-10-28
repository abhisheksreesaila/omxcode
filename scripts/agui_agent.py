"""An AG-UI agent backend for mojoui (goal 35): the protocol's own Python SDK (ag_ui.core events, ag_ui.encoder's
EventEncoder) over HTTP, server-sent events back.

  pixi run python scripts/agui_agent.py --serve [--port 8765] [--scenario chat]   # the scripted agent (deterministic)
  pixi run python scripts/agui_agent.py --serve --live                           # a live model (see below)
  pixi run python scripts/agui_agent.py --record DIR                             # the recorded streams (tests/fixtures/agui)
  pixi run python scripts/agui_agent.py --live --once "Show me sales as a chart"  # one live run, printed as SSE

Scripted scenarios (every check uses them): "tools" (state snapshot + delta, a frontend tool call ask_user, answered in
the next run), "ui" (a signup form built with render_ui; its Submit comes back as the tool result), "bad" (UI outside
the catalog: the app refuses it and says why), "chat" (streamed words, a chart whose range the user edits).

Live (owner, 2026-10-27, D-710): one OpenAI-compatible path. By default the OMX Console (mxconsole) on this machine:
  AGUI_LLM_BASE_URL   http://127.0.0.1:11435/v1   (the console's OpenAI-compatible endpoint)
  AGUI_LLM_MODEL      qwen2.5-0.5b                 (any model the console serves: `mxc serve <model>`)
  AGUI_LLM_KEY_VAR    MXC_API_KEY                  (the NAME of the env var holding the key; sent as a Bearer token)
Claude: AGUI_LLM_PROVIDER=anthropic uses the Anthropic SDK's plain Messages API, which reads ANTHROPIC_API_KEY itself
(model claude-opus-5-5, or AGUI_LLM_MODEL). NOT RUN: no key here; the OpenAI-compatible path is the one the checks prove.
No key is ever printed, logged or stored, and a request carrying one never follows a redirect. The model's tool-call
JSON is repaired before it reaches the app (small models break it); the app still validates everything.

Only a local app may start a run (D-722): a JSON content type, a localhost Host on this port, no foreign Origin, a body
of at most 1 MB with its Content-Length. RunAgentInputs are kept (Server.inputs) only when a test asks (record=True).
"""

import json
import os
import re
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ag_ui.core import (
    CustomEvent, EventType, MessagesSnapshotEvent, RawEvent, RunAgentInput, RunErrorEvent, RunFinishedEvent,
    RunStartedEvent, StateDeltaEvent, StateSnapshotEvent, StepFinishedEvent, StepStartedEvent, TextMessageContentEvent,
    TextMessageEndEvent, TextMessageStartEvent, ToolCallArgsEvent, ToolCallEndEvent, ToolCallResultEvent,
    ToolCallStartEvent,
)
from ag_ui.core import AssistantMessage, ToolMessage, UserMessage, ToolCall, FunctionCall
from ag_ui.encoder import EventEncoder

ENC = EventEncoder()
MAX_BODY = 1024 * 1024  # a RunAgentInput's bytes (D-722)
LOCAL_HOSTS = ("127.0.0.1", "localhost", "[::1]")
GREETING = "Hello! I'm a scripted AG-UI agent. My words arrive a few at a time."
QUARTER = [12, 15, 14, 18, 21, 19, 24, 26, 25, 29, 31, 34]
YEAR = [120, 132, 128, 150, 171, 165, 190, 204, 199, 230, 248, 270]


class Run:
    """Events for one run, with the delay before each (ms): ids come from the run's id, so streams are repeatable."""

    def __init__(self, inp):
        self.inp = inp
        self.out = []
        self.k = 0

    def id(self, what):
        self.k += 1
        return f"{self.inp.run_id}-{what}{self.k}"

    def add(self, event, delay=0):
        self.out.append((event, delay))

    def start(self):
        self.add(RunStartedEvent(thread_id=self.inp.thread_id, run_id=self.inp.run_id))

    def finish(self):
        self.add(RunFinishedEvent(thread_id=self.inp.thread_id, run_id=self.inp.run_id))

    def say(self, text, pieces=None, delay=0):
        mid = self.id("m")
        self.add(TextMessageStartEvent(message_id=mid, role="assistant"))
        for p in pieces or [text]:
            self.add(TextMessageContentEvent(message_id=mid, delta=p), delay)
        self.add(TextMessageEndEvent(message_id=mid))
        return mid

    def call(self, name, args, parent=None, chunks=1):
        cid = self.id("call")
        self.add(ToolCallStartEvent(tool_call_id=cid, tool_call_name=name, parent_message_id=parent))
        text = json.dumps(args)
        step = max(1, len(text) // chunks + 1)
        for i in range(0, len(text), step):
            self.add(ToolCallArgsEvent(tool_call_id=cid, delta=text[i:i + step]))
        self.add(ToolCallEndEvent(tool_call_id=cid))
        return cid


def words(text):
    """`text` in pieces of one word (with its space), as a model streams it."""
    return re.findall(r"\S+\s*", text)


def last_user(inp):
    for m in reversed(inp.messages):
        if m.role == "user":
            return m.content if isinstance(m.content, str) else " ".join(getattr(p, "text", "") for p in m.content)
    return ""


def last_tool(inp):
    """The newest message if it's a tool result (the app answered a frontend tool), else None."""
    return inp.messages[-1] if inp.messages and inp.messages[-1].role == "tool" else None


def state(inp):
    return inp.state if isinstance(inp.state, dict) else {}


# ---- the UI an agent sends: data built from the catalog's components (docs/genui.schema.json) ----

def form_ui():
    return {"component": "Card", "title": "Signup", "children": [
        {"component": "Text", "text": "Tell us who you are.", "style": "caption"},
        {"component": "TextField", "placeholder": "Your name", "bind": "/form/name"},
        {"component": "Toggle", "label": "Subscribe", "bind": "/form/subscribe"},
        {"component": "Button", "label": "Submit", "action": "submit", "style": "prominent"},
    ]}


def chart_ui():
    return {"component": "Card", "title": "Sales", "children": [
        {"component": "Segmented", "options": ["Quarter", "Year"], "bind": "/range", "action": "range"},
        {"component": "Sparkline", "bind": "/sales", "label": "Sales, in thousands"},
        {"component": "Table", "columns": ["Range", "Total"], "rows": [["Quarter", sum(QUARTER)], ["Year", sum(YEAR)]]},
    ]}


def scenario_tools(inp, r):
    tool = last_tool(inp)
    if tool is not None:
        answer = json.loads(tool.content).get("answer", "?") if tool.content.startswith("{") else tool.content
        r.say(f"You picked {answer}.", pieces=words(f"You picked {answer}."))
        return
    r.add(StateSnapshotEvent(snapshot={"count": 1, "items": ["a"], "a/b": {"~": 0}}))
    r.add(StateDeltaEvent(delta=[{"op": "replace", "path": "/count", "value": 3}, {"op": "add", "path": "/items/-", "value": "b"},
                                 {"op": "replace", "path": "/a~1b/~0", "value": 1}]))
    r.add(StepStartedEvent(step_name="lookup"))
    look = r.call("lookup", {"q": "colours"})  # a backend tool: its result is in the stream
    r.add(ToolCallResultEvent(message_id=r.id("t"), tool_call_id=look, content='["red","blue"]', role="tool"))
    r.add(StepFinishedEvent(step_name="lookup"))
    mid = r.say("Let me ask you.", pieces=["Let me ", "ask ", "you."])
    r.call("ask_user", {"question": "Which colour?", "options": ["red", "blue"]}, parent=mid, chunks=3)


def scenario_ui(inp, r):
    tool = last_tool(inp)
    if tool is not None:
        try:
            got = json.loads(tool.content)
        except ValueError:
            got = {}
        if got.get("action") == "submit":
            form = state(inp).get("form", {})
            text = f"Thanks, {form.get('name') or 'friend'}!" + (" You're subscribed." if form.get("subscribe") else "")
            r.say(text, pieces=words(text))
        else:
            r.say("Noted.")
        return
    said = last_user(inp).lower()
    if "markup" in said:
        mid = r.say("Here is some markup, shown as text:")
        r.call("render_ui", {"ui": {"component": "Card", "title": "Markup", "children": [
            {"component": "Text", "text": "<script>window.__agui_pwned = 1</script> <b>stays text</b>"},
            {"component": "Paragraph", "text": "<img src=x onerror=\"window.__agui_pwned = 2\"> is words too."}]}}, parent=mid)
        return
    r.add(StateSnapshotEvent(snapshot={"form": {"name": "", "subscribe": False}}))
    mid = r.say("Here is a form.", pieces=["Here is ", "a form."])
    r.call("render_ui", {"ui": form_ui()}, parent=mid, chunks=4)


def scenario_bad(inp, r):
    tool = last_tool(inp)
    if tool is not None:
        r.say("Sorry, I couldn't show that.")
        return
    mid = r.say("Let me try something.")
    r.call("render_ui", {"ui": {"component": "Card", "title": "Odd", "children": [
        {"component": "Text", "text": "fine so far"}, {"component": "Script", "code": "EVIL()"}]}}, parent=mid)


def scenario_chat(inp, r):
    tool = last_tool(inp)
    if tool is not None:
        try:
            got = json.loads(tool.content)
        except ValueError:
            got = {}
        rng = state(inp).get("range", "Quarter")
        if got.get("action") == "range":
            series = YEAR if rng == "Year" else QUARTER
            r.add(StateDeltaEvent(delta=[{"op": "replace", "path": "/sales", "value": series}]))
            text = f"I see you picked {rng}: sales were {sum(series)}k over the {rng.lower()}."
            r.say(text, pieces=words(text), delay=40)
        else:
            r.say("Okay.")
        return
    said = last_user(inp).lower()
    if "chart" in said or "sales" in said:
        r.add(StateSnapshotEvent(snapshot={"range": "Quarter", "sales": QUARTER}))
        mid = r.say("Here are this quarter's sales.", pieces=words("Here are this quarter's sales."), delay=30)
        r.call("render_ui", {"ui": chart_ui()}, parent=mid, chunks=5)
        return
    if said.startswith("hello") or said.startswith("hi"):
        r.add(StepStartedEvent(step_name="greet"))
        r.say(GREETING, pieces=words(GREETING), delay=60)
        r.add(StepFinishedEvent(step_name="greet"))
        r.add(CustomEvent(name="mood", value={"cheerful": True}))
        return
    text = "I can show a chart or a form: ask me for one."
    r.say(text, pieces=words(text), delay=30)


SCENARIOS = {"tools": scenario_tools, "ui": scenario_ui, "bad": scenario_bad, "chat": scenario_chat}


def scripted(inp, scenario):
    r = Run(inp)
    r.start()
    SCENARIOS[scenario](inp, r)
    r.finish()
    return r.out


# ---- live: an OpenAI-compatible chat API (the OMX Console by default), or Claude ----

CATALOG_HINT = """You build small user interfaces by calling the tool render_ui with {"ui": <node>}.
A node is a JSON object with "component" and that component's fields:
- Card: title, children (a list of nodes)
- VStack, HStack: children
- Text: text, style ("body", "title", "headline" or "caption")
- Paragraph: text
- Table: columns (list of strings), rows (list of lists of strings or numbers)
- Sparkline: values (list of numbers) or bind (a state path like "/sales"), label
- Meter: label, value (0-100), figure
- Button: label, action (one word, reported back to you), style ("plain" or "prominent")
- TextField: placeholder, bind (a state path like "/form/name")
- Toggle: label, bind
- Segmented: options (2-8 strings), bind, action
- Divider
Use only these components and fields. No HTML, no code: text is shown as text. Keep it small (a Card with a few children).
When the user asks for a chart, call render_ui with a Card holding a Sparkline. Otherwise answer in one or two short sentences."""

NAMES = {"card": "Card", "vstack": "VStack", "column": "VStack", "hstack": "HStack", "row": "HStack", "text": "Text",
         "label": "Text", "paragraph": "Paragraph", "table": "Table", "sparkline": "Sparkline", "chart": "Sparkline",
         "linechart": "Sparkline", "line": "Sparkline", "meter": "Meter", "progress": "Meter", "button": "Button",
         "textfield": "TextField", "input": "TextField", "toggle": "Toggle", "switch": "Toggle", "segmented": "Segmented",
         "divider": "Divider"}
ALIASES = {"Text": {"content": "text", "value": "text", "label": "text"}, "Sparkline": {"data": "values", "points": "values", "title": "label"},
           "Button": {"text": "label", "title": "label"}, "Card": {"items": "children", "name": "title", "label": "title"},
           "Meter": {"percent": "value"}}


def loose_json(raw):
    """A JSON object from a model's attempt: code fences and chatter stripped, trailing commas, single quotes and
    Python literals fixed. None when nothing can be read."""
    if not raw:
        return None
    s = raw.strip()
    s = re.sub(r"^```[a-zA-Z]*\s*|\s*```$", "", s)
    a, b = s.find("{"), s.rfind("}")
    if a < 0 or b < a:
        return None
    s = s[a:b + 1]
    for attempt in range(3):
        try:
            v = json.loads(s)
            return v if isinstance(v, dict) else None
        except ValueError:
            if attempt == 0:
                s = re.sub(r",\s*([}\]])", r"\1", s)
                s = re.sub(r"\bTrue\b", "true", re.sub(r"\bFalse\b", "false", re.sub(r"\bNone\b", "null", s)))
            elif attempt == 1 and '"' not in s:
                s = s.replace("'", '"')
            elif attempt == 1:
                s = re.sub(r"'([^'\"]*)'", r'"\1"', s)
    return None


def repair_node(n, depth=0):
    """A model's node with the catalog's names (case, common synonyms) and fields (aliases); unknown things are left for
    the app to refuse with a message."""
    if not isinstance(n, dict) or depth > 12:
        return n
    out = dict(n)
    comp = out.get("component") or out.get("type") or out.get("kind")
    out.pop("type", None)
    out.pop("kind", None)
    if isinstance(comp, str):
        out["component"] = NAMES.get(comp.replace("_", "").replace("-", "").lower(), comp)
    for old, new in ALIASES.get(out.get("component"), {}).items():
        if old in out and new not in out:
            out[new] = out.pop(old)
    if isinstance(out.get("children"), list):
        out["children"] = [repair_node(c, depth + 1) for c in out["children"]]
    return out


def repair_ui_args(raw):
    """render_ui's arguments from a model: {"ui": node}, or None. A bare node is wrapped."""
    v = loose_json(raw)
    if v is None:
        return None
    if "ui" not in v and ("component" in v or "type" in v):
        v = {"ui": v}
    if isinstance(v.get("ui"), str):
        v["ui"] = loose_json(v["ui"])
    if not isinstance(v.get("ui"), dict):
        return None
    return {"ui": repair_node(v["ui"])}


def chat_messages(inp):
    """RunAgentInput's conversation as OpenAI chat messages (with the state the user sees)."""
    out = [{"role": "system", "content": CATALOG_HINT + "\nThe shared state now: " + json.dumps(inp.state)[:2000]}]
    for m in inp.messages:
        if m.role == "user":
            out.append({"role": "user", "content": m.content if isinstance(m.content, str) else str(m.content)})
        elif m.role == "assistant":
            msg = {"role": "assistant", "content": m.content or ""}
            if m.tool_calls:
                msg["tool_calls"] = [{"id": c.id, "type": "function", "function": {"name": c.function.name, "arguments": c.function.arguments}} for c in m.tool_calls]
            out.append(msg)
        elif m.role == "tool":
            out.append({"role": "tool", "tool_call_id": m.tool_call_id, "content": m.content})
    return out


def small_tools(inp):
    """The frontend tools as the model sees them: render_ui's parameters kept small (the components are in the system
    prompt; the app validates the full schema)."""
    tools = []
    for t in inp.tools or []:
        params = t.parameters
        if t.name == "render_ui":
            params = {"type": "object", "properties": {"ui": {"type": "object", "description": "a node: {\"component\": ..., fields}"}}, "required": ["ui"]}
        tools.append({"type": "function", "function": {"name": t.name, "description": t.description, "parameters": params}})
    return tools


def sse_lines(resp):
    for raw in resp:
        line = raw.decode("utf-8", "replace").strip()
        if line.startswith("data:"):
            data = line[5:].strip()
            if data == "[DONE]":
                return
            try:
                yield json.loads(data)
            except ValueError:
                continue


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # (a 3xx becomes an error: the run ends with RUN_ERROR)


def live_openai(inp, r):
    base = os.environ.get("AGUI_LLM_BASE_URL", "http://127.0.0.1:11435/v1").rstrip("/")
    model = os.environ.get("AGUI_LLM_MODEL", "qwen2.5-0.5b")
    key = os.environ.get(os.environ.get("AGUI_LLM_KEY_VAR", "MXC_API_KEY"), "")
    body = {"model": model, "messages": chat_messages(inp), "stream": True, "temperature": 0.2}
    tools = small_tools(inp)
    if tools:
        body["tools"] = tools
    req = urllib.request.Request(base + "/chat/completions", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Accept": "text/event-stream",
                                          **({"Authorization": "Bearer " + key} if key else {})})
    mid, text, calls = None, "", {}
    with urllib.request.build_opener(NoRedirect).open(req, timeout=120) as resp:  # (the key never follows a redirect)
        for chunk in sse_lines(resp):
            for choice in chunk.get("choices", []):
                d = choice.get("delta") or {}
                if d.get("content"):
                    if mid is None:
                        mid = r.id("m")
                        r.add(TextMessageStartEvent(message_id=mid, role="assistant"))
                    text += d["content"]
                    r.add(TextMessageContentEvent(message_id=mid, delta=d["content"]))
                for tc in d.get("tool_calls") or []:
                    c = calls.setdefault(tc.get("index", 0), {"id": tc.get("id"), "name": "", "args": ""})
                    c["id"] = c["id"] or tc.get("id")
                    fn = tc.get("function") or {}
                    c["name"] += fn.get("name") or ""
                    c["args"] += fn.get("arguments") or ""
    if mid is not None:
        r.add(TextMessageEndEvent(message_id=mid))
    if not calls and "component" in text:  # (a model that wrote the UI into its words instead of calling the tool)
        calls[0] = {"id": None, "name": "render_ui", "args": text}
    for c in calls.values():
        emit_call(r, c["name"] or "render_ui", c["args"], mid)


def emit_call(r, name, args, parent):
    if name == "render_ui":
        fixed = repair_ui_args(args)
        args = json.dumps(fixed) if fixed is not None else args  # (unrepairable: the app refuses it and says why)
    else:
        v = loose_json(args)
        args = json.dumps(v) if v is not None else args
    cid = r.id("call")
    r.add(ToolCallStartEvent(tool_call_id=cid, tool_call_name=name, parent_message_id=parent))
    r.add(ToolCallArgsEvent(tool_call_id=cid, delta=args))
    r.add(ToolCallEndEvent(tool_call_id=cid))


def live_anthropic(inp, r):
    import anthropic
    client = anthropic.Anthropic()  # (the SDK reads ANTHROPIC_API_KEY itself)
    model = os.environ.get("AGUI_LLM_MODEL", "claude-opus-5-5")
    msgs = chat_messages(inp)
    system = msgs[0]["content"]
    convo = []
    for m in msgs[1:]:
        if m["role"] == "tool":
            convo.append({"role": "user", "content": [{"type": "tool_result", "tool_use_id": m["tool_call_id"], "content": m["content"]}]})
        elif m["role"] == "assistant" and m.get("tool_calls"):
            blocks = ([{"type": "text", "text": m["content"]}] if m["content"] else []) + [
                {"type": "tool_use", "id": c["id"], "name": c["function"]["name"], "input": loose_json(c["function"]["arguments"]) or {}} for c in m["tool_calls"]]
            convo.append({"role": "assistant", "content": blocks})
        else:
            convo.append({"role": m["role"], "content": m["content"] or "…"})
    tools = [{"name": t["function"]["name"], "description": t["function"]["description"], "input_schema": t["function"]["parameters"]} for t in small_tools(inp)]
    mid = None
    with client.messages.stream(model=model, max_tokens=16000, system=system, messages=convo, tools=tools) as stream:  # (NOT RUN: no key here)
        for event in stream:
            if event.type == "text":
                if mid is None:
                    mid = r.id("m")
                    r.add(TextMessageStartEvent(message_id=mid, role="assistant"))
                r.add(TextMessageContentEvent(message_id=mid, delta=event.text))
        final = stream.get_final_message()
    if mid is not None:
        r.add(TextMessageEndEvent(message_id=mid))
    if final.stop_reason == "refusal":
        raise RuntimeError("the model declined this request")
    for block in final.content:
        if block.type == "tool_use":
            emit_call(r, block.name, json.dumps(block.input), mid)


def live(inp):
    r = Run(inp)
    r.start()
    try:
        if os.environ.get("AGUI_LLM_PROVIDER", "openai") == "anthropic":
            live_anthropic(inp, r)
        else:
            live_openai(inp, r)
    except Exception as e:  # (never the key: errors name the endpoint and the failure)
        r.add(RunErrorEvent(message=f"the model couldn't answer: {type(e).__name__}: {str(e)[:200]}"))
        return r.out
    r.finish()
    return r.out


# ---- serving ----

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def refuse(self, status, why):
        msg = why.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(msg)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(msg)
        self.close_connection = True

    def local(self):
        """Why this request may not start a run ("" when it may): only a local app, never a web page."""
        if self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/json":
            return 415, "a run is a JSON POST (Content-Type: application/json)"
        port = self.server.server_address[1]
        if self.headers.get("Host", "") not in tuple(f"{h}:{port}" for h in LOCAL_HOSTS):
            return 403, "only this machine's apps may start a run (Host)"
        origin = self.headers.get("Origin")
        if origin is not None:
            from urllib.parse import urlparse
            o = urlparse(origin)
            if o.scheme not in ("http", "https") or (o.hostname or "") not in ("127.0.0.1", "localhost", "::1"):
                return 403, "only this machine's apps may start a run (Origin)"
        n = self.headers.get("Content-Length")
        if n is None:
            return 411, "a run needs its Content-Length"
        if not n.isdigit():
            return 400, "a bad Content-Length"
        if int(n) > MAX_BODY:
            return 413, "a RunAgentInput of more than 1 MB"
        return 0, ""

    def do_POST(self):
        status, why = self.local()
        if status:
            self.refuse(status, why)
            return
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        try:
            body = json.loads(raw)
            inp = RunAgentInput.model_validate(body)
        except Exception as e:
            msg = f"not a RunAgentInput: {e}"[:600].encode()
            self.send_response(422)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            return
        if self.server.record:
            self.server.inputs.append(body)
        events = live(inp) if self.server.scenario == "live" else scripted(inp, self.server.scenario)
        self.send_response(200)
        self.send_header("Content-Type", ENC.get_content_type())
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            for event, delay in events:
                if delay:
                    time.sleep(delay / 1000)
                b = ENC.encode(event).encode()
                self.wfile.write(f"{len(b):X}\r\n".encode() + b + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except OSError:
            self.close_connection = True


class Server:
    """The agent on a free port in a thread (`url` ends with '/'); with record=True (tests) `inputs` keeps every
    RunAgentInput it got, as sent."""

    def __init__(self, scenario="chat", port=0, record=False):
        self.httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.httpd.daemon_threads = True
        self.httpd.inputs = []
        self.httpd.record = record
        self.httpd.scenario = scenario
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}/"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    @property
    def inputs(self):
        return self.httpd.inputs

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()


def record(folder):
    """The recorded streams tests/test_agui.mojo reads: what this agent sends for fixed inputs, byte for byte."""
    def inp(run, messages, tools=None, st=None):
        return RunAgentInput(thread_id="t-rec", run_id=run, state=st, messages=messages, tools=tools or [], context=[], forwarded_props=None)

    def write(name, events):
        with open(os.path.join(folder, name), "w") as f:
            f.write("".join(ENC.encode(e) for e, _ in events))

    hello = [UserMessage(id="u1", role="user", content="Hello there")]
    write("chat.sse", scripted(inp("r-chat", hello), "chat"))
    write("tools.sse", scripted(inp("r-tools", [UserMessage(id="u1", role="user", content="Ask me")]), "tools"))
    write("ui.sse", scripted(inp("r-ui", [UserMessage(id="u1", role="user", content="Make me a signup form")]), "ui"))
    # a messages snapshot (the agent restores a conversation), then more words; and a run that fails midway
    r = Run(inp("r-snap", hello))
    r.start()
    r.add(MessagesSnapshotEvent(messages=[
        UserMessage(id="u1", role="user", content="What's 2+2?"),
        AssistantMessage(id="a1", role="assistant", content="Let me check.", tool_calls=[ToolCall(id="c1", type="function", function=FunctionCall(name="add", arguments='{"a":2,"b":2}'))]),
        ToolMessage(id="t1", role="tool", content="4", tool_call_id="c1"),
    ]))
    r.say("It's 4.", pieces=["It's ", "4."])
    r.add(RawEvent(event={"vendor": "example", "note": "a raw event, passed through"}, source="example"))
    r.finish()
    write("snapshot.sse", r.out)
    r = Run(inp("r-err", hello))
    r.start()
    mid = r.id("m")
    r.add(TextMessageStartEvent(message_id=mid, role="assistant"))
    r.add(TextMessageContentEvent(message_id=mid, delta="Working on "))
    r.add(RunErrorEvent(message="the model ran out of time", code="timeout"))
    write("error.sse", r.out)


def main(argv):
    if "--record" in argv:
        record(argv[argv.index("--record") + 1])
        return
    if "--once" in argv:
        prompt = argv[argv.index("--once") + 1]
        from ag_ui.core import Tool
        schema_path = os.path.join(os.path.dirname(__file__), "..", "docs", "genui.schema.json")
        params = json.load(open(schema_path)) if os.path.exists(schema_path) else {"type": "object"}
        i = RunAgentInput(thread_id="t-once", run_id="r-once", state={}, messages=[UserMessage(id="u1", role="user", content=prompt)],
                          tools=[Tool(name="render_ui", description="Show UI built from catalogued components", parameters=params)],
                          context=[], forwarded_props=None)
        for e, _ in live(i):
            sys.stdout.write(ENC.encode(e))
        return
    port = int(argv[argv.index("--port") + 1]) if "--port" in argv else 8765
    scenario = "live" if "--live" in argv else (argv[argv.index("--scenario") + 1] if "--scenario" in argv else "chat")
    srv = Server(scenario, port)
    with srv:
        print(f"AG-UI agent ({scenario}) at {srv.url}", flush=True)
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main(sys.argv[1:])
