# mojoui.stage: one screen of four regions for a counter or a tablet read from across the room (goal 77 M7a, D-7783): a
# top bar across the whole width; on the left what is passive (a big clock, Today, Pinned); in the centre what matters
# now, on a raised panel (the stage: live tiles go there, mojoui.livetiles) with the chat bar under it; on the right what
# is live (one-line rows: timers, scores). The side columns recede under a soft shade that runs to the window's edges, so
# the centre reads as in front. Flat: no glass, no blur.
#
#   Stage(top, left, centre, right, StageChat(orb, text, "Ask omx…", on_change=T, on_submit=S, on_mic=M), width)
#
#   Desktop: columns minmax(200, 1fr) | minmax(0, 2.75fr) | minmax(200, 1fr), 18 apart, 18 in from the sides; the top bar
#   14 from the top and 14 above the columns. Narrower than 1000: the right column goes (left minmax(180, 1fr) | 2.6fr).
#   760 or narrower (a phone): one column that scrolls (top, left, centre, right), the panel `compact_panel` high, the
#   chat bar fixed at the bottom. stage_layout(width) says which and how wide, so an app builds its left column for it
#   (StageList(compact=True): pins in a row) and a test checks the numbers without a host.
#
#   Parts (each a role its theme shapes, themes/omxqua.mojo omxqua_counter): StageClock(time, date, weather) ·
#   StageLabel(icon, text) · StageCard(icon, head, title, sub, hue, on_unpin) (a pinned or Today card) · StageRow(icon, head,
#   value, hue) (a Live or Today row) · StageNote(text) (an empty list's line) · StageList(items, compact) ·
#   StageAvatar(initials, hue, on_tap) · StagePill(icon, label, on_tap, compact) ·
#   StageChat(orb, text, placeholder, …) (orb, a text box or her subtitles, StageTool(label, msg, icon) buttons, the mic).
#
#   Roles: stage (the whole), stage-top, stage-side (a shaded band: its fill is the shade), stage-left, stage-centre,
#   stage-right, stage-panel, stage-bar, stage-phone-bar (the strip the phone's bar sits in) and the parts' own (below).
#   mojoui.regions names stage-top, stage-left, stage-centre, stage-right, stage-panel and stage-bar, so a test reads
#   their rects from GTK and the web alike (regions: in the test steps).
#
# The layout is the component's (the columns are computed here from the width, in points, and given to the views), the
# look is the theme's (fills, corners, shadows, type): a theme cannot break the proportions, and every host gets plain
# points (no CSS grid on GTK).

from mojoui.view import View, Text, Button, TextField, Icon, VStack, HStack, Spacer, Scroll, ICON_ONLY, SUBTLE, NO_MSG
from mojoui.view import CENTER, START, END, STRETCH, Overlay, Canvas
from mojoui.table import capitals
from mojoui.stagetv import StageTV, TVContent, tv_body

comptime STAGE_PHONE = 760  # this wide or narrower: one column (the prototype's @media (max-width: 760px))
comptime STAGE_NARROW = 1000  # narrower than this: no right column (max-width: 1000px)
comptime STAGE_PAD_TOP = 14  # the top bar from the window's top, and the columns from the top bar
comptime STAGE_PAD_X = 18  # the columns from the window's sides
comptime STAGE_GAP = 18  # between columns
comptime STAGE_ROW_GAP = 12  # the panel to the chat bar
comptime STAGE_BOTTOM = 14  # the chat bar from the window's bottom
comptime STAGE_PANEL_PAD = 14  # the panel's inside (the tiles from its edge)
comptime STAGE_BAR_H = 64  # the chat bar's height
comptime STAGE_PHONE_PAD = 14  # a phone's sides
comptime STAGE_SIDE_MIN = 200  # a side column's least width (desktop)
comptime STAGE_SIDE_MIN_NARROW = 180  # the left column's least width without a right one
comptime STAGE_COMPACT_PANEL = 380  # the panel's height on a phone (two columns of 112 pt tiles, three rows: M7b may ask for more)


