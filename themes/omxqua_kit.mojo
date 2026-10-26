# omxqua's measures for mojoui's page components (goal 33 M7, D-417): the roles of mojoui.shell, header, sidebar,
# panel, marks, words, buttons, copy, fields, results, meter, feedback and beacon, valued as the OMX Console wears
# omxqua (~/Projects/mxstudio/mxconsole/console: topbar.css, blades.css, library.css, model-page.css, blade-*.css and
# omxqua's components.css; each value beside the rule it comes from). The components carry no sizes or colours; this
# file is where they come from. kit_roles(palette, mono) gives omxqua_look all of them.

from mojoui.canvas import rgba
from mojoui.theme import Palette, Surface, Shadow, words, mix, HEIGHT_AUTO
from mojoui.view import CENTER, START

comptime BEACON_BG = 0xFF0D0B0B  # #0b0b0d (the Beacon is dark in both modes, like a terminal)
comptime BEACON_INK = 0xFFF5F4F4  # #f4f4f5
comptime BEACON_QUIET = 0xFFAAA1A1  # #a1a1aa
comptime CODE_BG = 0xFF0D0B0B  # --code
comptime CODE_INK = 0xFFE7E4E4  # --code-text
comptime CODE_BUTTON = 0xFF2A2727  # #27272a
comptime SIGNAL: List[UInt32] = [0xFFFF667C, 0xFFFF9000, 0xFF94A512, 0xFF156BF7, 0xFF4D48E5]  # core.js SIGNAL #7c66ff #0090ff #12a594 #f76b15 #e5484d (ABGR)


def tint(c: UInt32, a: Float64) -> UInt32:
    """`c` at alpha `a` (rgb(var(--oq-state) / a) when `c` is the ink)."""
    return (c & 0xFFFFFF) | (UInt32(Int(a * 255 + 0.5)) << 24)


def box(role: String, fill: UInt32, radius: Int, pad_v: Int, pad_h: Int) -> Surface:
    """A role with a fill (0: none), corners (-1: none of its own) and padding (-1: none of its own)."""
    return Surface(role, fill, radius, radius, -1, -1, -1, pad_v, pad_h, pad_v, [], 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False)


def words_role(role: String, size: Float64, weight: Int, ink: UInt32, font: String = "", tracking: Float64 = 0, line: Float64 = 0) -> Surface:
    """A role that is its words only."""
    var s = words(role, size, weight, ink, tracking)
    s.font, s.line_height = font, line
    return s^


def layout(role: String, gap: Int = -1, pad_v: Int = -1, pad_h: Int = -1) -> Surface:
    """A role that only lays its children out: the space between them and round them."""
    var s = box(role, 0, -1, pad_v, pad_h)
    s.gap = gap
    return s^


def hue_inks(p: Palette) -> List[UInt32]:
    """Hues 1–8: the six data colours, good, warning."""
    return [p.data(0), p.data(1), p.data(2), p.data(3), p.data(4), p.data(5), p.good, p.warn]


def with_hues(base: Surface, p: Palette, mut out: List[Surface]):
    """`base` and its eight hued copies (role-1 … role-8: its icon in the hue, the console's --c)."""
    var inks = hue_inks(p)
    for k in range(8):
        var h = base.copy()
        h.role, h.icon_ink = base.role + "-" + String(k + 1), inks[k]
        out.append(h^)
    out.append(base.copy())


def card_look(role: String, p: Palette, shadows: List[Shadow]) -> Surface:
    """omxqua's card (.card, .blade): surface-1, card corners, shadow-1, no padding (its parts pad themselves)."""
    var s = box(role, p.card, 12, 0, 0)
    s.shadows = shadows.copy()
    return s^


def shell_roles(p: Palette, mono: String, shadow: List[Shadow]) -> List[Surface]:
    """mojoui.shell (topbar.css, blades.css .journey/.blade, nav.js)."""
    var out = List[Surface]()
    var bar = layout("app-bar", 6, 0, 14)  # .bar: 60 high, 0 14px, 6 between
    bar.height = 60
    out.append(bar^)
    var bar_c = layout("app-bar-compact", 4, 0, 8)  # @container ≤ 760: 0 8px, 4 between
    bar_c.height = 60
    out.append(bar_c^)
    var brand = box("brand", 0, 12, 6, 8)  # .brand: 6px 8px, 9 between, 12 corners
    brand.gap = 9
    out.append(brand^)
    var mark = box("brand-mark", p.ink, 8, -1, -1)  # .brand .mk: 28 × 28, 8 corners, the ink; 700 10px mono in surface-0
    mark.width, mark.height = 28, 28
    mark.font, mark.font_size, mark.font_weight, mark.ink, mark.line_height, mark.tracking = mono, 10, 700, p.page, -1, -0.3  # (.brand's -.02em)
    out.append(mark^)
    var name = box("brand-name", 0, 0, 0, 0)  # .brand: 650 15px, -.02em, no button chrome
    name.font_size, name.font_weight, name.ink, name.tracking, name.line_height = 15, 650, p.ink, -0.3, -1
    out.append(name^)
    var rule = box("bar-rule", 0, -1, 0, 0)  # .crumbs: margin-left 4, its 1px line-2 rule 22 high
    rule.pad_left = 4
    out.append(rule^)
    var rule_c = box("bar-rule-compact", 0, -1, 0, 0)  # (≤ 760: the bar's gaps are 4, the crumbs' padding stays 6)
    rule_c.pad_left, rule_c.pad_right = 4, 2
    out.append(rule_c^)
    var line = box("bar-rule-line", p.line, 0, -1, -1)
    line.width, line.height = 1, 22
    out.append(line^)
    out.append(layout("nav-links", 2))  # .places: 2 between
    var link = box("nav-link", 0, 10, 0, 11)  # .places a: 36 high, 0 11px, 10 corners, 550 13px ink-2; a 15 pt icon (1.75), 7 from its word
    link.height, link.font_size, link.font_weight, link.ink, link.line_height = 36, 13, 550, p.ink2, -1
    link.gap, link.icon_size, link.icon_stroke = 7, 15, 1.75
    var here = link.copy()  # [aria-current]: the state layer at .09, the ink
    here.role, here.fill, here.ink = "nav-link-here", tint(p.ink, 0.09), p.ink
    with_hues(link, p, out)
    with_hues(here, p, out)
    var more = box("nav-more", 0, 12, 0, 0)  # .bar .more (≤ 760): 44 × 44, 12 corners, ink-2, its ⋯ 18 pt, 2 wide
    more.width, more.height, more.ink, more.icon_size, more.icon_stroke = 44, 44, p.ink2, 18, 2
    out.append(more^)
    out.append(card_look("page-card", p, shadow))
    var frame = box("page-frame", 0, -1, 0, 14)  # .journey: 0 14px 14px 2px
    frame.pad_bottom, frame.pad_left = 14, 2
    out.append(frame^)
    var frame_c = box("page-frame-compact", 0, -1, 0, 8)  # @container ≤ 760: 0 8px 8px
    frame_c.pad_bottom = 8
    out.append(frame_c^)
    var slot = Surface("beacon-slot", 0, -1, -1, 0, 8, 0, -1, -1, -1, [], 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False)  # .cx-right: 44 high, margin-right 8
    slot.height = 44
    out.append(slot^)
    var slot_c = box("beacon-slot-compact", 0, -1, -1, -1)  # (margin-right 0)
    slot_c.height = 44
    out.append(slot_c^)
    return out^


