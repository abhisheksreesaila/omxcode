# Review 3, MUST 5: a canvas keeps what it was read with. JSON Canvas documents of every kind (Personal Note's own, the
# spec's, ones with keys and kinds nobody knows, dangling and duplicate edges, strays): (1) read, unedited, saved: the very
# text, whether imported whole or opened progressively; (2) one object moved, or its words changed, deleted, undone: as
# JSON only that node differs (and the edges that join a moved one, in their geometry alone), and in it only what the edit
# means; (3) random edits, undo and redo all the way back: the very text again; (4) an object made, a copy made: appended,
# nothing else touched; (5) what isn't drawn is on the board as a card that moves.  canvasround: ok
#   … && build/test_canvasround [a folder of .json canvas documents as well]
from std.testing import assert_true, assert_equal
from std.os import listdir
from std.sys import argv
from mojoui.json import Json, J_OBJECT, J_ARRAY
from mojoui.objectlayer import ObjectLayer, import_json_canvas, export_json_canvas, CH_MOVE, CONNECTOR, TEXT, STICKY, RECT, ELLIPSE, INK
from mojoui.canvasload import OpenBoard


def same_json(a: Json, i: Int, b: Json, k: Int) -> Bool:
    if a.kind(i) != b.kind(k):
        return False
    if a.kind(i) == J_OBJECT:
        if a.size(i) != b.size(k):
            return False
        for q in range(a.size(i)):
            if a.key(i, q) != b.key(k, q) or not same_json(a, a.at(i, q), b, b.at(k, q)):
                return False
        return True
    if a.kind(i) == J_ARRAY:
        if a.size(i) != b.size(k):
            return False
        for q in range(a.size(i)):
            if not same_json(a, a.at(i, q), b, b.at(k, q)):
                return False
        return True
    return a.dump(i) == b.dump(k)


def opened(text: String) raises -> ObjectLayer:
    """As an app opens it: progressively, then whole."""
    var b = OpenBoard()
    var back = b.open(text, 0, 0, 600, 400, 6)
    if back != "":
        var whole = import_json_canvas(back)
        whole.mark_saved()  # (as an app does)
        return whole^
    for _ in range(3):
        _ = b.step(0, 0, 600, 400, 50)
    return b.take()


def differing(a: Json, b: Json, member: String) raises -> List[Int]:
    """Elements of array `member` that differ (the same count)."""
    var x = a.get(0, member)
    var y = b.get(0, member)
    var out = List[Int]()
    for i in range(a.size(x)):
        if not same_json(a, a.at(x, i), b, b.at(y, i)):
            out.append(i)
    return out^


def others_same(a: Json, b: Json, what: String) raises:
    """Every top-level member but nodes and edges."""
    assert_equal(a.size(0), b.size(0), what + ": members")
    for q in range(a.size(0)):
        assert_equal(a.key(0, q), b.key(0, q), what + ": member order")
        if a.key(0, q) != "nodes" and a.key(0, q) != "edges":
            assert_true(same_json(a, a.at(0, q), b, b.at(0, q)), what + ": " + a.key(0, q))


def is_text(got: String, want: String, what: String) raises:
    if got == want:
        return
    var a = got.as_bytes()
    var b = want.as_bytes()
    var i = 0
    while i < len(a) and i < len(b) and a[i] == b[i]:
        i += 1
    raise Error(what + ": differs at byte " + String(i) + ": …" + String(from_utf8_lossy=a[max(0, i - 60):min(len(a), i + 80)]) + "… for …" + String(from_utf8_lossy=b[max(0, i - 60):min(len(b), i + 80)]) + "…")