@fieldwise_init
struct StageLayout(Copyable, Movable):
    """Where a Stage's columns go at one window width (points). `side` is the left column's width (and the right's when
    there is one); `centre` the centre's; `right` False when the right column is hidden; `compact` a phone's one column."""

    var width: Int
    var compact: Bool
    var right: Bool
    var side: Int
    var centre: Int


def stage_layout(width: Int) -> StageLayout:
    """The columns at `width`, as the prototype's CSS grid would size them: the free width (less the sides' padding and
    the gaps) shared 1 : 2.75 : 1, a side never under 200 (no right column under 1000: 1 : 2.6, the left never under 180);
    a phone (≤ 760): one column the width less 14 a side."""
    if width <= STAGE_PHONE:
        var w = max(width - 2 * STAGE_PHONE_PAD, 0)
        return StageLayout(width, True, False, w, w)
    if width < STAGE_NARROW:
        var free = max(width - 2 * STAGE_PAD_X - STAGE_GAP, 0)
        var side = max(STAGE_SIDE_MIN_NARROW, Int(Float64(free) / 3.6 + 0.5))
        return StageLayout(width, False, False, side, max(free - side, 0))
    var free = max(width - 2 * STAGE_PAD_X - 2 * STAGE_GAP, 0)
    var side = max(STAGE_SIDE_MIN, Int(Float64(free) / 4.75 + 0.5))
    return StageLayout(width, False, True, side, max(free - 2 * side, 0))


def stage_compact(width: Int) -> Bool:
    """A phone's one column at this width (build the left column's pins as a row: StageList(compact=True))."""
    return width <= STAGE_PHONE


def _gap(points: Int) -> View:
    """An empty run of `points` (a band's inner padding, kept out of CSS so every host lays it out alike)."""
    return VStack(spacing=0).width(points)


def _side_scroll(side: View) -> View:
    """A side column's content in a scroller as tall as its band: a long Today, Pinned or Live list scrolls on its own."""
    return Scroll(VStack(side.copy().fill(), spacing=0).align(START).fill(), height=0).grow().fill().tag("stage-side-scroll")


def _below_gap(var band: View) -> View:
    """A side band with the top bar's 14 above it (when the columns own that gap: a Stage with a TV)."""
    return VStack(_gap(0).height(STAGE_PAD_TOP), band^.grow(), spacing=0).fill().tag("stage-side-wrap")


def _tv_layers(var base: View, tv: StageTV, content: TVContent, var bar_part: View, tail: Int) -> View:
    """The TV over a column whose bottom holds the chat bar (D-6710): `base` with the bar's room left empty; the TV's
    canvas over it (the veil over the tiles, the growing box: see-through, presses pass); a band across the bottom with the
    real chat bar (`bar_part`, the same TextField whether open or not) and, while open, the TV's body above it, `tail`
    points of room under the bar."""
    var box = Canvas(tv.canvas, tv.version, on_frame=tv.on_frame if tv.ticking() else NO_MSG).passthrough().grow().fill().tag("stage-tv-box")
    var band_items = List[View]()
    if tv.body and tv.area_h > 0:
        band_items.append(tv_body(tv, content))
    band_items.append(bar_part^)
    if tail > 0:
        band_items.append(_gap(0).height(tail))
    var band = VStack(band_items^, spacing=0).fill().pin(STRETCH, END).tag("stage-tv-band")
    return Overlay(base^, box^, band^)


