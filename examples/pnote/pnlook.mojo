# Personal Note's own look for pnote's web shell (D-7928): its names for the framework's boxes (the web app's DOM ids and
# labels, so the checker can compare box for box), its notes panel (brand, Quick note, Alt N, Inbox, the PARA shelves),
# its three skins (skins.css: Paper, Night, Crayon) and its canvas tool island. Nothing here is in mojoui: another app
# gives its own (tests/test_notesshell builds one).

from mojoui.canvas import rgba
from mojoui.skin import Skin, Shadow, hexc
from mojoui.notesshell import Boxes, PanelConfig, Shelf, SkinChoice, DockItem, DOCK_TOOL, DOCK_DIVIDER, DOCK_DOT, DOCK_ACCENT


def pn_names(mut b: Boxes):
    """The web app's names for the framework's boxes."""
    b.alias("title", "#island")
    b.alias("title.face:", ".isl-face:{}")
    b.alias("title.icon", "#island-icon")
    b.alias("title.button", "#share-button")
    b.alias("title.words", "#island-title")
    b.alias("panel", "#sidebar")
    b.alias("panel.brand", ".brand-row")
    b.alias("panel.brand-mark", ".brand-mark")
    b.alias("panel.brand-name:", ".brand-name:{}")
    b.alias("panel.action", "#rail-new-note")
    b.alias("panel.action-key", "#quick-note-kbd")
    b.alias("panel.navigator", "#notebook-navigator")
    b.alias("panel.shelf", ".sec")
    b.alias("panel.loose-rows:", "[{}]")
    b.alias("panel.empty:", ".empty-notebook:{}")
    b.alias("panel.list", "#notebook-list")
    b.alias("panel.footer", ".sidebar-footer")
    b.alias("panel.skin-label:", ".skin-label:{}")
    b.alias("panel.skins", "#skin-switcher")
    b.alias("panel.skin:", "[{}]")
    b.alias("panel.shelf-head", ".sec-head")
    b.alias("panel.shelf-icon", ".sec-ic")
    b.alias("panel.badge", "#inbox-badge")
    b.alias("panel.row:", "row:{}")
    b.alias("panel.group-icon:", "[Icon and colour of {}]")
    b.alias("panel.group-row:", ".nav-row:{}")
    b.alias("dock", "[Canvas tools]")
    b.alias("dock.divider", ".dock-divider")
    b.alias("dock.tool:", "[{}]")
    b.alias("zoom", "[Zoom controls]")
    b.alias("zoom.out", "[Zoom out]")
    b.alias("zoom.label:", ".mindmap-zoom-label:{}")
    b.alias("zoom.in", "[Zoom in]")
    b.alias("hint:", ".mindmap-hint:{}")
    b.alias("history", "#history-island")
    b.alias("history.undo", "#undo")
    b.alias("history.redo", "#redo")
    b.alias("pagezoom", "#zoom-control")
    b.alias("pagezoom.out", "#zoom-out")
    b.alias("pagezoom.value", "#zoom-value")
    b.alias("pagezoom.in", "#zoom-in")
    b.alias("pagezoom.fit", "#zoom-fit")
    b.alias("selbar", "#selection-bar")
    b.alias("selbar.item:", ".selection-bar:{}")
    b.alias("settings.dim", "#settings-dim")
    b.alias("settings.window", "#properties-panel")
    b.alias("settings.frame", ".sw")
    b.alias("settings.nav", "[Settings sections]")
    b.alias("settings.close", "#close-properties")
    b.alias("settings.close-label", "[Close settings]")
    b.alias("settings.search-box", ".sw-search")
    b.alias("settings.search", "#settings-search")
    b.alias("settings.search-label", "[Search settings]")
    b.alias("settings.group", ".sw-group")
    b.alias("settings.pane", ".sw-pane")
    b.alias("settings.head", ".sw-head")
    b.alias("settings.body", ".sw-body")
    b.alias("settings.page", ".sw-page")
    b.alias("settings.choices", "[Skin]")
    b.alias("settings.choice", ".sw-skin")
    b.alias("settings.art", ".sw-art")
    b.alias("settings.item:", ".sw-item:{}")
    b.alias("settings.title:", ".sw-title:{}")
    b.alias("settings.blurb:", ".sw-blurb:{}")
    b.alias("page.host", "#page-host")
    b.alias("page.desk", ".page-desk")
    b.alias("page.paper", ".page-paper")
    b.alias("page.icon", "[Change icon]")
    b.alias("page.draw-hint", ".page-draw-hint")
    b.alias("page.tools", "[Page tools]")
    b.alias("page.editor:", ".page-editor:{}")
    b.alias("page.tool:", ".page-tool:{}")
    b.alias("page.group:", "[{}]")
    b.alias("omni.backdrop", "#search-backdrop")
    b.alias("omni", "[Search or jump to]")
    b.alias("omni.input", "#search-input")
    b.alias("omni.close", "#search-close")
    b.alias("omni.chips", "#omni-chips")
    b.alias("omni.body", ".omni-body")
    b.alias("omni.results", "#search-results")
    b.alias("omni.preview", "#omni-preview")
    b.alias("omni.input-row:", ".spotlight-input-row:{}")
    b.alias("omni.chip:", ".omni-chip:{}")
    b.alias("omni.group:", "[{}]")
    b.alias("omni.row:", "#omni-row-{}")
    b.alias("card", "#island")
    b.alias("card.menu", "#share-menu")
    b.alias("card.name", "#note-title")
    b.alias("card.status", "#save-state")
    b.alias("card.place", "#island-notebook")
    b.alias("card.wide-key", "#focus-top-kbd")
    b.alias("card.meta:", ".isl-meta:{}")
    b.alias("card.grid:", ".isl-grid:{}")
    b.alias("map.host", "#mindmap-host")
    b.alias("map.canvas", "[Mind map canvas]")
    b.alias("map.named:", "[{} mind map]")
    b.alias("map.idea:", "[{}]")
    b.alias("map.add-branch:", "[Add branch from {}]")
    b.alias("map.overview", "[Map overview]")
    b.alias("desk.sheet", "#paper-sheet")