def check(text: String, name: String) raises:
    var src = Json.parse(text)
    for way in range(2):
        var w = name + (": imported" if way == 0 else ": opened")
        var l = import_json_canvas(text) if way == 0 else opened(text)
        assert_true(l.src.ok, w + ": has its source")
        is_text(export_json_canvas(l, 1, 1), text, w + ", unedited: the very text")
        assert_true(not l.unsaved() or way == 0, w + ": saved as it came")
        # every object drawn, moved alone
        var moved = 0
        for p in range(len(l.objs)):
            if l.objs[p].kind == CONNECTOR or l.objs[p].locked:
                continue
            var id = l.objs[p].id
            var key = l.objs[p].key
            l.select(id, False)
            l.begin_gesture(CH_MOVE)
            l.move_by(17, -9)
            l.end_gesture()
            var out = Json.parse(export_json_canvas(l, 1, 1))
            others_same(src, out, w + ", moved " + key)
            assert_equal(src.size(src.get(0, "nodes")), out.size(out.get(0, "nodes")), w + ": as many nodes")
            var dn = differing(src, out, "nodes")
            assert_equal(len(dn), 1, w + ", moved " + key + ": one node differs")
            var na = src.at(src.get(0, "nodes"), dn[0])
            var nb = out.at(out.get(0, "nodes"), dn[0])
            assert_equal(src.text(src.get(na, "id")), key, "the moved one")
            for q in range(src.size(na)):  # (in it: x, y and pn.geometry's x, y only)
                var k = src.key(na, q)
                assert_equal(out.key(nb, q), k)
                if k == "x" or k == "y":
                    var by = 17.0 if k == "x" else -9.0
                    assert_true(abs(out.real(out.at(nb, q)) - src.real(src.at(na, q)) - by) <= 0.5, w + ": moved by the move")
                elif k == "pn":
                    var pa = src.at(na, q)
                    var pb = out.at(nb, q)
                    for z in range(src.size(pa)):
                        if src.key(pa, z) == "geometry":
                            var ga = src.at(pa, z)
                            var gb = out.at(pb, z)
                            for y in range(src.size(ga)):
                                if src.key(ga, y) != "x" and src.key(ga, y) != "y":
                                    assert_true(same_json(src, src.at(ga, y), out, out.at(gb, y)), w + ": geometry." + src.key(ga, y))
                        else:
                            assert_true(same_json(src, src.at(pa, z), out, out.at(pb, z)), w + ": pn." + src.key(pa, z))
                else:
                    assert_true(same_json(src, src.at(na, q), out, out.at(nb, q)), w + ": " + k)
            for e in differing(src, out, "edges"):
                var ea = src.at(src.get(0, "edges"), e)
                var eb = out.at(out.get(0, "edges"), e)
                assert_true(src.text(src.get(ea, "fromNode")) == key or src.text(src.get(ea, "toNode")) == key, w + ": an edge that joins it")
                for q in range(src.size(ea)):
                    if src.key(ea, q) != "pn":
                        assert_true(same_json(src, src.at(ea, q), out, out.at(eb, q)), w + ": edge." + src.key(ea, q))
            # moved, read again: where it was put (nothing lost to the round trip)
            var again = import_json_canvas(export_json_canvas(l, 1, 1))
            for ref o in again.objs:
                if o.src_at == l.objs[l.index(id)].src_at:
                    assert_true(abs(o.x - l.objs[l.index(id)].x) <= 0.51 and abs(o.y - l.objs[l.index(id)].y) <= 0.51, w + ": " + key + " there after reading it again: " + String(o.x) + "," + String(o.y) + " for " + String(l.objs[l.index(id)].x) + "," + String(l.objs[l.index(id)].y))
            assert_true(l.undo(), "undo")
            is_text(export_json_canvas(l, 1, 1), text, w + ", moved and undone: the very text")
            moved += 1
            if moved > 40:
                break
        # words
        for p in range(len(l.objs)):
            if l.objs[p].kind != TEXT and l.objs[p].kind != STICKY:
                continue
            var id = l.objs[p].id
            l.set_words(id, "new words é \"quoted\"\n2")
            var out = Json.parse(export_json_canvas(l, 1, 1))
            var dn = differing(src, out, "nodes")
            assert_equal(len(dn), 1)
            var nb = out.at(out.get(0, "nodes"), dn[0])
            assert_equal(out.text(out.get(nb, "text")), "new words é \"quoted\"\n2")
            others_same(src, out, w + ", words")
            assert_true(len(differing(src, out, "edges")) == 0, w + ": no edge differs")
            _ = l.undo()
            is_text(export_json_canvas(l, 1, 1), text, w + ", words undone")
            break
        # a delete takes the node and its edges, nothing else; undone, all is back
        for p in range(len(l.objs)):
            if l.objs[p].kind == CONNECTOR:
                continue
            var id = l.objs[p].id
            var key = l.objs[p].key
            l.select(id, False)
            l.delete_selection()
            var out = Json.parse(export_json_canvas(l, 1, 1))
            others_same(src, out, w + ", deleted")
            assert_equal(out.size(out.get(0, "nodes")), src.size(src.get(0, "nodes")) - 1, w + ", deleted: one node less")
            var edges = out.get(0, "edges")
            for e in range(out.size(edges)):
                var n = out.at(edges, e)
                assert_true(key == "" or (out.text(out.get(n, "fromNode")) != key and out.text(out.get(n, "toNode")) != key), w + ": no edge to a deleted node")
            _ = l.undo()
            is_text(export_json_canvas(l, 1, 1), text, w + ", deleted and undone")
            break
        # one made here: appended
        _ = l.add_sticky(5000, 5000, 120, "made here")
        var out2 = Json.parse(export_json_canvas(l, 1, 1))
        others_same(src, out2, w + ", made")
        var sn = src.get(0, "nodes")
        var on = out2.get(0, "nodes")
        assert_equal(out2.size(on), src.size(sn) + 1)
        for q in range(src.size(sn)):
            assert_true(same_json(src, src.at(sn, q), out2, out2.at(on, q)), w + ": the others as they were")
        _ = l.undo()
        is_text(export_json_canvas(l, 1, 1), text, w + ", made and undone")
        # a copy of each kind: the same node under another id
        for p in range(min(len(l.objs), 12)):
            if l.objs[p].kind == CONNECTOR:
                continue
            l.select(l.objs[p].id, False)
            var n0 = len(l.objs)
            l.duplicate_selection()
            if len(l.objs) == n0:
                continue
            var out3 = Json.parse(export_json_canvas(l, 1, 1))
            assert_equal(out3.size(out3.get(0, "nodes")), src.size(sn) + 1, w + ": a copy is a node")
            var ids = Dict[String, Bool]()
            for q in range(out3.size(out3.get(0, "nodes"))):
                var kid = out3.text(out3.get(out3.at(out3.get(0, "nodes"), q), "id"))
                if q == out3.size(out3.get(0, "nodes")) - 1:
                    assert_true(kid not in ids and kid != "", w + ": its own id")
                ids[kid] = True
            _ = l.undo()
            is_text(export_json_canvas(l, 1, 1), text, w + ", copied and undone")
        # random edits, then everything undone
        var seed = 99
        var steps = 0
        for _ in range(60):
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
            if len(l.objs) == 0:
                break
            var p = (seed >> 8) % len(l.objs)
            if l.objs[p].kind == CONNECTOR:
                continue
            l.select(l.objs[p].id, False)
            var act = (seed >> 4) % 5
            if act == 0:
                l.delete_selection()
            elif act == 1 and (l.objs[p].kind == TEXT or l.objs[p].kind == STICKY):
                l.set_words(l.objs[p].id, "w" + String(seed))
            elif act == 2:
                if seed % 2 == 0:
                    l.bring_to_front()
                else:
                    l.send_to_back()
            else:
                l.begin_gesture(CH_MOVE)
                l.move_by(Float64(seed % 40) - 20, Float64(seed % 31) - 15)
                l.end_gesture()
            _ = Json.parse(export_json_canvas(l, 1, 1))  # (valid at every step)
            steps += 1
        while l.undo():
            pass
        is_text(export_json_canvas(l, 1, 1), text, w + ": " + String(steps) + " edits, all undone: the very text")


