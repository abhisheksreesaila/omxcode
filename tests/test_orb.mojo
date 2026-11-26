# mojoui.orb (goal 72 M4): the orb is drawn where it should be, in the palette's colours, over a see-through canvas;
# a voice makes it bigger and settles back; the cloud rim paints the warning tone at the edge and nothing when off.
#   pixi run mojo build -I . tests/test_orb.mojo -o build/test_orb && build/test_orb
from std.ffi import external_call, c_int
from std.testing import assert_equal, assert_true
from mojoui.canvas import Surface
from mojoui.orb import Orb, ORB_IDLE, ORB_LISTEN, ORB_THINK, draw_rim
from mojoui.theme import Palette
from mojoui.view import VStack, Text


def covered(buf: List[UInt32]) -> Int:
    var n = 0
    for v in buf:
        if (v >> 24) > 128:
            n += 1
    return n


def frames(mut orb: Orb, mut s: Surface, p: Palette, n: Int):
    for _ in range(n):
        orb.draw(s, p)  # (it clears the surface itself)
        _ = external_call["usleep", c_int](c_int(16_000))


def main() raises:
    var p = Palette.plain()
    var w = 400
    var h = 300
    var buf = List[UInt32](length=w * h, fill=0)
    var s = Surface(Int(buf.unsafe_ptr()), w, h, 1.0)
    var orb = Orb()
    orb.mode(ORB_IDLE)
    frames(orb, s, p, 10)
    var rest = covered(buf)
    assert_equal(buf[0], UInt32(0))  # the corner stays see-through
    assert_true((buf[(h // 2) * w + w // 2] >> 24) >= 240, "the body is opaque at its centre")
    assert_true(s.again, "it asks for the next frame: it breathes")
    frames(orb, s, p, 30)  # (a canvas keeps what was drawn: the glow must not pile up frame after frame)
    var glow = buf[(h // 2) * w + w // 2 + 126] >> 24
    assert_true(glow > 0 and glow < 60, "the halo's edge stays faint over many frames: alpha " + String(glow))
    # the body is the palette's accent (blobs of it, lightened): red, green, blue within reach of it at the centre
    var c = buf[(h // 2) * w + w // 2]
    assert_true(Int(c & 255) < 200 and Int((c >> 16) & 255) > 100, "an accent-family colour, not grey: " + String(c))
    assert_true(rest > 15000 and rest < 60000, "idle size: " + String(rest) + " px")
    orb.mode(ORB_LISTEN)
    orb.drive(1.0)
    frames(orb, s, p, 40)
    var loud = covered(buf)
    assert_true(loud > rest * 12 // 10, "a loud voice swells it: " + String(rest) + " -> " + String(loud))
    orb.drive(0.0)
    frames(orb, s, p, 80)
    var back = covered(buf)
    assert_true(back < loud * 9 // 10, "silence settles it: " + String(loud) + " -> " + String(back))
    # eyes (goal 77 M1): looking at something right of it grows two white eyes on the front whose pupils turn that way; letting go clears them
    var eyed = Orb()
    frames(eyed, s, p, 10)
    var cy = h // 2 - Int(0.06 * 0.30 * Float64(h))  # (the eyes sit a little above the middle)
    def whites(buf: List[UInt32], w: Int, y: Int) -> Int:
        var n = 0
        for x in range(w):
            var v = buf[y * w + x]
            if (v >> 24) > 200 and Int(v & 255) > 235 and Int((v >> 8) & 255) > 235 and Int((v >> 16) & 255) > 235:
                n += 1
        return n
    assert_equal(whites(buf, w, cy), 0)
    eyed.look(1.0, 0.0, 1.0)
    frames(eyed, s, p, 60)
    assert_true(whites(buf, w, cy) > 8, "two white eyes show once it looks at something: " + String(whites(buf, w, cy)))
    var dark_right = 0
    var dark_left = 0
    for x in range(w):
        var v = buf[cy * w + x]
        if Int(v & 255) < 60 and Int((v >> 8) & 255) < 60 and Int((v >> 16) & 255) < 70 and (v >> 24) > 200:
            if x > w // 2:
                dark_right += 1
            else:
                dark_left += 1
    assert_true(dark_right > 0 and dark_left > 0, "a dark pupil in each eye")
    eyed.look(0.0, 0.0, 0.0)
    frames(eyed, s, p, 90)
    assert_equal(whites(buf, w, cy), 0)
    var v0 = orb.version()
    orb.mode(ORB_THINK)
    assert_true(orb.version() != v0, "a new mode is a new canvas version")
    # a smaller canvas: the radius follows by spring, not by jump
    var small = List[UInt32](length=100 * 100, fill=0)
    var s2 = Surface(Int(small.unsafe_ptr()), 100, 100, 1.0)
    s2.fill(0)
    orb.draw(s2, p)
    var first = covered(small)
    frames(orb, s2, p, 60)
    var settled = covered(small)
    assert_true(first > settled, "the orb shrinks into the small canvas: " + String(first) + " -> " + String(settled))
    # the rim
    var rim = List[UInt32](length=w * h, fill=0)
    var s3 = Surface(Int(rim.unsafe_ptr()), w, h, 1.0)
    draw_rim(s3, p, False)
    assert_equal(covered(rim), 0)
    draw_rim(s3, p, True)
    var e = rim[(h // 2) * w + 1]
    assert_equal(e & 0x00FFFFFF, p.warn & 0x00FFFFFF)
    assert_true((e >> 24) >= 240, "the edge is the warning tone at nearly full strength")
    assert_equal(rim[(h // 2) * w + w // 2], UInt32(0))  # the middle is left alone
    assert_true((rim[(h // 2) * w + w - 2] >> 24) >= 240, "the right edge too")
    assert_true((rim[1 * w + w // 2] >> 24) >= 240 and (rim[(h - 2) * w + w // 2] >> 24) >= 240, "top and bottom too")
    print("orb: ok (idle", rest, "px, loud", loud, "px, settled", back, "px)")
