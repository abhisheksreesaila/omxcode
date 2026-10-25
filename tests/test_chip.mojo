# mojoui.chip: Chip (hue or quiet), Badge (tone, dot), Pill: each its role, in a row of its own (so it never stretches).
from std.testing import assert_equal
from mojoui import TEXT, HSTACK, VSTACK
from mojoui.chip import Chip, Badge, Pill, BADGE_OK, BADGE_BAD, BADGE_WARN, chip_role


def main() raises:
    var c = Chip("Chat", hue=1)
    assert_equal(c.nodes[0].kind, HSTACK)
    assert_equal(c.nodes[1].kind, TEXT)
    assert_equal(c.nodes[1].text, "Chat")
    assert_equal(c.nodes[1].name, "chip-1")
    assert_equal(Chip("#work").nodes[1].name, "chip")
    assert_equal(chip_role(6), "chip-6")
    assert_equal(chip_role(7), "chip")
    var b = Badge("active", BADGE_OK, dot=True)
    assert_equal(b.nodes[0].kind, HSTACK)
    assert_equal(b.nodes[1].name, "badge-ok")
    assert_equal(b.nodes[2].kind, VSTACK)
    assert_equal(b.nodes[2].name, "dot")
    assert_equal(b.nodes[2].w, 6)
    assert_equal(b.nodes[3].text, "active")
    assert_equal(Badge("revoked").nodes[1].name, "badge")
    assert_equal(Badge("x", BADGE_BAD).nodes[1].name, "badge-bad")
    assert_equal(Badge("x", BADGE_WARN).nodes[1].name, "badge-warn")
    assert_equal(len(Badge("x").nodes), 3)  # no dot
    var p = Pill("3")
    assert_equal(p.nodes[1].name, "pill")
    assert_equal(p.nodes[1].text, "3")
    print("chip: ok")
