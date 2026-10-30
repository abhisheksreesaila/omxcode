# mojoui.mediatimeline (goal 39 M11): the editor's model, timeline geometry, thumbnails, lanes and export.
#   G39_MEDIA=build/g39/media G39_OUT=build/g39 pixi run mojo run -I . tests/test_mediatimeline.mojo
# Prints "timeline: ok" (clips after split / trim / delete / undo / cut-by-sentence and the sequence ↔ source mapping;
# thumbnail count and positions at several zooms; x ↔ t at several zooms; marker lanes from rows; real thumbnails equal a
# CPU scale of VideoSource's own frames; the editor's tools through update() and its drawing) and "edit: ok" (a split and
# trimmed edit exported through mojoui.videoexport has the expected length ±1 frame, read back by ffprobe and VideoSource,
# and its frames after a cut are the source's frames after the cut).
from std.testing import assert_equal, assert_true, assert_false
from std.os import getenv
from std.python import Python
from mojoui.mediatimeline import (Clip, Project, TimelineScale, Tile, tiles, ruler_step, Lane, markers_from_rows, markers_from_table,
                                  objects_from_table, value_lane, clips_from_markers, thumb_interval, thumb_count, decode_thumbnails,
                                  MediaTimeline, ReelSpec, write_reel, clock_tenths, LANE_MARKERS, SHAPE_DOTS, M_SPLIT, M_TRIM_START,
                                  M_TRIM_END, M_DELETE, M_UNDO, M_CUT, M_WHAT, M_TIMELINE, M_PLAY, M_PAUSE, M_FRAME, M_ZOOM_IN, C_TIMELINE, C_PICTURE)
from mojoui.app import Event
from mojoui.charts import fixed
from mojoui.canvas import Surface
from mojoui.clock import now_ns
from mojoui.imageops import ImageOps, Frame
from mojoui.text import Font
from mojoui.theme import Palette
from mojoui.timeseries import TimeSeries
from mojoui.video import VideoSource
from mojoui.videotable import VideoTable
from mojoui.view import PRESS, PAN, RELEASE, SET_TO


def near(a: Float64, b: Float64, eps: Float64 = 1e-9) raises:
    assert_true(abs(a - b) <= eps, String(a) + " is not " + String(b))


def clips_are(p: Project, want: List[Clip]) raises:
    assert_equal(len(p.clips), len(want), "clip count")
    for i in range(len(want)):
        assert_true(p.clips[i] == want[i], "clip " + String(i) + " is " + String(p.clips[i]) + ", not " + String(want[i]))


def model() raises:
    var p = Project(30.0, 870)  # 29 s at 30 fps
    assert_equal(p.length(), 870)
    assert_false(p.split(0))  # at a clip's edge: nothing
    assert_true(p.split(300))
    clips_are(p, [Clip(0, 300), Clip(300, 870)])
    assert_equal(p.selected, 1)
    assert_equal(p.source_frame(299), 299)
    assert_equal(p.source_frame(300), 300)
    # trim the second clip's start to sequence frame 330: source 330
    assert_true(p.trim_start(1, 330))
    clips_are(p, [Clip(0, 300), Clip(330, 870)])
    assert_equal(p.length(), 840)
    assert_equal(p.source_frame(300), 330)  # the cut is skipped
    # trim the first clip's end to sequence frame 150
    assert_true(p.trim_end(0, 150))
    clips_are(p, [Clip(0, 150), Clip(330, 870)])
    assert_equal(p.source_frame(149), 149)
    assert_equal(p.source_frame(150), 330)
    assert_equal(p.clip_at(150), 1)
    assert_equal(p.start_of(1), 150)
    near(p.duration(), 690.0 / 30.0)
    # a trim at a clip's first frame changes nothing
    assert_false(p.trim_end(1, 150))
    assert_false(p.trim_start(1, 150))
    # source runs in the sequence: 100–400 shows as 100–150 then 330–400 (sequence 150–220)
    var sp = p.spans(100, 400)
    assert_equal(len(sp), 2)
    assert_equal(sp[0][0], 100)
    assert_equal(sp[0][1], 150)
    assert_equal(sp[1][0], 150)
    assert_equal(sp[1][1], 220)
    assert_equal(len(p.spans(200, 300)), 0)  # cut out
    # segments for the exporter
    var seg = p.segments()
    near(seg[1][0], 11.0)
    near(seg[1][1], 29.0)
    # handles: clamped to the source and one frame at least
    assert_true(p.set_in(1, -50) == False or p.clips[1].first == 0)
    p.clips[1] = Clip(330, 870)
    assert_false(p.set_out(1, 5000))  # (already at the source's end)
    assert_true(p.set_out(1, 600))
    assert_equal(p.clips[1].end, 600)
    assert_true(p.set_in(1, 400))
    assert_true(p.set_in(1, 9999))
    assert_equal(p.clips[1].first, 599)  # one frame left
    p.clips[1] = Clip(330, 870)
    # delete and undo, back to the start
    p.selected = 0
    assert_true(p.delete(0))
    clips_are(p, [Clip(330, 870)])
    assert_false(p.delete(0))  # the last clip stays
    assert_true(p.undo())
    clips_are(p, [Clip(0, 150), Clip(330, 870)])
    assert_true(p.undo())
    assert_true(p.undo())
    assert_true(p.undo())
    clips_are(p, [Clip(0, 870)])
    assert_false(p.undo())
    print("clips: split, trim, handles, delete, undo, spans")