def header_roles(p: Palette, mono: String) -> List[Surface]:
    """mojoui.header (blades.css .bh/.sq, library.css .hbar/.seg, model-page.css .mhead/.tabs/.cmdbar)."""
    var out = List[Surface]()
    var header = layout("page-header", 12, 14, 16)  # .bh: 14px 16px, 12 between, 65 high with its rule (the Divider under it)
    header.min_height = 64
    out.append(header^)
    var title = words_role("page-title", 17, 650, p.ink, "", -0.34)  # .bh .t: 650 17px, -.02em, one line
    var sub = words_role("page-sub", 12.5, 0, p.ink2)  # .bh .s: one line
    title.one_line, sub.one_line = True, True  # (nowrap + ellipsis: cut where they don't fit, D-445)
    out.append(title^)
    out.append(sub^)
    out.append(layout("page-tools", 8))  # .tools: 8 between
    var sq = box("icon-square", tint(p.data(0), 0.14), 10, -1, -1)  # .sq: 36 × 36, the hue at 14 %, 10 corners, the icon (16, 1.75) in the hue
    sq.width, sq.height, sq.ink, sq.icon_stroke = 36, 36, p.data(0), 1.75
    out.append(sq.copy())
    for k in range(1, 7):
        var h = sq.copy()
        h.role, h.fill, h.ink = "icon-square-" + String(k), tint(p.data(k - 1), 0.14), p.data(k - 1)
        out.append(h^)
    var quiet = sq.copy()  # (HUE_QUIET: nav.js's Settings hue, var(--oq-ink-2))
    quiet.role, quiet.fill, quiet.ink = "icon-square-7", tint(p.ink2, 0.14), p.ink2
    out.append(quiet^)
    var tones: List[UInt32] = [p.ink2, p.good, p.warn, p.bad]  # .ox-tile: the tone at 14 %, its icon 18
    for k in range(4):
        var t = sq.copy()
        t.role, t.fill, t.ink, t.icon_size, t.icon_stroke = "icon-square-tone-" + String(k), tint(tones[k], 0.14), tones[k], 18, 1.6
        out.append(t^)
    out.append(layout("filter-bar", 10, 12, 18))  # .hbar: 12px 18px, 10 between
    out.append(layout("filter-bar-compact", 10, 10, 12))  # ≤ 760: 10px 12px
    out.append(layout("tab-header", 10, 12, 18))  # .mhead: 12px 18px, 10 between
    out.append(layout("tab-header-compact", 8, 10, 10))  # @container ≤ 760: 10px, 8 between, the tabs over the verbs
    var strip = box("pill-tabs", tint(p.ink, 0.05), 999, 4, 4)  # .tabs: 4px, 2 between, a pill, the state layer at .05 (omxqua's .tabs line under it)
    strip.gap, strip.line_bottom = 2, p.line_strong
    out.append(strip.copy())
    var strip_f = strip.copy()
    strip_f.role = "pill-tabs-fill"
    out.append(strip_f^)
    var tab = box("tab", 0, 999, 0, 14)  # .tabs button: 34 high, 0 14px, 600 13px ink-2, a 15 pt icon (1.75) 7 before; .on: surface-2, ink
    tab.height, tab.font_size, tab.font_weight, tab.ink, tab.line_height, tab.gap, tab.icon_size, tab.icon_stroke = 34, 13, 600, p.ink2, -1, 7, 15, 1.75
    var tab_on = tab.copy()
    tab_on.role, tab_on.fill, tab_on.ink = "tab-on", p.raised, p.ink
    with_hues(tab, p, out)
    with_hues(tab_on, p, out)
    var tab_f = tab.copy()  # @container ≤ 760: 44 high, 0 10px, sharing the width (flex 1), no icons
    tab_f.role, tab_f.height, tab_f.pad_x, tab_f.icon_size, tab_f.shares, tab_f.text_align = "tab-fill", 44, 10, -1, True, CENTER
    var tab_on_f = tab_on.copy()
    tab_on_f.role, tab_on_f.height, tab_on_f.pad_x, tab_on_f.icon_size, tab_on_f.shares, tab_on_f.text_align = "tab-on-fill", 44, 10, -1, True, CENTER
    with_hues(tab_f, p, out)
    with_hues(tab_on_f, p, out)
    out.append(box("segment", tint(p.ink, 0.06), 999, 3, 3))  # .seg: 3px, a pill, the state layer at .06
    var seg = box("segment-off", 0, 999, 0, 12)  # .seg button: 36 high, 0 12px, 6 between, 600 12.5px ink-2, a 15 pt icon; .on: surface-2, ink
    seg.height, seg.font_size, seg.font_weight, seg.ink, seg.line_height, seg.gap, seg.icon_size = 36, 12.5, 600, p.ink2, -1, 6, 15
    var seg_on = seg.copy()
    seg_on.role, seg_on.fill, seg_on.ink = "segment-on", p.raised, p.ink
    out.append(seg.copy())
    out.append(seg_on.copy())
    var segi = seg.copy()  # @media ≤ 760: 44 wide, 40 high, the icon alone
    segi.role, segi.width, segi.height, segi.pad_x = "segment-icon-off", 44, 40, 0
    var segi_on = seg_on.copy()
    segi_on.role, segi_on.width, segi_on.height, segi_on.pad_x = "segment-icon-on", 44, 40, 0
    out.append(segi^)
    out.append(segi_on^)
    var fr = box("segment-framed", p.page, 999, 3, 3)  # .seg2: 3px, surface-0, a line ring inside; its buttons 26 high, 0 14px, 6 between,
    fr.shadows = [Shadow(0, 0, 1, p.line_strong, True)]   # 500 12.6px ink-2 with a 14 pt icon; the chosen one surface-2 with shadow-1
    out.append(fr^)
    var fb = box("segment-framed-off", 0, 999, 0, 14)
    fb.height, fb.font_size, fb.font_weight, fb.ink, fb.gap, fb.icon_size, fb.line_height = 26, 12.6, 500, p.ink2, 6, 14, 18.27
    out.append(fb.copy())
    fb.role, fb.fill, fb.ink = "segment-framed-on", p.raised, p.ink
    fb.shadows = [Shadow(1, 2, 0, rgba(20, 16, 10, 15), False), Shadow(0, 0, 1, rgba(20, 16, 10, 11), False)]
    out.append(fb^)
    out.append(layout("action-group", 6))  # .cmdbar: 6 between
    var agf = layout("action-group-fill", 6)
    agf.scrolls_x = True  # (one line)
    out.append(agf^)
    return out^


