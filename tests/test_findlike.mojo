# "Find more like this" (goal 39 M12): ONE tapped example -> every frame with something like it, through the framework's
# find_like (OWLv2 image-guided detection in ModelAnalyzer, scan()), with no words and no colour ranges.
#   CUDA_VISIBLE_DEVICES=1 G39_MEDIA=build/g39/media G39_OUT=build/g39 pixi run -e models mojo run -I . tests/test_findlike.mojo
# Writes into $G39_OUT: findlike_damaged.csv (frame, matches, score: one row per warehouse frame with a match) and
# findlike_drone_a.csv (lat, lon, rows: the places of flight A's matches), m12-warehouse.png and m12-drone.png (annotated).
# Prints "scan s: X" (the whole warehouse: the example, decode, model, rows) and "findlike: ok". scripts/check.py m12
# scores the files against truth.json.
#
# What this test may know (D-965): the tap, and nothing else. A person (or an agent) taps one example; here each tap is a
# FIXED frame and box written into this file (no file is read to find it at run time):
#   warehouse: frame 230, box (652, 366, 60, 44): from the generator's scene model (scripts/media_data.py: pallet 2's
#              position on the belt at that frame and where its tear is drawn on it), see main();
#   drone A:   frame 341, box (699, 343, 28, 28): from truth.json's P03 mark (severity 3) projected once, offline,
#              through the telemetry and the camera model onto the frame where it is nearest the centre, see main().
# This test never opens truth.json. The threshold, the zoom and the negatives are the framework's own rule.
from std.testing import assert_equal, assert_true
from std.os import getenv
from std.python import Python, PythonObject
from mojoui.video import VideoSource
from mojoui.videotable import VideoTable
from mojoui.visionmodel import VisionModel, Example, find_like, frames_with, LikeResult, DETECT
from mojoui.timeseries import TimeSeries
from mojoui.geo import NadirCamera, pose_at, georeference, places, metres
from mojoui.vision_presets import drone_camera_gsd_per_m_alt
from mojoui.clock import now_ns

comptime OWL = "google/owlv2-base-patch16-ensemble"


def read_series(path: String) raises -> TimeSeries:
    """A numeric CSV whose first column is time, as a TimeSeries (as tests/test_drone.mojo)."""
    var lines = open(path, "r").read().split("\n")
    var head = lines[0].split(",")
    var cols = List[List[Float64]]()
    for _ in range(len(head)):
        cols.append(List[Float64]())
    for i in range(1, len(lines)):
        if lines[i].byte_length() == 0:
            continue
        var cells = lines[i].split(",")
        for c in range(len(head)):
            cols[c].append(Float64(String(cells[c])))
    var ts = TimeSeries(cols[0].copy())
    for c in range(1, len(head)):
        ts.add(String(head[c]), cols[c].copy())
    return ts^


def save_annotated(mut video: VideoSource, frame: Int, table: VideoTable, kind: String, tap: Example, title: String,
                   path: String) raises:
    """Frame `frame` with every `kind` row on it (orange, with its logit) and, when the tap is on this frame, the tap
    (white). PIL through Python: a test picture, not a framework feature."""
    var px = video.read(frame)
    var np = Python.import_module("numpy")
    var ctypes = Python.import_module("ctypes")
    var image = Python.import_module("PIL.Image")
    var draw_mod = Python.import_module("PIL.ImageDraw")
    var n = video.width * video.height * 4
    var buf = ctypes.c_uint8.__mul__(n).from_address(Int(px.unsafe_ptr()))
    var arr = np.frombuffer(buf, dtype=np.uint8).reshape(video.height, video.width, 4).copy()
    var img = image.fromarray(arr).convert("RGB")
    var d = draw_mod.Draw(img)
    var hits = 0
    for i in range(table.rows()):
        if table.frame[i] != frame or table.kind[i] != kind:
            continue
        hits += 1
        var box = Python.list()
        box.append(table.x[i] - 3)
        box.append(table.y[i] - 3)
        box.append(table.x[i] + table.w[i] + 3)
        box.append(table.y[i] + table.h[i] + 3)
        d.rectangle(box, outline=Python.tuple(255, 150, 0), width=3)
        d.text(Python.tuple(table.x[i], table.y[i] - 16), "like " + String(Float64(Int(table.value[i] * 10)) / 10.0),
               fill=Python.tuple(255, 150, 0))
    if tap.frame == frame:
        var t = Python.list()
        t.append(Int(tap.x))
        t.append(Int(tap.y))
        t.append(Int(tap.x + tap.w))
        t.append(Int(tap.y + tap.h))
        d.rectangle(t, outline=Python.tuple(255, 255, 255), width=2)
    d.rectangle(Python.list(0, 0, 900, 28), fill=Python.tuple(20, 22, 30))
    d.text(Python.tuple(10, 8), title + " | frame " + String(frame) + ": " + String(hits) + " matches",
           fill=Python.tuple(240, 240, 240))
    img.save(path)
    _ = px^


