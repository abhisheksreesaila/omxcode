# Goal 79: mojoui.pagedesk (a whiteboard on pages in Personal Note's look), the centre-ray connector rule of
# mojoui.objectlayer, notesshell's tool island / history island / page zoom island and strokeicon's inline icon specs, on
# their own, against Personal Note's own functions (values printed by its navigation.js, viewport.js, connectors.js on
# node) and the web's DOM boxes of the canvas screen (docs/goals/79/ref.mjs at 1440 × 900).
#   pixi run mojo run -I . -I examples/pnote tests/test_pagedesk.mojo        → "pagedesk: ok"
from mojoui.skin import hexc
from pnlook import skin_named, pn_boxes, pn_panel, pn_skin_cards, canvas_dock_items
from mojoui.scene import Scene, KeptPaint
from mojoui.notesshell import Boxes, draw_dock, dock_height, draw_history_island, draw_page_zoom
from mojoui.pagedesk import DeskView, BoardLook, opening_view, shadow_bands, draw_page_chrome, PAGE_W, PAGE_H
from mojoui.objectlayer import ObjectLayer, import_json_canvas, CONNECTOR, STICKY, TEXT
from mojoui.strokeicon import icon_segments
from mojoui.pagedesk import BoardTools, page_view, clamp_axis
from mojoui.objectlayer import export_json_canvas, INK
from mojoui.buzanmap import BuzanMap, map_json
from mojoui.pagesheet import PageSheet
from mojoui.islandcard import IslandCard
from mojoui.json import Json


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error("pagedesk: FAIL " + what)


def box(bx: Boxes, name: String) -> List[Float64]:
    var i = bx.find(name)
    if i < 0:
        return [-1.0, -1.0, -1.0, -1.0]
    return [bx.r[i * 4], bx.r[i * 4 + 1], bx.r[i * 4 + 2], bx.r[i * 4 + 3]]


def near(a: List[Float64], b: List[Float64], tol: Float64 = 0.01) -> Bool:
    for i in range(len(b)):
        if abs(a[i] - b[i]) > tol:
            return False
    return True


def test_lift_at_first_move() raises:
    """(D-8018) A press on an object lifts nothing (a click leaves the board's tiles as they are); the first movement
    lifts the selection, the release drops it; a press and release alone is no undo step."""
    var layer = ObjectLayer()
    var a = layer.add_sticky(100, 100, 120, "a")
    _ = layer.add_sticky(400, 100, 120, "b")
    var tools = BoardTools()
    tools.tool = "select"
    var v = DeskView(0, 0, 1)
    check(tools.press(150, 150, layer, v), "press on a")
    check(layer.is_selected(a) and len(tools.lifted(layer)) == 0, "pressed: selected, not lifted")
    check(tools.pan(150, 150, layer, v) and len(tools.lifted(layer)) == 0, "a pointer that didn't move: not lifted")
    check(tools.pan(153, 150, layer, v) and len(tools.lifted(layer)) == 1, "moved: lifted")
    check(tools.pan(150, 150, layer, v) and len(tools.lifted(layer)) == 1, "back where it began: still the same drag")
    _ = tools.release(150, 150, layer, v)
    check(len(tools.lifted(layer)) == 0, "released: dropped")
    check(tools.press(150, 150, layer, v) and len(tools.lifted(layer)) == 0, "a new press starts again")
    _ = tools.release(150, 150, layer, v)


