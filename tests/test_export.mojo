# mojoui.videoexport on the generated warehouse (goal 39 M5): the reel of every damaged pallet, faces blurred, the
# shipment ID burned in.
#   G39_MEDIA=build/g39/media G39_OUT=build/g39 pixi run mojo run -I . tests/test_export.mojo
# Segments, faces and captions all come from M4's rows (mojoui.videotable), never from truth.json; scripts/check.py m5
# scores the reel against truth. Prints "export: ok".
from std.testing import assert_equal, assert_true
from std.os import getenv
from std.python import Python
from mojoui.video import VideoSource
from mojoui.videotable import scan
from mojoui.videoexport import VideoWriter, cut, RedactPlan, NoEdits, flagged_captions, read_csv_map, frame_ranges
from mojoui.vision_presets import warehouse_ranges, warehouse_analyzer, WAREHOUSE_CELL
from mojoui.imageops import ImageOps, Frame, Edits
from mojoui.clock import now_ns


def probe(path: String) raises -> Tuple[Int, Int, Float64, String, String]:
    """The ffprobe answers: width, height, duration, codec, pixel format."""
    var json = Python.import_module("json")
    var sp = Python.import_module("subprocess")
    var r = sp.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                    "stream=width,height,codec_name,pix_fmt:format=duration", "-of", "json", path], capture_output=True, text=True)
    var j = json.loads(r.stdout)
    var s = j["streams"][0]
    return (Int(py=s["width"]), Int(py=s["height"]), Float64(String(j["format"]["duration"])), String(s["codec_name"]), String(s["pix_fmt"]))


def main() raises:
    var media = getenv("G39_MEDIA", "build/g39/media")
    var out = getenv("G39_OUT", "build/g39")
    var src = media + "/warehouse.mp4"

    # VideoWriter alone: 15 frames of a gradient → a 0.5 s H.264 file
    var w = VideoWriter(out + "/export-probe.mp4", 320, 180, 30)
    var px = List[UInt32](length=320 * 180, fill=0)
    for f in range(15):
        for i in range(len(px)):
            px[i] = UInt32((i % 320 + f * 8) % 256) | (UInt32(128) << 8) | (UInt32(200) << 16) | 0xFF000000
        w.write(px)
    w.close()
    var p = probe(out + "/export-probe.mp4")
    assert_equal(p[0], 320)
    assert_equal(p[3], "h264")
    assert_equal(p[4], "yuv420p")
    assert_true(abs(p[2] - 0.5) < 0.05, "probe duration " + String(p[2]))

    # an oval blur (faces): GPU equals CPU, the rectangle's corners untouched, its middle blurred
    var probe_src = VideoSource(src)
    var src_px = probe_src.read(170)
    var f1 = Frame(1280, 720, src_px.copy())
    var f2 = Frame(1280, 720, src_px.copy())
    var e = Edits()
    e.blur_oval(880, 12, 104, 104, 14)
    var gpu_ops = ImageOps()
    var cpu_ops = ImageOps(False)
    gpu_ops.apply(f1, e)
    cpu_ops.apply(f2, e)
    for i in range(len(f1.pixels)):
        assert_equal(f1.pixels[i], f2.pixels[i])
    assert_equal(f1.pixels[12 * 1280 + 880], src_px[12 * 1280 + 880])
    assert_equal(f1.pixels[115 * 1280 + 983], src_px[115 * 1280 + 983])
    var changed = 0
    for y in range(44, 84):
        for x in range(912, 952):
            if f1.pixels[y * 1280 + x] != src_px[y * 1280 + x]:
                changed += 1
    assert_true(changed > 1200, "oval blur changed " + String(changed) + " of 1600 middle pixels")
    print("oval blur: ok (gpu equals cpu)")

    # M4's rows → segments (damaged pallets in view), faces to blur, captions naming the shipment
    var video = VideoSource(src)
    var a = warehouse_analyzer()
    var table = scan(video, a, warehouse_ranges(), WAREHOUSE_CELL)
    var segments = List[Tuple[Float64, Float64]]()
    for iv in table.intervals("pallet", damaged_only=True):
        segments.append((Float64(iv[0]) / table.fps, Float64(iv[1]) / table.fps))
    assert_true(len(segments) >= 1, "no damaged pallet seen")
    var want = 0
    for r in frame_ranges(segments, video.fps, video.frames):
        want += r[1] - r[0]
    var names = read_csv_map(media + "/shipments.csv", "pallet_code", "shipment")
    var captions = flagged_captions(table, "pallet", names)
    for c in captions:
        print("caption", c.first, "→", c.last, ":", c.text)
    assert_true(len(captions) >= len(segments), "a caption on every segment")
    var plan = RedactPlan(table^, "face", 18, "pallet")
    for ref c in captions:
        plan.add_caption(c.first, c.last, c.text)
    plan.caption_box(40, 630, 520, 60)

    var ops = ImageOps()
    var t0 = Int(now_ns())
    var n = cut(video, segments, plan, out + "/reel.mp4", ops)
    var secs = Float64(Int(now_ns()) - t0) / 1e9
    assert_equal(n, want)
    var q = probe(out + "/reel.mp4")
    assert_equal(q[0], 1280)
    assert_equal(q[1], 720)
    assert_equal(q[3], "h264")
    assert_equal(q[4], "yuv420p")
    assert_true(abs(q[2] - Float64(n) / 30) < 0.05, "reel duration " + String(q[2]))
    print("reel:", n, "frames,", q[2], "s, in", secs, "s (", Float64(n) / secs, "frames/s, decode + edits + encode )")
    print("export: ok")