def sidebar_roles(p: Palette, mono: String) -> List[Surface]:
    """mojoui.sidebar (library.css .groups/.gh/.gi; phone: the scrolling chip row)."""
    var out = List[Surface]()
    var col = box("sidebar", 0, -1, 6, 10)  # .groups: 228 with its 1 pt rule (the Divider beside it), 6px 10px, 1 between
    col.width, col.gap = 227, 1
    out.append(col^)
    var row = box("sidebar-compact", 0, -1, 8, 12)  # ≤ 760: 8px 12px 10px, 6 between, one line that scrolls sideways
    row.pad_bottom, row.gap, row.scrolls_x = 10, 6, True
    out.append(row^)
    var head = box("sidebar-head", 0, -1, 14, 10)  # .gh: 500 10.5px mono, caps, .06em, faint; 14px 10px 6px, 6 between
    head.pad_bottom, head.gap = 6, 6
    head.font, head.font_size, head.font_weight, head.ink, head.tracking, head.line_height = mono, 10.5, 500, p.ink3, 0.63, -1
    out.append(head^)
    var quiet = words_role("sidebar-quiet", 10.5, 500, mix(p.card, p.ink3, 0.75), mono, 0.001, -1)  # .gh em: no capitals or tracking, opacity .75
    out.append(quiet^)
    var hc = box("sidebar-head-compact", 0, -1, 0, 0)  # ≤ 760 .gh.mine: 4 in; its .ed a chip (36 high, 0 12px, the state layer at .06)
    hc.pad_left = 4
    out.append(hc^)
    var hchip = box("sidebar-head-chip", tint(p.ink, 0.06), 999, 0, 4)
    hchip.height = 36
    out.append(hchip^)
    # .gi: 36 high, 0 10px, 10 between, 10 corners; its words the page's 14px ink (blades.css button { font: inherit } wins over .gi's)
    var item = box("sidebar-item", 0, 10, 0, 10)
    item.height, item.gap, item.font_size, item.font_weight, item.ink = 36, 10, 14, 400, p.ink
    var on = item.copy()
    on.role, on.fill = "sidebar-item-on", tint(p.ink, 0.10)
    var faint = item.copy()
    faint.role, faint.ink, faint.icon_size = "sidebar-item-quiet", p.ink3, 15  # .gi.new: its + 15 pt
    out.append(item^)
    out.append(on^)
    out.append(faint^)
    var chip = box("sidebar-chip", tint(p.ink, 0.06), 999, 0, 13)  # ≤ 760 .gi: a pill, 0 13px, 6 between, 13px; .on the ink
    chip.height, chip.gap, chip.font_size, chip.font_weight, chip.ink = 36, 6, 13, 400, p.ink
    var chip_on = chip.copy()
    chip_on.role, chip_on.fill, chip_on.ink = "sidebar-chip-on", p.ink, p.page
    var chip_q = chip.copy()
    chip_q.role, chip_q.ink = "sidebar-chip-quiet", p.ink3
    out.append(chip^)
    out.append(chip_on^)
    out.append(chip_q^)
    var cl = box("sidebar-chip-label", 0, 0, 0, 0)  # (a chip's word: 13px, its chip's colour)
    cl.height, cl.font_size, cl.font_weight, cl.ink = HEIGHT_AUTO, 13, 400, p.ink
    out.append(cl.copy())
    cl.role, cl.ink = "sidebar-chip-label-quiet", p.ink3
    out.append(cl^)
    out.append(words_role("sidebar-chip-count-on", 11.5, 400, mix(p.ink, p.page, 0.6), mono, 0, -1))  # .gi.on small: inherit at .6
    var label = box("sidebar-label", 0, 0, 0, 0)  # (the row's own label: no button chrome)
    label.height, label.font_size, label.font_weight, label.ink = HEIGHT_AUTO, 14, 400, p.ink
    var label_q = label.copy()
    label_q.role, label_q.ink = "sidebar-label-quiet", p.ink3
    out.append(label^)
    out.append(label_q^)
    out.append(words_role("sidebar-count", 11.5, 400, p.ink3, mono, 0, -1))  # .gi small
    out.append(box("sidebar-dot", 0, -1, 0, 4))  # .gi .d: margin 0 4px
    out.append(box("sidebar-chip-dot", 0, -1, 0, 0))  # (≤ 760: none)
    var hash = words_role("sidebar-hash", 14, 600, p.ink3, mono, 0, -1)  # .gi .hash: 16 wide, centred, 600 14px mono faint
    hash.width, hash.text_align = 16, CENTER
    out.append(hash^)
    return out^


def mark_roles(p: Palette, mono: String) -> List[Surface]:
    """mojoui.marks (blades.css .mdot/.state/.sd, core.js SIGNAL, blade-settings.css .ox-st)."""
    var out = List[Surface]()
    var hues: List[UInt32] = [p.ink3]
    hues += hue_inks(p)
    for k in range(9):
        var d = box("hue-dot-" + String(k), hues[k], 99, -1, -1)  # .gi .d: 8 × 8, round
        d.width, d.height = 8, 8
        out.append(d^)
    var signal = materialize[SIGNAL]()
    for k in range(5):
        var d = box("signal-dot-" + String(k + 1), signal[k], 99, -1, -1)  # .mdot: 9 × 9
        d.width, d.height = 9, 9
        out.append(d^)
    var names: List[String] = ["quiet", "good", "warn", "bad", "info"]
    var inks: List[UInt32] = [p.ink2, p.good, p.warn, p.bad, p.data(0)]
    var dots: List[UInt32] = [p.ink3, p.good, p.warn, p.bad, p.data(0)]
    for k in range(5):
        var d = box("status-dot-" + names[k], dots[k], 99, -1, -1)  # .sd: 7 × 7
        d.width, d.height = 7, 7
        var live = d.copy()  # .state.running .sd: a 3px ring of its colour at 22 %
        live.role = "status-dot-live-" + names[k]
        live.shadows = [Shadow(0, 0, 3, tint(dots[k], 0.22), False)]
        out.append(d^)
        out.append(live^)
        var sw = words_role("status-" + names[k], 12.5, 0, inks[k])  # .state: 12.5px, one line
        sw.one_line = True
        out.append(sw^)
        out.append(words_role("status-cell-" + names[k], 12.5, 0, inks[k], "", 0, 18.676))  # (in a dense table's cell: as tall as its 12.88 pt line)
        out.append(words_role("status-mono-" + names[k], 12.5, 0, inks[k], mono, 0, -1))
    out.append(layout("status-mark", 6))  # .state: 6 between
    var icon = words_role("hue-icon", 0, 0, 0)  # (icons in a hue: model-page.js icon(…, 1.75))
    icon.icon_stroke = 1.75
    with_hues(icon, p, out)
    return out^


