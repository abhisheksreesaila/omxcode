# Goal 48 M5 (a, b): an agent in the app's own process, and a dataset the agent names but never sends.
# (a) a Mojo agent (LocalAgent) answers a run with > 2,000 AG-UI events (words, shared state, a dashboard streamed as
#     render_ui's arguments a few bytes at a time); the chat reads them with the handler a network stream uses.
# (b) a million rows held by the app as an MX frame sheet: a DataGrid and a ChartView name the dataset; the chart's
#     numbers come from MX frame's group-by (the GPU when there is one) and equal a plain loop's.
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_true
from mojoui.json import json_string
from mojoui.agui import LocalAgent, EV_TOOL_END
from mojoui.agentchat import AgentChat
from mojoui.sheethub import SheetHub
from mojoui.sheet import Sheet
from mojoui.canvas import Surface
from themes.omxqua import omxqua
from omxcore import Table, TEXT, DECIMAL, INT

comptime ROWS = 1_000_000


struct Dashboard(LocalAgent):
    """A scripted agent in Mojo: what a model would stream, as events."""

    var runs: Int

    def __init__(out self):
        self.runs = 0

    def respond(mut self, input: String) -> List[String]:
        self.runs += 1
        var ev = List[String]()
        ev.append('{"type":"RUN_STARTED","threadId":"t","runId":"r' + String(self.runs) + '"}')
        ev.append('{"type":"STATE_SNAPSHOT","snapshot":{"progress":0,"trend":[]}}')
        ev.append('{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}')
        for k in range(300):
            ev.append('{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"word' + String(k) + ' "}')
        ev.append('{"type":"TEXT_MESSAGE_END","messageId":"m1"}')
        for k in range(200):
            ev.append('{"type":"STATE_DELTA","delta":[{"op":"replace","path":"/progress","value":' + String(k) + '},{"op":"add","path":"/trend/-","value":' + String(k % 17) + "}]}")
        var ui = String('{"ui":{"component":"VStack","children":[{"component":"Text","text":"Orders, live","style":"title"},')
        ui += '{"component":"Grid","columns":4,"children":['
        for k in range(8):
            ui += ("," if k > 0 else "") + '{"component":"KpiView","label":"Metric ' + String(k) + '","value":"' + String(k * 1234) + '","note":"+' + String(k) + '%","spark":[1,2,3,' + String(k) + "]}"
        ui += ']},{"component":"Grid","columns":2,"children":['
        for k in range(6):
            ui += ("," if k > 0 else "") + '{"component":"Meter","label":"Gauge ' + String(k) + '","value":' + String(10 + k * 12) + "}"
        ui += ']},{"component":"ChartView","kind":"bar","title":"Revenue by region (1M rows)","dataset":"orders","group_by":"region","value":"revenue","combine":"sum"},'
        ui += '{"component":"DataGrid","title":"Every order","dataset":"orders","height":300},'
        ui += '{"component":"Sparkline","bind":"/trend","label":"live"},'
        for k in range(12):
            ui += '{"component":"Text","text":"note ' + String(k) + ': ' + String("lorem ipsum dolor sit amet ") * 3 + '"},'
        ui += '{"component":"Button","label":"Export","action":"export"}]}}'
        ev.append('{"type":"TOOL_CALL_START","toolCallId":"u1","toolCallName":"render_ui","parentMessageId":"m1"}')
        var b = ui.byte_length()
        var at = 0
        while at < b:
            var end = min(at + 2, b)
            ev.append('{"type":"TOOL_CALL_ARGS","toolCallId":"u1","delta":' + json_string(String(ui[byte = at : end])) + "}")
            at = end
        ev.append('{"type":"TOOL_CALL_END","toolCallId":"u1"}')
        ev.append('{"type":"RUN_FINISHED","threadId":"t","runId":"r' + String(self.runs) + '"}')
        return ev^


