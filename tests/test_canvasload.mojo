# mojoui.canvasload: a JSON Canvas opened a part at a time ends as the whole import does (D-7944).
#   pixi run mojo run -I . -I vendor tests/test_canvasload.mojo
# 1. skim: strings holding brackets, escaped quotes and backslash runs that cross 64-byte blocks don't fool it;
# 2. a generated board (texts, stickies, ink, cards, edges, in no spatial order) opened by take + step slices equals
#    import_json_canvas_doc: the same ids, z, order and the same exported document; stays "saved";
# 3. a pan during the open (the slices follow a moved rect) ends the same;
# 4. an edit during the open waits for the whole board (finish), lands, and undoes back to the document;
# 5. the first slice holds every node meeting its rect and both ends of every edge crossing it;
# 6. duplicate node ids (the later one making nothing) bind edges as the whole import binds them (review 2);
# 7. OpenBoard: an edit mid-open through edit() finishes the load first, lands, and undoes (review 2, D-7952).
from std.testing import assert_equal, assert_true, assert_false
from std.collections import Dict
from mojoui.json import Json, json_string
from mojoui.objectlayer import ObjectLayer, import_json_canvas_doc, export_json_canvas, CH_MOVE, CONNECTOR
from mojoui.canvasload import CanvasLoad, skim, OpenBoard


def rnd(mut seed: UInt64) -> Int:
    seed = seed * 6364136223846793005 + 1442695040888963407
    return Int(seed >> 33)


def board_text(count: Int, edges: Int, mut seed: UInt64) -> String:
    """A JSON Canvas with PN's extras: texts (some Markdown, some with brackets, quotes and backslashes in their words),
    stickies, ink strokes with long paths, cards; edges between random nodes; nodes in random places."""
    var nodes = List[String]()
    for i in range(count):
        var x = rnd(seed) % 6000 - 500
        var y = rnd(seed) % 6000 - 500
        var kind = rnd(seed) % 4
        var id = "n" + String(i)
        if kind == 0:
            var words = String("plain ") + String(i)
            var t = rnd(seed) % 5
            if t == 1:
                words = 'braces } { ] [ inside "quotes" ' + String(i)
            elif t == 2:
                words = "back\\\\slashes \\\\\\\\ and \\\" quote " + String(i)  # (escaped in the JSON below as written)
            elif t == 3:
                words = "unicode é 😀 ü " + String(i)
            var bs = String("")
            for _ in range(rnd(seed) % 70):  # (a backslash run of any length, so some cross a 64-byte block)
                bs += "\\\\"
            nodes.append('{"id":' + json_string(id) + ',"type":"text","x":' + String(x) + ',"y":' + String(y) + ',"width":220,"height":60,"text":'
                         + json_string(words) + ',"pn":{"type":"text","note":"' + bs + '","style":{"fontFamily":"Geist","fontSize":18,"color":"#222222","lineHeight":1.4}'
                         + (',"format":"markdown"' if t == 4 else "") + "}}")
        elif kind == 1:
            nodes.append('{"id":' + json_string(id) + ',"type":"text","x":' + String(x) + ',"y":' + String(y) + ',"width":180,"height":180,"text":"sticky ' + String(i)
                         + '","color":"#ffd36e","pn":{"type":"sticky","style":{"fontSize":16,"color":"#3a2a00"}}}')
        elif kind == 2:
            var path = String('[["M",0,0]')
            var n = 5 + rnd(seed) % 60
            for k in range(n):
                path += ',["Q",' + String(k) + "," + String(k % 7) + "," + String(Float64(k) + 0.123456789012345) + "," + String(Float64(k % 9) * 1.7976931348623157) + "]"
            path += "]"
            nodes.append('{"id":' + json_string(id) + ',"type":"file","x":' + String(x) + ',"y":' + String(y) + ',"width":120,"height":40,"file":"","pn":{"type":"ink","kind":"stroke","color":"#223344","width":2.5,"geometry":{"x":'
                         + String(x) + ',"y":' + String(y) + '},"path":' + path + "}}")
        else:
            nodes.append('{"id":' + json_string(id) + ',"type":"file","x":' + String(x) + ',"y":' + String(y) + ',"width":200,"height":120,"file":"","pn":{"type":"shape","kind":"rect"}}')
    var es = List[String]()
    for e in range(edges):
        var a = rnd(seed) % count
        var b = rnd(seed) % count
        es.append('{"id":"e' + String(e) + '","fromNode":"n' + String(a) + '","toNode":"n' + String(b) + '","color":"#884422","pn":{"lineWidth":3,"arrowheads":{"end":' + ("true" if e % 2 == 0 else "false") + "}}}")
    var out = String('{"nodes":[')
    for i in range(len(nodes)):
        out += ("," if i > 0 else "") + nodes[i]
    out += '],\n "edges":['
    for i in range(len(es)):
        out += ("," if i > 0 else "") + es[i]
    out += '],"pn":{"schemaVersion":1,"page":{"columns":4,"rows":3}}}'
    return out^