def panel_roles(p: Palette, mono: String, shadow: List[Shadow]) -> List[Surface]:
    """mojoui.panel (omxqua's .card-h/.card-b/.src, model-page.css .sec/.cardx/.m4/.dl, blade-bench.css .bn-row)."""
    var out = List[Surface]()
    out.append(card_look("card-bare", p, shadow))
    var head = box("card-head", 0, 0, 14, 16)  # .card-h: 14px 16px 10px, 10 between, one line
    head.pad_bottom, head.gap = 10, 10
    out.append(head^)
    out.append(words_role("card-title", 14.28, 600, p.ink, "", -0.1428))  # .card-h h3: 1.02em, 600, -.01em
    out.append(words_role("card-sub", 12.5, 0, p.ink2))
    var body = box("card-body", 0, 0, 0, 16)  # .card-b: 0 16px 14px, 10 between
    body.pad_bottom, body.gap = 14, 10
    out.append(body^)
    var foot = box("card-foot", 0, 0, 9, 16)  # .src: 11.5px mono ink-2 over a line-2 rule, 9px 16px, 8 between
    foot.line_top, foot.font, foot.font_size, foot.ink, foot.gap, foot.line_height = p.line, mono, 11.5, p.ink2, 8, -1
    out.append(foot^)
    var cp = box("foot-copy", tint(p.ink, 0.05), 999, 0, 10)  # .src .cp: 500 11px mono ink-2, 24 high, 0 10px
    cp.font, cp.font_size, cp.font_weight, cp.ink, cp.height, cp.line_height = mono, 11, 500, p.ink2, 24, -1
    out.append(cp^)
    var note = box("card-note", 0, -1, 0, 16)  # (a quiet line at the body's insets)
    note.font_size, note.ink = 12.5, p.ink2
    out.append(note^)
    out.append(layout("card-stack", 14, 16, 16))  # .pad: 16px, 14 between
    out.append(layout("card-column", 14))  # (cards in a column of their own: .nb-inner, .nb-side 14 between)
    out.append(layout("tab-body", 0))  # a tab: its head (.blade.embed > .bh) over its body (.bb)
    out.append(layout("tab-body-compact", 0))
    out.append(layout("tab-content", 14, 16, 16))  # .ox-pad: 16px, 14 between
    out.append(layout("tab-content-compact", 14, 12, 12))
    out.append(layout("tab-content-tight", 12, 16, 16))  # .lg: 16px, 12 between
    out.append(layout("tab-content-tight-compact", 12, 16, 16))  # (.lg keeps 16 on a phone)
    out.append(layout("tab-content-flush", 0, 0, 0))  # .nb: its parts pad themselves
    out.append(layout("tab-content-flush-compact", 0, 0, 0))
    var row = box("list-row", 0, 0, 10, 16)  # .bn-row: 10px 16px, a rule above, 10 between
    row.line_top, row.gap = p.line, 10  # (its words the page's 14px: a .bn-hrow is a button, font: inherit)
    var row_on = row.copy()
    row_on.role, row_on.fill = "list-row-on", tint(p.ink, 0.08)
    out.append(row^)
    out.append(row_on^)
    out.append(layout("panel", 10, 14, 16))
    out[len(out) - 1].fill, out[len(out) - 1].radius_top, out[len(out) - 1].radius_bottom = p.raised, 14, 14  # .cardx: surface-2, 14 corners, 14px 16px
    var phead = layout("panel-head", 8)  # .cardx h3: 22 high, 8 between
    phead.height = 22
    out.append(phead^)
    out.append(words_role("panel-title", 13.5, 650, p.ink))
    out.append(words_role("panel-foot", 11.5, 0, p.ink2, mono, 0, -1))  # .cardx .src: 8 between, its $ at .6
    out[len(out) - 1].gap = 8
    out.append(words_role("panel-foot-mark", 11.5, 0, mix(p.raised, p.ink2, 0.6), mono, 0, -1))
    out.append(layout("panel-row", 14))  # .sec: 14 between
    out.append(layout("panel-column", 10))
    out.append(layout("panel-grid", 14, 16, 18))  # .sec: 16px 18px
    out.append(layout("panel-grid-compact", 10, 10, 10))  # ≤ 760: 10px, 10 between
    out.append(box("stat-tile", tint(p.ink, 0.045), 12, 12, 14))  # .m4 > div: the state layer at .045, 12 corners, 12px 14px; b 4 under the label
    out[len(out) - 1].gap = 4
    out.append(layout("stat-body", 2))  # .m4 .cap: 2 under the number
    out.append(words_role("stat-label", 11, 500, p.ink2, mono, 0.66, -1))  # .m4 small
    out.append(words_role("stat-value", 24, 600, p.ink, mono, -0.48, -1))  # .m4 b
    out.append(words_role("stat-unit", 12, 500, p.ink2, mono, -0.48, -1))  # .m4 b em (in the b: its -.02em)
    out.append(words_role("stat-hint", 11.5, 0, p.ink2, mono, 0, -1))  # .m4 .cap
    out.append(layout("stat-number", 3))  # .m4 b em: margin-left 3
    out.append(layout("stat-grid", 10))  # .m4: 10 between
    out.append(layout("stat-row", 10))
    out.append(layout("fact", 14))  # .dl: 9px 14px
    var key = words_role("fact-key", 13.5, 0, p.ink2)  # .dl dt: 110 wide (96 compact)
    key.width = 110
    out.append(key.copy())
    key.role, key.width = "fact-key-compact", 96
    out.append(key.copy())
    key.role, key.width = "fact-key-narrow", 70  # (blade-security.css: the three things it does)
    out.append(key.copy())
    key.role, key.width = "fact-key-medium", 95  # (.ox-dl: as wide as "Caddy (HTTPS)")
    out.append(key.copy())
    key.role, key.width = "fact-key-widest", 150  # (the gateway's safeguards)
    out.append(key^)
    out.append(words_role("fact-value", 13, 0, p.ink, mono, 0, -1))  # .dl dd
    out.append(words_role("fact-value-plain", 13, 0, p.ink, "", 0, -1))
    var link = box("fact-link", 0, 0, 0, 0)  # .dl a: the accent
    link.font, link.font_size, link.font_weight, link.ink, link.line_height, link.height = mono, 13, 400, p.accent, -1, HEIGHT_AUTO
    out.append(link^)
    out.append(layout("fact-list", 9))
    var fg = layout("fact-grid", 9)  # .ox-dl: 9px 18px, the keys' column as wide as its widest
    fg.column_gap = 18
    out.append(fg^)
    out.append(words_role("fact-grid-key", 13.5, 0, p.ink2))
    out.append(words_role("fact-grid-key-mono", 13.5, 0, p.ink2, mono))
    var ft = layout("fact-grid-tight", 6)  # .nb-kv: 6px 12px, margin-top 12 (the card body's 10, and 2)
    ft.column_gap, ft.margin_top, ft.margin_x, ft.margin_bottom = 12, 2, 0, 0
    out.append(ft^)
    out.append(words_role("fact-grid-key-tight", 12.5, 0, p.ink2))
    out.append(words_role("fact-grid-key-mono-tight", 12.5, 0, p.ink2, mono))
    out.append(layout("labeled-row", 10))  # (a strong label, 110 wide, beside its value: the certificate's how-tos)
    out.append(layout("labeled-row-compact", 2))
    var lk = words_role("labeled-row-key", 13, 650, p.ink)
    lk.width = 110
    out.append(lk^)
    return out^