def orders(mut truth: List[Float64]) raises -> Sheet:
    """A million orders: region (5 words), units, revenue (cents); `truth`: the revenue per region by a plain loop."""
    var t = Table.empty()
    var region = t.add_column("region", TEXT)
    var units = t.add_column("units", INT)
    var revenue = t.add_column("revenue", DECIMAL, 2)
    var names: List[String] = ["North", "South", "East", "West", "Central"]
    var codes = List[Int]()
    for nm in names:
        codes.append(t.add_word(region, nm))
    var x: UInt64 = 88172645463325252
    for _ in range(ROWS):
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        var r = Int(x % 5)
        var cents = Int((x >> 8) % 50_000)
        t.append(region, Int64(codes[r]))
        t.append(units, Int64(Int((x >> 20) % 9) + 1))
        t.append(revenue, Int64(cents))
        truth[r] += Float64(cents) / 100.0
    return Sheet(t^.share(), True)


def main() raises:
    # (b) first: the dataset
    var t0 = perf_counter_ns()
    var truth = List[Float64](length=5, fill=0.0)
    var sheet = orders(truth)
    var build_ms = Float64(perf_counter_ns() - t0) / 1e6
    var chat = AgentChat[SheetHub]("http://unused/", base=20_000, canvas_base=2000)
    var hub = SheetHub()
    hub.add("orders", sheet^)
    chat.set_hub(hub^)
    assert_true(chat.agent.input_json().find('\\"rows\\":1000000') >= 0, "the agent hears of the dataset (its rows count) in the run's context")
    # (a) an agent in this process: > 2,000 events through the chat's handler
    var agent = Dashboard()
    var events = agent.respond("{}")
    var n = len(events)
    assert_true(n >= 2000, "the agent streams more than 2,000 events (" + String(n) + ")")
    var t1 = perf_counter_ns()
    chat.send("Show me the orders")  # (queues an HTTP request nobody sends: the run below is local)
    chat.agent.running = False
    chat.run_local(agent)
    var feed_ms = Float64(perf_counter_ns() - t1) / 1e6
    assert_equal(chat.agent.ended, "finished")
    assert_equal(len(chat.screens.uis), 1)
    var ui_problem = chat.screens.uis[0].problem
    assert_equal(ui_problem, "", "the dataset screen is shown")
    assert_true(chat.agent.state.dump().find('"progress":199') >= 0, "every state delta applied")
    var t2 = perf_counter_ns()
    var v = chat.view()
    var view_ms = Float64(perf_counter_ns() - t2) / 1e6
    assert_true(len(v.nodes) > 50)
    print("local: ok " + String(n) + " events in " + String(Int(feed_ms)) + " ms (" + String(Int(Float64(n) / (feed_ms / 1000.0))) + " events/s; previews rebuilt when a component finishes or 64 bytes arrive); the whole chat's view in " + String(Int(view_ms * 1000)) + " µs; no HTTP, no other language")
    # (b) the chart's numbers are MX frame's group-by, equal to the loop's; the grid draws a million rows' first screen
    ref ui = chat.screens.uis[0]
    var chart_k = -1
    for k in range(len(ui.kinds)):
        if ui.kinds[k] == 1:  # CV_CHART
            chart_k = k
    assert_true(chart_k >= 0)
    ref ch = ui.charts[chart_k]
    assert_equal(len(ch.labels), 5)
    for k in range(5):
        var want = 0.0
        var names: List[String] = ["North", "South", "East", "West", "Central"]
        for j in range(5):
            if names[j] == ch.labels[k]:
                want = truth[j]
        assert_true(abs(ch.values[k] - want) < 0.01, ch.labels[k] + ": " + String(ch.values[k]) + " vs " + String(want))
    var th = omxqua(False)
    var buf = List[UInt32](length=900 * 300, fill=0)
    var s = Surface(Int(buf.unsafe_ptr()), 900, 300, 1.0)
    var t3 = perf_counter_ns()
    var cv_count = len(chat.screens.uis[0].canvases)
    for k in range(cv_count):
        chat.draw(2000 + k, s, th.palette)
    var draw_ms = Float64(perf_counter_ns() - t3) / 1e6
    _ = buf^
    print("dataref: ok " + String(ROWS) + " rows held by the app (built in " + String(Int(build_ms)) + " ms), none sent; chart by region: "
          + chat.screens.uis[0].notes[chart_k] + ", equal to a plain loop; " + String(cv_count) + " canvases drawn in " + String(Int(draw_ms)) + " ms")
    print("test_local_agent: done")