def pn_panel() -> PanelConfig:
    """The notes panel as Personal Note fills it."""
    var c = PanelConfig()
    c.brand = "Personal Note"
    c.action_label = "Quick note"
    c.action_icon = "plus"
    c.action_key = "Alt N"
    c.loose_label = "Inbox"
    c.loose_icon = "inbox"
    c.shelves = [Shelf("projects", "Projects", "target", True, False), Shelf("areas", "Areas", "compass", True, False),
                 Shelf("resources", "Resources", "book-open", True, False), Shelf("archive", "Archive", "archive", False, True)]
    c.empty_text = "Drop a notebook here"
    c.skin_label = "Skin"
    c.skins = [SkinChoice("crayon", "Crayon skin", hexc("#2f6fe0")), SkinChoice("paper", "Paper skin", hexc("#1f1b16")),
               SkinChoice("night", "Night skin", hexc("#1b2130"))]
    return c^


def pn_skin_cards() -> Tuple[List[Skin], List[String]]:
    """The Appearance page's cards, in the web's order."""
    var s: List[Skin] = [skin_named("crayon"), skin_named("paper"), skin_named("night")]
    var l: List[String] = ["Crayon", "Paper", "Night"]
    return (s^, l^)


def canvas_dock_items(ink: UInt32) -> List[DockItem]:
    """A canvas note's tool island as Personal Note draws it (its own 24 px dock icons, stroke 1.7)."""
    var out = List[DockItem]()
    out.append(DockItem("[Select]", "path d=M5 3l6 16 2.2-6.8L20 10 5 3z", DOCK_TOOL, 0))
    out.append(DockItem("[Text]", "path d=M5 6V4h14v2M12 4v16M9 20h6", DOCK_TOOL, 0))
    out.append(DockItem("[Pen]", "path d=M4 20l4-1 11-11-3-3L5 16l-1 4z|path d=M14 6l3 3", DOCK_TOOL, 0))
    out.append(DockItem("[Stroke eraser]", "path d=M8 20h12|path d=M4.5 15.5l9-9a2 2 0 012.8 0l2.2 2.2a2 2 0 010 2.8L12 18H7l-2.5-2.5z", DOCK_TOOL, 0))
    out.append(DockItem("[Shape]", "rect x=4 y=4 width=16 height=16 rx=3", DOCK_TOOL, 0))
    out.append(DockItem("[Sticky note]", "path d=M5 4h14v10l-5 6H5z|path d=M14 20v-6h5", DOCK_TOOL, 0))
    out.append(DockItem(".dock-divider", "", DOCK_DIVIDER, 0))
    out.append(DockItem("#ink-options-trigger", "", DOCK_DOT, ink))
    out.append(DockItem("#dock-more", "plus", DOCK_TOOL, 0))
    out.append(DockItem("#voice-divider", "", DOCK_DIVIDER, 0))
    out.append(DockItem("#voice-button", "rect x=9 y=3 width=6 height=11 rx=3|path d=M5.5 11a6.5 6.5 0 0013 0M12 17.5V21", DOCK_ACCENT, 0))
    return out^


