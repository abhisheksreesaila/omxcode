# mojoui.pagekit: the pieces an admin console's page is made of (goal 33 M5, the OMX Console): a brand mark and a thin
# rule for a top bar, quiet place links, a page header (icon square, title, count, one line under it, tools), a groups
# column (small caps heads, rows with a lead dot and a count), stat tiles, facts (a key beside its value), panels with
# a title, source lines ("$ mxc ls"), flat pill buttons, a tab strip and a segmented pair of buttons, a state word with
# its dot, a mono line. Each is made of Text, Button, Icon and stacks and wears a framework role (tag) its theme
# shapes; page_roles(palette, mono) gives a theme those roles in omxqua's measures (the console's CSS).
#
#   PageHeader("layout-grid", "My models", "3", "3 models · 1 running", [SourceLine("mxc ls"), add])
#   GroupItem(HueDot(7), "Running", "1", on_tap=GROUP + 1, on=False)        StatTile("Requests", "101", "", "last 5 minutes")

from mojoui.view import View, Text, Button, Icon, TextField, VStack, HStack, Spacer, SUBTLE, PLAIN, CENTER, START, END, Node, VSTACK, CARD, _container
from mojoui.theme import Palette, Surface, Shadow, words, chip, mix
from mojoui.chip import Pill, Badge
from mojoui.table import capitals
from mojoui.canvas import rgba


def Mark(text: String, size: Int = 28) -> View:
    """A brand's mark: its letters on a small dark square (role brand-mark)."""
    return Text(text).width(size).height(size).tag("brand-mark")


def Rule(height: Int = 22) -> View:
    """A thin upright line between parts of a bar (role rule)."""
    return VStack(spacing=0).width(1).height(height).tag("rule")


def PlaceLink(title: String, icon: String, on_tap: Int, here: Bool = False) -> View:
    """A quiet link to a place (role place; place-here where you are)."""
    return Button(title, on_tap, SUBTLE, icon).height(36).tag("place-here" if here else "place")


def IconSquare(icon: String, size: Int = 36) -> View:
    """An icon on a tinted rounded square (role icon-square)."""
    return VStack(Icon(icon, 16), spacing=0).width(size).height(size).align(CENTER).justify(CENTER).tag("icon-square")


def PageHeader(icon: String, title: String, count: String, sub: String, var tools: List[View]) -> View:
    """A page's header: its icon square, the title with a count beside it, one line under it, then its tools at the
    trailing edge (role page-header: a rule under it)."""
    var head: List[View] = [Text(title).tag("page-title")]
    if count != "":
        head.append(Pill(count))
    var items: List[View] = [IconSquare(icon), VStack(HStack(head^, spacing=8).align(CENTER), Text(sub).tag("page-sub"), spacing=2).align(START).grow(),
                             Spacer()]
    for t in tools:
        items.append(t.copy())
    return HStack(items^, spacing=12).align(CENTER).fill().tag("page-header")


def GroupHead(text: String, quiet: String = "") -> View:
    """A small caps head in a groups column (role group-head), `quiet` after it in lower case."""
    if quiet == "":
        return Text(capitals(text)).tag("group-head")
    return HStack(Text(capitals(text)).tag("group-head"), Text(quiet).tag("group-quiet"), spacing=6).align(CENTER)


def GroupItem(lead: View, label: String, count: String, on_tap: Int, on: Bool = False) -> View:
    """A row in a groups column: its lead (a dot, an icon, a #), the label to tap, the count at the end (roles group-item
    or group-item-on, group-count)."""
    return HStack(lead.copy(), Button(label, on_tap, SUBTLE).align(START).grow().tag("group-label"), Text(count).tag("group-count"),
                  spacing=10).align(CENTER).height(36).fill().tag("group-item-on" if on else "group-item")


def HueDot(hue: Int, size: Int = 8) -> View:
    """A dot in data colour `hue` (1–6), the good colour (7) or the faint ink (0) (roles hue-dot-0 … hue-dot-7)."""
    return VStack(spacing=0).width(size).height(size).tag("hue-dot-" + String(min(max(hue, 0), 7)))


