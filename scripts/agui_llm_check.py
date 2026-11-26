"""goal 72 M3: the in-process LLM agent over AG-UI's HTTP/SSE transport, checked with the protocol's own Python SDK.

  scripts/mojo_flare.sh build tests/test_llmagent.mojo -o build/test_llmagent
  pixi run python scripts/agui_llm_check.py                     # starts build/test_llmagent --serve (its in-process cases first)
  pixi run python scripts/agui_llm_check.py --url http://127.0.0.1:PORT/    # against a server already running

Checks (each prints `sse <case>: ok ...`, exit 1 on the first failure):
  * the RunAgentInput is built and validated by ag_ui.core.RunAgentInput; every SSE `data:` line the endpoint sends parses
    with the SDK's Event models (a discriminated union over all 30 event types), in a valid order (RUN_STARTED first, one
    RUN_FINISHED or RUN_ERROR last, TEXT_MESSAGE_START/CONTENT/END and TOOL_CALL_START/ARGS/END/RESULT paired);
  * a question that needs a card: render_ui's arguments are JSON with a "ui" component, and words are spoken;
  * the app's buttons are its tools: "add milk" calls add-milk and the app says milk is on the list;
  * time to the first TEXT_MESSAGE_CONTENT through the endpoint (warm, median of 3) goes to build/g72/agent-bench.json
    beside the in-process number tests/test_llmagent.mojo wrote;
  * a foreign Origin is refused (403), a second run while one runs is a 409, and a client that leaves mid-run (barge-in:
    the connection closes) cancels it: the next run works.
"""

import argparse
import http.client
import json
import os
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

from ag_ui.core import Event, RunAgentInput, Tool, UserMessage
from pydantic import TypeAdapter

ROOT = Path(__file__).resolve().parent.parent
EVENT = TypeAdapter(Event)
BENCH = ROOT / "build" / "g72" / "agent-bench.json"


def fail(msg):
    print("FAIL:", msg)
    sys.exit(1)


def run_input(thread, run, text):
    inp = RunAgentInput(
        thread_id=thread, run_id=run, state={}, context=[], forwarded_props={},
        messages=[UserMessage(id="u-" + run, role="user", content=text)],
        tools=[Tool(name="render_ui", description="Show UI on screen", parameters={"type": "object", "properties": {"ui": {"type": "object"}}})],
    )
    return inp.model_dump_json(by_alias=True)


class Run:
    """One POST, its SSE stream read event by event: every event validated as it arrives."""

    def __init__(self, base, body, headers=None, abort_after_text=False):
        u = urllib.parse.urlparse(base)
        self.conn = http.client.HTTPConnection(u.hostname, u.port, timeout=120)
        h = {"Content-Type": "application/json", "Accept": "text/event-stream"}
        h.update(headers or {})
        self.t0 = time.perf_counter()
        self.conn.request("POST", u.path or "/", body=body, headers=h)
        self.resp = self.conn.getresponse()
        self.status = self.resp.status
        self.events = []
        self.first_text_ms = None
        self.first_event_ms = None
        self.text = ""
        if self.status != 200:
            self.error = self.resp.read().decode()
            return
        buf = ""
        while True:
            line = self.resp.fp.readline()
            if not line:
                break
            line = line.decode()
            if line.startswith("data: "):
                now = (time.perf_counter() - self.t0) * 1000
                ev = EVENT.validate_json(line[6:])  # raises unless the SDK accepts it
                self.events.append(ev)
                if self.first_event_ms is None:
                    self.first_event_ms = now
                t = ev.type.value
                if t == "TEXT_MESSAGE_CONTENT":
                    self.text += ev.delta
                    if self.first_text_ms is None:
                        self.first_text_ms = now
                        if abort_after_text:
                            self.conn.close()
                            return
                if t in ("RUN_FINISHED", "RUN_ERROR"):
                    break
        self.conn.close()

    def types(self):
        return [e.type.value for e in self.events]

    def check_order(self):
        ts = self.types()
        if not ts or ts[0] != "RUN_STARTED":
            fail("a run starts with RUN_STARTED: " + str(ts[:3]))
        if ts[-1] not in ("RUN_FINISHED", "RUN_ERROR") or sum(t in ("RUN_FINISHED", "RUN_ERROR") for t in ts) != 1:
            fail("one RUN_FINISHED or RUN_ERROR, last: " + str(ts[-3:]))
        text, calls = None, {}
        for e in self.events:
            t = e.type.value
            if t == "TEXT_MESSAGE_START":
                if text is not None:
                    fail("a text message opened inside another")
                text = e.message_id
            elif t == "TEXT_MESSAGE_CONTENT":
                if e.message_id != text:
                    fail("content outside its message")
            elif t == "TEXT_MESSAGE_END":
                if e.message_id != text:
                    fail("end of a message that isn't open")
                text = None
            elif t == "TOOL_CALL_START":
                calls[e.tool_call_id] = ["start", e.tool_call_name, ""]
            elif t == "TOOL_CALL_ARGS":
                c = calls[e.tool_call_id]
                if c[0] != "start":
                    fail("args out of order")
                c[2] += e.delta
            elif t == "TOOL_CALL_END":
                calls[e.tool_call_id][0] = "end"
            elif t == "TOOL_CALL_RESULT":
                if calls[e.tool_call_id][0] != "end":
                    fail("a result before the call ended")
                calls[e.tool_call_id].append(e.content)
        if text is not None:
            fail("a text message never ended")
        return calls