def main() raises:
    var media = getenv("G39_MEDIA", "build/g39/media")
    var out = getenv("G39_OUT", "build/g39")

    # ---------- the warehouse: one tapped tear -> every frame with a tear ----------
    var t0 = Int(now_ns())
    var det = VisionModel(OWL, DETECT)
    var video = VideoSource(media + "/warehouse.mp4")
    var warm = video.read(0)  # the first call pays CUDA's start-up (kernels, cuDNN); a loaded app has paid it already
    _ = det.detect(UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=Int(warm.unsafe_ptr())), video.width,
                   video.height, ["a box"], 0.5)
    print("owlv2 load + warm-up:", Float64(Int(now_ns()) - t0) / 1e9, "s")
    # The tap: the tear on the first damaged pallet (PLAN "..D.H.D..", pallet 2, on the belt from t0 = 0.4 + 2 * 2 s)
    # on frame 230, when it is alone in view. Scene model (scripts/media_data.py): the pallet's left edge is at
    # x = -pw + 220 * (230 / 30 - 4.4) ≈ 719 - pw, the tear's centre pw - (36..40) px right of it and rx 31..35, ry 22..26
    # around y = top + ph - (34..38): the box below (x 652..712, y 366..410).
    var tap = Example(230, 652, 366, 60, 44)
    var taps = List[Example]()
    taps.append(tap)
    var wh = find_like(video, det^, taps, "like", stride=5, batch=8)
    var frames = frames_with(wh.table, "like")
    print("warehouse:", wh.table.frames, "frames,", wh.model_frames, "model frames in", wh.model_seconds, "s;",
          wh.table.rows(), "rows on", len(frames), "frames; threshold", wh.threshold, "(self-match", wh.self_match,
          "), tiles", wh.tiles, ",", wh.negatives, "negatives")
    assert_equal(wh.table.frames, 1140, "the whole video")
    var seen = Dict[String, Bool]()  # one row per track per frame: linking never gives a track two boxes on a keyframe
    for i in range(wh.table.rows()):
        var key = String(wh.table.frame[i]) + "/" + String(wh.table.track[i])
        assert_true(key not in seen, "a duplicate row: frame/track " + key)
        seen[key] = True
    var csv = String("frame,matches,score\n")
    var count = List[Int](length=wh.table.frames + 1, fill=0)
    var best = List[Float64](length=wh.table.frames + 1, fill=-1e9)
    for i in range(wh.table.rows()):
        count[wh.table.frame[i]] += 1
        best[wh.table.frame[i]] = max(best[wh.table.frame[i]], wh.table.value[i])
    for f in frames:
        csv += String(f) + "," + String(count[f]) + "," + String(best[f]) + "\n"
    with open(out + "/findlike_damaged.csv", "w") as fh:
        fh.write(csv)
    var stretches = wh.table.intervals("like")
    for s in stretches:
        print("  stretch", s[0], "-", s[1])
    assert_true(len(frames) > 400, "matches on many frames")
    assert_true(len(stretches) >= 3, "the damaged pallets come by in stretches")
    save_annotated(video, 800, wh.table, "like", tap, "find more like this: one tapped tear (frame 230)",
                   out + "/m12-warehouse.png")
    print("scan s:", wh.seconds)

    # intervals() on a scan that did not start at frame 0 (the bug the spike found): frame numbers are the video's
    var late = VideoTable()
    late.first = 400
    late.frames = 10
    late.add(403, "x", 0, 0, 1, 1)
    late.add(404, "x", 0, 0, 1, 1)
    var iv = late.intervals("x")
    assert_equal(len(iv), 1, "one stretch from a scan that starts at 400")
    assert_equal(iv[0][0], 403)
    assert_equal(iv[0][1], 405)

    # ---------- the drone, flight A: one tapped burn mark -> places on the map ----------
    var ts = read_series(media + "/telemetry_a.csv")
    var dv = VideoSource(media + "/drone_a.mp4")
    var cam = NadirCamera(dv.width, dv.height, drone_camera_gsd_per_m_alt(), ts.value("lat", 0))
    # The tap: a fixed frame and box, written here (D-965). Where they came from, once, offline: truth.json's most
    # severe mark on flight A (P03, severity 3) projected through the telemetry and the camera model onto every frame;
    # frame 341 is where it is nearest the picture's centre (pixel ≈ 713, 357); the box is the scorch's size in the scene
    # model (radius 0.22 + 0.17 * 3 = 0.73 m ≈ 12 px at 6 cm/px) plus 2 px, rounded to whole pixels: (699, 343, 28, 28).
    var dtap = Example(341, 699, 343, 28, 28)
    var tap_frame = dtap.frame
    var tap_ground = cam.to_ground(pose_at(ts, Float64(tap_frame) / dv.fps), dtap.x + dtap.w / 2, dtap.y + dtap.h / 2)
    var mlat = tap_ground[0]
    var mlon = tap_ground[1]
    print("drone tap: frame", tap_frame, "box", Int(dtap.x), Int(dtap.y), Int(dtap.w), Int(dtap.h))
    var det2 = VisionModel(OWL, DETECT)
    var dtaps = List[Example]()
    dtaps.append(dtap)
    var dr = find_like(dv, det2^, dtaps, "like", stride=5, batch=8)
    georeference(dr.table, ts, cam)
    dr.table.write_csv(out + "/findlike_drone_a_rows.csv")  # every georeferenced row, for looking into
    # places: a mark is one point on the ground; its rows (1 s of video or more) fall within 1.5 m of each other
    var spots = places(dr.table, "like", 1.5, 30)
    print("drone:", dr.table.frames, "frames,", dr.model_frames, "model frames in", dr.model_seconds, "s;", dr.table.rows(),
          "rows,", len(spots), "places; threshold", dr.threshold, "(self-match", dr.self_match, "), tiles", dr.tiles)
    var dcsv = String("lat,lon,rows\n")
    for p in spots:
        dcsv += String(p.lat) + "," + String(p.lon) + "," + String(p.rows) + "\n"
        print("  place", p.lat, p.lon, "rows", p.rows)
    with open(out + "/findlike_drone_a.csv", "w") as fh:
        fh.write(dcsv)
    assert_true(len(spots) >= 1, "places found")
    # the picture: another mark found from that one tap (the place farthest from it, on the frame it is most central)
    var far = 0
    for i in range(len(spots)):
        if metres(spots[i].lat, spots[i].lon, mlat, mlon) > metres(spots[far].lat, spots[far].lon, mlat, mlon):
            far = i
    var show = 0
    var show_d = 1e18
    for f in range(0, dv.frames, 5):
        var p = cam.to_pixel(pose_at(ts, Float64(f) / dv.fps), spots[far].lat, spots[far].lon)
        var d = (p[0] - 640) ** 2 + (p[1] - 360) ** 2
        if d < show_d:
            show_d = d
            show = f
    save_annotated(dv, show, dr.table, "like", dtap, "find more like this: one tapped burn mark (frame " + String(tap_frame)
                   + "), another match " + String(Int(metres(spots[far].lat, spots[far].lon, mlat, mlon))) + " m away",
                   out + "/m12-drone.png")
    print("findlike: ok  scan", wh.seconds, "s;", len(frames), "frames;", len(spots), "drone places")
