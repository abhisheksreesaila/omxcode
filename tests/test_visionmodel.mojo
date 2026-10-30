# mojoui.visionmodel in process (goal 39 M12 spike): a VideoSource frame handed to PyTorch without files or HTTP, OWLv2's
# boxes back as VideoTable rows, SAM 2.1 following one of them, and a ModelAnalyzer scan with keyframes.
#   G39_MEDIA=../mojo-ui-g39/build/g39/media CUDA_VISIBLE_DEVICES=1 pixi run -e models mojo run -I . tests/test_visionmodel.mojo
# Prints "visionmodel: ok" plus the timings (hand-off ms, model ms). Needs the `models` pixi environment and a CUDA GPU.
from std.testing import assert_equal, assert_true
from std.os import getenv
from max.gpu.host import DeviceContext
from mojoui.video import VideoSource
from mojoui.videotable import VideoTable, ColourRange, scan
from mojoui.visionmodel import VisionModel, ModelAnalyzer, Detection, DETECT, SEGMENT, iou
from mojoui.clock import now_ns


def ms_since(t0: Int) -> Float64:
    return Float64(Int(now_ns()) - t0) / 1e6


def main() raises:
    var media = getenv("G39_MEDIA", "build/g39/media")
    var path = media + "/warehouse.mp4"
    var prompts = List[String]()
    prompts.append("a box on a conveyor belt")
    prompts.append("a red splat")
    var kinds = List[String]()
    kinds.append("box")
    kinds.append("splat")

    var v = VideoSource(path)
    v.seek_frame(420)
    var px = v.next()
    var w = v.width
    var h = v.height
    var addr = UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=Int(px.unsafe_ptr()))

    var t0 = Int(now_ns())
    var det = VisionModel("google/owlv2-base-patch16-ensemble", DETECT)
    print("owlv2 load:", ms_since(t0), "ms (backend says", det.load_ms, "ms; the rest is importing torch)")

    # host frame -> GPU: numpy view of our address (no copy) -> pinned -> GPU
    _ = det.detect(addr, w, h, prompts, 0.15)  # warm-up
    var calls = List[Float64]()
    var handoffs = List[Float64]()
    var models = List[Float64]()
    var found = List[Detection]()
    for _ in range(11):
        var t1 = Int(now_ns())
        found = det.detect(addr, w, h, prompts, 0.15)
        calls.append(ms_since(t1))
        handoffs.append(det.handoff_ms())
        models.append(det.model_ms())
    sort(calls)
    sort(handoffs)
    sort(models)
    var handoff = handoffs[5]
    var model = models[5]
    print("host path: hand-off", handoff, "ms, model", model, "ms, whole call from Mojo", calls[5], "ms,", len(found), "boxes")
    var table = VideoTable()
    for d in found:
        table.add(420, kinds[d.label], Int(d.x), Int(d.y), Int(d.w), Int(d.h), value=d.score)
    var boxes = 0
    var splats = 0
    for i in range(table.rows()):
        if table.kind[i] == "box":
            boxes += 1
        else:
            splats += 1
    print(table.csv())
    assert_true(boxes >= 3, "the three pallets on frame 420")
    assert_true(splats >= 1, "the tear on frame 420")

    # zero copy: the same frame in a MAX DeviceBuffer, its CUDA pointer wrapped by torch
    var ctx = DeviceContext()
    var dev = ctx.enqueue_create_buffer[DType.uint32](w * h)
    ctx.enqueue_copy(dst_buf=dev, src_ptr=px.unsafe_ptr())
    ctx.synchronize()
    var on_dev = det.detect_on_device(Int(dev.unsafe_ptr()), w, h, prompts, 0.15)
    print("device path (MAX buffer -> torch, no copy): wrap", det.handoff_ms(), "ms, model", det.model_ms(), "ms,", len(on_dev), "boxes")
    assert_equal(len(on_dev), len(found), "same boxes from the GPU buffer")
    for i in range(len(found)):
        assert_true(iou(found[i], on_dev[i]) > 0.99, "same box")

    # SAM 2.1: one box -> a mask, then followed for 30 frames
    var sam = VisionModel("facebook/sam2.1-hiera-tiny", SEGMENT)
    var first = Detection(0, 0, 0, 0, 0, 0, 0)
    for d in found:
        if d.label == 0 and d.score > first.score:
            first = d
    var m = sam.segment(addr, w, h, first)
    print("sam mask: box", m.x, m.y, m.w, m.h, "area", m.area, "for OWLv2 box", Int(first.x), Int(first.y), Int(first.w), Int(first.h))
    assert_true(m.area > Int(first.w * first.h * 0.6), "the mask fills most of the box")
    sam.track_start(w, h)
    var ids = List[Int]()
    ids.append(7)
    var seed = List[Detection]()
    seed.append(first)
    sam.track_add(0, ids, seed)
    var x0 = -1
    var x_last = -1
    var track_ms = List[Float64]()
    v.seek_frame(420)
    for k in range(30):
        _ = v.next_into(px)
        var r = sam.track_step(addr, w, h)
        if k > 0:
            track_ms.append(sam.model_ms())
        if k == 0:
            x0 = r[0].x
        if r[0].area > 0:
            x_last = r[0].x
    sort(track_ms)
    print("sam track: 30 frames, x", x0, "->", x_last, "; median", track_ms[len(track_ms) // 2], "ms per frame")
    assert_true(x_last > x0 + 100, "the tracked box moves with the belt")

    # a whole stretch through scan(): keyframes every 5 frames, 8 per batch, interpolated between
    var v2 = VideoSource(path)
    v2.seek_frame(400)
    var a = ModelAnalyzer(det^, prompts, kinds, threshold=0.15, stride=5, batch=8)
    var ranges = List[ColourRange]()
    ranges.append(ColourRange(0, 359, 0, 255, 0, 255))
    var t2 = Int(now_ns())
    var rows = scan(v2, a, ranges, 8, True, 120)
    var secs = ms_since(t2) / 1000
    print("scan: 120 frames,", a.model_frames, "model frames in", a.model_seconds, "s;", rows.rows(), "rows in", secs, "s (",
          Float64(120) / secs, "frames per s)")
    assert_true(rows.rows() > 200, "rows on most frames")
    var splat_frames = 0
    var tracks = 0
    for i in range(rows.rows()):
        if rows.kind[i] == "splat":
            splat_frames += 1
        tracks = max(tracks, rows.track[i] + 1)
    print("scan rows: splat on", splat_frames, "frame-rows;", tracks, "tracks")
    assert_true(splat_frames > 20, "the tear is found across the stretch")
    print("visionmodel: ok  hand-off", handoff, "ms  model", model, "ms  call", calls[5], "ms")