def geometry() raises:
    var p = Project(30.0, 870)
    var sc = TimelineScale()
    sc.fit(1000.0, p.duration())
    near(sc.x_of(0.0), 16.0)
    near(sc.x_of(29.0), 984.0, 1e-6)
    # x ↔ t at several zooms, and a zoom keeps the time under the pointer
    for z in range(4):
        var factor = [1.0, 2.5, 8.0, 0.25][z]
        var at_x = 300.0 + 100.0 * Float64(z)
        var before = sc.t_of(at_x)
        sc.zoom(factor, at_x, 1000.0, p.duration(), p.fps)
        for i in range(7):
            var t = Float64(i) * 4.1
            near(sc.t_of(sc.x_of(t)), t, 1e-9)
        if sc.pps > sc.fit_pps(1000.0, p.duration()) * 1.0001 and sc.scroll > 0:
            near(sc.t_of(at_x), before, 1e-6)
    sc.zoom(1e6, 500.0, 1000.0, p.duration(), p.fps)
    near(sc.pps, 14.0 * 30.0)  # the most: a frame is 14 points
    sc.zoom(1e-6, 500.0, 1000.0, p.duration(), p.fps)
    near(sc.pps, sc.fit_pps(1000.0, p.duration()))
    near(sc.scroll, 0.0)
    # thumbnails along the strip: whole video at fit, 64-pt tall 16:9 tiles
    var tw = 64.0 * 16.0 / 9.0
    var ts = tiles(p, sc, 1000.0, tw)
    assert_equal(len(ts), 9)  # 968 points of video / 113.8 per tile → 9 (the last cut short)
    near(ts[0].x, 16.0)
    near(ts[0].source_t, 0.0)
    near(ts[1].x, 16.0 + tw, 1e-9)
    near(ts[1].source_t, tw / sc.pps, 1e-9)
    near(ts[8].x + ts[8].w, 984.0, 1e-6)
    # zoomed 4× with the playhead at 10 s: only tiles in view, each at its own source time
    sc.zoom(4.0, sc.x_of(10.0), 1000.0, p.duration(), p.fps)
    var zs = tiles(p, sc, 1000.0, tw)
    assert_true(len(zs) >= 9 and len(zs) <= 10, String(len(zs)) + " tiles zoomed")
    for t in zs:
        assert_true(t.x < 1000.0 and t.x + t.w > 0)
        near(sc.x_of(t.source_t), t.x, 1e-6)  # one clip, uncut: source time = sequence time
    # after a split and a trim each clip starts its own run of tiles at its own source time
    sc.fit(1000.0, p.duration())
    _ = p.split(300)
    _ = p.trim_start(1, 330)
    sc.fit(1000.0, p.duration())
    var cs = tiles(p, sc, 1000.0, tw)
    var first_of_two = -1
    for i in range(len(cs)):
        if cs[i].clip == 1 and first_of_two < 0:
            first_of_two = i
    assert_true(first_of_two > 0)
    near(cs[first_of_two].x, sc.x_of(10.0), 1e-6)
    near(cs[first_of_two].source_t, 11.0, 1e-9)
    near(cs[first_of_two - 1].x + cs[first_of_two - 1].w, sc.x_of(10.0), 1e-6)
    near(ruler_step(10.0), 10.0)
    near(ruler_step(100.0), 1.0)
    assert_equal(clock_tenths(12.46), "0:12.4")
    assert_equal(clock_tenths(3723.5), "1:02:03.5")
    print("geometry: x↔t at 5 zooms, " + String(len(ts)) + " tiles at fit, " + String(len(zs)) + " zoomed")


