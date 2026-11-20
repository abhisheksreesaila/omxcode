# Goal 79: the web-look components on their own (mojoui.skin, mojoui.strokeicon, mojoui.notesshell, mojoui.pagesheet,
# fonttext.line_metrics). Expected values are the web app's computed styles (docs/goals/79/ref.mjs's style dump).
#   pixi run mojo run -I . -I examples/pnote tests/test_notesshell.mojo        → "notesshell: ok"
from mojoui.skin import hexc
from pnlook import skin_named, pn_boxes, pn_panel, pn_skin_cards, canvas_dock_items
from mojoui.canvas import Surface, rgba
from mojoui.scene import SurfacePainter, Scene
from mojoui.strokeicon import icon_pixels, icon_segments
from mojoui.notesshell import Boxes, NotesPanel, PanelNote, PanelNotebook, PanelConfig, Shelf, SkinChoice, draw_desk, draw_title_island, title_island_width
from mojoui.settingswin import SettingsWindow, SettingsPage, skin_cards
from mojoui.skin import Skin
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
    var bx = pn_boxes()
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
    var panel = NotesPanel(pn_panel())
    panel.notes.append(PanelNote(1, "Lighthouse trip", "page", "✈️", 2, 0))
    panel.notebooks.append(PanelNotebook(1, "Travel", hexc("#b86b4b"), "projects", "plane", 0))
    panel.active = 1
    var boxes = pn_boxes()
    draw_desk(sp, Float64(w), Float64(h), 1, paper)
    panel.draw(sp, boxes, 1, paper, Float64(h))
    check(boxes.find("#sidebar") >= 0 and boxes.find("row:✈️ Lighthouse trip") >= 0 and boxes.find(".nav-row:Travel 0") >= 0, "panel boxes")
    var r = boxes.find("#rail-new-note")
    check(boxes.r[r * 4] == 27 and boxes.r[r * 4 + 1] == 133 and boxes.r[r * 4 + 2] == 258, "Quick note sits where the web's does")
    check(title_island_width("Lighthouse trip", False) == 148, "title island width")
    var sc = Scene(w, h, 1.0)
    var page = PageSheet()
    page.set_markdown("# Lighthouse trip\n\nThree days on the coast in **late May**.\n")
    var pb = pn_boxes()
    page.draw(sc, pb, 300, 66, 1428, 888, 1, "✈️", paper.c2, 14)
    check(pb.find("[Page tools]") >= 0 and pb.find(".page-paper") >= 0, "page boxes")
    # (D-7928) another app: its own brand, action, shelves, skins and no name table: the panel draws its words and the
    # framework's generic names, none of Personal Note's
    var cfg = PanelConfig()
    cfg.brand = "Field Log"
    cfg.action_label = "New entry"
    cfg.action_key = "Ctrl E"
    cfg.loose_label = "Today"
    cfg.shelves = [Shelf("trips", "Trips", "map", True, False), Shelf("done", "Done", "check", False, True)]
    var dawn = Skin("dawn")
    dawn.desk = hexc("#fff4e6")
    dawn.panel = hexc("#ffffff")
    dawn.ink = hexc("#202020")
    dawn.accent = hexc("#d9480f")
    dawn.accent_ink = hexc("#ffffff")
    dawn.derive()
    cfg.skins = [SkinChoice("dawn", "Dawn", dawn.accent), SkinChoice("dusk", "Dusk", hexc("#364fc7"))]
    var other = NotesPanel(cfg)
    other.notes.append(PanelNote(7, "Ridge walk", "page", "🥾", 1, 0))
    other.notebooks.append(PanelNotebook(3, "Alps 2027", hexc("#2b8a3e"), "trips", "", 2))
    other.active = 7
    var ob = Boxes()
    other.draw(sp, ob, 1, dawn, Float64(h))
    check(ob.find("panel") >= 0 and ob.find("panel.brand-name:Field Log") >= 0 and ob.find("panel.action-key") >= 0, "another app's panel names")
    check(ob.find("panel.row:🥾 Ridge walk") >= 0 and ob.find("panel.group-row:Alps 2027 2 A") >= 0, "its rows and groups")
    check(ob.find("panel.skin:Dawn") >= 0 and ob.find("panel.skin:Dusk") >= 0 and ob.find("panel.skin:Paper skin") < 0, "its own skins only")
    check(ob.find("panel.shelf-head@3") >= 0 and ob.find("panel.shelf-head@4") < 0, "the loose shelf and its two shelves: three heads")
    for i in range(len(ob.names)):
        var nm = ob.names[i]
        check(not nm.startswith("#") and nm.find("Personal Note") < 0 and nm.find("Inbox") < 0 and nm.find("Projects") < 0, "a Personal Note name leaked: " + nm)
    other.toggle_shelf(2)
    check(other.open_shelves[1], "toggle the second shelf")
    var sw = SettingsWindow("Preferences", "Find a preference")
    sw.groups.append([SettingsPage("Look", "sun", "How it looks.", "Dawn")])
    var sb = Boxes()
    var body = sw.draw(sc, sb, Float64(w), Float64(h), 1, dawn)
    var choices: List[Skin] = [dawn.copy()]
    skin_cards(sc, sb, body[0], body[1], body[2], 1, dawn, "dawn", choices, ["Dawn"])
    check(sb.find("settings.choice") >= 0 and sb.find("settings.choice@2") < 0 and sb.find("settings.title:Look") >= 0, "another app's settings: one skin card")
    print("notesshell: ok")
