# mojoui.jam (goal 82 M6): each case of $JAM_CASES (default docs/goals/82/jam-cases.json: a map and a recorded brain reply)
# through parse_jam and apply_jam; one JSON line per case: {"case": i, "ok": true, "wire": [...], "dropped": [...], "map": {...}}
# or {"case": i, "ok": false, "error": "..."}. docs/goals/82-check.py runs the web's jam_brain.parse_edits and
# mindmap/jam.js applyJamEdits on the same cases and compares.
from std.os import getenv
from mojoui.jam import parse_jam, apply_jam, jam_prompt
from mojoui.json import Json, json_string


def main() raises:
    var text = String(open(getenv("JAM_CASES", "docs/goals/82/jam-cases.json"), "r").read())
    var j = Json.parse(text)
    for i in range(j.size(0)):
        var c = j.at(0, i)
        var map_doc = j.dump(j.get(c, "map"))
        var reply = j.text(j.get(c, "reply"))
        try:
            var edits = parse_jam(reply, map_doc)
            var dropped = String("[")
            for k in range(len(edits.dropped)):
                dropped += (", " if k > 0 else "") + json_string(edits.dropped[k])
            dropped += "]"
            var applied = apply_jam(map_doc, edits, "t")
            print('{"case": ' + String(i) + ', "ok": true, "wire": ' + edits.wire() + ', "dropped": ' + dropped + ', "map": ' + applied + "}")
        except e:
            print('{"case": ' + String(i) + ', "ok": false, "error": ' + json_string(String(e)) + "}")
    var empty = List[String]()
    var p = jam_prompt(j.dump(j.get(j.at(0, 0), "map")), "  we should eat seafood  ", ["Day trips"])
    print('{"prompt": ' + json_string(p) + "}")
