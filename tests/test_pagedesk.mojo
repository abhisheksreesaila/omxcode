# Goal 79: mojoui.pagedesk (a whiteboard on pages in Personal Note's look), the centre-ray connector rule of
# mojoui.objectlayer, notesshell's tool island / history island / page zoom island and strokeicon's inline icon specs, on
# their own, against Personal Note's own functions (values printed by its navigation.js, viewport.js, connectors.js on
# node) and the web's DOM boxes of the canvas screen (docs/goals/79/ref.mjs at 1440 × 900).
#   pixi run mojo run -I . tests/test_pagedesk.mojo        → "pagedesk: ok"
from mojoui.skin import skin_named, hexc
from mojoui.scene import Scene
from mojoui.notesshell import Boxes, draw_dock, dock_height, canvas_dock_items, draw_history_island, draw_page_zoom
from mojoui.pagedesk import DeskView, BoardLook, opening_view, shadow_bands, draw_page_chrome, PAGE_W, PAGE_H
from mojoui.objectlayer import ObjectLayer, import_json_canvas, CONNECTOR, STICKY, TEXT
from mojoui.strokeicon import icon_segments


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


def main() raises:
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
    var bx = Boxes()
    draw_page_chrome(sc, bx, v, 1440, 900, 1, 1, PAGE_W, PAGE_H, 1.6, sk)
    look.paint(sc, layer, v, 1440, 900, 1.6)
    check(near(box(bx, "#paper-sheet"), [v.x, v.y, PAGE_W * v.scale, PAGE_H * v.scale], 1e-9), "sheet box")
    # the canvas islands at the web's boxes (canvas.boxes.json)
    var d = Boxes()
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
    print("pagedesk: ok")
