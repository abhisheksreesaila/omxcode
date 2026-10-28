# mojoui.webcomponent: a WebComponent's node (tag, id, props as JSON, on_event), how its props are written, what the
# diff makes of a change (props: a patch; another widget: built again), and the runtime's side of the seam: widget events
# reach update() with the widget's id, the event's name and its JSON payload; commands go out numbered and their replies
# come back as Events; nothing that isn't JSON (or a name that isn't a word) gets through.
from std.testing import assert_equal, assert_true, assert_false
from mojoui import App, Event, Runtime, View, VStack, Text, WEBCOMP, NO_MSG
from mojoui.diff import diff, SET_TEXT
from mojoui.json import Json
from mojoui.webcomponent import WebComponent, Props, Command, Widgets, is_widget_tag, is_event_name, commands_json, assets_json

comptime HEARD = 7
comptime ASK = 8
comptime GOT = 9
comptime ASK_BAD = 10


struct Probe(App):
    var heard: List[String]  # "id name payload" per widget event; "reply id name text|error" per reply
    var widgets: Widgets
    var label: String

    def __init__(out self):
        self.heard = List[String]()
        self.widgets = Widgets()
        self.label = "a"

    def title(self) -> String:
        return "probe"

    @staticmethod
    def web_assets() -> List[String]:
        return ["probe.js"]

    def update(mut self, event: Event):
        if event.message == HEARD:
            self.heard.append(String(event.id) + " " + event.name + " " + event.text)
            self.label = "b"
        elif event.message == ASK:
            self.widgets.call(Command("mx-probe", 3, "read", "{\"k\": 1}", reply=GOT).tagged(42))
            self.widgets.call(Command("mx-probe", 3, "focus"))  # (no answer wanted)
        elif event.message == ASK_BAD:
            self.widgets.call(Command("mx-probe", 3, "read", "{not json", reply=GOT))
        elif event.message == GOT:
            self.heard.append("reply " + String(event.id) + " " + event.name + " " + (event.text if event.error == "" else "error " + event.error))

    def commands(mut self) -> List[Command]:
        return self.widgets.take()

    def view(self) -> View:
        return VStack(WebComponent("mx-probe", Props().text("label", self.label), on_event=HEARD, id=3), Text(self.label))


