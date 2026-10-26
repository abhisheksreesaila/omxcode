# mojoui.adminkit: the small pieces an admin page's cards are made of (goal 33 M6, the OMX Console's Keys, Gateway,
# Security and Settings): a card foot with a copy button ("$ mxc status   copy"), a state as a dot and a word in four
# tones (quiet, good, warn, bad; mono for a status code), small buttons in the console's other tones (text, danger,
# danger armed for a tap-twice action, and dimmed when they can't act), an endpoint row (a tag, a value, Copy), a
# secret shown once (a dark mono box), a warning box, and an icon on a tinted square in a tone. Each is made of Text,
# Button, Icon and stacks and wears a framework role its theme shapes; admin_roles(palette, mono) gives a theme those
# roles in omxqua's measures (omxqua's components.css, the console's blade-settings.css and blade-keys.css).
#
#   CopyFoot("mxc status", COPY_STATUS)                    StateMark("running · :4000", GOOD)
#   ActionButton("Revoke", REVOKE + k, "trash-2", DANGER, armed=keys.is_armed(k), off=not active)
#   EndpointRow("https · lan", url, "Copy", COPY_URL)       SecretBox(key)        WarnBox([Text("Stop the daemon?"), …])

from mojoui.view import View, Text, Button, Icon, VStack, HStack, Spacer, SUBTLE, PLAIN, CENTER, START, NO_MSG
from mojoui.theme import Palette, Surface, Shadow, words, chip, mix
from mojoui.table import capitals

# tones: a state's dot and word, a tinted square
comptime QUIET = 0
comptime GOOD = 1
comptime WARN = 2
comptime BAD = 3
# an ActionButton's look (omxqua's .btn.sm with .tonal, .fill, .text, .danger)
comptime TONAL = 0
comptime FILL = 1
comptime TEXT = 2
comptime DANGER = 3

comptime TONE_NAMES: List[String] = ["quiet", "good", "warn", "bad"]
comptime ACT_NAMES: List[String] = ["tonal", "fill", "text", "danger"]


def CopyFoot(command: String, on_copy: Int, note: Bool = False) -> View:
    """A card's foot: a source line over a rule ($ mxc …, or ↳ a note) with a small copy button at its end (roles
    card-foot, foot-copy). The copy itself is the app's (a mojoui.overlays.Clipboard), on `on_copy`."""
    return HStack(Text(("↳ " if note else "$ ") + command), Spacer(), Button("copy", on_copy, SUBTLE).tag("foot-copy"),
                  spacing=8).align(CENTER).fill().tag("card-foot")


def StateMark(text: String, tone: Int = QUIET, mono: Bool = False) -> View:
    """A state: a 7 pt dot and a word in a tone (roles mark-dot-<tone>, mark-<tone>; mark-mono-<tone> for a figure)."""
    var t = materialize[TONE_NAMES]()[min(max(tone, 0), 3)]
    return HStack(VStack(spacing=0).width(7).height(7).tag("mark-dot-" + t), Text(text).tag(("mark-mono-" if mono else "mark-") + t),
                  spacing=6).align(CENTER)


def ActionButton(title: String, on_tap: Int, icon: String = "", look: Int = TONAL, armed: Bool = False, off: Bool = False) -> View:
    """A small pill button (26 pt high) in a look: TONAL, FILL, TEXT or DANGER (roles act-<look>); a DANGER one that
    waits for its second tap is `armed` (act-danger-armed); `off`: dimmed and it sends nothing (act-<look>-off)."""
    var name = materialize[ACT_NAMES]()[min(max(look, 0), 3)]
    var role = "act-" + name + ("-off" if off else ("-armed" if armed and look == DANGER else ""))
    return Button(title, NO_MSG if off else on_tap, PLAIN, icon).height(26).tag(role)


def EndpointRow(key: String, value: String, copy_title: String, on_copy: Int) -> View:
    """An endpoint or a file: a small caps tag, the value in the mono, a text button to copy it, in a ring (roles
    endpoint-row, endpoint-key, endpoint-value)."""
    var items: List[View] = [Text(capitals(key)).tag("endpoint-key"), Text(value).tag("endpoint-value").grow()]
    if copy_title != "":
        items.append(ActionButton(copy_title, on_copy, "copy", TEXT))
    return HStack(items^, spacing=10).align(CENTER).fill().tag("endpoint-row")


def SecretBox(text: String) -> View:
    """A secret shown once: the mono on the dark code surface, wrapping anywhere (role secret)."""
    return Text(text).grow().tag("secret")


def WarnBox(var items: List[View]) -> View:
    """A warning that asks before something can't be undone: the bad colour faintly behind its words (role warn-box)."""
    return VStack(items^, spacing=10).align(START).fill().tag("warn-box")