def lanes() raises:
    # rows: kind, frame, flag; merged with a 3-frame gap
    var frames: List[Int] = [10, 11, 12, 14, 40, 41, 100, 50, 51]
    var kinds: List[String] = ["face", "face", "face", "face", "face", "face", "face", "pallet", "pallet"]
    var flags: List[Bool] = [False, False, False, False, True, False, False, True, True]
    var faces = markers_from_rows(frames, kinds, flags, "face", 10.0, "Faces", shape=SHAPE_DOTS)
    assert_equal(faces.markers(), 3)
    near(faces.starts[0], 1.0)
    near(faces.ends[0], 1.5)
    near(faces.starts[1], 4.0)
    near(faces.ends[1], 4.2)
    assert_true(faces.flags[1] and not faces.flags[0])
    near(faces.starts[2], 10.0)
    var flagged = markers_from_rows(frames, kinds, flags, "face", 10.0, "Faces", flagged_only=True)
    assert_equal(flagged.markers(), 1)
    # objects from a table: one pill per track, labelled by its code, flagged if any row is damaged; overlaps stack
    var t = VideoTable()
    t.fps = 30.0
    t.frames = 300
    for f in range(30, 90):
        t.add(f, "pallet", 10, 10, 20, 20, 2417, f > 60, 1)
    for f in range(60, 150):
        t.add(f, "pallet", 50, 10, 20, 20, 1953, False, 2)
    for f in range(200, 240):
        t.add(f, "pallet", 50, 10, 20, 20, 3933, True, 3)
    for f in range(0, 300, 2):
        t.add(f, "face", 100, 100, 30, 30)
    var pallets = objects_from_table(t, "pallet", "Pallets", "damaged")
    assert_equal(pallets.markers(), 3)
    assert_equal(pallets.labels[0], "2417")
    near(pallets.starts[0], 1.0)
    near(pallets.ends[0], 3.0)
    assert_true(pallets.flags[0] and not pallets.flags[1] and pallets.flags[2])
    assert_equal(pallets.row[0], 0)
    assert_equal(pallets.row[1], 1)  # overlaps 2417: the next row
    assert_equal(pallets.row[2], 0)
    assert_equal(pallets.rows, 2)
    assert_equal(pallets.flagged(), 2)
    var face_lane = markers_from_table(t, "face", "Faces", shape=SHAPE_DOTS)
    assert_equal(face_lane.markers(), 1)  # every other frame: one run
    # Cut it: the flagged pallets (±0.5 s), merged, inside the source
    var cl = clips_from_markers(pallets, True, 30.0, 300, 0.5)
    assert_equal(len(cl), 2)
    assert_true(cl[0] == Clip(15, 105), String(cl[0]))
    assert_true(cl[1] == Clip(185, 255), String(cl[1]))
    var all_cl = clips_from_markers(pallets, False, 30.0, 300, 0.0)
    assert_equal(len(all_cl), 2)
    assert_true(all_cl[0] == Clip(30, 150), String(all_cl[0]))  # 2417 and 1953 overlap: one clip
    # markers through an edit: pallet 3933 (200–240) after cutting 100–220 out shows as its last 20 frames
    var p = Project(30.0, 300)
    p.clips = [Clip(0, 100), Clip(220, 300)]
    var s = p.spans(200, 240)
    assert_equal(len(s), 1)
    assert_equal(s[0][0], 100)
    assert_equal(s[0][1], 120)
    # a values lane
    var ts = TimeSeries([0.0, 1.0, 2.0])
    ts.add("alt_m", [60.0, 62.0, 61.0])
    var alt = value_lane("Altitude", ts, "alt_m", "m")
    near(alt.value_at(0.5), 61.0)
    near(alt.value_at(5.0), 61.0)
    near(alt.low_high()[1], 62.0)
    print("lanes: dots, flagged pills stacked, cut-it clips, values")


