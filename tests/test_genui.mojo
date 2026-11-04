# mojoui.genui (goal 35 M2): the schema generated from the catalog, and the validator's verdict on each case in
# tests/fixtures/genui/cases.json (scripts/check.py M2 compares them with jsonschema's on the same schema):
#   build/test_genui tests/fixtures/genui/cases.json
from std.sys import argv
from std.testing import assert_equal, assert_true
from mojoui.json import Json, json_string
from mojoui.jsonpatch import JDoc
from mojoui.genui import GenUi, schema, catalog, sample, ACT_STATE, ACT_ACTION, ACT_LOCAL, P_CHILDREN, P_TEXT, P_ENUM, P_WORD, P_POINTER
from mojoui.app import Event
from mojoui.agui import Agent, Tool
from mojoui.agentui import Screens, MAX_RETRIES
from mojoui.view import BUTTON, FIELD, TOGGLE


def main() raises:
    print("SCHEMA: " + schema())
    _ = Json.parse(schema())
    # goal 48 M0: every catalogued component renders from a sample node, and a bad prop on each is refused
    var blank = JDoc.parse('{"form": {}}')
    var specs = catalog()
    for ref s in specs:
        var ui = GenUi(sample(s.name), 10_000, 100)
        assert_equal(ui.problem, "", s.name + "'s sample is refused")
        var v = ui.view(blank, 0)
        assert_true(len(v.nodes) > 0, s.name + " renders nothing")
        print("render: " + s.name)
        var bad = sample(s.name).replace('{"component":"' + s.name + '"', '{"component":"' + s.name + '","nope":1')
        var refused = GenUi(bad, 10_000, 100)
        assert_true(refused.problem.find("bad prop") >= 0 and refused.problem.find("nope") >= 0, s.name + ": " + refused.problem)
        print("refuse: " + s.name)
        for ref p in s.props:  # (and a prop of the wrong type: the type check itself, not only unknown names)
            if p.kind == P_CHILDREN:
                continue
            var wrong = "12345" if (p.kind == P_TEXT or p.kind == P_ENUM or p.kind == P_WORD or p.kind == P_POINTER) else '"x"'
            var typed = GenUi('{"ui":{"component":"' + s.name + '","' + p.name + '":' + wrong + "}}", 10_000, 100)
            assert_true(typed.problem.find("bad prop") >= 0 and typed.problem.find(p.name) >= 0, s.name + "." + p.name + ": " + typed.problem)
            print("type: " + s.name + "." + p.name)
            break
    print("catalog: ok " + String(len(specs)))
    if len(argv()) < 2:
        return
    var text: String
    with open(String(argv()[1]), "r") as f:
        text = f.read()
    var cases = Json.parse(text)
    for i in range(cases.size(0)):
        var c = cases.at(0, i)
        var args: String
        if cases.get(c, "args_text") >= 0:
            args = cases.text(cases.get(c, "args_text"))  # (exact bytes, numbers JSON can't hold: as the agent sent them)
        else:
            var d = JDoc()
            d.root = d.take(cases, cases.get(c, "ui"))
            args = d.dump()
        var ui = GenUi(args, 10_000, 100)
        if ui.problem == "":
            print("CASE " + String(i) + ": OK " + ui.summary())
        else:
            print("CASE " + String(i) + ": REFUSED " + ui.problem)
    # rendering and handling: a form edits the state; its button reports its action
    var state = JDoc.parse('{"form": {"name": "", "subscribe": false}}')
    var form = GenUi('{"ui": {"component": "Card", "title": "Signup", "children": [{"component": "TextField", "placeholder": "Your name", "bind": "/form/name"}, {"component": "Toggle", "label": "Subscribe", "bind": "/form/subscribe"}, {"component": "Button", "label": "Submit", "action": "submit"}]}}', 10_000, 100)
    assert_equal(form.problem, "")
    var v = form.view(state, 0)
    var kinds = List[Int]()
    for n in v.nodes:
        if n.kind == FIELD or n.kind == TOGGLE or n.kind == BUTTON:
            kinds.append(n.kind)
            assert_true(form.owns(n.msg), "its controls send its messages")
    assert_equal(len(kinds), 3)
    var a = form.handle(Event(10_000, "Ada", 0), state)
    assert_equal(a.kind, ACT_STATE)
    var b = form.handle(Event(10_001, "", 1), state)
    assert_equal(b.kind, ACT_STATE)
    var s = form.handle(Event(10_002, "", 0), state)
    assert_equal(s.kind, ACT_ACTION)
    assert_equal(s.report(), '{"action":"submit"}')
    assert_equal(state.dump(), '{"form":{"name":"Ada","subscribe":true}}')
    # Screens (mojoui.agentui): an agent's render_ui calls shown, refused (told why, in JSON), and capped
    var agent = Agent("http://unused/", 1, 2)
    agent.offer(Tool("render_ui", "UI", schema()))
    var screens = Screens(20_000, 3000, 3)
    _ = agent.on_json('{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}')
    var good = String('{"ui":{"component":"Text","text":"hi"}}')
    var bad = String('{"ui":{"component":"Script","q":"\\"x"}}')
    for k in range(5):
        var id = "c" + String(k)
        _ = agent.on_json('{"type":"TOOL_CALL_START","toolCallId":"' + id + '","toolCallName":"render_ui","parentMessageId":"m1"}')
        _ = agent.on_json('{"type":"TOOL_CALL_ARGS","toolCallId":"' + id + '","delta":' + json_string(good if k != 1 else bad) + "}")
        _ = agent.on_json('{"type":"TOOL_CALL_END","toolCallId":"' + id + '"}')
        _ = screens.take(agent)
    assert_equal(len(screens.uis), 3, "no more screens than the cap")
    assert_equal(len(agent.pending()), 2, "the two shown screens nobody used wait for an action")
    var told = 0
    for ref m in agent.messages:
        if m.role == "tool":
            _ = Json.parse(m.content)  # (valid JSON, whatever the problem said)
            assert_true(m.content.find("refused") >= 0)
            told += 1
    assert_equal(told, 3, "the refused one and the two past the cap were told why")
    # an agent that keeps sending refused UI gets at most MAX_RETRIES reruns, then the app stops (round 2, D-725)
    var stubborn = Agent("http://unused/", 1, 2)
    stubborn.offer(Tool("render_ui", "UI", schema()))
    var tries = Screens(30_000, 4000, 40)
    _ = stubborn.on_json('{"type":"TEXT_MESSAGE_START","messageId":"s1","role":"assistant"}')
    var reruns = 0
    for k in range(6):
        var id = "b" + String(k)
        _ = stubborn.on_json('{"type":"TOOL_CALL_START","toolCallId":"' + id + '","toolCallName":"render_ui","parentMessageId":"s1"}')
        _ = stubborn.on_json('{"type":"TOOL_CALL_ARGS","toolCallId":"' + id + '","delta":' + json_string(bad) + "}")
        _ = stubborn.on_json('{"type":"TOOL_CALL_END","toolCallId":"' + id + '"}')
        if tries.take(stubborn):
            reruns += 1
    assert_equal(reruns, MAX_RETRIES, "three reruns, then no more")
    assert_true(tries.gave_up)
    tries.reset()
    assert_true(not tries.gave_up, "the user's next message starts again")
    print("SCREENS: ok")
    print("test_genui: done")
