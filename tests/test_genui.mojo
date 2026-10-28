# mojoui.genui (goal 35 M2): the schema generated from the catalog, and the validator's verdict on each case in
# tests/fixtures/genui/cases.json (scripts/check.py M2 compares them with jsonschema's on the same schema):
#   build/test_genui tests/fixtures/genui/cases.json
from std.sys import argv
from std.testing import assert_equal, assert_true
from mojoui.json import Json
from mojoui.jsonpatch import JDoc
from mojoui.genui import GenUi, schema, catalog, ACT_STATE, ACT_ACTION
from mojoui.app import Event
from mojoui.view import BUTTON, FIELD, TOGGLE


def main() raises:
    print("SCHEMA: " + schema())
    _ = Json.parse(schema())
    var text: String
    with open(String(argv()[1]), "r") as f:
        text = f.read()
    var cases = Json.parse(text)
    for i in range(cases.size(0)):
        var c = cases.at(0, i)
        var d = JDoc()
        d.root = d.take(cases, cases.get(c, "ui"))
        var ui = GenUi(d.dump(), 10_000, 100)
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
    print("test_genui: done")