def thumbnails(path: String) raises:
    var v = VideoSource(path)
    var iv = thumb_interval(v.duration)
    near(iv, 0.5)
    var n = thumb_count(v.duration, iv)
    assert_equal(n, Int(v.duration / 0.5) + 1)
    var t0 = now_ns()
    var got = decode_thumbnails(path, iv, 3, 6, 64)
    var ms = Float64(now_ns() - t0) / 1e6
    assert_equal(len(got), 6)
    assert_equal(got[0].height, 64)
    assert_equal(got[0].width, 64 * v.width // v.height)
    # thumbnail 5 (index 3 + 2) is the source picture at 2.5 s, scaled: equal to a CPU scale of VideoSource's own frame
    var src = Frame(v.width, v.height, v.read(Int(5 * iv * v.fps + 0.5)))
    var cpu = ImageOps(False)
    var want = cpu.crop(src, 0, 0, v.width, v.height, got[2].width, 64, bilinear=True)
    for i in range(len(want.pixels)):
        assert_equal(got[2].pixels[i], want.pixels[i])
    print("thumbnails: " + String(n) + " every " + String(iv) + " s; 6 decoded in " + String(Int(ms)) + " ms, equal to the CPU's")


def editor(path: String) raises:
    var ed = MediaTimeline(path, 300, 300)
    var t = VideoTable()
    t.fps = ed.project.fps
    t.frames = ed.project.source_frames
    for f in range(60, 120):
        t.add(f, "pallet", 100, 100, 80, 80, 2417, f > 90, 1)
    for f in range(400, 460):
        t.add(f, "pallet", 300, 100, 80, 80, 3933, True, 2)
    for f in range(0, 200, 3):
        t.add(f, "face", 600, 50, 40, 40)
    ed.use_rows(t^, blur_kind="face", object_kind="pallet", object_label="Pallets", flag_word="damaged")
    assert_equal(len(ed.lanes), 2)
    var opts = ed.what_options()
    assert_equal(len(opts), 3)
    assert_equal(opts[0], "damaged pallets")
    assert_equal(opts[1], "all pallets")
    assert_equal(opts[2], "faces")
    assert_equal(ed.sentence_text(), "Reel of damaged pallets, faces blurred")
    # split at 4 s through update(), then trim the end of the left clip at 2 s
    ed.seek(4.0)
    _ = ed.update(Event(300 + M_SPLIT, "", 0))
    assert_equal(len(ed.project.clips), 2)
    ed.seek(2.0)
    _ = ed.update(Event(300 + M_TRIM_END, "", 0))
    assert_true(ed.project.clips[0] == Clip(0, 60), String(ed.project.clips[0]))
    _ = ed.update(Event(300 + M_UNDO, "", 0))
    _ = ed.update(Event(300 + M_UNDO, "", 0))
    assert_equal(len(ed.project.clips), 1)
    # Cut it: the damaged pallets ±0.5 s → two clips
    _ = ed.update(Event(300 + M_CUT, "", 0))
    assert_equal(len(ed.project.clips), 2)
    assert_true(ed.project.clips[0] == Clip(45, 135), String(ed.project.clips[0]))
    assert_true(ed.project.clips[1] == Clip(385, 475), String(ed.project.clips[1]))
    # the agent's seek, and a handle drag on the timeline (draw first, so it knows its width)
    _ = ed.update(Event(300 + M_TIMELINE, "2.5", SET_TO))
    near(ed.t(), 2.5)
    var w = 1200
    var h = Int(ed.timeline_height())
    var px = List[UInt32](length=w * h, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), w, h, 1.0)
    var font = Font()
    var pal = Palette.plain()
    ed.thumbs.put(0, decode_thumbnails(path, ed.thumbs.interval, 0, ed.thumbs.count(), ed.thumbs.height))
    assert_true(ed.thumbs.complete())
    var w2 = 2880  # a 1440-point window on a 2x screen, every thumbnail in
    var h2 = h * 2
    var px2 = List[UInt32](length=w2 * h2, fill=0)
    var s2 = Surface(Int(px2.unsafe_ptr()), w2, h2, 2.0)
    var t0 = now_ns()
    for _ in range(10):
        ed.draw(300 + C_TIMELINE, s2, pal, font)
    var draw_ms = Float64(now_ns() - t0) / 1e7
    _ = len(px2)
    ed.draw(300 + C_TIMELINE, s, pal, font)
    ed.project.selected = 1
    var right = ed._clip_x(1)[1]
    var y = ed.strip_top() + 30
    _ = ed.update(Event(300 + M_TIMELINE, "", PRESS, right - 3, y))
    _ = ed.update(Event(300 + M_TIMELINE, "", PAN, right - 3 - ed.scale.pps * 1.0, y))  # one second shorter
    _ = ed.update(Event(300 + M_TIMELINE, "", RELEASE, right - 3 - ed.scale.pps * 1.0, y))
    assert_true(abs(ed.project.clips[1].end - (475 - 30)) <= 1, "handle drag: " + String(ed.project.clips[1]))
    _ = ed.update(Event(300 + M_UNDO, "", 0))
    assert_true(ed.project.clips[1] == Clip(385, 475))
    # play the edit: it skips what was cut (frame 89 of the sequence is source 134, frame 90 is source 385)
    ed.seek(2.9)
    _ = ed.update(Event(300 + M_PLAY, "", 0))
    for _ in range(12):
        _ = ed.update(Event(300 + M_FRAME, "", 16_667))
    _ = ed.update(Event(300 + M_PAUSE, "", 0))
    assert_true(ed.seq.frame >= 90, "played to " + String(ed.seq.frame))
    assert_equal(ed.project.source_frame(ed.seq.frame), 385 + ed.seq.frame - 90)
    # the viewer with the preview's blur on (GPU)
    var vw = 640
    var vh = 360
    var vpx = List[UInt32](length=vw * vh, fill=0)
    var vs = Surface(Int(vpx.unsafe_ptr()), vw, vh, 1.0)
    ed.draw(300 + C_PICTURE, vs, pal, font)
    assert_true(ed.preview.width == ed.player.src.width, "preview made")
    _ = len(px)  # (the surfaces' pixels live until here)
    _ = len(vpx)
    print("editor: tools through update(), cut it, handle drag, playback across a cut, timeline draw at 2880 px " + fixed(draw_ms, 2) + " ms")
    assert_true(draw_ms < 16.0, "timeline draw " + String(draw_ms) + " ms")