def StatTile(label: String, value: String, unit: String, hint: String) -> View:
    """A number with its label over it (small caps), its unit beside it and a hint under it (roles stat-tile,
    stat-label, stat-value, stat-unit, stat-hint)."""
    var number: List[View] = [Text(value).tag("stat-value")]
    if unit != "":
        number.append(Text(unit).tag("stat-unit"))
    return VStack(Text(capitals(label)).tag("stat-label"), HStack(number^, spacing=3).align(END), Text(hint).tag("stat-hint"),
                  spacing=3).align(START).grow().tag("stat-tile")


def Fact(key: String, value: View, key_width: Int = 110) -> View:
    """A key beside its value, as a definition list reads (roles fact-key; FactText for a plain value)."""
    return HStack(Text(key).width(key_width).tag("fact-key"), HStack(value.copy(), spacing=0).align(CENTER).justify(START).grow(), spacing=14).align(START).fill()


def FactText(value: String) -> View:
    return Text(value).tag("fact-value")


def PanelTitle(icon: String, title: String) -> View:
    """A panel's title with its icon (role panel-title)."""
    return HStack(Icon(icon, 15), Text(title).tag("panel-title"), spacing=8).align(CENTER)


def Panel(var items: List[View], spacing: Int = 10) -> View:
    """A quiet panel on a page: a tonal surface, its items top to bottom (role panel)."""
    return VStack(items^, spacing=spacing).align(START).tag("panel")


def SourceLine(command: String) -> View:
    """The command that shows the same thing, as a mono line after a $ (role source-line)."""
    return Text("$ " + command).tag("source-line")


def MonoLine(text: String, quiet: Bool = False) -> View:
    """A line in the mono, in the quiet ink (role mono-line; mono-faint fainter still)."""
    return Text(text).tag("mono-faint" if quiet else "mono-line")


def FlatButton(title: String, on_tap: Int, icon: String = "", filled: Bool = False, danger: Bool = False) -> View:
    """A flat pill button: a tonal tint, no shadow (role flat); `filled` the accent (flat-fill), `danger` the bad colour."""
    return Button(title, on_tap, PLAIN, icon).height(36).tag("flat-fill" if filled else ("flat-danger" if danger else "flat"))


def TabStrip(titles: List[String], icons: List[String], selected: Int, on_tap: Int) -> View:
    """Tabs as a pill track; tab k sends on_tap + k (roles tab-strip, tab, tab-on)."""
    var tabs: List[View] = []
    for k in range(len(titles)):
        tabs.append(Button(titles[k], on_tap + k, SUBTLE, icons[k] if k < len(icons) else String("")).height(34).tag("tab-on" if k == selected else "tab"))
    return HStack(tabs^, spacing=0).align(CENTER).tag("tab-strip")


def SegButtons(titles: List[String], icons: List[String], selected: Int, on_tap: Int) -> View:
    """Two or three buttons joined in a pill, one chosen; button k sends on_tap + k (roles seg, seg-on, seg-off)."""
    var items: List[View] = []
    for k in range(len(titles)):
        items.append(Button(titles[k], on_tap + k, SUBTLE, icons[k] if k < len(icons) else String("")).height(36).tag("seg-on" if k == selected else "seg-off"))
    return HStack(items^, spacing=0).align(CENTER).tag("seg")


def StateWord(text: String, good: Bool) -> View:
    """A state: a dot and a word, good (the good colour, role state-good) or quiet (state-quiet)."""
    return HStack(HueDot(7 if good else 0, 7), Text(text).tag("state-good" if good else "state-quiet"), spacing=6).align(CENTER)


def NoteBox(var items: List[View]) -> View:
    """A quiet note across the page: a tint, its words and maybe a button (role note-box)."""
    return HStack(items^, spacing=8).align(CENTER).justify(START).fill().tag("note-box")


# ---------- the look (the console's CSS in omxqua's measures), for a theme to add to its Look's surfaces ----------

def _tint(c: UInt32, a: Float64) -> UInt32:
    return (c & 0xFFFFFF) | (UInt32(Int(a * 255 + 0.5)) << 24)


def _box(role: String, fill: UInt32, radius: Int, pad_v: Int, pad_h: Int) -> Surface:
    return Surface(role, fill, radius, radius, -1, -1, -1, pad_v, pad_h, pad_v, [], 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False)


def _words(role: String, size: Float64, weight: Int, ink: UInt32, font: String = "", tracking: Float64 = 0) -> Surface:
    var s = words(role, size, weight, ink, tracking)
    s.font = font
    return s^


