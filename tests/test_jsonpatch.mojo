# mojoui.jsonpatch against tests/fixtures/jsonpatch/cases.json (RFC 6902 Appendix A and more; goal 35 M1):
#   build/test_jsonpatch tests/fixtures/jsonpatch/cases.json
# Prints "CASE i: <the document after>" or "CASE i: ERROR <why>"; scripts/check.py M1 compares each with the expected
# result and with the jsonpatch library's.
from std.sys import argv
from std.testing import assert_equal, assert_true
from mojoui.json import Json
from mojoui.jsonpatch import JDoc, MAX_DOC_BYTES


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
    # bounds (reviewer, D-717): a copy bomb, deep adds, a snapshot past the caps, non-finite numbers, binds on arrays
    var bomb = JDoc.parse('{"a": [1, 2, 3, 4, 5, 6, 7, 8]}')
    var refused = False
    var applied = 0
    for _ in range(40):
        try:
            bomb.patch('[{"op": "copy", "from": "/a", "path": "/a/-"}]')
            applied += 1
        except e:
            refused = String(e).find("too big") >= 0
            break
    assert_true(refused, "a copy bomb is refused")
    assert_true(applied < 20)
    assert_true(bomb.dump().byte_length() <= MAX_DOC_BYTES)
    var before_bomb = bomb.dump()
    try:
        bomb.patch('[{"op": "copy", "from": "/a", "path": "/a/-"}]')
    except:
        pass
    assert_equal(bomb.dump(), before_bomb, "refused atomically")
    var deep = JDoc.parse("{}")
    var deep_path = String("")
    var deep_refused = False
    for k in range(80):
        deep_path += "/d"
        try:
            deep.patch('[{"op": "add", "path": "' + deep_path + '", "value": {}}]')
        except e:
            deep_refused = String(e).find("too deep") >= 0
            break
    assert_true(deep_refused, "nesting past the cap is refused")
    var nested = String("")
    for _ in range(40):
        nested += "["
    for _ in range(40):
        nested += "]"
    var deep_snap = False
    try:
        _ = JDoc.parse(nested)
    except e:
        deep_snap = String(e).find("too deep") >= 0
    assert_true(deep_snap, "a document past the depth cap is refused when read")
    var inf = False
    try:
        _ = JDoc.parse('{"x": 1e999}')
    except e:
        inf = String(e).find("finite") >= 0
    assert_true(inf, "1e999 is refused, never dumped as inf")
    var huge = False
    try:
        _ = JDoc.parse('{"n": 123456789012345678901234567890}')
    except:
        huge = True
    assert_true(huge, "a whole number past Int is refused, not wrapped")
    var big_int = JDoc.parse('{"n": 1152921504606846976}')
    assert_true(big_int.dump().find(".") >= 0 or big_int.dump().find("e") >= 0, "a whole number past 2^53 is written as a decimal: " + big_int.dump())
    var arr = JDoc.parse('{"list": ["a", "b"]}')
    arr.set("/list/0", '"z"')
    assert_equal(arr.dump(), '{"list":["z","b"]}', "set replaces an array item")
    var dash = False
    try:
        arr.set("/list/-", '"y"')
    except:
        dash = True
    assert_true(dash, "set refuses -")
    var out_of_range = False
    try:
        arr.set("/list/5", '"y"')
    except:
        out_of_range = True
    assert_true(out_of_range, "set refuses an index past the end")
    assert_equal(arr.dump(), '{"list":["z","b"]}')
    # a refused set changes nothing: no parents made on the way (round 2, D-724)
    var keep = JDoc.parse('{"a": 1}')
    var deep_set = String("")
    for _ in range(40):
        deep_set += "/p"
    var set_refused = False
    try:
        keep.set(deep_set, "1")
    except:
        set_refused = True
    assert_true(set_refused)
    assert_equal(keep.dump(), '{"a":1}', "a refused set leaves the document as it was")
    print("BOUNDS: ok")
    print("test_jsonpatch: done")