def export_test(path: String, folder: String) raises:
    var ed = MediaTimeline(path, 300, 300)
    var fps = ed.project.fps
    # split at 3 s, cut 3–8 s out by trimming the second clip's start, trim the end at 20 s of the edit: 3 + 12 = 15 s
    ed.seek(3.0)
    assert_true(ed.split())
    ed.seek(8.0)
    assert_true(ed.trim_start())  # (the second clip now starts at source 8 s, at sequence 3 s)
    ed.seek(15.0)
    assert_true(ed.trim_end())
    var want = ed.project.length()
    assert_equal(want, Int(15 * fps + 0.5))
    var file = folder + "/m11-edit.mp4"
    var n = ed.export_now(file)
    assert_equal(n, want)
    var back = VideoSource(file)
    assert_true(abs(back.frames - want) <= 1, "read back " + String(back.frames) + " frames, want " + String(want))
    var json = Python.import_module("json")
    var sp = Python.import_module("subprocess")
    var r = sp.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", file], capture_output=True, text=True)
    var dur = Float64(String(json.loads(r.stdout)["format"]["duration"]))
    assert_true(abs(dur - Float64(want) / fps) <= 1.0 / fps + 1e-6, "ffprobe " + String(dur) + " s, want " + String(Float64(want) / fps))
    # the frame after the cut is the source's frame at 8 s (H.264 is lossy: a small mean difference)
    var src = VideoSource(path)
    var a = back.read(Int(3 * fps) + 5)
    var b = src.read(Int(8 * fps) + 5)
    var c = src.read(Int(3 * fps) + 5)  # what would show had nothing been cut
    var diff_b = 0.0
    var diff_c = 0.0
    for i in range(0, len(a), 7):
        for sh in range(0, 24, 8):
            var va = Int((a[i] >> UInt32(sh)) & 0xFF)
            diff_b += Float64(abs(va - Int((b[i] >> UInt32(sh)) & 0xFF)))
            diff_c += Float64(abs(va - Int((c[i] >> UInt32(sh)) & 0xFF)))
    var m = Float64(len(a) // 7 * 3)
    assert_true(diff_b / m < 6.0 and diff_b < diff_c, "after the cut: mean diff " + String(diff_b / m) + " vs uncut " + String(diff_c / m))
    print("edit: ok (" + String(n) + " frames, " + String(dur) + " s by ffprobe; after the cut the source's 8 s, mean diff " + fixed(diff_b / m, 2) + ")")


def main() raises:
    var media = getenv("G39_MEDIA", "build/g39/media")
    var out = getenv("G39_OUT", "build/g39")
    model()
    geometry()
    lanes()
    thumbnails(media + "/drone_a.mp4")
    editor(media + "/drone_a.mp4")
    print("timeline: ok")
    export_test(media + "/drone_a.mp4", out)