def page_roles(p: Palette, mono: String) -> List[Surface]:
    """pagekit's roles in omxqua's measures (the console's topbar.css, blades.css, library.css, model-page.css)."""
    var state = p.ink  # (omxqua's state layer: the ink at a low alpha)
    var out = List[Surface]()
    var mark = _box("brand-mark", p.ink, 8, -1, -1)  # .brand .mk: 28 × 28, 8 corners, the ink; 700 10px mono in surface-0
    mark.font, mark.font_size, mark.font_weight, mark.ink, mark.line_height = mono, 10, 700, p.page, 28
    out.append(mark^)
    out.append(_box("rule", p.line, 0, -1, -1))  # .crumbs: border-left 1px line-2
    var place = _box("place", 0, 10, 0, 11)  # .places a: 36 high, 0 11px, 10 corners, 550 13px ink-2
    place.font_size, place.font_weight, place.ink = 13, 550, p.ink2
    var here = place.copy()
    here.role, here.fill, here.ink = "place-here", _tint(state, 0.09), p.ink
    out.append(place^)
    out.append(here^)
    out.append(_box("icon-square", _tint(p.data(0), 0.14), 10, -1, -1))  # .sq: the hue at 14 %, 10 corners
    var header = _box("page-header", 0, 0, 14, 16)  # .bh: 14px 16px, a line-2 rule under it, 65 high at least
    header.line_bottom, header.min_height = p.line, 65
    out.append(header^)
    out.append(_words("page-title", 17, 650, p.ink, "", -0.34))  # .bh .t: 650 17px, -.02em
    out.append(_words("page-sub", 12.5, 0, p.ink2))  # .bh .s: 12.5px ink-2
    var gh = _box("group-head", 0, -1, -1, -1)  # .gh: 500 10.5px mono, caps, .06em, faint; 14px 10px 6px
    gh.pad_top, gh.pad_x, gh.pad_bottom = 14, 10, 6
    gh.font, gh.font_size, gh.font_weight, gh.ink, gh.tracking = mono, 10.5, 500, p.ink3, 0.63
    out.append(gh^)
    out.append(_words("group-quiet", 10.5, 500, p.ink3, mono))
    var gi = _box("group-item", 0, 10, 0, 10)  # .gi: 36 high, 0 10px, 10 corners, 550 13.5px ink-2
    gi.font_size, gi.font_weight, gi.ink = 13.5, 550, p.ink2
    var gon = gi.copy()
    gon.role, gon.fill, gon.ink = "group-item-on", _tint(state, 0.10), p.ink
    out.append(gi^)
    out.append(gon^)
    var gl = _box("group-label", 0, 0, 0, 0)  # (the row's own label: no button chrome)
    gl.font_size, gl.font_weight = 13.5, 550
    out.append(gl^)
    out.append(_words("group-count", 11.5, 0, p.ink3, mono))  # .gi small: 11.5px mono faint
    var hues: List[UInt32] = [p.ink3]
    for k in range(6):
        hues.append(p.data(k))
    hues.append(p.good)
    for k in range(8):
        out.append(_box("hue-dot-" + String(k), hues[k], 99, -1, -1))
    var tile = _box("stat-tile", _tint(state, 0.045), 12, 12, 14)  # .m4 > div: the state layer at .045, 12 corners, 12px 14px
    out.append(tile^)
    out.append(_words("stat-label", 11, 500, p.ink2, mono, 0.66))  # .m4 small
    out.append(_words("stat-value", 24, 600, p.ink, mono, -0.48))  # .m4 b
    out.append(_words("stat-unit", 12, 500, p.ink2, mono))  # .m4 b em
    out.append(_words("stat-hint", 11.5, 0, p.ink2, mono))  # .m4 .cap
    out.append(_words("fact-key", 13.5, 0, p.ink2))  # .dl dt
    out.append(_words("fact-value", 13, 0, p.ink, mono))  # .dl dd
    out.append(_box("panel", p.raised, 14, 14, 16))  # .cardx: surface-2, 14 corners, 14px 16px
    out.append(_words("panel-title", 13.5, 650, p.ink))  # .cardx h3
    out.append(_words("source-line", 11.5, 0, p.ink2, mono))  # .cli / .src
    out.append(_words("mono-line", 11.5, 0, p.ink2, mono))  # .cnt
    out.append(_words("mono-faint", 11.5, 0, p.ink3, mono))  # .cnt .ht
    var flat = _box("flat", _tint(state, 0.06), 999, 0, 14)  # .fb: 36 high, 0 14px, a pill, the state layer at .06, 600 13px
    flat.font_size, flat.font_weight, flat.ink = 13, 600, p.ink
    var fill = flat.copy()
    fill.role, fill.fill, fill.ink = "flat-fill", p.accent, p.accent_ink
    var danger = flat.copy()
    danger.role, danger.ink = "flat-danger", p.bad
    out.append(flat^)
    out.append(fill^)
    out.append(danger^)
    out.append(_box("tab-strip", _tint(state, 0.05), 999, 4, 4))  # .tabs: 4px, a pill, the state layer at .05
    var tab = _box("tab", 0, 999, 0, 14)  # .tabs button: 34 high, 0 14px, 600 13px ink-2; .on: surface-2, ink
    tab.font_size, tab.font_weight, tab.ink = 13, 600, p.ink2
    var tab_on = tab.copy()
    tab_on.role, tab_on.fill, tab_on.ink = "tab-on", p.raised, p.ink
    out.append(tab^)
    out.append(tab_on^)
    out.append(_box("seg", _tint(state, 0.06), 999, 3, 3))  # .seg: 3px, a pill, the state layer at .06
    var seg = _box("seg-off", 0, 999, 0, 12)  # .seg button: 36 high, 0 12px, 600 12.5px ink-2; .on: surface-2, ink
    seg.font_size, seg.font_weight, seg.ink = 12.5, 600, p.ink2
    var seg_on = seg.copy()
    seg_on.role, seg_on.fill, seg_on.ink = "seg-on", p.raised, p.ink
    out.append(seg^)
    out.append(seg_on^)
    out.append(_words("state-good", 12.5, 0, p.good))  # .state.running
    out.append(_words("state-quiet", 12.5, 0, p.ink2))  # .state.idle
    var note = _box("note-box", _tint(state, 0.05), 12, 10, 14)  # .bn-note: 12.5px ink-2 on the state layer at .05, 12 corners
    note.font_size, note.ink = 12.5, p.ink2
    out.append(note^)
    return out^


