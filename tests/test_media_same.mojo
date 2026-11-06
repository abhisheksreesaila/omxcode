# mojoui.video on every platform (goal 58): the same lines from Linux (ffmpeg) and a Mac (AVFoundation, ImageIO), so a
# check can compare what each decoder delivered. No reference decoder here: the other platform is the reference.
#   MEDIA_VIDEO=<an .mp4> MEDIA_DIR=tests/fixtures pixi run mojo run -I . tests/test_media_same.mojo
# Prints "INFO: w h fps frames duration", "FRAME <n>: w h <64 thumbnail colours>" for frames 0–9 read in order and 30,
# 100 and 12 reached by seeking, "PICTURE <name>: w h <64 colours>", "WRITTEN: w h n frames" for 30 frames written and read
# back, "WRITTEN 10:" / "SOURCE 10:" thumbnails of frame 10 after and before, then "MEDIA: done".
from std.os import getenv
from mojoui.video import VideoSource
from mojoui.videoexport import VideoWriter


def hex2(v: Int) -> String:
    comptime digits = "0123456789abcdef"
    return String(digits[byte = (v >> 4) & 15]) + String(digits[byte = v & 15])


def thumb(px: List[UInt32], w: Int, h: Int) -> String:
    """An 8 × 8 grid of the picture's mean colours (rrggbbaa each), cell by cell, row by row."""
    var out = String("")
    for gy in range(8):
        for gx in range(8):
            var x0 = gx * w // 8
            var x1 = max((gx + 1) * w // 8, x0 + 1)
            var y0 = gy * h // 8
            var y1 = max((gy + 1) * h // 8, y0 + 1)
            var r = 0
            var g = 0
            var b = 0
            var a = 0
            var n = 0
            for y in range(y0, y1):
                for x in range(x0, x1):
                    var p = px[y * w + x]
                    r += Int(p & 0xFF)
                    g += Int((p >> 8) & 0xFF)
                    b += Int((p >> 16) & 0xFF)
                    a += Int((p >> 24) & 0xFF)
                    n += 1
            out += " " + hex2(r // n) + hex2(g // n) + hex2(b // n) + hex2(a // n)
    return out


def main() raises:
    var video = getenv("MEDIA_VIDEO", "")
    var dir = getenv("MEDIA_DIR", "tests/fixtures")
    var v = VideoSource(video)
    print("INFO:", v.width, v.height, v.fps, v.frames, v.duration)
    for n in range(10):
        var px = v.next()
        print("FRAME " + String(n) + ": " + String(v.width) + " " + String(v.height) + thumb(px, v.width, v.height))
    for n in [30, 100, 12]:
        var px = v.read(n)
        print("FRAME " + String(n) + ": " + String(v.width) + " " + String(v.height) + thumb(px, v.width, v.height))
    for name in ["media/alpha.png", "vision/cat.jpg", "vision/cat_gray.jpg"]:
        var p = VideoSource(dir + "/" + name)
        var px = p.next()
        print("PICTURE " + name + ": " + String(p.width) + " " + String(p.height) + thumb(px, p.width, p.height))
    # write: the first 30 frames into an H.264 .mp4 (libx264 on Linux, AVAssetWriter on a Mac), then read back
    var out = getenv("TMPDIR", "/tmp") + "/test_media_same.mp4"
    var src = VideoSource(video)
    var w = VideoWriter(out, src.width, src.height, src.fps)
    var source10 = List[UInt32]()
    for n in range(30):
        var px = src.next()
        if n == 10:
            source10 = px.copy()
        w.write(px)
    w.close()
    var back = VideoSource(out)
    var px10 = back.read(10)
    print("WRITTEN: " + String(back.width) + " " + String(back.height) + " " + String(back.frames) + " frames")
    print("WRITTEN 10:" + thumb(px10, back.width, back.height))
    print("SOURCE 10:" + thumb(source10, src.width, src.height))
    print("MEDIA: done")
