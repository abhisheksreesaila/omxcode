# mojoui.links (goal 41 M6): links, match counts, the join a key link implies, a selection followed to linked cards, time
# links both ways, and the panel's agent tools. A hand-made claim sheet: 14 shipments; a video's analysis rows that saw
# 12 of their codes (one code twice, one stranger); a BOL page's words with boxes.
#   pixi run mojo run -I . tests/test_links.mojo
# join: the SQL the link implies runs on omxcore (tools/links_join.mojo, built with scripts/mxbuild.sh because `mojo run`
# can't link the engine) and on DuckDB (Python, only here) over the same CSV files; the rows must be equal.
from std.os import getenv
from std.python import Python
from std.testing import assert_equal, assert_true, assert_false
from mojoui.app import Event
from mojoui.links import (Link, Links, End, Selection, CardRows, match_count, parse_link, LINK_KEY, LINK_TIME, LINK_PLACE,
                          BY_AGENT, REACT_SEEK, REACT_HIGHLIGHT, REACT_SELECT, LINKS_OPEN, LINKS_DRAFT, LINKS_ADD, LINKS_REMOVE)
from mojoui.view import View, FIELD, BUTTON, DROPDOWN

comptime SAW: List[Int] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13]  # shipments S-5001 … S-5014 on camera: not 11 nor 14

comptime ORACLE = """
import subprocess, duckdb

def build(root):
    r = subprocess.run(["scripts/mxbuild.sh", "tools/links_join.mojo", "-o", "build/links_join"], cwd=root, capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr)[-600:]

def engine(root, query, tables):
    r = subprocess.run(["build/links_join", query] + tables, cwd=root, capture_output=True, text=True)
    lines = r.stdout.splitlines()
    if r.returncode or not lines or not lines[0].startswith("ROWS:"):
        return None, (r.stdout + r.stderr)[-600:]
    return sorted(lines[1:]), ""

def duck(query, tables):
    con = duckdb.connect()
    for name, path in zip(tables[0::2], tables[1::2]):
        con.execute(f"CREATE VIEW {name} AS SELECT * FROM read_csv_auto('{path}', header=true)")
    return sorted("\\t".join("" if v is None else str(v) for v in row) for row in con.execute(query).fetchall())
"""


def tag_index(v: View, tag: String) -> Int:
    for i in range(len(v.nodes)):
        if v.nodes[i].name == tag:
            return i
    return -1


