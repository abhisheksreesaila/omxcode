# mojoui.marks: small marks that carry a state or an identity (goal 33 M7, D-415): a dot in a hue, a thing's own colour
# (the n-th of the theme's signal colours), a state as a dot and a word in a tone, an icon in a hue. Sizes and colours
# come from the theme's roles.
#
#   StatusMark("Running", GOOD, live=True)     StatusMark("idle", QUIET)     SignalDot(2)     HueIcon("gauge", 15, 1)

from mojoui.view import View, Text, Icon, VStack, HStack, CENTER, SPACE_S

# tones: a state's dot and word, a tinted square (mojoui.header.IconSquare)
comptime QUIET = 0
comptime GOOD = 1
comptime WARN = 2
comptime BAD = 3
comptime INFO = 4  # (the first data colour: something to do, not a problem)
comptime TONE_NAMES: List[String] = ["quiet", "good", "warn", "bad", "info"]


def tone_name(tone: Int) -> String:
    return materialize[TONE_NAMES]()[min(max(tone, 0), 4)]


def HueDot(hue: Int) -> View:
    """A dot in data colour `hue` (1–6), the good colour (7), the warning colour (8) or the faint ink (0) (roles
    hue-dot-0 … hue-dot-8: its size and colour)."""
    return VStack(spacing=0).tag("hue-dot-" + String(min(max(hue, 0), 8)))


def SignalDot(k: Int) -> View:
    """A thing's own colour as a dot: the k-th (from 1, wrapping) of the theme's signal colours, a model's in the order
    they're first seen (roles signal-dot-1 … signal-dot-5)."""
    return VStack(spacing=0).tag("signal-dot-" + String((max(k, 1) - 1) % 5 + 1))


def StatusMark(text: String, tone: Int = QUIET, mono: Bool = False, live: Bool = False, cell: Bool = False) -> View:
    """A state: a dot and a word in a tone (QUIET, GOOD, WARN, BAD, INFO; roles status-dot-<tone>, status-<tone>,
    status-mono-<tone> for a figure); `live`: the dot ringed, something running now (status-dot-live-<tone>); `cell`:
    in a table's cell, as tall as the cell's line (status-cell-<tone>)."""
    var t = tone_name(tone)
    var dot = VStack(spacing=0).tag(("status-dot-live-" if live else "status-dot-") + t)
    var word = ("status-mono-" if mono else ("status-cell-" if cell else "status-")) + t
    return HStack(dot^, Text(text).tag(word), spacing=SPACE_S).align(CENTER).tag("status-mark")


def HueIcon(name: String, size: Int, hue: Int) -> View:
    """An icon in a hue (role hue-icon-<hue>: 1–6 the data colours, 7 good, 8 warning), 0 the text's colour (hue-icon)."""
    return Icon(name, size).tag("hue-icon" + ("-" + String(min(hue, 8)) if hue > 0 else String("")))