def Stage(top: View, left: View, centre: View, right: View, bar: View, width: Int,
          compact_panel: Int = STAGE_COMPACT_PANEL, tv: StageTV = StageTV(), content: TVContent = TVContent()) -> View:
    """The four regions and the chat bar at a window `width` (App.resize hands it: pass what it said; the height is the
    hosts' to fill). `top` spans the window; `left` and `right` sit in shaded bands that run to the window's edges and
    bottom, each scrolling on its own when what it holds is taller than the window (a desktop); `centre` fills
    the raised panel (a Canvas of tiles: give it grow/fill); `bar` (StageChat) sits under the panel in a pill 64 high.
    On a phone the regions stack and scroll, and the bar stays at the bottom.
    `tv` (mojoui.stagetv, M7d): when it has a canvas, the chat bar can grow into the TV over the whole centre column (a
    phone: the window), showing `content` (the card, the conversation, the chips) while it is open."""
    var lay = stage_layout(width)
    var bar_box = HStack(bar.copy().grow(), spacing=0).align(CENTER).padding(6, 6).height(STAGE_BAR_H).fill().tag("stage-bar")
    if lay.compact:
        var panel = VStack(centre.copy().grow().fill(), spacing=0).padding(10).height(compact_panel).fill().tag("stage-panel")
        var column = VStack(top.copy().fill().tag("stage-top"), left.copy().fill().tag("stage-left"),
                            VStack(panel, spacing=0).fill().tag("stage-centre"), right.copy().fill().tag("stage-right"),
                            spacing=STAGE_PAD_TOP).padding(STAGE_PAD_TOP, STAGE_PHONE_PAD).fill()
        var page = Scroll(column, height=0).grow().fill()
        var strip = HStack(bar_box.copy().grow(), spacing=0).padding(8, STAGE_PHONE_PAD).fill().tag("stage-phone-bar")
        if tv.on():
            var base = VStack(page, _gap(0).height(STAGE_BAR_H + 16), spacing=0).grow().fill()
            return _tv_layers(base^, tv, content, strip^, 0).grow().fill().tag("stage")
        return VStack(page, strip, spacing=0).grow().fill().tag("stage")
    var top_line = HStack(_gap(STAGE_PAD_X), top.copy().grow().tag("stage-top"), _gap(STAGE_PAD_X), spacing=0).align(CENTER)
    var top_row = top_line.copy().padding(STAGE_PAD_TOP, 0).fill()
    if tv.on():  # (the 14 under the top bar moves into the columns: the TV's canvas reaches into it, so the spring's
        # overshoot pokes up into the gap as the prototype's does rather than being cut flat; D-6712)
        top_row = VStack(_gap(0).height(STAGE_PAD_TOP), top_line^.fill(), spacing=0).fill()
    var half = STAGE_GAP // 2  # (a band's shade stops half a gap short of the centre, as the prototype's st-shade)
    var left_band = HStack(_gap(STAGE_PAD_X), VStack(_side_scroll(left), spacing=0).align(START).padding(4, 0).width(lay.side).fill().tag("stage-left"),
                           _gap(half), spacing=0).width(STAGE_PAD_X + lay.side + half).fill().tag("stage-side")
    var panel = VStack(centre.copy().grow().fill(), spacing=0).padding(STAGE_PANEL_PAD).grow().fill().tag("stage-panel")
    var centre_col: View
    if tv.on():
        var stack = VStack(panel, _gap(0).height(STAGE_BAR_H), _gap(0).height(STAGE_BOTTOM - STAGE_ROW_GAP), spacing=STAGE_ROW_GAP).grow().fill()
        var base = VStack(_gap(0).height(STAGE_PAD_TOP), stack^, spacing=0).grow().fill()
        centre_col = _tv_layers(base^, tv, content, bar_box^, STAGE_BOTTOM).grow().fill().tag("stage-centre")
        left_band = _below_gap(left_band^)
    else:
        centre_col = VStack(panel, bar_box, _gap(0).height(STAGE_BOTTOM - STAGE_ROW_GAP), spacing=STAGE_ROW_GAP).grow().fill().tag("stage-centre")
    var cols = List[View]()
    cols.append(left_band^)
    cols.append(centre_col^)
    if lay.right:
        var right_band = HStack(_gap(half), VStack(_side_scroll(right), spacing=0).align(START).padding(4, 0).width(lay.side).fill().tag("stage-right"),
                                _gap(STAGE_PAD_X), spacing=0).width(half + lay.side + STAGE_PAD_X).fill().tag("stage-side")
        cols.append(_below_gap(right_band^) if tv.on() else right_band^)
    else:
        cols.append(_gap(STAGE_PAD_X - half))  # (the centre 18 from the window's right edge: 9 of gap + 9 here)
    var body = HStack(cols, spacing=half).grow().fill()
    return VStack(top_row, body, spacing=0).grow().fill().tag("stage")