def word_roles(p: Palette, mono: String) -> List[Surface]:
    """mojoui.words (blades.css .cli, library.css .cnt/.rep, .cx-tbl .axs)."""
    var out = List[Surface]()
    out.append(words_role("quiet", 12.5, 0, p.ink2))
    out.append(words_role("strong", 13, 650, p.ink))  # .selbar b
    out.append(words_role("mono-line", 11.5, 0, p.ink2, mono, 0, -1))  # .cnt, .rep
    out.append(words_role("mono-faint", 11.5, 0, p.ink3, mono, 0, -1))  # .cnt .ht
    out.append(words_role("mono-strong", 12.5, 600, p.ink, mono))
    out.append(words_role("mono-text", 12, 0, p.ink2, mono, 0, -1))  # .cx-tbl .axs
    var cli = words_role("command-line", 11.5, 0, p.ink2, mono, 0, -1)  # .cli: 5 between, its $ faint
    cli.gap = 5
    out.append(cli^)
    out.append(words_role("command-dollar", 11.5, 0, p.ink3, mono, 0, -1))
    out.append(words_role("mono", 0, 0, 0, mono))
    out.append(words_role("cell-text", 0, 0, 0))  # (a table cell's words: its .92em and ink)
    out.append(words_role("cell-text-quiet", 0, 0, p.ink2))
    out.append(words_role("cell-text-strong", 0, 600, p.ink))
    out.append(words_role("cell-mono", 0, 0, 0, mono))
    out.append(words_role("cell-mono-quiet", 0, 0, p.ink2, mono))
    out.append(words_role("cell-mono-strong", 0, 600, p.ink, mono))  # (the mono alone: a cell's size and ink, .tbl td.mono)
    var hint = words_role("hint", 12.5, 0, p.ink2, "", 0, 18.75)  # .ox-note: 12.5px/1.5 ink-2, 64ch at most
    hint.max_width = 520
    out.append(hint^)
    out.append(words_role("muted", 14, 0, p.ink2))  # (a .bn-hrow's date: a button's inherited 14px)
    out.append(words_role("mono-muted", 14, 0, p.ink2, mono))
    out.append(words_role("mono-paragraph", 12, 0, p.ink2, mono, 0, 19.2))  # .bn-work: 12px, line-height 1.6
    out.append(words_role("error-line", 13, 0, p.bad))
    out.append(words_role("warn-line", 13, 0, p.warn))
    return out^


def button_roles(p: Palette, mono: String) -> List[Surface]:
    """mojoui.buttons (model-page.css .fb, omxqua's .btn.sm, library.css .gh .ed/.namebtn, blade-model.css .lnk)."""
    var out = List[Surface]()
    # .fb: 36 high, 0 14px, a pill, the state layer at .06, 7 between its 15 pt icon (1.75) and its words, which are the
    # page's 14px (blades.css button { font: inherit } wins over .fb's 600 13px)
    var flat = box("flat", tint(p.ink, 0.06), 999, 0, 14)
    flat.height, flat.font_size, flat.font_weight, flat.ink, flat.gap, flat.icon_size, flat.icon_stroke = 36, 14, 400, p.ink, 7, 15, 1.75
    var fill = flat.copy()
    fill.role, fill.fill, fill.ink = "flat-fill", p.accent, p.accent_ink
    var danger = flat.copy()
    danger.role, danger.ink = "flat-danger", p.bad
    var square = flat.copy()  # ≤ 760 .fb.cp: 44 × 44, the icon alone
    square.role, square.width, square.height, square.pad_x = "flat-icon", 44, 44, 0
    with_hues(flat, p, out)
    var flat_c = flat.copy()  # ≤ 760 .cmdbar .fb: 44 high, sharing the row (flex 1); the copy one 44 × 44
    flat_c.role, flat_c.height, flat_c.shares, flat_c.text_align = "flat-compact", 44, True, CENTER
    with_hues(flat_c, p, out)
    for f in [fill.copy(), danger.copy()]:
        var c = f.copy()
        c.role, c.height, c.shares, c.text_align = f.role + "-compact", 44, True, CENTER
        out.append(c^)
    var square_c = square.copy()
    square_c.role = "flat-icon-compact"
    out.append(square_c^)
    out.append(fill^)
    out.append(danger^)
    out.append(square^)
    var primary = words_role("primary", 0, 0, 0)  # blade-home.js: the + at 14 pt, 2 wide
    primary.icon_size, primary.icon_stroke = 14, 2
    out.append(primary.copy())
    var primary_i = box("primary-icon", 0, 999, 0, 0)  # compact (.ib): a 32 pt circle, the + alone 15 pt in the ink
    primary_i.width, primary_i.height, primary_i.ink, primary_i.icon_size, primary_i.icon_stroke = 32, 32, p.ink, 15, 2
    out.append(primary_i^)
    # .btn.sm (26 high, 0 12px, 550 .88em) in each look; [disabled] at .45; .danger.armed
    var fills: List[UInt32] = [tint(p.ink, 0.06), p.accent, 0, 0]
    var inks: List[UInt32] = [p.ink, p.accent_ink, p.ink2, p.bad]
    var rings: List[UInt32] = [0, 0, 0, mix(p.card, p.bad, 0.40)]
    var looks: List[String] = ["tonal", "fill", "text", "danger"]
    for k in range(4):
        var a = box("small-" + looks[k], fills[k], 999, 0, 12)
        a.height, a.font_size, a.font_weight, a.ink, a.icon_size = 26, 12.32, 400, inks[k], 13  # (550 loses to blades.css's font: inherit; the blades' icons 13)
        a.one_line = True  # (.btn: white-space nowrap: squeezed, a small button never wraps its words)
        if rings[k] != 0:
            a.shadows = [Shadow(0, 0, 1, rings[k], True)]
        var off = a.copy()
        off.role, off.fill, off.ink = "small-" + looks[k] + "-off", mix(p.card, fills[k], 0.45) if fills[k] != 0 else 0, mix(p.card, inks[k], 0.45)
        if rings[k] != 0:
            off.shadows = [Shadow(0, 0, 1, mix(p.card, rings[k], 0.45), True)]
        out.append(a^)
        out.append(off^)
    var armed = box("small-danger-armed", mix(p.card, p.bad, 0.14), 999, 0, 12)
    armed.height, armed.font_size, armed.font_weight, armed.ink, armed.icon_size = 26, 12.32, 650, p.bad, 13
    armed.one_line = True
    armed.shadows = [Shadow(0, 0, 1, mix(p.card, p.bad, 0.40), True)]
    out.append(armed^)
    var act = box("text-action", 0, 8, 4, 8)  # .gh .ed: 600 12px, the accent, 4px 8px, 8 corners
    act.font_size, act.font_weight, act.ink, act.line_height, act.height = 12, 600, p.accent, -1, HEIGHT_AUTO
    out.append(act^)
    var name = box("name-link", 0, 0, 0, 0)  # .namebtn: the cell's own type, as tall as its line
    name.font_weight, name.ink, name.height = 400, p.ink, HEIGHT_AUTO
    out.append(name^)
    var link = box("link", 0, 0, 0, 0)  # .lnk: underlined, its line's type
    link.font_size, link.font_weight, link.ink, link.height = 12.5, 400, p.ink, HEIGHT_AUTO
    out.append(link^)
    var back = box("back-button", 0, 999, 0, 12)  # .bh .back: 26 high, 76 wide, 0 12px, 12.32px in ink-2
    back.height, back.width, back.font_size, back.font_weight, back.ink = 26, 76, 12.32, 400, p.ink2
    out.append(back^)
    return out^


