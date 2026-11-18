# mojoui.iso + mojoui.explain (goal 77 M4): the isometric diagram an agent builds (genui's Iso, the explain tool): validated, laid
# out by the links, its blocks pointable parts named by their labels, drawn (light and dark: build/iso_light.png, build/iso_dark.png),
# a pointed-at block rising and its step marked.
from std.testing import assert_equal, assert_true
from mojoui.canvas import Surface
from mojoui.explain import explain_call, explain_tool, EXPLAIN
from mojoui.genui import GenUi, validate, sample
from mojoui.iso import IsoDiagram, explain_ui, walk_text, kind_index, draw_iso
from mojoui.json import Json
from mojoui.jsonpatch import JDoc
from mojoui.png import encode_png
from mojoui.pointer import match_clause, fitted_rect
from mojoui.text import Font
from mojoui.view import View
from mojoui.visual import card_kind
from themes.liquid import liquid_palette

comptime HEAT = (
    '{"title":"How a heat pump heats a house","blocks":[{"label":"Outdoor coil","kind":"device"},{"label":"Compressor","kind":"machine"},'
    '{"label":"Indoor coil","kind":"device"},{"label":"Expansion valve","kind":"device"}],'
    '"links":[{"from":"Outdoor coil","to":"Compressor","label":"warm gas"},{"from":"compressor","to":"Indoor coil","label":"hot gas"},'
    '{"from":"Indoor coil","to":"Expansion valve","label":"liquid"},{"from":"Expansion valve","to":"Outdoor coil","label":"cold liquid"}],'
    '"steps":[{"block":"Outdoor coil","text":"The outdoor coil soaks up heat from the outside air."},{"block":"the compressor","text":"The compressor squeezes the gas so it gets hot."},'
    '{"block":"Indoor coil","text":"The indoor coil gives the heat to the house."},{"block":"Expansion valve","text":"The expansion valve lets the pressure drop, so it is cold again."}],'
    '"colour":"ignored"}'
)


def names_in(v: View) -> List[String]:
    var out = List[String]()
    for i in range(len(v.nodes)):
        if v.nodes[i].name != "":
            out.append(v.nodes[i].name)
    return out^


def has(names: List[String], want: String) -> Bool:
    for n in names:
        if n == want:
            return True
    return False


def save(path: String, buf: List[UInt32], w: Int, h: Int) raises:
    var bytes = encode_png(buf, w, h)
    with open(path, "w") as f:
        f.write_bytes(Span(bytes))


