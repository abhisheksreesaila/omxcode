# Goal 79: the web-look components on their own (mojoui.skin, mojoui.strokeicon, mojoui.notesshell, mojoui.pagesheet,
# fonttext.line_metrics). Expected values are the web app's computed styles (docs/goals/79/ref.mjs's style dump).
#   pixi run mojo run -I . tests/test_notesshell.mojo        → "notesshell: ok"
from mojoui.skin import skin_named, hexc
from mojoui.canvas import Surface, rgba
from mojoui.scene import SurfacePainter, Scene
from mojoui.strokeicon import icon_pixels, icon_segments
from mojoui.notesshell import Boxes, NotesPanel, PanelNote, PanelNotebook, draw_desk, draw_title_island, title_island_width
from mojoui.pagesheet import PageSheet
from mojoui.fonttext import TextStyle, line_metrics, baseline_in


def chan(c: UInt32, i: Int) -> Int:
    return Int((c >> UInt32(8 * i)) & 0xFF)


def near(c: UInt32, r: Int, g: Int, b: Int) -> Bool:
    return abs(chan(c, 0) - r) <= 1 and abs(chan(c, 1) - g) <= 1 and abs(chan(c, 2) - b) <= 1


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error("notesshell: FAIL " + what)


def main() raises:
    # skins: derived colours equal the browser's color-mix results
    var paper = skin_named("paper")
    check(near(paper.ui_muted, 84, 77, 67), "paper --ui-muted")  # color(srgb .330 .304 .265)
    check(near(paper.toggle_on, 226, 224, 219), "paper toggle open")  # color(srgb .886 .877 .857)
    check(near(paper.accent_fill, 31, 27, 22), "paper --accent-fill")
    var night = skin_named("night")
    check(night.accent_fill == night.accent and night.display == "Instrument Serif" and night.display_italic, "night tokens")
    check(skin_named("crayon").radius == 18, "crayon radius")
    # icons: Lucide's geometry rasterized, ink where the strokes are and nowhere else
    check(len(icon_segments("panel-left")) > 16, "panel-left geometry")
    var nseg = len(icon_segments("file-text")) // 4
    check(nseg > 30, "file-text has its outline (multi-line node)")
    _ = icon_pixels("search", 32, rgba(31, 27, 22), 2)
    # boxes: duplicates numbered, taps reach the topmost actionable box
    var bx = Boxes()
    bx.add(".sec-head", 0, 0, 100, 34)
    bx.add(".sec-head", 0, 40, 100, 34)
    bx.add("row:a", 10, 45, 50, 20)
    bx.add("#notebook-list", 0, 0, 100, 100)
    check(bx.find(".sec-head@2") == 1, "duplicate names")
    check(bx.hit(20, 50) == "#notebook-list", "hit: topmost")
    check(bx.hit_any(20, 50, ["row:", ".sec-head"]) == "row:a", "hit_any: actionable")
    # metrics as Blink keeps them
    check(line_metrics(TextStyle("Literata", 400, False, 18)).ascent + line_metrics(TextStyle("Literata", 400, False, 18)).descent == 27, "Literata content area")
    check(baseline_in(195.25, 13.5, TextStyle("Geist", 600, False, 13.5)) == 192.25 + 14, "a shelf label's baseline")
    # the panel and a page draw (through both painters) and name what the web names
    var w = 1440
    var h = 900
    var px = List[UInt32](length=w * h, fill=0)
    var sp = SurfacePainter(Surface(Int(px.unsafe_ptr()), w, h, 1.0))
    var panel = NotesPanel()
    panel.notes.append(PanelNote(1, "Lighthouse trip", "page", "✈️", 2, 0))
    panel.notebooks.append(PanelNotebook(1, "Travel", hexc("#b86b4b"), "projects", "plane", 0))
    panel.active = 1
    var boxes = Boxes()
    draw_desk(sp, Float64(w), Float64(h), 1, paper)
    panel.draw(sp, boxes, 1, paper, Float64(h))
    check(boxes.find("#sidebar") >= 0 and boxes.find("row:✈️ Lighthouse trip") >= 0 and boxes.find(".nav-row:Travel 0") >= 0, "panel boxes")
    var r = boxes.find("#rail-new-note")
    check(boxes.r[r * 4] == 27 and boxes.r[r * 4 + 1] == 133 and boxes.r[r * 4 + 2] == 258, "Quick note sits where the web's does")
    check(title_island_width("Lighthouse trip", False) == 148, "title island width")
    var sc = Scene(w, h, 1.0)
    var page = PageSheet()
    page.set_markdown("# Lighthouse trip\n\nThree days on the coast in **late May**.\n")
    var pb = Boxes()
    page.draw(sc, pb, 300, 66, 1428, 888, 1, "✈️", paper.c2, 14)
    check(pb.find("[Page tools]") >= 0 and pb.find(".page-paper") >= 0, "page boxes")
    print("notesshell: ok")