def copy_roles(p: Palette, mono: String) -> List[Surface]:
    """mojoui.copy (blade-model.css .urlrow/.code, model-page.css .keyrow, blade-settings.css .ox-ep, .secret)."""
    var out = List[Surface]()
    var row = box("copy-row", p.card, 12, 0, 6)  # .urlrow: 44 high, 0 6px 0 12px, 10 between, a 1px line, 12 corners
    row.pad_left, row.min_height, row.outline, row.outline_w, row.gap = 12, 44, p.line_strong, 1, 10
    out.append(row^)
    var tag = box("copy-tag", tint(p.ink, 0.06), 999, 3, 9)  # .urlrow .tag: 500 11px mono caps, .06em, a .tag pill
    tag.font, tag.font_size, tag.font_weight, tag.ink, tag.tracking, tag.line_height = mono, 11, 500, p.ink2, 0.66, -1
    out.append(tag^)
    out.append(words_role("copy-value", 13, 0, p.ink, mono, 0, -1))
    var icon = box("copy-icon", 0, 999, 0, 0)  # .ib: a 32 pt circle, its 14 pt icon in ink-2
    icon.width, icon.height, icon.ink, icon.icon_size, icon.icon_stroke = 32, 32, p.ink2, 14, 1.6
    out.append(icon^)
    var text = box("copy-text", 0, 999, 0, 12)  # (.btn.text.sm: 26 high, ink-2)
    text.height, text.font_size, text.font_weight, text.ink = 26, 12.32, 550, p.ink2
    out.append(text^)
    out.append(layout("labeled-value", 8))  # .keyrow: 12.5px, 8 between
    out.append(words_role("value-label", 12.5, 0, p.ink2))
    out.append(words_role("value-text", 12.5, 0, p.ink, mono))
    var code = box("code-panel", CODE_BG, 12, 8, 8)  # .code: --code, 12 corners; 12px/1.65 mono --code-text; its button 8 in from the corner
    code.font, code.font_size, code.line_height, code.ink, code.gap = mono, 12, 19.8, CODE_INK, 2
    out.append(code^)
    var button = box("code-panel-copy", CODE_BUTTON, 999, 0, 10)  # .code .cp: 26 high, #27272a, 600 11.5px mono
    button.font, button.font_size, button.font_weight, button.ink, button.height, button.line_height = mono, 11.5, 600, CODE_INK, 26, -1
    out.append(button^)
    var lines = box("code-panel-lines", 0, -1, 0, 8)  # (the lines 22 under the padding, 14 16 in: 8 more than the panel's)
    lines.pad_bottom = 6
    out.append(lines^)
    var secret = box("secret", CODE_BG, 10, 10, 12)  # .secret: --code, 10 corners, 10px 12px, 12.5px mono
    secret.font, secret.font_size, secret.ink = mono, 12.5, CODE_INK
    out.append(secret^)
    return out^


def field_roles(p: Palette, mono: String) -> List[Surface]:
    """mojoui.fields (library.css .psearch, omxqua's .mo/.mf-help, the console's .chip)."""
    var out = List[Surface]()
    var search = box("search-box", tint(p.ink, 0.06), 12, 0, 12)  # .psearch.big: 46 high, 0 12px, 8 between
    search.min_height, search.ink, search.gap = 46, p.ink2, 8
    out.append(search^)
    var key = box("key-hint", tint(p.ink, 0.06), 6, 2, 6)  # .psearch kbd: 11px mono faint, 2px 6px, 6 corners
    key.font, key.font_size, key.ink, key.line_height = mono, 11, p.ink3, -1
    out.append(key^)
    var field = box("outlined-field", p.card, 10, 0, 14)  # .mo: 46 high, 10 corners, a line ring, 14 in
    field.min_height, field.ink, field.gap = 46, p.ink2, 10
    field.shadows = [Shadow(0, 0, 1, p.line_strong, True)]
    out.append(field^)
    var help = box("field-help", 0, -1, 0, 14)  # .mf-help: .78em ink-2, 14 in
    help.font_size, help.ink = 10.92, p.ink2
    out.append(help^)
    out.append(layout("field-with-help", 6))
    out.append(layout("filter-chips", 8))
    var chip = box("filter-chip", tint(p.ink, 0.06), 999, 0, 12)  # .chip: 32 high, 0 12px, a pill; .on the ink
    chip.height, chip.font_size, chip.font_weight, chip.ink = 32, 14, 400, p.ink
    var on = chip.copy()
    on.role, on.fill, on.ink, on.font_weight = "filter-chip-on", p.ink, p.page, 600
    out.append(chip^)
    out.append(on^)
    var filt = layout("filter-field")  # .lg-bar .mo: 340, giving way when the row is short of room
    filt.width, filt.shrinks = 340, True
    out.append(filt.copy())
    filt.role = "filter-field-compact"
    out.append(filt^)
    var short = layout("short-field")  # (a name: 260 wide; a phone 300)
    short.width = 260
    out.append(short.copy())
    short.role, short.width = "short-field-compact", 300
    out.append(short^)
    return out^


def result_roles(p: Palette, mono: String) -> List[Surface]:
    """mojoui.results (blade-add.css .res/.badge/.sz/.sug)."""
    var out = List[Surface]()
    var row = box("result-row", 0, 0, 10, 16)  # .res: 10px 16px, a line-2 rule, 12 between
    row.line_top, row.gap = p.line, 12
    out.append(row^)
    var name = box("result-name", 0, 0, 0, 0)  # 600 13px mono, 17 high
    name.height, name.font, name.font_size, name.font_weight, name.ink, name.line_height = 17, mono, 13, 600, p.ink, -1
    out.append(name^)
    out.append(words_role("result-meta", 12, 0, p.ink2))
    out.append(words_role("result-figure", 11, 0, p.ink2, mono, 0, 14))  # .sz
    for k in range(6):
        var b = box("source-badge-" + String(k + 1), p.card, 4, 4, 6)  # .badge: 52 wide, a 1px line, 500 11px mono in its hue
        b.width, b.outline, b.outline_w = 52, p.line_strong, 1
        b.font, b.font_size, b.font_weight, b.ink, b.line_height = mono, 11, 500, p.data(k), 11
        out.append(b^)
    var sug = box("suggestion", tint(p.ink, 0.045), 12, 12, 12)  # .sug: a quiet tile, 12px, 6 between
    sug.gap = 6
    out.append(sug^)
    return out^


def meter_roles(p: Palette, mono: String) -> List[Surface]:
    """mojoui.meter (blade-settings.css .meter, model-page.css .gpufit/.fitk)."""
    var out = List[Surface]()
    out.append(words_role("meter", 12, 0, p.ink2, mono))
    out[len(out) - 1].gap = 10
    var label = words_role("meter-label", 12, 0, p.ink2, mono)  # 110 wide
    label.width = 110
    out.append(label^)
    var fig = words_role("meter-figure", 12, 0, p.ink2, mono)  # 70 wide
    fig.width = 70
    out.append(fig^)
    out.append(box("meter-bar", 0, -1, -1, -1))
    out.append(box("meter-bar-bad", 0, -1, -1, -1))
    var share = box("share-bar", 0, 4, -1, -1)  # .bn-tr: a .prog 12 high (its track line, its fill the accent, 4 corners)
    share.height = 12
    out.append(share.copy())
    share.role = "share-bar-mine"  # .bn-row.me .bn-tr: an inset 1px ring in the ink
    share.shadows = [Shadow(0, 0, 1, p.ink, True)]
    out.append(share^)
    var bar = box("usage-bar", 0, 5, -1, -1)  # .gpufit: 10 high, 5 corners
    bar.height = 10
    out.append(bar^)
    out.append(words_role("usage-figures", 11.5, 0, p.ink2, mono, 0, -1))  # .fitk
    out[len(out) - 1].gap = 8
    return out^


