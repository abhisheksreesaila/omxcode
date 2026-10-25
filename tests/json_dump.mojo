# Prints a JSON file as mojoui.json reads it: one line per container and leaf (scripts/check.py M2 compares the lines with
# Python's json.loads, value for value). Keys and strings as UTF-8 hex, floats as their IEEE-754 bits.
#   build/json_dump docs/goals/33/fixtures/admin_models.json
from std.sys import argv
from std.memory import bitcast
from mojoui.json import Json, J_NULL, J_BOOL, J_NUMBER, J_STRING, J_ARRAY, J_OBJECT


def hex_of(s: String) -> String:
    var digits = "0123456789abcdef"
    var out = String("")
    for b in s.as_bytes():
        out += String(digits[byte = Int(b) // 16 : Int(b) // 16 + 1]) + String(digits[byte = Int(b) % 16 : Int(b) % 16 + 1])
    return out


def bits_of(f: Float64) -> String:
    var u = bitcast[DType.uint64](f)
    var digits = "0123456789abcdef"
    var out = String("")
    for k in range(16):
        var d = Int((u >> UInt64((15 - k) * 4)) & 15)
        out += String(digits[byte = d : d + 1])
    return out


def dump(j: Json, node: Int, path: String):
    var k = j.kind(node)
    if k == J_OBJECT:
        print(path + "\tobj " + String(j.size(node)))
        for i in range(j.size(node)):
            dump(j, j.at(node, i), path + "." + hex_of(j.keys[node][i]))
    elif k == J_ARRAY:
        print(path + "\tarr " + String(j.size(node)))
        for i in range(j.size(node)):
            dump(j, j.at(node, i), path + "[" + String(i) + "]")
    elif k == J_NULL:
        print(path + "\tnull")
    elif k == J_BOOL:
        print(path + "\t" + ("true" if j.flag(node) else "false"))
    elif k == J_NUMBER:
        if j.is_whole(node):
            print(path + "\tint " + String(j.number(node)))
        else:
            print(path + "\tfloat " + bits_of(j.real(node)))
    else:
        print(path + "\tstr " + hex_of(j.text(node)))


def main() raises:
    var f = open(argv()[1], "r")
    var text = f.read()
    f.close()
    var j = Json.parse(text)
    dump(j, 0, "$")