def _shadows(a: Float64, b: Float64, c: Float64, r: Int, g: Int, bl: Int) -> Tuple[List[Shadow], List[Shadow], List[Shadow]]:
    var s1 = List[Shadow]()
    s1.append(Shadow(0, 1, 2, 0, rgba(r, g, bl, 15)))
    s1.append(Shadow(0, 0, 0, 1, rgba(r, g, bl, Int(a * 255 + 0.5))))
    var s2 = List[Shadow]()
    s2.append(Shadow(0, 6, 18, 0, rgba(r, g, bl, 26)))
    s2.append(Shadow(0, 0, 0, 1, rgba(r, g, bl, Int(b * 255 + 0.5))))
    var s3 = List[Shadow]()
    s3.append(Shadow(0, 18, 48, 0, rgba(r, g, bl, 46)))
    s3.append(Shadow(0, 0, 0, 1, rgba(r, g, bl, Int(c * 255 + 0.5))))
    return (s1^, s2^, s3^)


def paper_skin() -> Skin:
    var s = Skin("paper")
    s.desk = hexc("#ece7dd")
    s.desk_dot = rgba(60, 45, 20, 26)  # .10
    s.panel = hexc("#fffdf8")
    s.edge = hexc("#e2dbcd")
    s.ink = hexc("#1f1b16")
    s.ink_soft = hexc("#4a443b")
    s.muted = hexc("#6b6357")
    s.line = hexc("#e2dbcd")
    s.accent = hexc("#1f1b16")
    s.accent_ink = hexc("#fffdf8")
    s.c1 = hexc("#ffd66b")
    s.c2 = hexc("#9fe0c0")
    s.c3 = hexc("#a9cfff")
    s.c4 = hexc("#cdb8ff")
    s.c5 = hexc("#ff9c85")
    s.danger = hexc("#b93a27")
    s.paper = hexc("#fbfaf5")
    s.page_radius = 4
    s.display = "Bricolage Grotesque"
    s.display_weight = 700
    s.title_track = -0.02
    s.radius = 14
    s.radius_control = 8
    s.state = rgba(31, 27, 22)
    s.swatch = hexc("#1f1b16")
    var sh = _shadows(0.05, 0.055, 0.06, 20, 16, 10)
    s.shadow1 = sh[0].copy()
    s.shadow2 = sh[1].copy()
    s.shadow3 = sh[2].copy()
    s.scrim = rgba(12, 10, 8, 82)
    s.locked = hexc("#6a46c9")  # (skins.css --sk-secure, -soft, -line)
    s.locked_soft = hexc("#efe9fb")
    s.locked_line = hexc("#d9cdf6")
    s.derive()
    return s^


