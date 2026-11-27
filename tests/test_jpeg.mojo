# mojoui.jpeg (goal 82 M2): the encoder's bytes decode, in another program, to the picture within the quality's error.
#   pixi run mojo run -I . tests/test_jpeg.mojo <out-dir>     then tests/test_jpeg.py <out-dir> decodes and compares (Pillow)
from mojoui.jpeg import encode_jpeg, quality_table, _lum_q
from mojoui.png import encode_png
from std.sys import argv
from std.math import sin, cos


def picture(w: Int, h: Int) -> List[UInt32]:
    var px = List[UInt32](capacity=w * h)
    for y in range(h):
        for x in range(w):
            var r = UInt32(Int(127.5 + 127.5 * sin(Float64(x) * 0.05)))
            var g = UInt32(Int(Float64(y) * 255.0 / Float64(max(h - 1, 1))))
            var b = UInt32(Int(127.5 + 127.5 * cos(Float64(x + y) * 0.02)))
            if (x // 40 + y // 40) % 2 == 0 and x > w // 2:  # (hard edges too)
                r = 250
                g = 30
                b = 30
            px.append(r | (g << 8) | (b << 16) | (UInt32(255) << 24))
    return px^


def write(path: String, data: List[UInt8]) raises:
    with open(path, "w") as f:
        f.write_bytes(Span(data))


def main() raises:
    var out = argv()[1] if len(argv()) > 1 else "/tmp"
    var t = quality_table(_lum_q(), 85)
    if t[0] != 5 or t[1] != 3 or t[63] != 30:
        raise Error("FAIL: libjpeg's quality 85 scaling (want 5 3 … 30): " + String(t[0]) + " " + String(t[1]) + " " + String(t[63]))
    for size in [(64, 64), (333, 217), (1, 1), (17, 9)]:
        var w = size[0]
        var h = size[1]
        var px = picture(w, h)
        write(String(out) + "/jpeg-" + String(w) + "x" + String(h) + ".jpg", encode_jpeg(px, w, h, 85))
        write(String(out) + "/jpeg-" + String(w) + "x" + String(h) + ".png", encode_png(px, w, h))
        var again = encode_jpeg(px, w, h, 85)
        var once = encode_jpeg(px, w, h, 85)
        if len(again) != len(once):
            raise Error("FAIL: the same pixels, other bytes")
    print("test_jpeg: written to " + String(out))