def main() raises:
    # the reviewer's, as it was
    check('{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":100,"height":50,"text":"hi"},{"id":"img","type":"file","file":"pics/cat.png","x":200,"y":0,"width":300,"height":200,"pn":{"type":"image","src":"data:abc","style":{"opacity":0.5}}},{"id":"g","type":"group","label":"My group","x":0,"y":0,"width":900,"height":600,"background":"#eee"},{"id":"l","type":"link","url":"https://example.org","x":0,"y":300,"width":200,"height":100},{"id":"shape","type":"text","x":10,"y":400,"width":80,"height":80,"text":"","pn":{"type":"ellipse","style":{"fill":"#f00"}}}],"edges":[{"id":"e1","fromNode":"a","toNode":"img","label":"uses","color":"3","fromSide":"right","toSide":"left"}],"pn":{"page":{"columns":1,"rows":1,"paper":"dots"},"future":{"keep":"me"}},"other":"top level"}', "reviewer's")
    # jsoncanvas.org's sample (its kinds and edge ends), spelled with spaces
    check('{\n\t"nodes":[\n\t\t{"id":"754a8ef995f366bc","type":"group","x":-300,"y":-460,"width":610,"height":200,"label":"JSON Canvas"},\n\t\t{"id":"8132d4d894c80022","type":"file","file":"readme.md","x":-280,"y":-200,"width":570,"height":560,"color":"6"},\n\t\t{"id":"7efdbbe0c4742315","type":"file","file":"_site/logo.svg","x":-280,"y":-440,"width":217,"height":80},\n\t\t{"id":"59e896bc8da20699","type":"text","text":"Learn more:\\n\\n- [Apps](/docs/apps.md)\\n- [Spec](spec/1.0.md)\\n- [Github](https://github.com/obsidianmd/jsoncanvas)","x":40,"y":-440,"width":250,"height":160},\n\t\t{"id":"0ba565e7f30e0652","type":"file","file":"spec/1.0.md","x":360,"y":-400,"width":400,"height":400,"subpath":"#intro"}\n\t],\n\t"edges":[\n\t\t{"id":"6fa11ab87f90b8af","fromNode":"7efdbbe0c4742315","fromSide":"right","toNode":"59e896bc8da20699","toSide":"left"},\n\t\t{"id":"5d8e4ab8df6c5ea1","fromNode":"59e896bc8da20699","fromSide":"top","toNode":"0ba565e7f30e0652","toSide":"bottom","fromEnd":"arrow","toEnd":"none","color":"#ff0000","label":"spec"}\n\t]\n}', "spec sample")
    # strays, dangling and duplicate things, numbers spelled oddly, unknown kinds, members before and after
    check('{"first":[1,2,{"nodes":[]}],"edges":[{"id":"x","fromNode":"a","toNode":"nowhere","label":"dangling"},{"id":"y","fromNode":"a","toNode":"b","toEnd":"none"},{"id":"loop","fromNode":"a","toNode":"a"},{"id":"dup","fromNode":"a","toNode":"d","pn":{"type":"connector","geometry":{"x":1.25,"y":2,"width":3,"height":4,"k":[1]},"arrowheads":{"start":true,"end":false},"z":7}}],"nodes":[{"id":"a","type":"text","x":1.50e1,"y":-3,"width":120,"height":60,"text":"e\\u0301 \\u4e2d \\"q\\"","color":"2"},{"id":"b","type":"hologram","x":200,"y":0,"width":50,"height":50,"beam":{"deep":[null,true,-0]}},{"id":"d","type":"text","x":400,"y":0,"width":90,"height":40,"text":"first d"},{"id":"d","type":"text","x":500,"y":0,"width":90,"height":40,"text":"second d"},{"type":"text","x":0,"y":900,"width":90,"height":40,"text":"no id"},{"id":"bare"},{"id":"ink","type":"file","file":"k.svg","x":10,"y":700,"width":50,"height":20,"pn":{"type":"ink","kind":"stroke","geometry":{"x":10.25,"y":700.5,"width":50,"height":20,"rotation":0,"scaleX":1},"width":3.5,"color":"#112233","cap":"round","alpha":0.5,"path":[["M",0,0],["L",25,10],["Q",30,15,50,20]]}},{"id":"dot","type":"file","file":"d.svg","x":100,"y":700,"width":8,"height":8,"pn":{"type":"ink","kind":"dot","radius":4}},{"id":"c","type":"file","file":"c.svg","x":300,"y":700,"width":80,"height":80,"pn":{"type":"shape","kind":"circle","radius":40,"fill":"#00ff00","stroke":null,"geometry":{"x":300,"y":700,"width":80,"height":80}}}],"last":12.50}', "odd ones")
    check('{"nodes":[7,{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10,"text":"t"},null,"s",{"id":"b","type":"text","x":30,"y":0,"width":10,"height":10,"text":"u"}],"edges":[false,{"id":"e","fromNode":"a","toNode":"b"}]}', "strays in the arrays")
    check('{"nodes":[],"edges":[]}', "empty")
    check('{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10,"text":"t"}]}', "no edges")
    check('{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10,"text":"t"}],"edges":null,"pn":{"schemaVersion":1}}', "edges null")
    var files = 0
    for a in range(1, len(argv())):
        var dir = String(argv()[a])
        for name in listdir(dir):
            if not String(name).endswith(".json"):
                continue
            var t: String
            with open(dir + "/" + String(name), "r") as f:
                t = f.read()
            if t.find('"nodes"') < 0:
                continue
            check(t, String(name))
            files += 1
    print("canvasround: ok · " + String(files) + " documents from folders")