def main() raises:
    var out = getenv("G41_OUT", "build/g41") + "/links"
    var root = String(Python.import_module("os").getcwd())
    _ = Python.import_module("os").makedirs(out, exist_ok=True)

    # the hand table: shipments, the video's rows (frame, t, code), the BOL page's words
    var ids = List[String]()
    var ship = String("shipment_id,carrier,pallets\n")
    for k in range(1, 15):
        var id = "S-50" + (String("0") if k < 10 else String("")) + String(k)
        ids.append(id)
        ship += id + "," + ("Ridge" if k % 2 else "Polar") + "," + String(k % 4 + 1) + "\n"
    var video = CardRows("dock.mp4", "dock.mp4 · detections", ["frame", "t", "code"])
    video.seeks("t", "frame")
    var det = String("frame,t,code\n")
    var codes = List[String]()
    for k in materialize[SAW]():
        var frame = k * 40
        var code = ids[k - 1]
        video.add_row([String(frame), String(Float64(frame) / 25.0), code])
        det += String(frame) + "," + String(frame // 25) + "," + code + "\n"
        codes.append(code)
    video.add_row([String(700), String(28.0), "S-5012"])  # S-5012 again, later (the seek goes to the first)
    det += "700,28,S-5012\n"
    codes.append("S-5012")
    video.add_row([String(720), String(28.8), "S-9999"])  # a code the sheet doesn't have
    det += "720,28,S-9999\n"
    codes.append("S-9999")
    var page = CardRows("BOL-5012.pdf", "BOL-5012.pdf · words", ["text", "page", "x", "y", "w", "h"])
    page.highlights("page", "x", "y", "w", "h")
    page.add_row(["Shipment", "1", "72", "96", "60", "12"])
    page.add_row(["S-5012", "1", "140", "96", "48", "12"])
    page.add_row(["Exceptions", "1", "72", "300", "70", "12"])
    with open(out + "/shipments.csv", "w") as f:
        f.write(ship)
    with open(out + "/detections.csv", "w") as f:
        f.write(det)

    # link: made, listed, per card, no doubles, nothing inside one table, removed
    var links = Links(msg_base=7600)
    var key = links.add(Link.key(End("shipments", "shipment_id"), End("dock.mp4", "code", "dock.mp4 · detections")))
    var pg = links.add(Link.key(End("shipments", "shipment_id"), End("BOL-5012.pdf", "text", "BOL-5012.pdf · words")))
    var tm = links.add(Link.time(End("forklift_log", "t"), End("dock.mp4", "t"), offset=1.2))
    assert_equal(len(links), 3)
    assert_equal(links.list()[0], "shipments.shipment_id = dock.mp4.code")
    assert_equal(links.list()[2], "forklift_log.t ~ dock.mp4.t +1.2 s")
    assert_equal(len(links.for_card("dock.mp4")), 2)
    assert_equal(len(links.for_card("shipments")), 2)
    assert_equal(len(links.for_card("nobody")), 0)
    var dup = False
    try:
        _ = links.add(Link.key(End("dock.mp4", "code", "dock.mp4 · detections"), End("shipments", "shipment_id")))  # the same, reversed
    except:
        dup = True
    assert_true(dup, "a link twice")
    var inside = False
    try:
        _ = links.add(Link.key(End("shipments", "carrier"), End("shipments", "pallets")))
    except:
        inside = True
    assert_true(inside, "a key link inside one table is implicit")
    var parsed = parse_link("shipments.shipment_id = dock.mp4.code")
    assert_equal(parsed.b.card, "dock.mp4")
    assert_equal(parsed.b.column, "code")
    var pt = parse_link("forklift_log.t ~ dock.mp4.t -0.5 ×2")
    assert_equal(pt.kind, LINK_TIME)
    assert_equal(pt.offset, -0.5)
    assert_equal(pt.scale, 2.0)
    var place = Link.place(End("photo.jpg", "x"), End("site", "lon"), 0.0001, 4.35, -0.0001, 52.01)
    var ll = place.place_to_b(100.0, 200.0)
    var px = place.place_to_a(ll[0], ll[1])
    assert_true(abs(px[0] - 100.0) < 1e-6 and abs(px[1] - 200.0) < 1e-6, "place both ways")
    assert_equal(place.kind, LINK_PLACE)
    print("link: ok")

    # match: 12 of the 14 shipments are on camera (S-5012 twice and a stranger don't change it); the other way 13 codes, 12 known
    var m = match_count(ids, codes)
    assert_equal(m.matched, 12)
    assert_equal(m.total, 14)
    assert_equal(m.text(), "12 of 14")
    var back = match_count(codes, ids)
    assert_equal(back.matched, 12)
    assert_equal(back.total, 13)
    var with_empty: List[String] = ["S-5001", "", "S-5001", "S-0000"]
    var e = match_count(with_empty, ids)
    assert_equal(e.text(), "1 of 2")
    print("match: ok")

    # join: the implied SQL on omxcore and on DuckDB, the same rows
    var q = links.join_sql(key, "shipments.shipment_id, shipments.carrier, detections.frame")
    assert_equal(q, "SELECT shipments.shipment_id, shipments.carrier, detections.frame FROM shipments JOIN detections ON shipments.shipment_id = detections.code")
    var builtins = Python.import_module("builtins")
    var mod = Python.import_module("types").ModuleType("oracle")
    _ = builtins.exec(ORACLE, mod.__dict__)
    var built = mod.build(root)
    assert_equal(Int(py=built[0]), 0, "build tools/links_join.mojo: " + String(built[1]))
    var tables = Python.list()
    tables.append("shipments")
    tables.append(out + "/shipments.csv")
    tables.append("detections")
    tables.append(out + "/detections.csv")
    var mine = mod.engine(root, q, tables)
    assert_true(String(mine[1]) == "", "omxcore: " + String(mine[1]))
    var duck = mod.duck(q, tables)
    assert_equal(Int(py=builtins.len(mine[0])), 13)  # 12 shipments, S-5012 twice
    assert_true(Bool(py=mine[0] == duck), "omxcore " + String(mine[0]) + " vs DuckDB " + String(duck))
    print("join: ok")

    # follow: picking S-5012's row seeks the video to its first sighting and highlights its box on the BOL page; another
    # card on the same table selects the same row; a column the link isn't about reaches nobody through it
    var sel = Selection("shipments", "shipments", 11, "shipment_id", "S-5012")
    var follows = links.follow(sel, ["shipments", "shipments (chart)"])
    assert_equal(len(follows), 3)
    var seen_seek = False
    var seen_box = False
    var seen_same = False
    for f in follows:
        if f.card == "dock.mp4":
            var r = video.react(f)
            assert_equal(r.action, REACT_SEEK)
            assert_equal(r.frame, 480)
            assert_equal(r.time, 19.2)
            assert_equal(len(r.rows), 2)
            assert_equal(r.line(), "FOLLOW: dock.mp4 seek t=19.2 frame=480")
            seen_seek = True
        elif f.card == "BOL-5012.pdf":
            var r = page.react(f)
            assert_equal(r.action, REACT_HIGHLIGHT)
            assert_equal(r.page, 1)
            assert_equal(r.x, 140.0)
            assert_equal(r.w, 48.0)
            seen_box = True
        elif f.card == "shipments (chart)":
            var same = CardRows("shipments (chart)", "shipments", ["shipment_id"])
            for id in ids:
                same.add_row([id])
            var r = same.react(f)
            assert_equal(r.action, REACT_SELECT)
            assert_equal(r.rows[0], 11)
            seen_same = True
    assert_true(seen_seek and seen_box and seen_same, "follow reached every linked card")
    var other_col = links.follow(Selection("shipments", "shipments", 11, "carrier", "Polar"))
    assert_equal(len(other_col), 0)
    var unseen = video.react(links.follow(Selection("shipments", "shipments", 10, "shipment_id", "S-5011"))[0])
    assert_equal(unseen.line(), "FOLLOW: dock.mp4 nothing")  # never on camera
    print("follow: ok")

    # time: the log's clock + 1.2 s is the video's; back again; a selection with a time follows through it
    var tl = links.items[tm]
    assert_equal(tl.to_b(10.0), 11.2)
    assert_true(abs(tl.to_a(tl.to_b(37.25)) - 37.25) < 1e-9, "time both ways")
    var scaled = Link.time(End("a", "t"), End("b", "t"), offset=-3.0, scale=0.5)
    assert_equal(scaled.to_b(10.0), 2.0)
    assert_equal(scaled.to_a(2.0), 10.0)
    var tsel = Selection("forklift_log", "forklift_log", 5, "t", "")
    tsel.time = 18.0
    var tf = links.follow(tsel)
    assert_equal(len(tf), 1)
    assert_equal(tf[0].kind, LINK_TIME)
    assert_true(abs(tf[0].time - 19.2) < 1e-9, "log 18.0 s is video 19.2 s")
    var tr = video.react(tf[0])
    assert_equal(tr.action, REACT_SEEK)
    assert_true(abs(tr.time - 19.2) < 1e-9, "the video seeks to the mapped time")
    var vsel = Selection("dock.mp4", "dock.mp4", 0, "t", "")
    vsel.time = 19.2
    assert_true(abs(links.follow(vsel)[0].time - 18.0) < 1e-9, "video → log")
    print("time: ok")

    # tools: the panel shows `links`, `link` and `unlink`; typing a link and Return adds it, picking one removes it
    var v = links.view()
    var i_links = tag_index(v, "links")
    var i_link = tag_index(v, "link")
    var i_unlink = tag_index(v, "unlink")
    assert_true(i_links >= 0 and i_link >= 0 and i_unlink >= 0, "three tools")
    assert_equal(v.nodes[i_links].kind, BUTTON)
    assert_equal(v.nodes[i_link].kind, FIELD)
    assert_equal(v.nodes[i_unlink].kind, DROPDOWN)
    assert_true(v.nodes[i_links].tip.find("shipments.shipment_id = dock.mp4.code") >= 0, "links lists them")
    assert_equal(len(v.nodes[i_unlink].options), 4)  # Unlink… + 3
    assert_true(links.update(Event(7600 + LINKS_DRAFT, "trucks.plate = dock.mp4.plate", 0)))
    assert_true(links.update(Event(7600 + LINKS_ADD, "trucks.plate = dock.mp4.plate", 0)))
    assert_equal(len(links), 4)
    assert_equal(links.problem, "")
    assert_true(links.update(Event(7600 + LINKS_ADD, "nonsense", 0)))
    assert_equal(len(links), 4)
    assert_true(links.problem != "", "a bad link says why")
    var v2 = links.view()
    assert_equal(v2.nodes[tag_index(v2, "unlink")].options[4], "trucks.plate = dock.mp4.plate")
    assert_true(links.update(Event(7600 + LINKS_REMOVE, "", 4)))
    assert_equal(len(links), 3)
    assert_false(links.update(Event(7600 + 99, "", 0)))
    assert_true(links.update(Event(7600 + LINKS_OPEN, "", 0)))
    assert_true(links.open)
    print("tools: ok")
