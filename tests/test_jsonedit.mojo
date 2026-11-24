# mojoui.jsonedit: a patched document differs where it was patched and nowhere else: unknown keys, order, spelling of
# numbers, spaces, escapes, duplicate keys stay byte for byte; what comes out parses. `jsonedit: ok`.
from std.testing import assert_true, assert_equal
from mojoui.json import Json
from mojoui.jsonedit import members, elements, patched, patched_in, member_text, part, Change


def main() raises:
    var t = String('{ "a" : 1.50e2 ,"b":"x\\"y,}{", "u\\u0041":[1,{"k":"]"}],\n  "n" : null, "o":{"p":{"q":[ ]}} }')
    var ms = members(t, 0, t.byte_length())
    assert_equal(len(ms), 5)
    assert_equal(ms[2].key, "uA")
    assert_equal(part(t, ms[0].start, ms[0].end), "1.50e2")
    assert_equal(part(t, ms[1].start, ms[1].end), '"x\\"y,}{"')
    assert_equal(len(elements(t, ms[2].start, ms[2].end)), 2)
    assert_equal(patched(t, List[Change]()), t)
    assert_equal(patched(t, [Change("n", "true")]), t.replace("null", "true"))
    assert_equal(patched(t, [Change("a", "7")]), t.replace("1.50e2", "7"))
    assert_equal(patched('{"a":1}', [Change("z", '"w"')]), '{"a":1,"z":"w"}')
    assert_equal(patched("{}", [Change("z", "1"), Change("y", "2")]), '{"z":1,"y":2}')
    assert_equal(patched("{ }", [Change("z", "1")]), '{"z":1 }')
    assert_equal(patched('{"a":1,"b":2,"c":3}', [Change("b", "")]), '{"a":1,"c":3}')
    assert_equal(patched('{"a":1,"b":2,"c":3}', [Change("a", "")]), '{"b":2,"c":3}')
    assert_equal(patched('{"a":1,"b":2,"c":3}', [Change("c", "")]), '{"a":1,"b":2}')
    assert_equal(patched('{"a":1,"b":2,"c":3}', [Change("a", ""), Change("c", ""), Change("d", "4")]), '{"b":2,"d":4}')
    assert_equal(patched('{"a":1}', [Change("a", "")]), "{}")
    assert_equal(patched('{"a":1}', [Change("a", ""), Change("b", "5")]), '{"b":5}')
    assert_equal(patched('{"a":1}', [Change("nope", "")]), '{"a":1}')
    assert_equal(patched('{"a":1,"a":2}', [Change("a", "9")]), '{"a":1,"a":9}')  # (readers take the last)
    assert_equal(patched_in('{"pn":{"x":1,"keep":[1 , 2]},"y":0}', "pn", [Change("x", "5")]), '{"pn":{"x":5,"keep":[1 , 2]},"y":0}')
    assert_equal(patched_in('{"y":0}', "pn", [Change("x", "5")]), '{"y":0,"pn":{"x":5}}')
    assert_equal(patched_in('{"pn":null}', "pn", [Change("x", "5")]), '{"pn":{"x":5}}')
    assert_equal(member_text('{"a":{"b":1}}', "a"), '{"b":1}')
    assert_equal(member_text('{"a":1}', "b"), "")
    for bad in ["", "[1]", '{"a":1', '{"a"1}', '{"a":}', '{a:1}', '{"a":"x}']:
        var raised = False
        try:
            _ = patched(String(bad), [Change("q", "1")])
        except:
            raised = True
        assert_true(raised, "not an object: " + String(bad))
    # every member of a generated object changed, taken out, or left, one at a time: the rest is the same text
    var big = String("{")
    for i in range(40):
        big += ("" if i == 0 else ", ") + '"k' + String(i) + '" :' + ["1", '"s,\\\\\\""', "[1,2 ]", '{"a":{}}', "-0.0", "1e-9", "false"][i % 7]
    big += "}"
    for i in range(40):
        var k = "k" + String(i)
        var one = patched(big, [Change(k, "12345")])
        var j = Json.parse(one)
        assert_equal(j.number(j.get(0, k)), 12345)
        assert_equal(patched(one, [Change(k, member_text(big, k))]), big, "back again: the very text")
        var out = patched(big, [Change(k, "")])
        var jo = Json.parse(out)
        assert_equal(jo.size(0), 39)
        assert_equal(jo.get(0, k), -1)
    print("jsonedit: ok")