def median(xs):
    return sorted(xs)[len(xs) // 2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="")
    a = ap.parse_args()
    proc = None
    if a.url:
        base = a.url
    else:
        port_file = ROOT / "build" / "g72" / "agent-port"
        port_file.unlink(missing_ok=True)
        log = open(ROOT / "build" / "g72" / "agent-serve.log", "w")
        proc = subprocess.Popen([str(ROOT / "build" / "test_llmagent"), "--serve"], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        t0 = time.time()
        while not port_file.exists():
            if proc.poll() is not None:
                fail("build/test_llmagent exited (see build/g72/agent-serve.log)")
            if time.time() - t0 > 400:
                proc.kill()
                fail("the server never came up")
            time.sleep(0.5)
        time.sleep(0.3)
        base = "http://127.0.0.1:%s/" % port_file.read_text().strip()
    try:
        # 0. refused: a page from elsewhere may not start a run; a body that isn't JSON-typed
        r = Run(base, run_input("t0", "x0", "hi"), headers={"Origin": "http://evil.example"})
        if r.status != 403:
            fail("a foreign Origin must be a 403, got %s" % r.status)
        r = Run(base, run_input("t0", "x0", "hi"), headers={"Content-Type": "text/plain"})
        if r.status != 415:
            fail("a non-JSON content type must be a 415, got %s" % r.status)
        print("sse refused: ok (foreign Origin 403, text/plain 415)")

        # 1. a card: the SDK validates every event
        r = Run(base, run_input("thread-1", "run-1", "Compare Lisbon and Porto for a weekend trip: population, one famous food each. Show it as a card on screen and just say the gist."))
        if r.status != 200:
            fail("status %s %s" % (r.status, getattr(r, "error", "")))
        calls = r.check_order()
        uis = [c for c in calls.values() if c[1] == "render_ui"]
        if not uis:
            fail("no render_ui call; calls: %s, said: %s" % ([c[1] for c in calls.values()], r.text))
        ui = json.loads(uis[0][2])
        if "component" not in ui.get("ui", {}):
            fail("render_ui's arguments aren't a component: %s" % uis[0][2])
        if not r.text.strip() or len(r.text) > 400:
            fail("a short spoken line expected, got: %r" % r.text)
        if r.types()[-1] != "RUN_FINISHED":
            fail("the run ended with " + r.types()[-1])
        print("sse card: ok, %d events, all validate with ag_ui.core.Event | ui %s... | said: %s" % (len(r.events), uis[0][2][:60], r.text))

        # 2. the app's buttons are the tools
        r = Run(base, run_input("thread-1", "run-2", "Please add milk to my shopping list."))
        r.check_order()
        pressed = [c for c in r.check_order().values() if c[1] == "add-milk"]
        if not pressed or "milk" not in pressed[0][-1]:
            fail("add-milk wasn't pressed or the screen didn't change: %s said %s" % (pressed, r.text))
        print("sse buttons: ok | result %s | said: %s" % (pressed[0][-1], r.text))

        # 3. time to the first words through the endpoint (warm)
        times = []
        for k in range(3):
            r = Run(base, run_input("thread-ttft", "sse-ttft-%d" % k, "Say hello to me in one short sentence."))
            r.check_order()
            if r.first_text_ms is None:
                fail("no words: " + str(r.types()))
            times.append(r.first_text_ms)
        print("sse ttft: first TEXT_MESSAGE_CONTENT median %.1f ms (%s)" % (median(times), ", ".join("%.1f" % t for t in times)))

        # 4. barge-in: leave mid-run (the connection closes); the agent cancels; the next run works. A second run while one
        # runs is refused.
        slow_body = run_input("thread-1", "run-3", "Count from one to three hundred in words, separated by commas, nothing else.")
        u = urllib.parse.urlparse(base)
        busy = http.client.HTTPConnection(u.hostname, u.port, timeout=60)
        busy.request("POST", "/", body=slow_body, headers={"Content-Type": "application/json"})
        resp = busy.getresponse()
        got = b""
        while b"TEXT_MESSAGE_CONTENT" not in got:
            got += resp.fp.readline()
        r2 = Run(base, run_input("thread-1", "run-4", "hi"))
        if r2.status != 409:
            fail("a second run while one runs must be a 409, got %s" % r2.status)
        t_leave = time.perf_counter()
        busy.close()  # barge-in
        r3 = None
        for _ in range(200):
            r3 = Run(base, run_input("thread-1", "run-5", "What is the capital of France? One word."))
            if r3.status == 200:
                break
            time.sleep(0.02)
        if r3.status != 200:
            fail("after the client left the next run never started: %s" % r3.status)
        r3.check_order()
        if "Paris" not in r3.text:
            fail("the run after barge-in: %r" % r3.text)
        back_ms = (time.perf_counter() - t_leave) * 1000
        print("sse barge-in: ok, 409 while busy; the next run answered %r %.0f ms after the client left" % (r3.text, back_ms))

        bench = json.loads(BENCH.read_text()) if BENCH.exists() else {}
        bench["sse_first_text_ms"] = round(median(times), 1)
        bench["sse_runs_ms"] = [round(t, 1) for t in times]
        if "in_process_first_text_ms" in bench:
            bench["sse_overhead_ms"] = round(bench["sse_first_text_ms"] - bench["in_process_first_text_ms"], 1)
        bench["note"] = "time from the run's start (begin / POST) to the first TEXT_MESSAGE_CONTENT, warm prompt cache, median of 3; Qwen3.8-27B UD-Q4_K_M on GPU 1"
        BENCH.write_text(json.dumps(bench, indent=1) + "\n")
        print("sse: all checks passed;", json.dumps(bench))
    finally:
        if proc:
            proc.terminate()
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    main()