def CardHead(title: String, badge: String = "") -> View:
    """A card's head: its title, a badge at the end (roles card-head, card-title; the badge is a mojoui.chip.Badge)."""
    var items: List[View] = [Text(title).tag("card-title"), Spacer()]
    if badge != "":
        items.append(Badge(badge))
    return HStack(items^, spacing=10).align(CENTER).fill().tag("card-head")


def CardFoot(text: String, note: Bool = False, tail: String = "") -> View:
    """A card's foot: a source line over a rule ($ mxc …, or ↳ a note), `tail` at the end (role card-foot)."""
    var items: List[View] = [Text(("↳ " if note else "$ ") + text)]
    if tail != "":
        items.append(Spacer())
        items.append(Text(tail))
    return HStack(items^, spacing=8).align(CENTER).justify(START).fill().tag("card-foot")


def card_roles(p: Palette, mono: String) -> List[Surface]:
    """The card's head, body and foot (omxqua's .card-h, .card-b, .src)."""
    var out = List[Surface]()
    var head = _box("card-head", 0, 0, -1, -1)
    head.pad_top, head.pad_x, head.pad_bottom = 14, 16, 10
    out.append(head^)
    out.append(_words("card-title", 14.28, 600, p.ink, "", -0.14))
    var body = _box("card-body", 0, 0, -1, -1)
    body.pad_top, body.pad_x, body.pad_bottom = 0, 16, 14
    out.append(body^)
    var foot = _box("card-foot", 0, 0, 9, 16)
    foot.line_top, foot.font, foot.font_size, foot.ink = p.line, mono, 11.5, p.ink2
    out.append(foot^)
    return out^


def CardBody(var items: List[View], spacing: Int = 10) -> View:
    """A card's body between its head and foot (role card-body)."""
    return VStack(items^, spacing=spacing).align(START).fill().tag("card-body")


def BareCard(var items: List[View], spacing: Int = 0) -> View:
    """A card with no padding of its own: its head, body and foot bring theirs (omxqua's .card; role bare-card: the
    theme's card look with no padding: a plain stack wearing it, so no host's own card padding applies)."""

    return _container(Node(VSTACK, spacing=spacing), items).align(START).tag("bare-card")


def NameButton(title: String, on_tap: Int) -> View:
    """A name to tap in a list (a model's): bold, no button chrome (role name-button)."""
    return Button(title, on_tap, SUBTLE).tag("name-button")


