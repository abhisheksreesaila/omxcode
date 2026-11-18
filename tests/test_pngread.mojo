# mojoui.pngread (goal 77 M3): PNG pictures decoded in Mojo match Pillow's reading of them, pixel for pixel, in every colour type
# (fixtures made by Pillow with optimize=True: dynamic Huffman blocks, every row filter), and mojoui.png's own stored-block files.
from std.testing import assert_equal, assert_true
from mojoui.pngread import decode_png, inflate_zlib
from mojoui.png import encode_png
from mojoui.clock import now_ns


def read(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def main() raises:
    var names: List[String] = ["rgba", "rgb", "grey", "greya", "pal", "pal4", "bw", "palt"]
    for name in names:
        var img = decode_png(read("tests/fixtures/png/" + name + ".png"))
        var ref_ = read("tests/fixtures/png/" + name + ".rgba")
        assert_equal(img.width, 37)
        assert_equal(img.height, 23)
        assert_equal(len(ref_), 37 * 23 * 4)
        var bad = 0
        for i in range(37 * 23):
            var want = UInt32(ref_[4 * i]) | (UInt32(ref_[4 * i + 1]) << 8) | (UInt32(ref_[4 * i + 2]) << 16) | (UInt32(ref_[4 * i + 3]) << 24)
            if img.pixels[i] != want:
                bad += 1
        assert_equal(bad, 0, name)
        print("pngread", name, ": ok")
    # mojoui.png's own files (stored blocks) round-trip
    var px = List[UInt32]()
    for i in range(64 * 48):
        px.append(UInt32(i * 2654435761 % 4294967296))
    var back = decode_png(encode_png(px, 64, 48))
    var same = True
    for i in range(64 * 48):
        same = same and back.pixels[i] == px[i]
    assert_true(same)
    print("pngread stored round-trip: ok")
    # damaged input raises, never crashes
    var junk = read("tests/fixtures/png/rgb.png")
    junk.resize(len(junk) // 2, 0)
    var raised = False
    try:
        _ = decode_png(junk)
    except:
        raised = True
    assert_true(raised)
    var t0 = now_ns()
    for _ in range(200):
        _ = decode_png(read("tests/fixtures/png/rgba.png"))
    print("pngread a 37x23 RGBA picture:", Float64(now_ns() - t0) / 200e3, "us")