def main() raises:
    # the catalog takes it; links and steps must name a block
    assert_equal(validate(sample("Iso")), "")
    assert_true(validate('{"ui":{"component":"Iso","blocks":[{"label":"A"},{"label":"B"},{"label":"C"}],"steps":[{"block":"Z","text":"z"}]}}').find("not one of its blocks") >= 0)
    assert_true(validate('{"ui":{"component":"Iso","blocks":[{"label":"A"},{"label":"B"}],"steps":[{"block":"A","text":"a"}]}}').startswith("bad prop"))  # (3 blocks at least)
    assert_equal(kind_index("Device"), 1)
    assert_equal(kind_index("machine"), 6)  # (unknown kinds are things)
    # the explain tool's arguments as a card: unknown props dropped, an unknown kind a thing, a step naming "the compressor" resolved
    var ui = explain_ui(HEAT)
    assert_equal(validate(ui), "")
    assert_true(ui.find('"title":"How a heat pump heats a house"') >= 0)
    assert_true(ui.find("colour") < 0)
    var j = Json.parse(ui)
    var d = IsoDiagram.parse(j, j.at(j.get(j.get(0, "ui"), "children"), 0))
    assert_equal(len(d.blocks), 4)
    assert_equal(len(d.links), 4)
    assert_equal(len(d.steps), 4)
    assert_equal(d.steps[1].block, 1)
    assert_equal(walk_text(d), "1 Outdoor coil, 2 Compressor, 3 Indoor coil, 4 Expansion valve")
    # layout: the loop is cut where it closes (expansion valve -> outdoor coil), so the layers follow the flow
    assert_equal(d.blocks[0].layer, 0)
    assert_equal(d.blocks[1].layer, 1)
    assert_equal(d.blocks[2].layer, 2)
    assert_equal(d.blocks[3].layer, 3)
    assert_true(d.width > 200 and d.height > 150)
    # the tool: shown, with the order to walk; a bad call refused with the reason
    var said = explain_call(HEAT)
    assert_true(said.startswith('{"shown":true'), said)
    assert_true(said.find("1 Outdoor coil, 2 Compressor") >= 0)
    assert_true(explain_call('{"title":"x","blocks":[{"label":"A"},{"label":"B"},{"label":"C"}],"links":[],"steps":[{"block":"Q","text":"q"}]}').startswith('{"error":"refused'))
    assert_true(explain_call("not json").startswith('{"error"'))
    assert_equal(explain_tool().name, EXPLAIN)
    # on a card: the drawing's view tagged, a step row each, its blocks parts named by their labels
    var screen = GenUi(ui, 100, 10)
    screen.card = "card4"
    assert_equal(screen.problem, "")
    assert_equal(card_kind("", screen.summary()), "iso")
    var names = names_in(screen.view(JDoc(), 0))
    assert_true(has(names, "card4.iso0"))
    var parts = screen.parts()
    assert_equal(len(parts), 4)
    assert_equal(parts[0].tag(), "card4.outdoor-coil")
    assert_equal(parts[1].tag(), "card4.compressor")
    assert_equal(parts[0].inside, "card4.iso0")
    var hits = match_clause("The outdoor coil soaks up heat, the compressor makes it hot, and the indoor coil warms the room.", parts)
    assert_equal(len(hits), 3)
    assert_equal(hits[0].tag(), "card4.outdoor-coil")
    assert_equal(hits[1].tag(), "card4.compressor")
    assert_equal(hits[2].tag(), "card4.indoor-coil")
    assert_true(hits[0].at < hits[1].at and hits[1].at < hits[2].at)
    assert_equal(match_clause("Then the valve drops the pressure.", parts)[0].tag(), "card4.expansion-valve")  # (a word only it has)
    # a block's box is inside the drawing and where the pointer will find it in a 360 x 250 view
    var r = fitted_rect([0.0, 0.0, 360.0, 250.0], parts[1].area)
    assert_true(r[0] > 0.0 and r[1] >= 0.0 and r[0] + r[2] < 360.0 and r[1] + r[3] <= 250.0)
    # pointed at: the compressor's step is marked, the next point moves the mark on
    screen.point_at("card4.compressor")
    assert_equal(screen.stepping[0], 1)
    screen.point_at("card4.indoor-coil")
    assert_equal(screen.stepping[0], 2)
    screen.point_at("card9.word")  # (another card's part: let go here)
    assert_equal(screen.focus, "")
    # drawn, light and dark: blocks in the theme's data colours, nothing outside the canvas
    var font = Font()
    for dark in [False, True]:
        var w = 720
        var h = 500
        var buf = List[UInt32](length=w * h, fill=0)
        var s = Surface(Int(buf.unsafe_ptr()), w, h, 2.0)
        s.still = True
        var p = liquid_palette(dark)
        draw_iso(s, d, p, font, 1, 1.0, -1, 1.0, 1)
        var ink = 0
        for i in range(w * h):
            if buf[i] != p.card:
                ink += 1
        assert_true(ink > w * h // 10, "the diagram covers a good part of its canvas")
        var c = fitted_rect([0.0, 0.0, Float64(w), Float64(h)], parts[1].area)
        var mid = buf[Int(c[1] + c[3] * 0.62) * w + Int(c[0] + c[2] / 2.0)]
        assert_true(mid != p.card, "the compressor is drawn inside its box")
        save("build/iso_light.png" if not dark else "build/iso_dark.png", buf, w, h)
    print("iso: ok (" + String(d.width) + " x " + String(d.height) + " units, parts " + String(len(parts)) + ")")
