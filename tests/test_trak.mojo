# fonttext's 'trak' reader (D-7989): a synthetic table (two tracks, three sizes) parsed and interpolated as HarfBuzz
# does: the normal track picked, clamped below the first size and past the last, linear between. `trak: ok`.
from std.testing import assert_true, assert_equal
from mojoui.fonttext import parse_trak, trak_units


def be16(mut b: List[UInt8], v: Int):
    var u = v & 0xFFFF
    b.append(UInt8(u >> 8))
    b.append(UInt8(u & 0xFF))


def be32(mut b: List[UInt8], v: Int):
    var u = v & 0xFFFFFFFF
    be16(b, u >> 16)
    be16(b, u & 0xFFFF)


def main() raises:
    var b = List[UInt8]()
    for _ in range(5):  # (junk before the table: the offset is honoured)
        b.append(0)
    var t = len(b)
    be32(b, 0x00010000)  # version
    be16(b, 0)  # format
    be16(b, 12)  # horizOffset
    be16(b, 0)  # vertOffset
    be16(b, 0)  # reserved
    # TrackData at 12: 2 tracks, 3 sizes, size table at 12 + 8 + 16 = 36
    be16(b, 2)
    be16(b, 3)
    be32(b, 36)
    be32(b, -65536)  # track -1 (tight)
    be16(b, 256)
    be16(b, 48)
    be32(b, 0)  # track 0 (normal)
    be16(b, 257)
    be16(b, 54)
    for s in [12, 18, 36]:
        be32(b, s * 65536)
    for v in [-30, -40, -50]:
        be16(b, v)
    for v in [40, 20, -10]:
        be16(b, v)
    var tk = parse_trak(b, t)
    assert_equal(len(tk.values), 3)
    assert_equal(tk.values[0], 40)
    assert_equal(tk.values[2], -10)
    assert_true(trak_units(tk, 8) == 40.0, "below the first size")
    assert_true(trak_units(tk, 12) == 40.0, "at a size")
    assert_true(trak_units(tk, 15) == 30.0, "between")
    assert_true(trak_units(tk, 27) == 5.0, "between 18 and 36")
    assert_true(trak_units(tk, 72) == -10.0, "past the last")
    assert_true(parse_trak(b, -1).empty() and parse_trak(List[UInt8](), 0).empty(), "none")
    print("trak: ok")