# ---------- the parts ----------

def StageClock(time: String, date: String, weather: String, compact: Bool = False) -> View:
    """The big clock at the top of the left column: the time (thin, very large: read across a room), the date, one line of
    weather (roles stage-clock, stage-clock-time or stage-clock-time-compact, stage-clock-date, stage-clock-weather)."""
    var items = List[View]()
    items.append(Text(time).tag("stage-clock-time-compact" if compact else "stage-clock-time"))
    items.append(Text(date).tag("stage-clock-date"))
    if weather != "":
        items.append(Text(weather).tag("stage-clock-weather"))
    return VStack(items, spacing=2).align(START).fill().tag("stage-clock")


def StageLabel(icon: String, text: String) -> View:
    """A section's small-caps label in a side column ("PINNED", "LIVE · ALSO TODAY"): its icon, the words on one line
    (stage-label, stage-label-text)."""
    var items = List[View]()
    if icon != "":
        items.append(Icon(icon, 14))
    items.append(Text(capitals(text)).grow().tag("stage-label-text"))  # (grown: GTK measures the words without their tracking)
    return HStack(items, spacing=6).align(CENTER).fill().tag("stage-label")


def _kind(icon: String, hue: Int) -> View:
    """A kind's icon (stage-glyph: in the ink on the accent) on a small square in a data colour (stage-kind-1 … stage-kind-6;
    0: the quiet one, stage-kind)."""
    var role = String("stage-kind") if hue < 1 or hue > 6 else "stage-kind-" + String(hue)
    return HStack(Icon(icon, 12).tag("stage-glyph"), spacing=0).align(CENTER).justify(CENTER).width(20).height(20).tag(role)


def StageCard(icon: String, head: String, title: String, sub: String = "", hue: Int = 0, on_unpin: Int = NO_MSG) -> View:
    """A card in a side column (a pinned card, a Today card): the kind's icon and its head in small caps, a title, a quiet
    line under it (roles stage-card, stage-card-head, stage-card-title, stage-card-sub); `on_unpin`: a pinned card's
    pin-off button at the head's end ("Unpin <head>", role stage-unpin) that puts it back on the stage."""
    var items = List[View]()
    var head_row = List[View]()
    head_row.append(_kind(icon, hue))
    if on_unpin != NO_MSG:  # (the head grows to the button: GTK measures its capitals without their tracking, D-7789b)
        head_row.append(Text(capitals(head)).grow().tag("stage-card-head"))
        head_row.append(Button("Unpin " + head, on_unpin, ICON_ONLY, "pin-off").width(28).height(28).tag("stage-unpin"))
    else:
        head_row.append(Text(capitals(head)).tag("stage-card-head"))
    items.append(HStack(head_row^, spacing=8).align(CENTER).fill())
    items.append(Text(title).tag("stage-card-title"))
    if sub != "":
        items.append(Text(sub).tag("stage-card-sub"))
    return VStack(items, spacing=2).align(START).fill().tag("stage-card")


def StageRow(icon: String, head: String, value: String, hue: Int = 0) -> View:
    """A Live or Today row in a side column: one line that keeps ticking (a timer's 7:20, a score's 2–1): the kind's icon,
    what it is, its value at the end (roles stage-row, stage-row-head, stage-row-value: mono and tabular for a number;
    stage-row-note for words, quiet, on one line, cut with an ellipsis)."""
    return HStack(_kind(icon, hue), Text(head).tag("stage-row-head"), Spacer(),
                  Text(value).tag("stage-row-value" if _numeric(value) else "stage-row-note"), spacing=10).align(CENTER).fill().tag("stage-row")


