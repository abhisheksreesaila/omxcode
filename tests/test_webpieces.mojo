# Goal 79: mojoui.omnibar, mojoui.islandcard, mojoui.settingswin, mojoui.pagesheet's editing and draw_radial_steps on
# their own, against the web app's computed boxes (docs/goals/79/ref.mjs) and its rules.
#   pixi run mojo run -I . -I examples/pnote tests/test_webpieces.mojo        → "webpieces: ok"
from pnlook import skin_named, pn_boxes, pn_panel, pn_skin_cards, canvas_dock_items
from mojoui.scene import Scene
from mojoui.notesshell import Boxes, draw_radial_steps
from mojoui.omnibar import Omnibar, OmniGroup, OmniRow, OmniPill, relative_time, utc_epoch, word_match
from mojoui.islandcard import IslandCard, CardTile
from mojoui.settingswin import SettingsWindow, SettingsPage, skin_cards
from mojoui.pagesheet import PageSheet


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error("webpieces: FAIL " + what)


def box(bx: Boxes, name: String) -> List[Float64]:
    var i = bx.find(name)
    if i < 0:
        return [-1.0, -1.0, -1.0, -1.0]
    return [bx.r[i * 4], bx.r[i * 4 + 1], bx.r[i * 4 + 2], bx.r[i * 4 + 3]]


def near(a: List[Float64], b: List[Float64]) -> Bool:
    for i in range(4):
        if abs(a[i] - b[i]) > 0.6:
            return False
    return True


def main() raises:
    var sk = skin_named("paper")
    var sc = Scene(2304, 1440, 1.6)
    # the omnibar: the web's spotlight is 760 wide at (340, 96), its rows 56 tall from 224
    var o = Omnibar()
    o.query = "li"
    o.pills.append(OmniPill("All", ""))
    o.pills.append(OmniPill("Notes", "2"))
    var rows = List[OmniRow]()
    rows.append(OmniRow("📚", "", sk.c4, "Reading list", "Page", "Inbox", sk.ink, "now"))
    o.groups.append(OmniGroup("Notes", rows^))
    var bx = pn_boxes()
    o.draw(sc, bx, 1440, 900, 1.6, sk)
    check(near(box(bx, "[Search or jump to]"), [340.0, 96.0, 760.0, 456.39]), "spotlight box")
    check(near(box(bx, "#omni-row-0"), [349.0, 224.0, 492.0, 56.0]), "first row box")
    check(near(box(bx, ".omni-chip:Notes 2"), [400.0, 162.0, 68.0, 25.0]), "pill box")
    check(word_match("Lighthouse trip", "li") and word_match("Reading list", "li") and not word_match("Garden plan", "li"), "word starts")
    check(relative_time("2026-11-20 04:00:00", utc_epoch("2026-11-20 04:00:30")) == "now", "now")
    check(relative_time("2026-11-20 04:00:00", utc_epoch("2026-11-20 04:05:10")) == "5 min ago", "minutes")
    check(relative_time("2026-11-20 04:00:00", utc_epoch("2026-11-20 07:00:00")) == "3 h ago", "hours")
    # the island card: 422 wide, centred over the note area; its tiles 93.5 × 64
    var c = IslandCard()
    c.title = "Book mind map"
    c.status = "Saved on this device"
    c.place = "Inbox"
    c.wide_id = "#share-focus"
    c.wide_label = "Focus"
    c.wide_icon = "focus"
    c.wide_key = "Ctrl ."
    for t in range(10):
        c.tiles.append(CardTile("#t" + String(t), "Tile", "printer", t == 9))
    var bc = pn_boxes()
    c.draw(sc, bc, 16, 1424, 1.6, sk)
    check(near(box(bc, "#island"), [509.0, 16.0, 422.0, 354.0]), "card box")
    check(near(box(bc, "#t1"), [623.5, 152.59, 93.5, 64.0]), "a tile")
    # the settings window: 900 × 620 centred, nav items 42 tall from 264
    var sw = SettingsWindow()
    var g = List[SettingsPage]()
    g.append(SettingsPage("Appearance", "sun", "How Personal Note looks.", "Paper"))
    g.append(SettingsPage("Writing", "pen-line", "", ""))
    sw.groups.append(g^)
    var bs = pn_boxes()
    var body = sw.draw(sc, bs, 1440, 900, 1.6, sk)
    check(near(box(bs, "#properties-panel"), [270.0, 140.0, 900.0, 620.0]), "window box")
    check(near(box(bs, ".sw-item:AppearancePaper"), [280.0, 264.0, 244.0, 42.0]), "nav item")
    var cards = pn_skin_cards()
    skin_cards(sc, bs, body[0], body[1], body[2], 1.6, sk, "paper", cards[0], cards[1])
    check(near(box(bs, ".sw-skin@2"), [761.33, 244.48, 181.33, 152.0]), "skin card")
    # page editing: caret at the end, typing, an input method's commit, newline, backspace by whole characters
    var p = PageSheet()
    p.set_markdown("# Title\n\n")
    p.caret_end()
    p.insert("漢字")
    p.newline()
    p.insert("नमस्ते")
    p.backspace()
    check(p.markdown() == "# Title\n\n漢字\nनमस्त", "editing: " + p.markdown())
    # a CSS radial gradient as its colour steps draws (and stays inside its box)
    draw_radial_steps(sc, 4, 66, 1424, 822, 0.48, 0.44, 0xFFFAFEFF, 0xFFEFF6F8, 0.74, 14)
    print("webpieces: ok")
