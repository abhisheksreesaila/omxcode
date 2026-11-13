# Goal 68 M3: a bag's topics as mojoui.bag reads them, written as JSON lines for docs/goals/68-check.py to compare with
# the official mcap / rosbags readers field for field.
#   pixi run mojo build -I . tests/bag_dump.mojo -o build/g68/bin/bag_dump && build/g68/bin/bag_dump BAG LIMIT OUT.jsonl
# A line per topic ({"topic", "type", "encoding", "count", "note", "columns", "kinds"}), then a line per row: a JSON
# array (an INT as a number, a FLOAT as {"f": its 64 bits as an integer}: exact, NaN included; TEXT as a string).
from std.sys import argv
from std.memory import bitcast
from std.time import perf_counter_ns
from mojoui.bag import Bag, BagTable, BAG_INT, BAG_FLOAT
from mojoui.json import json_string


def main() raises:
    var args = argv()
    var bag = Bag.open(String(args[1]))
    var limit = Int(String(args[2]))
    var t0 = perf_counter_ns()
    var all = List[Int]()
    for k in range(len(bag.topics)):
        all.append(k)
    var tables = bag.tables(all, limit)
    var secs = Float64(perf_counter_ns() - t0) / 1e9
    var rows = 0
    with open(String(args[3]), "w") as f:
        for k in range(len(tables)):
            ref tb = tables[k]
            var cols = String("[")
            var kinds = String("[")
            for c in range(tb.columns()):
                cols += ("," if c > 0 else "") + json_string(tb.names[c])
                kinds += ("," if c > 0 else "") + String(tb.kinds[c])
            var tp = bag.topics[k].copy()
            f.write("{\"topic\":", json_string(tp.name), ",\"type\":", json_string(tp.type), ",\"encoding\":", json_string(tp.encoding),
                    ",\"count\":", String(tp.count), ",\"rows\":", String(tb.rows), ",\"note\":", json_string(tb.note),
                    ",\"columns\":", cols, "],\"kinds\":", kinds, "]}\n")
            for r in range(tb.rows):
                var line = String("[")
                for c in range(tb.columns()):
                    if c > 0:
                        line += ","
                    if tb.kinds[c] == BAG_INT:
                        line += String(tb.ints[tb.slot[c]][r])
                    elif tb.kinds[c] == BAG_FLOAT:
                        line += "{\"f\":" + String(Int64(bitcast[DType.int64, 1](SIMD[DType.float64, 1](tb.floats[tb.slot[c]][r]))[0])) + "}"
                    else:
                        line += json_string(tb.texts[tb.slot[c]][r])
                f.write(line, "]\n")
                rows += 1
    print("BAG:", bag.format, len(bag.topics), "topics", rows, "rows", String(secs), "s", bag.duration_s(), "s long")
