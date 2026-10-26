# mojoui.catalog (goal 33 M6): the pieces of a catalog search, as the OMX Console's Add a model screen has them
# (blade-add.js, blade-add.css, omxqua's .mo field): an outlined field with a lead icon and its help line, a row of
# filter chips, result rows (a source badge, the name to tap, a quiet line under it, a fit mark and a size at the end),
# a meter (a label, a bar, a figure), an empty state (a ring icon, a title, a line, one action) and a back button. Each
# is made of Text, Button, Icon, TextField, ProgressBar and stacks and wears a framework role its theme shapes;
# catalog_roles(palette, mono) gives a theme those roles in omxqua's measures.
#
#   OutlinedField(q, "Search models", on_change=SEARCH, on_submit=SEARCH_NOW)   FilterChips(["All", "Fits"], 0, FILTER)
#   ResultRow("MAX", 3, "qwen2.5-0.5b", PICK + k, "Qwen/Qwen2.5-0.5B-Instruct · Qwen2 · 500M · 1 GB", "ok", "fits", "~2.2 GB VRAM")

from mojoui.view import View, Text, Button, Icon, TextField, VStack, HStack, Spacer, ProgressBar, SUBTLE, PLAIN, NO_MSG, CENTER, START, END
from mojoui.theme import Palette, Surface, Shadow, words, mix

comptime FIT_KEYS: List[String] = ["ok", "tight", "no", "port", "inst"]


def OutlinedField(value: String, label: String, on_change: Int, on_submit: Int = NO_MSG, icon: String = "search") -> View:
    """omxqua's outlined field (.mo.has-lead): a lead icon and a borderless field in a 46 pt box with a hairline ring;
    `label` shows in the field until something is typed (role outlined-field)."""
    return HStack(Icon(icon, 16), TextField(value, placeholder=label, on_change=on_change, on_submit=on_submit).grow(),
                  spacing=10).align(CENTER).fill().tag("outlined-field")


def FieldHelp(text: String) -> View:
    """The quiet line under a field, 14 in from its edge (.mf-help: role field-help); 6 below the field (FieldWithHelp)."""
    return Text(text).padding(0, 14).tag("field-help")


def FieldWithHelp(var field: View, help: String) -> View:
    """A field with its help line under it (.mf-help sits 6 below: omxqua's margin -8px under a 14 gap)."""
    return VStack(field^, FieldHelp(help), spacing=6).align(START).fill()


def FilterChips(titles: List[String], selected: Int, on_tap: Int) -> View:
    """Chips to pick one filter; chip k sends on_tap + k (roles filter-chip, filter-chip-on: the chosen one in ink)."""
    var chips: List[View] = []
    for k in range(len(titles)):
        chips.append(Button(titles[k], on_tap + k, PLAIN).height(32).tag("filter-chip-on" if k == selected else "filter-chip"))
    return HStack(chips^, spacing=8).align(CENTER).justify(START)


def fit_role(key: String) -> String:
    """A fit's role: fit-ok, fit-tight, fit-no, fit-port; anything else fit-inst (size unknown)."""
    var keys = materialize[FIT_KEYS]()
    for k in keys:
        if k == key:
            return "fit-" + k
    return "fit-inst"


def FitMark(key: String, label: String) -> View:
    """A fit as a dot and a word in its colour (blade-add.css .fit: ok good, tight warn, no bad, port data-1, else
    the quiet ink)."""
    var role = fit_role(key)
    return HStack(VStack(spacing=0).width(7).height(7).tag(role + "-dot"), Text(label).tag(role), spacing=6).align(CENTER)


def SourceBadge(text: String, hue: Int, width: Int = 52) -> View:
    """Where a result comes from, as a hairline box in the mono in data colour `hue` (MAX, HF; role source-badge-<hue>)."""
    return HStack(Text(text), spacing=0).width(width).justify(CENTER).align(CENTER).tag("source-badge-" + String(min(max(hue, 1), 6)))


def ResultRow(badge: String, badge_hue: Int, name: String, on_tap: Int, meta: String, fit_key: String, fit_label: String,
              size: String) -> View:
    """One result (.res): the source badge, the name to tap (mono, strong) over its quiet line, the fit mark over the
    size at the trailing edge; a rule above it (roles result-row, result-name, result-meta, result-size)."""
    var ends: List[View] = [FitMark(fit_key, fit_label)]
    if size != "":
        ends.append(Text(size).tag("result-size"))
    var words_: List[View] = [Button(name, on_tap, SUBTLE).height(17).tag("result-name")]
    if meta != "":
        words_.append(Text(meta).tag("result-meta"))
    return HStack(SourceBadge(badge, badge_hue), VStack(words_^, spacing=2).align(START).grow(), VStack(ends^, spacing=3).align(END),
                  spacing=12).align(CENTER).fill().tag("result-row")


def Meter(label: String, percent: Int, bad: Bool, figure: String, label_width: Int = 110, figure_width: Int = 70) -> View:
    """A label, a bar `percent` full (the bad colour, or data-3) and a figure, in the mono (.meter; roles meter,
    meter-bar, meter-bar-bad)."""
    return HStack(Text(label).width(label_width), ProgressBar(min(max(percent, 0), 100)).grow().tag("meter-bar-bad" if bad else "meter-bar"),
                  Text(figure).width(figure_width).tag("meter-figure"), spacing=10).align(CENTER).fill().tag("meter")