def feedback_roles(p: Palette, mono: String) -> List[Surface]:
    """mojoui.feedback (blade-bench.css .bn-note, blade-settings.css .ox-warnbox, omxqua's .empty)."""
    var out = List[Surface]()
    var note = box("note", tint(p.ink, 0.05), 12, 10, 14)  # .bn-note: 12.5px ink-2 on the state layer at .05
    note.font_size, note.ink, note.gap, note.inline_flow = 12.5, p.ink2, 4, True  # (its words and its button flow as a sentence: a space, then margin-left 4)
    out.append(note^)
    var na = box("note-action", tint(p.ink, 0.06), 999, 0, 12)  # .bn-note .btn.sm: .88em of the note's 12.5 (11px), its ink-2
    na.height, na.font_size, na.font_weight, na.ink = 26, 11, 400, p.ink2
    out.append(na^)
    var warn = box("warning", tint(p.bad, 0.08), 12, 12, 14)  # .ox-warnbox: the bad colour at 8 %, 12px 14px
    warn.font_size, warn.ink, warn.gap = 13, p.ink2, 10
    out.append(warn^)
    var empty = box("empty-state", 0, -1, 26, 16)  # .empty: 26px 16px, 6 between
    empty.font_size, empty.ink, empty.gap = 14, p.ink2, 6
    out.append(empty^)
    var ring = box("empty-ring", tint(p.ink, 0.07), 22, -1, -1)  # .ring: 44, round
    ring.width, ring.height, ring.ink = 44, 44, p.ink2
    out.append(ring^)
    out.append(words_role("empty-title", 14.28, 600, p.ink))
    var action = box("empty-action", p.accent, 999, 0, 12)  # (.btn.sm.fill)
    action.height, action.font_size, action.font_weight, action.ink = 26, 12.32, 550, p.accent_ink
    out.append(action^)
    return out^


def beacon_roles(p: Palette, mono: String, accent: UInt32) -> List[Surface]:
    """mojoui.beacon (omxqua's components.css .beacon, topbar.css): #0b0b0d, a deep soft shadow, 22 corners, 40 high in
    its 44 pt slot with the words at the slot's middle (4 on top), 0 16px 0 12px, 10 between; the label 600 13px, the
    value 500 12px mono in a quieter grey; the live dot in `accent`."""
    var out = List[Surface]()
    var pill = Surface("beacon", BEACON_BG, 22, 22, -1, -1, -1, 4, 14, 0,
                       [Shadow(10, 30, 0, rgba(0, 0, 0, 89), False), Shadow(0, 0, 1, rgba(255, 255, 255, 15), False)], 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False,
                       pad_left=12, pad_right=16, gap=10, height=40)
    out.append(pill^)
    out.append(words("beacon-label", 13, 600, BEACON_INK))
    var value = words("beacon-value", 12, 500, BEACON_QUIET)
    value.font = mono
    out.append(value^)
    var live = box("beacon-live", accent, 4, -1, -1)
    live.width, live.height = 8, 8
    out.append(live^)
    var ring = box("beacon-ring", 0, -1, -1, -1)
    ring.width, ring.height = 20, 20
    out.append(ring^)
    return out^


def list_roles(p: Palette, mono: String) -> List[Surface]:
    """mojoui.lists and mojoui.chip.ChipRow, TagEditor (library.css .cnt/.body2/.cgrid/.selbar, blade-home.css .tbl td.nm,
    library.js labelsEditor)."""
    var out = List[Surface]()
    var count = layout("list-count", 10, 12, 18)  # .cnt: 12px 18px 0, 10 between
    count.pad_bottom = 0
    out.append(count^)
    var body = box("list-body", 0, -1, 4, 0)  # .body2: 4px 18px 0 0
    body.pad_bottom, body.pad_right = 0, 18
    out.append(body^)
    var count_c = layout("list-count-compact", 10, 10, 14)  # ≤ 760 .cnt: 10px 14px 0
    count_c.pad_bottom = 0
    out.append(count_c^)
    var body_c = box("list-body-compact", 0, -1, 4, 0)  # ≤ 760: its right 12
    body_c.pad_bottom, body_c.pad_right = 0, 12
    out.append(body_c^)
    var empty = box("list-empty", 0, -1, 30, 18)  # .none: 30px 18px, 13px ink-2
    empty.font_size, empty.ink = 13, p.ink2
    out.append(empty^)
    var grid = box("card-grid", 0, -1, 4, 0)  # .cgrid: 4px 0 18px 18px, 10 between
    grid.pad_bottom, grid.pad_left, grid.gap = 18, 18, 10
    out.append(grid^)
    var bar = box("selection-bar", p.raised, -1, 10, 18)  # .selbar: 10px 18px, 6 between, surface-2
    bar.gap = 6
    out.append(bar^)
    out.append(layout("split-view", 0))
    out.append(layout("split-view-compact", 0))
    out.append(layout("name-cell", 3))  # td.nm: the name's line is 0.8 taller than the name (an inline-flex in a 12.88 pt line), the .rep 2 under it
    out.append(layout("name-cell-head", 9))  # .namebtn: 9 between the dot and the name
    var sub = box("name-cell-sub", 0, -1, 0, 0)  # .tbl td.nm .rep: margin-left 18
    sub.pad_left = 18
    out.append(sub^)
    out.append(layout("cell-stack", 2))  # .tbl td .rep: margin-top 2
    out.append(layout("chip-row", 4))  # .tags: 4 between
    out.append(layout("tag-editor", 0))
    var tag = box("tag-chip", tint(p.ink, 0.06), 999, 3, 9)  # .tag.lab: a .tag (500 11.5px ink-2, 3px 9px) holding its ✕
    tag.font_size, tag.font_weight, tag.ink, tag.line_height = 11.5, 500, p.ink2, -1
    out.append(tag^)
    var x = box("tag-remove", tint(p.ink, 0.05), 999, 0, 0)  # .x: a 32 pt circle, its ✕ 12 pt
    x.width, x.height, x.ink, x.icon_size = 32, 32, p.ink2, 12
    out.append(x^)
    var add = box("tag-add", tint(p.ink, 0.06), 999, 5, 11)  # .tag.add: 13px mono, its + 12 pt against its word, 3px 9px inside the button's own 2px
    add.font, add.font_size, add.font_weight, add.ink, add.icon_size, add.height, add.gap, add.line_height = mono, 13, 400, p.ink, 12, HEIGHT_AUTO, 0, -1
    out.append(add^)
    out.append(layout("page-column", 14, 18, 20))  # .add-find: 18px 20px, 14 between, 980 wide at most
    out[len(out) - 1].max_width = 980
    out.append(layout("page-column-compact", 14, 14, 12))
    out.append(layout("main-aside", 14, 16, 16))  # the setup's columns: 16px, 14 between; the log 150 wide until opened
    out.append(layout("main-aside-compact", 14, 12, 12))
    var narrow = layout("aside-narrow")
    narrow.width = 150
    out.append(narrow^)
    out.append(layout("aside-wide"))
    return out^


