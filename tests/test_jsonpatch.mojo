# mojoui.jsonpatch against tests/fixtures/jsonpatch/cases.json (RFC 6902 Appendix A and more; goal 35 M1):
#   build/test_jsonpatch tests/fixtures/jsonpatch/cases.json
# Prints "CASE i: <the document after>" or "CASE i: ERROR <why>"; scripts/check.py M1 compares each with the expected
# result and with the jsonpatch library's.
from std.sys import argv
from std.testing import assert_equal, assert_true
from mojoui.json import Json
from mojoui.jsonpatch import JDoc


def main() raises:
    var path = String(argv()[1])
    var text: String
    with open(path, "r") as f:
        text = f.read()
    var cases = Json.parse(text)
    for i in range(cases.size(0)):
        var c = cases.at(0, i)
        var doc = JDoc()
        doc.root = doc.take(cases, cases.get(c, "doc"))
        var patch: String
        if cases.get(c, "patch_text") >= 0:
            patch = cases.text(cases.get(c, "patch_text"))
        else:
            var p = JDoc()
            p.root = p.take(cases, cases.get(c, "patch"))
            patch = p.dump()
        var before = doc.dump()
        try:
            doc.patch(patch)
            print("CASE " + String(i) + ": " + doc.dump())
        except e:
            assert_equal(doc.dump(), before, "a failed patch changes nothing")
            print("CASE " + String(i) + ": ERROR " + String(e))
    # atomic: the first op would apply, the second fails: the document is as it was
    var d = JDoc.parse('{"a": 1, "list": [1, 2]}')
    var failed = False
    try:
        d.patch('[{"op": "add", "path": "/list/-", "value": 3}, {"op": "replace", "path": "/a", "value": 2}, {"op": "remove", "path": "/nope"}]')
    except:
        failed = True
    assert_true(failed)
    assert_equal(d.dump(), '{"a":1,"list":[1,2]}')
    # set (an app's edit), find, read back; many patches stay small (compact)
    d.set("/form/name", '"Ada"')
    d.set("/form/subscribe", "true")
    assert_equal(d.text_at("/form/name"), "Ada")
    assert_true(d.flag_at("/form/subscribe"))
    for k in range(500):
        d.patch('[{"op": "replace", "path": "/a", "value": ' + String(k) + "}]")
    assert_true(len(d.kinds) < 200, "compacted")
    assert_equal(d.dump(), '{"a":499,"list":[1,2],"form":{"name":"Ada","subscribe":true}}')
    print("ATOMIC: ok")
    print("test_jsonpatch: done")