def main() raises:
    # the node: tag in hint, id in value, props (JSON) in text, on_event in msg; its one child is the stand-in
    var p = Props().text("label", "say \"hi\"\n</script>").number("step", 2).real("half", 0.5).flag("on", True).raw("xs", "[1,2]")
    var j = Json.parse(p.json())  # (what the props say, read back)
    assert_equal(j.text(j.get(0, "label")), "say \"hi\"\n</script>")
    assert_equal(j.number(j.get(0, "step")), 2)
    assert_equal(j.real(j.get(0, "half")), 0.5)
    assert_true(j.flag(j.get(0, "on")))
    assert_equal(j.size(j.get(0, "xs")), 2)
    assert_equal(Props().real("x", Float64(0) / Float64(0)).json(), "{\"x\":null}")  # (NaN isn't JSON)
    assert_equal(Props().json(), "{}")
    var w = WebComponent("mx-counter", Props().number("step", 1), on_event=HEARD, id=5)
    assert_equal(w.nodes[0].kind, WEBCOMP)
    assert_equal(w.nodes[0].hint, "mx-counter")
    assert_equal(w.nodes[0].value, 5)
    assert_equal(w.nodes[0].text, "{\"step\":1}")
    assert_equal(w.nodes[0].msg, HEARD)
    assert_equal(len(w.nodes[0].children), 1)
    var standin = WebComponent("mx-counter", Props(), Text("Runs on the web"), on_event=HEARD, id=5)
    assert_equal(standin.nodes[standin.nodes[0].children[0]].text, "Runs on the web")

    # the diff: new props are a patch (the widget is kept); another id or tag is another widget
    var a = VStack(WebComponent("mx-counter", Props().number("step", 1), on_event=HEARD, id=5))
    var b = VStack(WebComponent("mx-counter", Props().number("step", 2), on_event=HEARD, id=5))
    var d = diff(a, b)
    assert_false(d.rebuild)
    assert_equal(len(d.patches), 1)
    assert_equal(d.patches[0].op, SET_TEXT)
    assert_equal(d.patches[0].text, "{\"step\":2}")
    assert_true(diff(a, VStack(WebComponent("mx-counter", Props().number("step", 1), on_event=HEARD, id=6))).rebuild)
    assert_true(diff(a, VStack(WebComponent("mx-other", Props().number("step", 1), on_event=HEARD, id=5))).rebuild)

    # names the hosts accept
    for ok in ["mx-counter", "mx-editor", "my-widget.v2", "a-b", "x-1_2"]:
        assert_true(is_widget_tag(ok), ok)
    for bad in ["counter", "Mx-counter", "1x-a", "mx counter", "mx-<b>", "script", "font-face", "annotation-xml", "-x", "", "mx-" + "a" * 70]:
        assert_false(is_widget_tag(bad), bad)
    for ok in ["click", "change", "selection:set", "a1", "on-key_up.x"]:
        assert_true(is_event_name(ok), ok)
    for bad in ["", "1click", "click()", "a b", "<x>", "a\"b", "x" * 65]:
        assert_false(is_event_name(bad), bad)

    # the runtime: a widget event reaches update() with the widget's id, the event's name and its JSON payload
    var rt = Runtime(Probe())
    assert_true(rt.accepts_widget_event(1, "click", "{\"count\":3}"))
    assert_false(rt.accepts_widget_event(1, "click", "{count: 3}"))  # (not JSON)
    assert_false(rt.accepts_widget_event(1, "click()", "{}"))  # (not a word)
    assert_false(rt.accepts_widget_event(0, "click", "{}"))  # (node 0 is the stack, not a widget)
    assert_false(rt.accepts_widget_event(99, "click", "{}"))
    var changed = rt.widget_event(1, "click", "{\"count\":3}")
    assert_equal(rt.app.heard[0], "3 click {\"count\":3}")
    assert_false(changed.rebuild)  # (the label and the widget's props changed: patches)
    var bad = rt.widget_event(1, "click", "not json")
    assert_equal(len(rt.app.heard), 1)
    assert_false(bad.rebuild)
    assert_equal(len(bad.patches), 0)

    # commands: numbered as they go out; the ones that want an answer wait for it; replies come back as Events
    _ = rt.dispatch(ASK)
    var out = rt.take_commands()
    assert_equal(len(out), 2)
    assert_equal(out[0].seq, 1)
    assert_equal(out[1].seq, 2)
    assert_equal(len(rt.take_commands()), 0)  # (taken once)
    assert_equal(commands_json(out), "[{\"seq\":1,\"tag\":\"mx-probe\",\"widget\":3,\"name\":\"read\",\"args\":{\"k\": 1}},"
                                     + "{\"seq\":2,\"tag\":\"mx-probe\",\"widget\":3,\"name\":\"focus\",\"args\":null}]")
    assert_true(rt.knows_reply(1))
    assert_false(rt.knows_reply(2))  # (no answer wanted)
    assert_false(rt.knows_reply(7))
    _ = rt.reply(1, "{\"count\":4}", "")
    assert_equal(rt.app.heard[1], "reply 42 read {\"count\":4}")
    assert_false(rt.knows_reply(1))  # (answered once)
    _ = rt.reply(1, "{\"count\":5}", "")  # a second answer to the same command: nothing happens
    assert_equal(len(rt.app.heard), 2)
    _ = rt.dispatch(ASK)
    var again = rt.take_commands()
    _ = rt.reply(again[0].seq, "{oops", "")  # an answer that isn't JSON arrives as an error
    assert_equal(rt.app.heard[2], "reply 42 read error the widget's reply isn't JSON")
    _ = rt.dispatch(ASK)
    var failing = rt.take_commands()
    _ = rt.reply(failing[0].seq, "", "no widget mx-probe#3 on the page")
    assert_equal(rt.app.heard[3], "reply 42 read error no widget mx-probe#3 on the page")
    # a command whose args aren't JSON never goes out: its answer is an error at the next poll
    _ = rt.dispatch(ASK_BAD)
    assert_equal(len(rt.take_commands()), 0)
    _ = rt.poll(0)
    assert_equal(rt.app.heard[4], "reply 0 read error the command's args aren't JSON")

    # Command.json splices args in as they are, so Json.parse must refuse anything after the value (review, D-623)
    for spliced in ["{} , \"name\": \"x\"", "null}", "1 2", "{\"k\": 1}}", "[1]]"]:
        var refused = False
        try:
            _ = Json.parse(spliced)
        except:
            refused = True
        assert_true(refused, spliced)
    assert_equal(assets_json(Probe.web_assets()), "[\"probe.js\"]")

    # an agent's set (goal 34b): the built-in command mojoui.set {field, value}, only for a widget on the screen, a word
    # for a field and JSON for a value; numbered like the app's commands, no answer wanted
    var art = Runtime(Probe())
    _ = art.take_commands()
    assert_true(art.set_widget("mx-probe", 3, "label", "\"hi \\\"there\\\"\""))
    var sets = art.take_commands()
    assert_equal(len(sets), 1)
    assert_equal(sets[0].name, "mojoui.set")
    assert_equal(sets[0].reply, NO_MSG)
    var sj = Json.parse(sets[0].json())
    assert_equal(sj.text(sj.get(0, "tag")), "mx-probe")
    var args = sj.get(0, "args")
    assert_equal(sj.text(sj.get(args, "field")), "label")
    assert_equal(sj.text(sj.get(args, "value")), "hi \"there\"")
    assert_true(sets[0].seq > 0)
    assert_true(art.set_widget("mx-probe", 3, "count", "42"))
    assert_true(art.take_commands()[0].seq > sets[0].seq)  # (seq only grows)
    assert_false(art.set_widget("mx-probe", 4, "label", "1"))  # not on the screen
    assert_false(art.set_widget("mx-other", 3, "label", "1"))
    assert_false(art.set_widget("Probe", 3, "label", "1"))  # not a custom element's name
    assert_false(art.set_widget("mx-probe", 3, "x\"}", "1"))  # not a word
    assert_false(art.set_widget("mx-probe", 3, "label", "1, \"field\": \"innerHTML\""))  # not one JSON value
    assert_false(art.set_widget("mx-probe", 3, "label", "alert(1)"))
    assert_equal(len(art.take_commands()), 0)
    print("webcomponent: ok")
