# mojoui.json: the reader and the writer round-trip what the .omx metadata holds.
#   pixi run mojo run -I . tests/test_json.mojo
from std.testing import assert_equal, assert_true, assert_false
from mojoui.json import Json, json_string, J_ARRAY, J_OBJECT, c_locale
from std.ffi import external_call


def main() raises:
    var j = Json.parse(' {"omx": 2, "name": "a\\"b\\n\\u00e9\\ud83d\\ude00", "ok": true, "no": false, "n": null, "list": [1, -20, {"x": []}], "empty": {}} ')
    assert_equal(j.number(j.get(0, "omx")), 2)
    assert_equal(j.text(j.get(0, "name")), 'a"b\né😀')
    assert_true(j.flag(j.get(0, "ok")))
    assert_false(j.flag(j.get(0, "no")))
    var list = j.get(0, "list")
    assert_equal(j.kind(list), J_ARRAY)
    assert_equal(j.size(list), 3)
    assert_equal(j.number(j.at(list, 1)), -20)
    assert_equal(j.kind(j.at(list, 2)), J_OBJECT)
    assert_equal(j.size(j.get(j.at(list, 2), "x")), 0)
    assert_equal(j.get(0, "missing"), -1)
    assert_equal(j.number(j.get(0, "missing"), 7), 7)
    var back = Json.parse(json_string('tab\t quote" back\\ é \x01'))
    assert_equal(back.text(0), 'tab\t quote" back\\ é \x01')
    # decimals, exponents and negatives (goal 33 M2): real() reads them; number() keeps its whole part
    var d = Json.parse('[1.5, -2.25e2, 3E-1, 7, -0.0, 1e400]')
    assert_equal(d.real(d.at(0, 0)), 1.5)
    assert_equal(d.number(d.at(0, 0)), 1)
    assert_false(d.is_whole(d.at(0, 0)))
    assert_equal(d.real(d.at(0, 1)), -225.0)
    assert_equal(d.number(d.at(0, 1)), -225)
    assert_equal(d.real(d.at(0, 2)), 0.3)
    assert_true(d.is_whole(d.at(0, 3)))
    assert_equal(d.real(d.at(0, 3)), 7.0)
    assert_equal(d.real(d.at(0, 4)), 0.0)
    assert_equal(d.real(d.at(0, 5)), Float64.MAX * 10, "past the range: infinity, as Python's float()")
    assert_equal(d.real(-1, 2.5), 2.5)
    for bad in ["", "{", '{"a" 1}', "[1,]", '"open', "01", "1.", ".5", "1e", "1e+", "-", "--1", "+1", "99999999999999999999", "{} x", '{"a": tru}', '"\\udc00"', '"\\udbff\\uffff"', '"\\ud800"', '"\\ud800x"', '"\\ud800\\n"']:
        var failed = False
        try:
            _ = Json.parse(bad)
        except e:
            failed = String(e).startswith("not JSON: ")
        assert_true(failed, "refuses: " + bad)

    # fuzz: random fragments and mutations of real metadata either parse or are refused; nothing aborts the app
    var pieces: List[String] = ["{", "}", "[", "]", '"', ":", ",", "\\", "u", "d", "8", "0", "c", "f", "-", "1", "9", "t", "r", "e", "n", "l",
                                "x", " ", "é", "😀", "\\u", "\\ud83d", "\\ude00", "\\udc00", "\\ud800", "\\uffff", "\\u0000", "\\n",
                                "true", "false", "null", '"omx"', '"columns"', "123", "-5", "1.5", "1e3", "\x01"]
    var real = String('{"omx": 2, "columns": [{"name": "a\\u00e9", "format": {"style": 2, "symbol": "\\ud83d\\ude00"}}], "formulas": [], "objects": [{"kind": 1, "x": -4}], "report": {"tiles": [], "filter": {"col": 0, "word": "West"}}}')
    var seed = UInt64(12345)
    var parsed = 0
    var refused = 0
    for i in range(40000):
        var text = String("")
        seed = seed * 6364136223846793005 + 1442695040888963407
        if i % 2 == 0:  # random fragments
            var n = Int((seed >> 33) % 24) + 1
            for _ in range(n):
                seed = seed * 6364136223846793005 + 1442695040888963407
                text += pieces[Int((seed >> 33) % UInt64(len(pieces)))]
        else:  # the real metadata with a piece dropped, doubled or replaced
            var chars = List[String]()
            for c in real.codepoint_slices():
                chars.append(String(c))
            var at = Int((seed >> 33) % UInt64(len(chars)))
            seed = seed * 6364136223846793005 + 1442695040888963407
            var how = Int((seed >> 33) % 4)
            seed = seed * 6364136223846793005 + 1442695040888963407
            var swap_in = pieces[Int((seed >> 33) % UInt64(len(pieces)))]
            for k in range(len(chars)):
                if k == at:
                    if how == 0:
                        continue  # dropped
                    if how == 1:
                        text += chars[k]  # doubled
                    if how == 2:
                        text += swap_in  # replaced
                        continue
                    if how == 3:
                        text += swap_in  # inserted
                text += chars[k]
                if how == 3 and k > at + 20:
                    break  # (and cut short)
        try:
            _ = Json.parse(text)
            parsed += 1
        except e:
            assert_true(String(e).startswith("not JSON: "), String(e))
            refused += 1
    assert_true(parsed > 100 and refused > 100, "the fuzz reached both outcomes")
    # (D-7945) long decimals read by Eisel–Lemire give strtod_l's bits: a million of the forms documents hold (JS
    # doubles' 16–17 digits, short ones, exponents both ways, 19 digits, halfway cases near the round-to-even range)
    var loc = c_locale()
    var checked = 0
    seed = UInt64(987654321)
    var digits = String("0123456789")
    for i in range(1_000_000):
        seed = seed * 6364136223846793005 + 1442695040888963407
        var r = seed >> 11
        var nd = Int(r % 19) + 1
        var t = String("-" if (r >> 20) & 1 == 1 else "")
        var ip = Int((r >> 21) % 6)
        var body = String("")
        var s2 = seed
        for k in range(nd):
            s2 = s2 * 6364136223846793005 + 1442695040888963407
            var dg = Int((s2 >> 33) % 10)
            if k == 0 and dg == 0:
                dg = 1 + Int((s2 >> 40) % 9)
            body += String(digits[byte=dg:dg + 1])
        if i % 7 == 0:
            body = String("9007199254740993") if i % 2 == 0 else String("4503599627370497")  # (2^53 + 1, 2^52 + 1: halfway)
        var int_len = min(ip, body.byte_length())
        if int_len == 0:
            t += "0." + body
        elif int_len >= body.byte_length():
            t += body + ".5"
        else:
            t += String(body[byte=0:int_len]) + "." + String(body[byte=int_len:])
        if i % 3 == 0:
            var ex = Int((r >> 30) % 640) - 330
            t += "e" + String(ex)
        var want = external_call["strtod_l", Float64](Int(t.as_c_string_span().unsafe_ptr()), Int(0), loc)
        var got = Json.parse(t).real(0)
        if want.to_bits() != got.to_bits():
            raise Error("Eisel–Lemire differs from strtod_l on " + t + ": " + String(got) + " vs " + String(want))
        checked += 1
    print("JSON TESTS PASSED · fuzz " + String(parsed) + " parsed, " + String(refused) + " refused · " + String(checked) + " long decimals as strtod_l")