def main() raises:
    test_lift_at_first_move()
    # the opening view (navigation.js openingView with main.js's margins): one page fits, a 4 × 3 grid opens at 0.4
    var v = opening_view(1440, 900, PAGE_W, PAGE_H)
    check(near([v.scale, v.x, v.y], [0.5611111111111111, 478.72222222222223, 104.0], 1e-9), "opening view of one page")
    var g = opening_view(1440, 900, PAGE_W * 4, PAGE_H * 3)
    check(near([g.scale, g.x, g.y], [0.4, 72.0, 104.0], 1e-9), "opening view of a big grid")
    var z = v.zoomed_at(1.0, 720, 450)
    var a = v.to_page(720, 450)
    var b = z.to_page(720, 450)
    check(near([a[0], a[1]], [b[0], b[1]], 1e-9), "zoom about a point keeps it")
    # shadow bands (viewport.js shadowBands, blur 18, alpha .1, 32 steps)
    var bands = shadow_bands(18, 0, 0.1)
    check(len(bands) == 32, "32 bands")
    check(near([bands[0][0], bands[0][1], bands[1][0], bands[1][1], bands[3][0], bands[3][1]],
               [18.0, 0.0022750062887256783, 16.838709677419356, 0.0007942720008032866, 14.516129032258064, 0.0012674597228508055], 1e-9), "band values")
    var sum = 0.0
    for t in bands:
        sum += t[1]
    check(abs(sum - 0.10263268852158758) < 1e-9, "band alpha sum")
    # the fixture's canvas: a text box, two stickies, one arrow, routed by the centre-ray rule with a 6 px gap
    var doc = String('{"nodes":[{"id":"a","type":"text","x":80,"y":80,"width":320,"height":120,"text":"# Garden plan\\nBeds by the south wall, herbs near the door.","pn":{"type":"text","style":{"fontFamily":"Source Serif 4","fontSize":24,"lineHeight":1.45,"color":"#20201e"}}},')
    doc += '{"id":"b","type":"text","x":460,"y":90,"width":200,"height":160,"text":"Tomatoes","color":"#e0de71","pn":{"type":"sticky","style":{"fontFamily":"Source Serif 4","fontSize":24,"lineHeight":1.45,"color":"#20201e"}}}],'
    doc += '"edges":[{"id":"e1","fromNode":"a","toNode":"b","color":"#20201e","pn":{"lineWidth":2.6,"arrowheads":{"start":false,"end":true}}}]}'
    var layer = import_json_canvas(doc)
    layer.set_connector_gap(6)
    check(layer.count_kind(TEXT) == 1 and layer.count_kind(STICKY) == 1 and layer.count_kind(CONNECTOR) == 1, "kinds")
    var c = -1
    for i in range(len(layer.objs)):
        if layer.objs[i].kind == CONNECTOR:
            c = i
    ref o = layer.objs[c]
    check(near([o.ax, o.ay, o.bx, o.by], [405.97380535635574, 155.56004425215835, 454.02619464364426, 160.06495574784165], 1e-6), "connector ends (connectorEndpoints)")
    check(o.line_width == 2.6 and o.head_end, "connector width and head")
    var t = -1
    for i in range(len(layer.objs)):
        if layer.objs[i].kind == TEXT:
            t = i
    check(layer.objs[t].family == "Source Serif 4" and layer.objs[t].line_height == 1.45 and layer.objs[t].color == hexc("#20201e"), "text type")
    # words wrap at the box (Leafer's normal wrap): the web breaks after "herbs"
    var look = BoardLook()
    var lines = look.lines(layer.objs[t], 320)
    check(len(lines) == 3 and lines[1] == "Beds by the south wall, herbs" and lines[2] == "near the door.", "wrap: " + String(len(lines)))
    # the board paints: one run per line, the sticky's words, the arrow
    var sc = Scene(2304, 1440, 1.6)
    var sk = skin_named("paper")
    var bx = pn_boxes()
    var frame_kept = KeptPaint()
    draw_page_chrome(sc, bx, v, 1440, 900, 1, 1, PAGE_W, PAGE_H, 1.6, sk, frame_kept)
    # (D-8024) again, moved: replayed op for op under the same version; another zoom, another grid: drawn anew
    var fa = Scene(2304, 1440, 1.6)
    draw_page_chrome(fa, bx, v, 1440, 900, 4, 4, PAGE_W, PAGE_H, 1.6, sk, frame_kept)
    var fb = Scene(2304, 1440, 1.6)
    draw_page_chrome(fb, bx, DeskView(v.x + 33, v.y - 7, v.scale), 1440, 900, 4, 4, PAGE_W, PAGE_H, 1.6, sk, frame_kept)
    check(fa.ops() == fb.ops() and fa.ops() > 600, "page frame replayed: " + String(fa.ops()))
    check(fa.same_layer(0, fb, 0) and fb.layer_tx[0] == (v.x + 33) * 1.6, "the same picture, moved")
    for op in range(fa.ops()):
        check(fa.same_op(op, fb, op), "page frame op " + String(op))
    var fc = Scene(2304, 1440, 1.6)
    draw_page_chrome(fc, bx, DeskView(v.x, v.y, v.scale * 1.01), 1440, 900, 4, 4, PAGE_W, PAGE_H, 1.6, sk, frame_kept)
    check(not fc.same_layer(0, fb, 0), "another zoom: another picture")
    look.paint(sc, layer, v, 1440, 900, 1.6)
    check(near(box(bx, "#paper-sheet"), [v.x, v.y, PAGE_W * v.scale, PAGE_H * v.scale], 1e-9), "sheet box")
    # the canvas islands at the web's boxes (canvas.boxes.json)
    var d = pn_boxes()
    var items = canvas_dock_items(hexc("#20201e"))
    draw_dock(sc, d, 1440 - 72, 72 + (900 - 144 - dock_height(items)) / 2, items, "[Text]", 1.6, sk, "#dock-canvas")
    check(near(box(d, "[Canvas tools]"), [1368.0, 222.0, 56.0, 456.0]), "dock box")
    check(near(box(d, "#dock-canvas"), [1374.0, 229.0, 44.0, 442.0]), "dock column")
    check(near(box(d, "[Sticky note]"), [1374.0, 459.0, 44.0, 44.0]), "sticky tool")
    check(near(box(d, ".dock-divider"), [1382.0, 511.0, 28.0, 1.0]), "divider")
    check(near(box(d, "#ink-options-dot"), [1382.0, 528.0, 28.0, 28.0]), "ink dot")
    check(near(box(d, "#voice-divider"), [1382.0, 618.0, 28.0, 1.0]), "voice divider")
    check(near(box(d, "#voice-button"), [1374.0, 627.0, 44.0, 44.0]), "voice button")
    draw_history_island(sc, d, 16, 836, 1.6, sk)
    check(near(box(d, "#redo"), [69.0, 838.0, 44.0, 44.0]) and near(box(d, "#history-island"), [16.0, 836.0, 104.0, 48.0]), "history island")
    draw_page_zoom(sc, d, 1424, 836, 56, 1.6, sk)
    check(near(box(d, "#zoom-control"), [1239.0, 836.0, 185.0, 48.0]) and near(box(d, "#zoom-value"), [1284.0, 844.0, 48.0, 32.0])
          and near(box(d, "#zoom-fit"), [1381.0, 842.0, 36.0, 36.0]), "zoom island")
    # an app's own icon goes through the stroker like a Lucide one
    check(len(icon_segments("rect x=4 y=4 width=16 height=16 rx=3")) > 16 and len(icon_segments("path d=M5 6V4h14v2M12 4v16M9 20h6")) == 5 * 4, "inline icon specs")
    # ---- the tools (goal 79 M4), against the web's numbers (steps.mjs probes at 1440 × 900)
    var board = import_json_canvas(doc)
    board.set_connector_gap(6)
    var tools = BoardTools()
    var view = opening_view(1440, 900, PAGE_W, PAGE_H)
    # the Text tool at (700, 600): writing comes back to 100 % about the page origin, the line 16 px above the bottom
    check(tools.tap(700, 600, board, view, 1440, 900), "text tap")
    check(abs(view.scale - 1) < 1e-9 and abs(view.x - 478.72222222222223) < 1e-6 and abs(view.y - (-34.757)) < 0.01, "writing view (the web: editor top 849.203 for the page point 883.960): " + String(view.y))
    check(abs(tools.edit_x - (700 - 478.72222222222223) / 0.5611111111111111) < 1e-6 and tools.edit_w == 410, "writing box (margin 56): " + String(tools.edit_w))
    for ch in ["C", "o", "m", "p", "o", "s", "t"]:
        _ = tools.key(ch, 0, board, view, 1440, 900, 1, 1)
    _ = tools.key("Escape", 0, board, view, 1440, 900, 1, 1)
    check(tools.tool == "select" and board.count_kind(TEXT) == 2 and tools.changed, "a text made on Escape")
    # the Sticky tool opens the page (pageView: 57 %) and places a 240 × 200 sticky centred on the tap
    tools.set_tool("sticky", board, view, 1440, 900, 1, 1)
    check(abs(view.scale - 0.5703703703703704) < 1e-9 and abs(view.x - (140 + (1160 - 860 * 616.0 / 1080) / 2)) < 1e-6 and abs(view.y - 104) < 1e-9, "page view")
    _ = tools.tap(860, 480, board, view, 1440, 900)
    var sid = board.selected[0]
    ref so = board.objs[board.index(sid)]
    check(abs(so.x - 555.5) < 0.05 and abs(so.y - 559.2) < 0.05 and so.w == 240 and so.h == 200 and so.family == "Caveat", "sticky placed")
    for ch in ["S", "e", "e", "d", "s"]:
        _ = tools.key(ch, 0, board, view, 1440, 900, 1, 1)
    _ = tools.key("Escape", 0, board, view, 1440, 900, 1, 1)
    check(board.objs[board.index(sid)].text == "Seeds", "sticky words")
    # undo takes the sticky and its words away in one step, redo brings both back
    tools.undo(board)
    check(not board.has(sid), "undo the sticky")
    tools.redo(board)
    check(board.has(sid) and board.objs[board.index(sid)].text == "Seeds", "redo the sticky with its words")
    # connect: a drag from the new text to the sticky
    _ = tools.key("c", 0, board, view, 1440, 900, 1, 1)
    check(tools.press(720, 615, board, view) and tools.release(860, 480, board, view), "connect drag")
    check(board.count_kind(CONNECTOR) == 2, "connector made")
    # (D-7935) delete the sticky the new connector ends at, then undo: it comes back selected, and the connector ends at
    # it again (as the web's undo shows it), not where it was left
    var cq = -1
    for q in range(len(board.objs)):
        if board.objs[q].kind == CONNECTOR:
            cq = q
    var end_before = (board.objs[cq].bx, board.objs[cq].by)
    board.clear_selection()
    board.select(sid)
    _ = tools.key("Delete", 0, board, view, 1440, 900, 1, 1)
    check(not board.has(sid), "the sticky deleted")
    tools.undo(board)
    check(board.has(sid) and len(board.selected) == 1 and board.selected[0] == sid, "undo brings the sticky back selected")
    for q in range(len(board.objs)):
        if board.objs[q].kind == CONNECTOR:
            cq = q
    check(abs(board.objs[cq].bx - end_before[0]) < 0.01 and abs(board.objs[cq].by - end_before[1]) < 0.01, "the connector ends at the sticky again")
    # the zoom island's + (57 % → 71 %)
    var zv = tools.zoom_step(view, 1, 1440, 900, 1, 1)
    check(Int(zv.scale * 100 + 0.5) == 71, "zoom step")
    # the document again: JSON Canvas the web's normalizer reads as the same objects
    var out = export_json_canvas(board)
    var j = Json.parse(out)
    check(j.size(j.get(0, "nodes")) == 4 and j.size(j.get(0, "edges")) == 2, "export counts")
    var again = import_json_canvas(out)
    check(again.count_kind(STICKY) == 2 and again.count_kind(TEXT) == 2 and again.count_kind(CONNECTOR) == 2, "export → import")
    # ---- the map's new ideas (model.js makeNode: the web saved Weather at (275, 190) #3d8fe8, Endings at (-275, 228) #8c67cf)
    var m = BuzanMap()
    var r = m.add(-1, "The book", 0, 0, hexc("#ef684b"), "root")
    var cols: List[String] = ["#efad28", "#65ae4f", "#2d9c91", "#3d8fe8"]
    var xy: List[Float64] = [280, -130, -280, -130, 280, 130, -280, 130]
    for q in range(4):
        _ = m.add(r, "k" + String(q), xy[2 * q], xy[2 * q + 1], hexc(cols[q]), "k" + String(q))
    m.selected = r
    var c1 = m.add_idea(False)
    check(m.topics[c1].x == 275 and m.topics[c1].y == 190 and m.topics[c1].color == hexc("#3d8fe8") and m.editing == c1, "child idea")
    for ch in ["W", "e", "a", "t", "h", "e", "r"]:
        _ = m.edit_key(ch, 0)
    check(m.edit_key("Enter", 0) == 2 and m.topics[c1].text == "Weather", "child named")
    var c2 = m.add_idea(True)
    check(m.topics[c2].x == -275 and m.topics[c2].y == 228 and m.topics[c2].color == hexc("#8c67cf") and m.topics[c2].font_size == 22, "sibling idea")
    _ = m.edit_key("Escape", 0)
    check(m.topics[c2].text == "New idea" and "Weather" in map_json(m, "Book", "root"), "map json")
    # ---- a page: a tap types only on words (the web's onText), keys move the caret
    var pg = PageSheet()
    pg.set_markdown("- [ ] Binoculars\n\nend")
    var bxs = pn_boxes()
    pg.draw(sc, bxs, 4, 66, 1436, 888, 1.6, "", 0, 14)
    check(not pg.tap(900, pg.line_top[0] + 5), "a tap far past the words starts a mark")
    check(pg.tap(pg.text_x + 3, pg.line_top[0] + 5), "a tap on the words places the caret")
    pg.caret_home()
    pg.caret_right()
    pg.caret_right()
    pg.caret_right()
    pg.delete_forward()
    pg.insert("x")
    check(pg.lines[0] == "- [x] Binoculars", "ticked: " + pg.lines[0])
    # ---- the island card's name field
    var card = IslandCard()
    card.title = "Lighthouse trip"
    card.editing = True
    _ = card.title_key("a", 2)
    _ = card.title_key("W", 0)
    check(card.title == "W" and card.title_key("Enter", 0) == 2 and not card.editing, "name field")
    print("pagedesk: ok")