def same_layers(a: ObjectLayer, b: ObjectLayer) raises:
    assert_equal(len(a.objs), len(b.objs))
    for i in range(len(a.objs)):
        assert_equal(a.objs[i].id, b.objs[i].id)
        assert_equal(a.objs[i].z, b.objs[i].z)
        assert_equal(a.objs[i].kind, b.objs[i].kind)
        assert_equal(a.objs[i].key, b.objs[i].key)
    assert_equal(export_json_canvas(a, 4, 3), export_json_canvas(b, 4, 3))


def main() raises:
    # 1. skim against the reader: every node found, at its own bytes
    var seed = UInt64(7)
    for trial in range(40):
        var text = board_text(60 + trial * 7, 20, seed)
        var sk = skim(Int(text.unsafe_ptr()), text.byte_length())
        assert_true(sk.ok, "skim balanced")
        var j = Json.parse(text)
        var nodes = j.get(0, "nodes")
        var found = 0
        for k in range(len(sk.el_start)):
            if sk.members[sk.el_member[k]].key == "nodes":
                var one = Json.parse_bytes(Int(text.unsafe_ptr()) + sk.el_start[k], sk.el_end[k] - sk.el_start[k])
                assert_equal(one.text(one.get(0, "id")), j.text(j.get(j.at(nodes, found), "id")))
                found += 1
        assert_equal(found, j.size(nodes))
    var bad = String('{"nodes":[{"id":"a","text":"unclosed}]}')
    assert_false(CanvasLoad(bad).ok, "a document that doesn't balance isn't opened progressively")

    # 2. a board opened in slices equals the whole import
    var text = board_text(3000, 400, seed)
    var whole = import_json_canvas_doc(Json.parse(text))
    var ld = CanvasLoad(text)
    assert_true(ld.ok)
    var layer = ObjectLayer()
    layer.mark_saved()
    ld.take(layer, 0, 0, 1500, 1000)
    var first = len(layer.objs)
    assert_true(first > 0 and first < len(whole.objs), "the first slice is a part")
    var slices = 0
    while not ld.done():
        ld.step(layer, 0, 0, 1500, 1000, 300)
        slices += 1
    assert_true(slices >= 2, "the rest came in several slices")
    same_layers(layer, whole)
    assert_false(layer.unsaved(), "adopting a document isn't an edit")
    assert_false(layer.can_undo(), "nothing to undo after an open")

    # 3. a pan during the open: the slices follow the moved rect, the end is the same
    var ld2 = CanvasLoad(text)
    var l2 = ObjectLayer()
    ld2.take(l2, 0, 0, 1500, 1000)
    var x = 0.0
    while not ld2.done():
        x += 400
        ld2.step(l2, x, 0, x + 1500, 1000, 200)
    same_layers(l2, whole)

    # 4. an edit during the open waits for the whole board, lands, and undoes to the document
    var ld3 = CanvasLoad(text)
    var l3 = ObjectLayer()
    l3.mark_saved()
    ld3.take(l3, 0, 0, 1500, 1000)
    ld3.step(l3, 0, 0, 1500, 1000, 200)
    assert_false(ld3.done())
    var target = l3.objs[0].id
    ld3.finish(l3)  # (what an app calls before an edit: pnote's whole())
    assert_true(ld3.done())
    l3.select(target, False)
    l3.begin_gesture(CH_MOVE)
    l3.move_by(37, -21)
    l3.end_gesture()
    var w2 = import_json_canvas_doc(Json.parse(text))
    w2.select(target, False)
    w2.begin_gesture(CH_MOVE)
    w2.move_by(37, -21)
    w2.end_gesture()
    assert_equal(export_json_canvas(l3, 4, 3), export_json_canvas(w2, 4, 3))
    assert_true(l3.unsaved(), "the edit is an edit")
    assert_true(l3.undo(), "the edit is in the history after the open")
    assert_equal(export_json_canvas(l3, 4, 3), export_json_canvas(whole, 4, 3))

    # 5. the first slice: every node meeting the rect, and both ends of edges crossing it
    var ld4 = CanvasLoad(text)
    var l4 = ObjectLayer()
    var rx0 = 1000.0
    var ry0 = 1000.0
    var rx1 = 2000.0
    var ry1 = 1800.0
    ld4.take(l4, rx0, ry0, rx1, ry1)
    var have = Dict[String, Bool]()
    for ref o in l4.objs:
        have[o.key] = True
    for i in range(ld4.nodes()):
        if ld4.bx1[i] >= rx0 and ld4.bx0[i] <= rx1 and ld4.by1[i] >= ry0 and ld4.by0[i] <= ry1:
            if whole.has(i + 1):
                assert_true(whole.objs[whole.index(i + 1)].key in have, "a node in the rect is in the first slice")
    var crossing = 0
    for ref o in whole.objs:
        if o.kind != CONNECTOR:
            continue
        if max(o.ax, o.bx) < rx0 or min(o.ax, o.bx) > rx1 or max(o.ay, o.by) < ry0 or min(o.ay, o.by) > ry1:
            continue
        crossing += 1
        assert_true(o.key in have, "an edge crossing the rect is drawn in the first slice: " + o.key)
    assert_true(crossing > 0, "the case has crossing edges")
    # 6. duplicate ids: "d" twice, the later a kind the importer makes nothing of; edges to it bind to the earlier one
    var dup = String('{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":100,"height":40,"text":"a"},'
                     + '{"id":"d","type":"text","x":4000,"y":4000,"width":100,"height":40,"text":"first d"},'
                     + '{"id":"b","type":"text","x":300,"y":0,"width":100,"height":40,"text":"b"},'
                     + '{"id":"d","type":"weird","x":10,"y":10,"width":50,"height":50},'
                     + '{"id":"b","type":"text","x":600,"y":0,"width":100,"height":40,"text":"second b"}],'
                     + '"edges":[{"id":"e1","fromNode":"a","toNode":"d"},{"id":"e2","fromNode":"a","toNode":"b"},{"id":"e3","fromNode":"d","toNode":"zz"}]}')
    var wd = import_json_canvas_doc(Json.parse(dup))
    var ldd = CanvasLoad(dup)
    var ld_layer = ObjectLayer()
    ldd.take(ld_layer, -50, -50, 150, 150)  # (only "a" and what its edges need)
    while not ldd.done():
        ldd.step(ld_layer, -50, -50, 150, 150, 50)
    same_layers(ld_layer, wd)
    var conns = 0
    for ref o in wd.objs:
        if o.kind == CONNECTOR:
            conns += 1
    assert_equal(conns, 2, "e1 binds to the first d, e2 to the second b, e3 has no end")

    # 7. OpenBoard: painting reads part of the board; edit() finishes it first; the edit is undoable after the open
    var ob = OpenBoard()
    assert_equal(ob.open(text, 0, 0, 1500, 1000), "")
    assert_true(ob.loading() and ob.left() > 0, "still coming in")
    _ = ob.step(0, 0, 1500, 1000, 200)  # (the open's own frame: no slice)
    _ = ob.step(0, 0, 1500, 1000, 200)
    var partial = len(ob.layer.objs)
    assert_true(partial < len(whole.objs))
    ref lay = ob.edit()
    assert_false(ob.loading(), "edit() finished the open")
    assert_equal(len(lay.objs), len(whole.objs))
    lay.select(target, False)
    lay.begin_gesture(CH_MOVE)
    lay.move_by(37, -21)
    lay.end_gesture()
    assert_equal(export_json_canvas(ob.layer, 4, 3), export_json_canvas(w2, 4, 3))
    assert_true(ob.edit().undo())
    assert_equal(export_json_canvas(ob.layer, 4, 3), export_json_canvas(whole, 4, 3))
    assert_true(ob.open("{not a canvas", 0, 0, 1, 1) != "", "a text the skim can't open comes back")
    print("canvasload: ok · " + String(len(whole.objs)) + " objects, first slice " + String(first) + ", " + String(slices) + " slices, " + String(crossing) + " crossing edges")
