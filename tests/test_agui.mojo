# mojoui.agui (goal 35 M1): the recorded streams in tests/fixtures/agui (made by the official AG-UI Python SDK through
# scripts/agui_agent.py --record) read offline, then a live round trip with the scripted agent:
#   AGUI_TEST_URL=http://127.0.0.1:PORT/ build/test_agui tests/fixtures/agui
# Prints "<file> MESSAGES|STATE|ENDED|TYPES: …" per recording and "LIVE: …"; scripts/check.py M1 compares them with its
# own reading of the same streams and validates what was POSTed with the SDK's models.
from std.sys import argv
from std.os import getenv, listdir
from std.testing import assert_equal, assert_true
from mojoui.app import App, Event, Runtime
from mojoui import View, Text
from mojoui.http import Http, Request
from mojoui.agui import Agent, Tool, EV_TOOL_END, EV_TEXT, EV_STREAM_END, EV_BAD, EV_STATE_REFUSED
from mojoui.clock import now_ns

comptime ASK = 1
comptime PIECE = 2
comptime END = 3


struct Live(App):
    comptime HTTP = True
    var http: Http
    var agent: Agent
    var ends: Int
    var texts: Int

    def __init__(out self):
        self.http = Http()
        self.agent = Agent(getenv("AGUI_TEST_URL"), PIECE, END, "t-live")
        self.agent.offer(Tool("ask_user", "Ask the user a question", '{"type":"object","properties":{"question":{"type":"string"}},"required":["question"]}'))
        self.ends = 0
        self.texts = 0

    def title(self) -> String:
        return "agui live"

    def update(mut self, e: Event):
        if e.message == ASK:
            self.agent.say("Ask me")
            _ = self.agent.run(self.http)
        elif e.message == PIECE or e.message == END:
            var what = self.agent.handle(e)
            if what == EV_TEXT:
                self.texts += 1
            if what == EV_STREAM_END:
                self.ends += 1

    def view(self) -> View:
        return Text(self.agent.last_text())

    def requests(mut self) -> List[Request]:
        return self.http.take()


def until_ends(mut rt: Runtime[Live], n: Int) raises:
    var deadline = now_ns() + 20_000_000_000
    while rt.app.ends < n and now_ns() < deadline:
        _ = rt.poll(now_ns() // 1000)
    assert_equal(rt.app.ends, n, "the run's stream ended")


def main() raises:
    var folder = String(argv()[1])
    var names = listdir(folder)
    sort(names)
    var read = 0
    for name in names:
        if not name.endswith(".sse"):
            continue
        var text: String
        with open(folder + "/" + name, "r") as f:
            text = f.read()
        var a = Agent("http://unused/", PIECE, END)
        var kinds = a.feed_sse(text)
        for k in kinds:
            assert_true(k != EV_BAD, name + ": every event is an AG-UI event")
            assert_true(k != EV_STATE_REFUSED, name + ": every delta applies: " + a.state_error)
        print(name + " MESSAGES: " + a.messages_json())
        print(name + " STATE: " + a.state.dump())
        print(name + " ENDED: " + a.ended)
        print(name + " TYPES: " + a.types_json())
        read += 1
    assert_true(read >= 4, "the recordings are there")
    # a delta that doesn't apply leaves the state as it was and says why
    var b = Agent("http://unused/", PIECE, END)
    _ = b.on_json('{"type":"STATE_SNAPSHOT","snapshot":{"n":1}}')
    assert_equal(b.on_json('{"type":"STATE_DELTA","delta":[{"op":"replace","path":"/n","value":2},{"op":"remove","path":"/missing"}]}'), EV_STATE_REFUSED)
    assert_equal(b.state.dump(), '{"n":1}')
    assert_equal(b.on_json("not json"), EV_BAD)
    assert_equal(b.on_json('{"no":"type"}'), EV_BAD)
    # live: a run, a frontend tool call answered by the app, the next run carries the answer and the state kept
    if getenv("AGUI_TEST_URL") != "":
        var rt = Runtime(Live())
        _ = rt.dispatch(ASK)
        until_ends(rt, 1)
        assert_equal(rt.app.agent.ended, "finished")
        assert_true(rt.app.texts >= 3, "the words came in pieces")
        assert_equal(rt.app.agent.state.dump(), '{"count":3,"items":["a","b"],"a/b":{"~":1}}')
        var calls = rt.app.agent.pending()
        assert_equal(len(calls), 1, "one frontend tool call to answer (lookup was the agent's own)")
        assert_equal(calls[0].name, "ask_user")
        rt.app.agent.answer(calls[0].id, '{"answer": "blue"}')
        assert_equal(len(rt.app.agent.pending()), 0)
        _ = rt.app.agent.run(rt.app.http)
        _ = rt.refresh()
        rt.take_effects()
        until_ends(rt, 2)
        assert_equal(rt.app.agent.ended, "finished")
        print("LIVE: answered ask_user; agent said '" + rt.app.agent.last_text() + "'")
    print("test_agui: all passed")