def ToneSquare(icon: String, tone: Int = QUIET, size: Int = 36) -> View:
    """An icon on a rounded square tinted in a tone (role tone-square-<tone>)."""
    return VStack(Icon(icon, 18), spacing=0).width(size).height(size).align(CENTER).justify(CENTER).tag(
        "tone-square-" + materialize[TONE_NAMES]()[min(max(tone, 0), 3)])


# ---------- the look, for a theme to add to its Look's surfaces ----------

def _tint(c: UInt32, a: Float64) -> UInt32:
    return (c & 0xFFFFFF) | (UInt32(Int(a * 255 + 0.5)) << 24)


def _box(role: String, fill: UInt32, radius: Int, pad_v: Int, pad_h: Int) -> Surface:
    return Surface(role, fill, radius, radius, -1, -1, -1, pad_v, pad_h, pad_v, [], 0, 0, 0, -1, "", 0, 0, 0, 0, 0, 0, 0, False)


def _words(role: String, size: Float64, weight: Int, ink: UInt32, font: String = "") -> Surface:
    var s = words(role, size, weight, ink)
    s.font = font
    return s^


def admin_roles(p: Palette, mono: String, code: UInt32, code_ink: UInt32) -> List[Surface]:
    """adminkit's roles in omxqua's measures; `code`/`code_ink`: the theme's dark code surface (the secret's box)."""
    var out = List[Surface]()
    var cp = _box("foot-copy", _tint(p.ink, 0.05), 999, 0, 10)  # .src .cp: 500 11px mono ink-2, 24 high, 0 10px, a pill
    cp.font, cp.font_size, cp.font_weight, cp.ink, cp.min_height = mono, 11, 500, p.ink2, 24
    out.append(cp^)
    var inks: List[UInt32] = [p.ink2, p.good, p.warn, p.bad]  # .ox-st: 12.5px ink-2; .run ok, .warn, .bad
    var dots: List[UInt32] = [p.ink3, p.good, p.warn, p.bad]
    var names = materialize[TONE_NAMES]()
    for k in range(4):
        out.append(_box("mark-dot-" + names[k], dots[k], 99, -1, -1))
        out.append(_words("mark-" + names[k], 12.5, 0, inks[k]))
        out.append(_words("mark-mono-" + names[k], 12.5, 0, inks[k], mono))
        var sq = _box("tone-square-" + names[k], _tint(dots[k] if k > 0 else p.ink2, 0.14), 10, -1, -1)  # .ox-tile: the colour at 14 %
        sq.ink = dots[k] if k > 0 else p.ink2
        out.append(sq^)
    # .btn.sm (26 high, 0 12px, 550 .88em) in each look; [disabled] at .45
    var state = _tint(p.ink, 0.06)
    var fills: List[UInt32] = [state, p.accent, 0, 0]
    var acts_ink: List[UInt32] = [p.ink, p.accent_ink, p.ink2, p.bad]
    var rings: List[UInt32] = [0, 0, 0, mix(p.card, p.bad, 0.40)]
    var acts = materialize[ACT_NAMES]()
    for k in range(4):
        var a = chip("act-" + acts[k], fills[k], rings[k], 12.32, acts_ink[k], 999, 0, 12)
        a.min_height, a.font_weight = 26, 550
        var off = chip("act-" + acts[k] + "-off", mix(p.card, fills[k], 0.45) if fills[k] != 0 else 0, mix(p.card, rings[k], 0.45) if rings[k] != 0 else 0,
                       12.32, mix(p.card, acts_ink[k], 0.45), 999, 0, 12)
        off.min_height, off.font_weight = 26, 550
        out.append(a^)
        out.append(off^)
    var armed = chip("act-danger-armed", mix(p.card, p.bad, 0.14), mix(p.card, p.bad, 0.40), 12.32, p.bad, 999, 0, 12)  # .btn.danger.armed
    armed.min_height, armed.font_weight = 26, 650
    out.append(armed^)
    var ep = chip("endpoint-row", 0, p.line, 13, p.ink, 12, 0, 6)  # .ox-ep: a 1px line, 12 corners, 0 6 0 12, 44 high, 13px mono
    ep.min_height, ep.font = 44, mono
    out.append(ep^)
    var key = _words("endpoint-key", 11, 0, p.ink2, mono)  # .ox-ep .k: 11px, ink-2, caps, .06em
    key.tracking = 0.66
    out.append(key^)
    out.append(_words("endpoint-value", 13, 0, p.ink, mono))
    var secret = _box("secret", code, 10, 10, 12)  # .secret: --code, 10 corners, 10px 12px, 12.5px mono --code-text
    secret.font, secret.font_size, secret.ink = mono, 12.5, code_ink
    out.append(secret^)
    var warn = _box("warn-box", _tint(p.bad, 0.08), 12, 12, 14)  # .ox-warnbox: the bad colour at 8 %, 12 corners, 12px 14px
    warn.font_size, warn.ink = 13, p.ink2
    out.append(warn^)
    return out^