def _numeric(value: String) -> Bool:
    """A value read as a number (digits and : . , – - + ° % and spaces): a timer, a score, a temperature."""
    for c in value.codepoints():
        var s = String(c)
        if not (s >= "0" and s <= "9") and s != ":" and s != "." and s != "," and s != "–" and s != "-" and s != "+" and s != "°" and s != "%" and s != " ":
            return False
    return value != ""


def StageNote(text: String) -> View:
    """A quiet line in a side column where a list is empty ("Drag a tile here to keep it at your side"; role stage-note)."""
    return Text(text).tag("stage-note")


def StageList(items: List[View], compact: Bool = False) -> View:
    """Cards or rows under a label, top to bottom (stage-list); compact (a phone): one row that scrolls sideways
    (stage-list-row), as the prototype's pins."""
    if compact:
        return HStack(items, spacing=10).align(START).justify(START).fill().tag("stage-list-row")
    return VStack(items, spacing=10).align(START).fill().tag("stage-list")


def StageAvatar(initials: String, hue: Int, on_tap: Int) -> View:
    """A person in the top bar: their initials in a round button in their data colour (stage-avatar-1 … -6; 0: everyone,
    stage-avatar)."""
    var role = String("stage-avatar") if hue < 1 or hue > 6 else "stage-avatar-" + String(hue)
    return Button(initials, on_tap, SUBTLE).width(38).height(38).tag(role)


def StagePill(icon: String, label: String, on_tap: Int, compact: Bool = False) -> View:
    """A pill in the top bar ("Settings", "Charms"): an icon and a word on a card (stage-pill); compact (a phone): the
    icon alone in a 38 pt circle, the word its tooltip and accessible name (stage-pill-compact)."""
    if compact:
        return Button(label, on_tap, ICON_ONLY, icon).width(38).height(38).tag("stage-pill-compact")
    return Button(label, on_tap, SUBTLE, icon).tag("stage-pill")


def StageTool(label: String, on_tap: Int, icon: String) -> View:
    """A quiet round button in the chat bar beside the mic (stage-tool: 40 pt, the icon in the ink on a faint disc): the
    keyboard that opens the text box, a stop. `label` is its name (what a test or an agent taps) and tooltip."""
    return Button(label, on_tap, ICON_ONLY, icon).width(40).height(40).tag("stage-tool").tooltip(label)


def StageChat(orb: View, text: String, placeholder: String, on_change: Int = NO_MSG, on_submit: Int = NO_MSG, on_mic: Int = NO_MSG,
              subtitle: String = "", field: Bool = True, tools: List[View] = List[View](), mic: String = "Talk", mic_icon: String = "mic") -> View:
    """The chat bar's row: the orb (an OrbView(…, big=False) or any 52 pt view), a text box (stage-input), the round mic
    button (stage-mic, `mic`: "Talk"; a mute switch passes "Mute"/"Unmute" and "mic"/"mic-off"). Stage puts it in the bar's
    pill; M7d grows the pill into the TV.
    A voice-first bar (`field` False) shows a line of words where the box would be (stage-subtitle, one line): `subtitle`
    (what she is saying, as she says it) or else `placeholder`, and a keyboard among `tools` opens the box. `tools`: quiet round
    buttons before the mic (StageTool: the keyboard, a stop)."""
    var middle: View
    if field:
        middle = HStack(TextField(text, placeholder, on_change, on_submit).grow(), spacing=0).align(CENTER).grow().tag("stage-input")
    else:
        middle = HStack(Text(subtitle if subtitle != "" else placeholder).grow().tag("stage-subtitle"), spacing=0).align(CENTER).grow().tag("stage-input")
    var orb_box = HStack(orb.copy(), spacing=0).align(CENTER).justify(CENTER).width(52).height(52).tag("stage-orb")
    var items = List[View]()
    items.append(orb_box^)
    items.append(middle^)
    for t in tools:
        items.append(t.copy())
    items.append(Button(mic, on_mic, ICON_ONLY, mic_icon).width(50).height(50).tag("stage-mic"))
    return HStack(items^, spacing=10).align(CENTER).fill()
