# mojoui.accents: the accents a person may pick for their look (mojoui.personalize) and what each is, kept apart from
# personalize so a theme can name them without importing the agent stack: the values in order (the default first), each
# one's colour in a palette (the palette's own series colours, never one from outside it), and the roles of the swatches
# that show them (mojoui.personalize.accent_swatches draws the buttons; a theme styles look-swatch-<value>[-on]:
# themes/omxqua's swatch_roles).
#
#   accent_colour(palette, "gold") · accent_index("gold") · ACCENT_VALUES · swatch_role("gold", on=True)

from mojoui.theme import Palette

comptime ACCENT_VALUES: List[String] = ["default", "violet", "blue", "teal", "orange", "red", "gold"]  # (the default first; then
# Palette.series 0..5 in its order)
comptime SWATCH_SIDE = 32  # a swatch's round button, points (a touch target on the Counter)
comptime SWATCH_ROLE = "look-swatch-"  # + the value, + "-on" when chosen


def accent_values() -> List[String]:
    """The accent values, the default first."""
    return materialize[ACCENT_VALUES]()


def accent_index(accent: String) -> Int:
    """The accent's palette series slot (0..5), -1 for the theme's own accent (or a word that isn't one)."""
    var vs = accent_values()
    for i in range(1, len(vs)):
        if vs[i] == accent:
            return i - 1
    return -1


def accent_colour(p: Palette, accent: String) -> UInt32:
    """The accent as a colour of palette `p` (its series colour; the palette's own accent for "default")."""
    var k = accent_index(accent)
    if k < 0 or len(p.series) == 0:
        return p.accent
    return p.series[k % len(p.series)]


def swatch_role(value: String, on: Bool) -> String:
    """The role an accent swatch wears: look-swatch-<value>, and -on for the chosen one (a theme gives each its colour, the
    chosen one a ring and a tick)."""
    return SWATCH_ROLE + value + ("-on" if on else "")