def crayon_skin() -> Skin:
    var s = Skin("crayon")
    s.desk = hexc("#f2f2f7")
    s.desk_dot = rgba(0, 0, 40, 18)  # .07
    s.panel = hexc("#ffffff")
    s.edge = hexc("#e3e3ea")
    s.ink = hexc("#111114")
    s.ink_soft = hexc("#3a3a42")
    s.muted = hexc("#6e6e78")
    s.line = hexc("#e6e6ec")
    s.accent = hexc("#2f6fe0")
    s.accent_ink = hexc("#ffffff")
    s.c1 = hexc("#ffd60a")
    s.c2 = hexc("#30d158")
    s.c3 = hexc("#64b5ff")
    s.c4 = hexc("#bf5af2")
    s.c5 = hexc("#ff6b3d")
    s.danger = hexc("#d6391f")
    s.paper = hexc("#ffffff")
    s.page_radius = 10
    s.display = "Bricolage Grotesque"
    s.display_weight = 700
    s.title_track = -0.035
    s.radius = 18
    s.radius_control = 10
    s.state = rgba(17, 17, 20)
    s.swatch = hexc("#2f6fe0")
    var sh = _shadows(0.05, 0.055, 0.06, 10, 14, 40)
    s.shadow1 = sh[0].copy()
    s.shadow2 = sh[1].copy()
    s.shadow3 = sh[2].copy()
    s.scrim = rgba(12, 10, 8, 82)
    s.locked = hexc("#6a46c9")  # (skins.css --sk-secure, -soft, -line)
    s.locked_soft = hexc("#efe9fb")
    s.locked_line = hexc("#d9cdf6")
    s.derive()
    return s^


def night_skin() -> Skin:
    var s = Skin("night")
    s.dark = True
    s.accent_flat = True
    s.desk = hexc("#0d1015")
    s.desk_dot = rgba(160, 190, 255, 18)  # .07
    s.panel = hexc("#171c24")
    s.edge = hexc("#232a35")
    s.ink = hexc("#eceff4")
    s.ink_soft = hexc("#b9c1cd")
    s.muted = hexc("#7d8796")
    s.line = hexc("#262e3a")
    s.accent = hexc("#7ee7c8")
    s.accent_ink = hexc("#07261d")
    s.c1 = hexc("#ffc877")
    s.c2 = hexc("#7ee7c8")
    s.c3 = hexc("#9db4ff")
    s.c4 = hexc("#d3a6ff")
    s.c5 = hexc("#ff8fb1")
    s.danger = hexc("#ff8fb1")
    s.paper = hexc("#fbfaf5")
    s.page_radius = 6
    s.display = "Instrument Serif"
    s.display_weight = 400
    s.display_italic = True
    s.title_track = -0.01
    s.radius = 14
    s.radius_control = 8
    s.state = rgba(236, 239, 244)
    s.swatch = hexc("#1b2130")
    s.shadow1.append(Shadow(0, 1, 2, 0, rgba(0, 0, 0, 128)))
    s.shadow2.append(Shadow(0, 6, 18, 0, rgba(0, 0, 0, 115)))
    s.shadow2.append(Shadow(0, 0, 0, 1, rgba(236, 239, 244, 13)))
    s.shadow3.append(Shadow(0, 18, 48, 0, rgba(0, 0, 0, 153)))
    s.shadow3.append(Shadow(0, 0, 0, 1, rgba(236, 239, 244, 15)))
    s.scrim = rgba(0, 0, 0, 140)
    s.locked = hexc("#c3a8ff")
    s.locked_soft = rgba(195, 168, 255, 33)
    s.locked_line = rgba(195, 168, 255, 82)
    s.derive()
    return s^


def skin_named(name: String) -> Skin:
    if name == "night":
        return night_skin()
    if name == "crayon":
        return crayon_skin()
    return paper_skin()


def pn_boxes() -> Boxes:
    """A Boxes that records the web app's names."""
    var b = Boxes()
    pn_names(b)
    return b^