def EmptyState(icon: String, title: String, text: String, action: String = "", on_action: Int = NO_MSG) -> View:
    """An empty state (.empty): an icon in a ring, a title, one line, and the one action that fills it (roles
    empty-state, empty-ring, empty-title; the action is a small filled button, role small-fill)."""
    var items: List[View] = [VStack(Icon(icon, 20), spacing=0).width(44).height(44).align(CENTER).justify(CENTER).tag("empty-ring"),
                             Text(title).tag("empty-title"), Text(text)]
    if action != "":
        items.append(Button(action, on_action, PLAIN).height(26).tag("small-fill"))
    return VStack(items^, spacing=6).align(CENTER).fill().tag("empty-state")


def BackButton(on_tap: Int, title: String = "Back") -> View:
    """A quiet Back with its chevron in a page's header (omxqua's .btn.text.sm.back, 76 wide: role back-button)."""
    return Button(title, on_tap, SUBTLE, "back").height(26).width(76).tag("back-button")


# ---------- the look (blade-add.css, omxqua's components.css), for a theme to add to its Look's surfaces ----------

def _box(role: String, fill: UInt32, radius: Int, pad_v: Int, pad_h: Int) -> Surface:
    return Surface(role, fill, radius, radius, -1, -1, -1, pad_v, pad_h, pad_v, [], 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False, False)


def _words(role: String, size: Float64, weight: Int, ink: UInt32, font: String = "") -> Surface:
    var s = words(role, size, weight, ink)
    s.font = font
    return s^


def _tint(c: UInt32, a: Float64) -> UInt32:
    return (c & 0xFFFFFF) | (UInt32(Int(a * 255 + 0.5)) << 24)


def catalog_roles(p: Palette, mono: String) -> List[Surface]:
    """The catalog's roles in omxqua's measures: .mo (46 high, 10 corners, a line ring, surface-1, 14 in), .mf-help
    (.78em ink-2), the console's .chip (32 high, 0 12px, a pill, the state layer at .06; .on the ink), .res (10 16, a
    line-2 rule), .badge (500 11px mono, 4 6, radius-xs, a line ring) in data-3 / data-4, .fit (12.5px, a 7 px dot),
    .sz (11px mono ink-2), .meter (12px mono ink-2), .empty."""
    var out = List[Surface]()
    var field = _box("outlined-field", p.card, 10, 0, 14)
    field.shadows = [Shadow(0, 0, 1, p.line_strong, True)]
    field.min_height, field.ink = 46, p.ink2
    out.append(field^)
    out.append(_words("field-help", 10.92, 0, p.ink2))  # (.mf-help: .78em of 14)
    var chip = _box("filter-chip", _tint(p.ink, 0.06), 999, 0, 12)
    chip.min_height, chip.font_size, chip.font_weight, chip.ink = 32, 14, 400, p.ink
    var on = chip.copy()
    on.role, on.fill, on.ink, on.font_weight = "filter-chip-on", p.ink, p.page, 600
    out.append(chip^)
    out.append(on^)
    var row = _box("result-row", 0, 0, 10, 16)
    row.line_top = p.line
    out.append(row^)
    var name = _box("result-name", 0, 0, 0, 0)
    name.min_height, name.font, name.font_size, name.font_weight, name.ink = 1, mono, 13, 600, p.ink
    out.append(name^)
    out.append(_words("result-meta", 12, 0, p.ink2))
    var size = _words("result-size", 11, 0, p.ink2, mono)  # (.sz: the font shorthand sets a normal line height)
    size.line_height = 14
    out.append(size^)
    for k in range(6):
        var b = _box("source-badge-" + String(k + 1), p.card, 4, 4, 6)  # (a 1 px border: 52 × 21)
        b.outline, b.outline_w = p.line_strong, 1
        b.font, b.font_size, b.font_weight, b.ink, b.line_height = mono, 11, 500, p.data(k), 11
        out.append(b^)
    var fits: List[String] = ["ok", "tight", "no", "port", "inst"]
    var inks: List[UInt32] = [p.good, p.warn, p.bad, p.data(0), p.ink2]
    for k in range(5):
        out.append(_words("fit-" + fits[k], 12.5, 0, inks[k]))
        out.append(_box("fit-" + fits[k] + "-dot", inks[k], 4, -1, -1))
    var meter = _words("meter", 12, 0, p.ink2, mono)
    out.append(meter^)
    out.append(_words("meter-figure", 12, 0, p.ink2, mono))
    out.append(_box("meter-bar", 0, -1, -1, -1))
    out.append(_box("meter-bar-bad", 0, -1, -1, -1))
    var empty = _box("empty-state", 0, -1, 26, 16)
    empty.font_size, empty.ink = 14, p.ink2
    out.append(empty^)
    var ring = _box("empty-ring", _tint(p.ink, 0.07), 22, -1, -1)
    ring.ink = p.ink2
    out.append(ring^)
    out.append(_words("empty-title", 14.28, 600, p.ink))
    var back = _box("back-button", 0, 999, 0, 12)  # (.bh .back: 26 high, 0 12px, 12.32px in ink-2)
    back.min_height, back.font_size, back.font_weight, back.ink = 26, 12.32, 400, p.ink2
    out.append(back^)
    return out^