def extra_roles(p: Palette, mono: String) -> List[Surface]:
    """The rest: the frame's own stack, sub-headers and tool rows, command lines, button rows, suggestions, chart rows
    and history columns (blade-bench.css .bn-row/.bn-hrow), the document's cells, outline, spec rows and columns
    (blade-notebook.css), a secret with its copy."""
    var out = List[Surface]()
    out.append(layout("shell", 0))
    var sub = layout("sub-header", 10, 10, 18)  # .blade.embed > .bh: 10px 18px 0, 10 between, its line 12px mono, its tools 8 apart; one line
    sub.pad_bottom, sub.one_line = 0, True
    out.append(sub.copy())
    sub.role, sub.pad_top, sub.pad_x = "sub-header-compact", 8, 12  # ≤ 760: 8px 12px 0
    out.append(sub^)
    var st = words_role("sub-header-text", 12, 0, p.ink2, mono, 0, -1)  # .bh .s: nowrap, cut
    st.one_line = True
    out.append(st^)
    var sts = layout("sub-header-tools", 8)  # .b-notebook .tools: min-width 0, one line
    sts.one_line, sts.shrinks = True, True
    out.append(sts^)
    var ss = layout("sub-header-status")  # .kchip: overflow hidden, min-width 0 (cut on a phone)
    ss.shrinks = True
    out.append(ss^)
    var tr = layout("tool-row", 12)
    tr.scrolls_x = True  # (one line)
    out.append(tr^)
    out.append(layout("command-lines", 3))  # .twins: 3 between
    out.append(layout("button-row", 8))
    out.append(layout("suggestion-row", 10))
    out.append(layout("chart-row", 10))  # .bn-row: the label 150 wide, 10 between, 12.5px mono; the figure 92 wide, right
    out.append(words_role("chart-name", 12.5, 0, p.ink, mono, 0, 15.625))
    out.append(words_role("chart-name-strong", 12.5, 600, p.ink, mono, 0, 15.625))  # .bn-row.me .bn-nm
    var fig = words_role("chart-figure", 12.5, 0, p.ink2, mono, 0, -1)
    fig.width, fig.text_align = 92, 3
    out.append(fig.copy())
    fig.role, fig.font_weight, fig.ink = "chart-figure-strong", 600, p.ink  # .bn-row.best .bn-v
    out.append(fig^)
    var label = layout("chart-label", 8)
    label.width, label.one_line = 150, True
    out.append(label.copy())
    label.role, label.width = "chart-label-compact", 100  # (≤ 420: 100)
    out.append(label^)
    var c1 = layout("column-1")  # .bn-hrow: the date 130, the count 80
    c1.width = 130
    out.append(c1^)
    var c2 = layout("column-2")
    c2.width = 80
    out.append(c2^)
    var ct = layout("column-tail-compact")  # ≤ 420: minmax(0, 1fr) var(--bn-val: 92px), the best run's words cut (.trunc)
    ct.width, ct.one_line = 92, True
    out.append(ct^)
    var md = layout("markdown-cell", -1, 16, 18)  # .nb-md: 16px 18px 8px
    md.pad_bottom = 8
    out.append(md^)
    out.append(layout("code-cell", 0))  # .nb-in: 56px | the code
    var cl = words_role("code-cell-label", 11.5, 0, p.ink2, mono, 0, -1)  # .nb-n: 56 wide, centred, 14 from the top
    cl.width, cl.text_align, cl.pad_top, cl.pad_x, cl.pad_bottom = 56, CENTER, 14, 0, 0
    out.append(cl^)
    var cc = box("code-cell-code", CODE_BG, 0, 14, 16)  # .nb-code: --code, 14px 16px, 12.5px/1.6 mono
    cc.font, cc.font_size, cc.line_height, cc.ink = mono, 12.5, 20, CODE_INK
    out.append(cc^)
    var ol = box("outline", 0, -1, 12, 8)  # .nb-toc: 12px 8px, 2 between
    ol.gap = 2
    out.append(ol^)
    var oh = box("outline-head", 0, -1, 4, 10)  # .nb-lab: 500 11px mono, caps, .06em, ink-2; 4px 10px 8px
    oh.pad_bottom = 8
    oh.font, oh.font_size, oh.font_weight, oh.ink, oh.tracking, oh.line_height = mono, 11, 500, p.ink2, 0.66, -1
    out.append(oh^)
    var row1 = box("outline-row-1", 0, 10, 8, 10)  # .nb-toc button: 8px 10px, 10 corners, 10 between, on the baseline; 13px 550 ink-2
    row1.gap, row1.font_weight, row1.ink = 10, 550, p.ink2
    out.append(row1.copy())
    row1.role, row1.pad_left, row1.font_weight = "outline-row-2", 24, 500  # .lv2: 24 in, 12.5px 500
    out.append(row1^)
    var on = words_role("outline-number", 11, 0, p.ink2, mono)  # .nb-toc .num: 11px
    out.append(on^)
    var ch1 = box("chapter-1", 0, 0, 0, 0)  # (the chapter's words: no button chrome)
    ch1.font_size, ch1.font_weight, ch1.ink, ch1.height = 13, 550, p.ink2, HEIGHT_AUTO
    out.append(ch1.copy())
    ch1.role, ch1.font_size, ch1.font_weight = "chapter-2", 12.5, 500
    out.append(ch1^)
    var sr = layout("spec-rows", 0)  # .nb-rows: margin-top 14 (the card body's 10 between, and 4)
    sr.margin_top, sr.margin_x, sr.margin_bottom = 4, 0, 0
    out.append(sr^)
    var sk = words_role("spec-key", 11.5, 0, p.ink2, mono)  # .nb-rows th: 4px 10px 4px 0, a line-2 rule on top, 52 % wide (the grid's share)
    sk.pad_top, sk.pad_bottom, sk.pad_left, sk.pad_right, sk.pad_x, sk.line_top, sk.breaks_words, sk.text_align = 4, 4, 0, 10, 0, p.line, True, START
    out.append(sk^)
    var sv = words_role("spec-value", 11.5, 0, p.ink, mono)  # .nb-rows td: 4px 0
    sv.pad_top, sv.pad_bottom, sv.pad_x, sv.line_top, sv.breaks_words, sv.text_align = 4, 4, 0, p.line, True, START
    out.append(sv^)
    out.append(layout("doc-layout", 0))  # .nb-grid: 210 | 1fr | 300
    var dlc = layout("doc-layout-compact", 0, 16, 12)  # .nb-main ≤ 720: 16px clamp(12px, 2vw, 24px) 60px, no outline, no side panels
    dlc.pad_bottom = 60
    out.append(dlc^)
    var dout = layout("doc-outline")  # 210 with its rule (the Divider)
    dout.width = 209
    out.append(dout^)
    var dmain = layout("doc-main", 0, 16, 24)  # .nb-main: 16px 24px 60px, the cells 880 at most
    dmain.pad_bottom = 60
    out.append(dmain^)
    var das = layout("doc-aside", 0, 16, 16)  # .nb-side: 300, 16px 16px 60px 0
    das.width, das.pad_bottom, das.pad_left = 300, 60, 0
    out.append(das^)
    out.append(layout("secret-row", 10))
    out.append(layout("side-scroll", 0))
    return out^


def kit_roles(p: Palette, mono: String, shadow: List[Shadow], beacon_accent: UInt32) -> List[Surface]:
    """Every role above, in order (containers first: a leaf role inside one has the last word)."""
    var out = shell_roles(p, mono, shadow)
    out += header_roles(p, mono)
    out += sidebar_roles(p, mono)
    out += panel_roles(p, mono, shadow)
    out += mark_roles(p, mono)
    out += word_roles(p, mono)
    out += button_roles(p, mono)
    out += copy_roles(p, mono)
    out += field_roles(p, mono)
    out += result_roles(p, mono)
    out += meter_roles(p, mono)
    out += feedback_roles(p, mono)
    out += list_roles(p, mono)
    out += extra_roles(p, mono)
    out += beacon_roles(p, mono, beacon_accent)
    return out^