def HashMark() -> View:
    """The # before a label's name in a list (role hash-mark)."""
    return Text("#").width(16).tag("hash-mark")


def QuietAction(title: String, on_tap: Int) -> View:
    """A small action in a head (Edit labels): the accent, no chrome (role quiet-action)."""
    return Button(title, on_tap, SUBTLE).tag("quiet-action")


def Strong(text: String) -> View:
    """A few strong words (role strong)."""
    return Text(text).tag("strong")


def more_roles(p: Palette, mono: String) -> List[Surface]:
    """NameButton, HashMark, QuietAction, Strong (library.css .namebtn, .gi .hash, .gh .ed, .selbar b)."""
    var out = List[Surface]()
    var brand = _box("brand-name", 0, 0, 0, 0)  # (.brand: the word sits beside the mark, no button chrome)
    brand.font_size, brand.font_weight, brand.ink = 15, 650, p.ink
    out.append(brand^)
    var name = _box("name-button", 0, 0, 0, 0)
    name.font_size, name.font_weight, name.ink = 13.5, 550, p.ink
    out.append(name^)
    out.append(_words("hash-mark", 14, 600, p.ink3, mono))
    var act = _box("quiet-action", 0, 8, 4, 8)
    act.font_size, act.font_weight, act.ink = 12, 600, p.accent
    out.append(act^)
    out.append(_words("strong", 13, 650, p.ink))
    return out^


def QuietText(text: String) -> View:
    """Words in the quiet ink, a little smaller (role page-sub)."""
    return Text(text).tag("page-sub")


def BrandName(title: String, on_tap: Int) -> View:
    """A brand's name beside its mark, tapping home (role brand-name)."""
    return Button(title, on_tap, SUBTLE).tag("brand-name")


def SearchField(value: String, placeholder: String, on_change: Int) -> View:
    """A wide search: a magnifier and a borderless field on a tonal box (library.css .psearch.big; role search-box)."""
    return HStack(Icon("search", 16), TextField(value, placeholder=placeholder, on_change=on_change).grow(), spacing=8).align(CENTER).tag("search-box")


def search_roles(p: Palette) -> List[Surface]:
    """SearchField's box: the state layer at .06, 12 corners, 46 high, 0 12px (its field's own chrome is the theme's)."""
    var out = List[Surface]()
    var b = _box("search-box", _tint(p.ink, 0.06), 12, 0, 12)
    b.min_height, b.ink = 46, p.ink2
    out.append(b^)
    return out^


def SmallButton(title: String, on_tap: Int, icon: String = "", filled: Bool = False) -> View:
    """A small pill button in a page's head (omxqua's .btn.sm): tonal, or the accent when `filled` (roles small, small-fill)."""
    return Button(title, on_tap, PLAIN, icon).height(26).tag("small-fill" if filled else "small")


def MonoStrong(text: String) -> View:
    """A figure or a name in the mono, strong (role mono-strong: .bn-row.me, .bn-row.best)."""
    return Text(text).tag("mono-strong")


def ListRow(var items: List[View], on: Bool = False) -> View:
    """A row in a card's list: a rule above it, 10 16 padding; `on` the chosen one, tinted (roles list-row, list-row-on)."""
    return HStack(items^, spacing=10).align(CENTER).padding(10, 16).fill().tag("list-row-on" if on else "list-row")


def small_roles(p: Palette, mono: String) -> List[Surface]:
    """SmallButton, MonoStrong, ListRow (omxqua's .btn.sm; blade-bench.css .bn-row, .bn-hrow)."""
    var out = List[Surface]()
    var small = _box("small", _tint(p.ink, 0.06), 999, 0, 12)
    small.min_height, small.font_size, small.font_weight, small.ink = 26, 12.5, 550, p.ink
    var fill = small.copy()
    fill.role, fill.fill, fill.ink = "small-fill", p.accent, p.accent_ink
    out.append(small^)
    out.append(fill^)
    out.append(_words("mono-strong", 12.5, 600, p.ink, mono))
    var row = _box("list-row", 0, 0, 10, 16)
    row.line_top, row.font_size = p.line, 12.5
    var on = row.copy()
    on.role, on.fill = "list-row-on", _tint(p.ink, 0.08)
    out.append(row^)
    out.append(on^)
    return out^
