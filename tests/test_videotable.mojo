# mojoui.videotable on the generated warehouse.mp4 (goal 39 M4): frames become rows.
#   G39_MEDIA=build/g39/media G39_OUT=build/g39 pixi run mojo run -I . tests/test_videotable.mojo
# Writes $G39_OUT/warehouse_regions.csv (scripts/check.py m4 scores it against truth.json, which this test never reads),
# prints "videotable: ok" when its own sanity checks pass and "frames per s: X" (the whole video, decode included).
from std.testing import assert_equal, assert_true
from std.os import getenv
from mojoui.video import VideoSource
from mojoui.videotable import (ColourRange, StripeSpec, ObjectAnalyzer, FaceAnalyzer, RegionsAnalyzer, Both, Cells,
                               CellGpu, measure_cpu, scan, regions, NO_CODE)
from mojoui.vision_presets import warehouse_ranges, warehouse_analyzer, WAREHOUSE_CELL


def main() raises:
    var media = getenv("G39_MEDIA", "build/g39/media")
    var out = getenv("G39_OUT", "build/g39")
    var path = media + "/warehouse.mp4"
    var ranges = warehouse_ranges()

    # the GPU's cell grid equals the CPU's on a frame (and its motion against the frame before)
    var v = VideoSource(path)
    var g = CellGpu(v.width, v.height, WAREHOUSE_CELL, ranges)
    assert_true(g.on_gpu(), "no GPU")
    _ = v.next_into_address(Int(g.frame_ptr(1)))
    _ = v.next_into_address(Int(g.frame_ptr(0)))
    var gc = Cells(v.width, v.height, WAREHOUSE_CELL)
    g.launch(1, True)
    g.collect(gc)
    g.launch(0, False)
    g.collect(gc)
    var cc = Cells(v.width, v.height, WAREHOUSE_CELL)
    measure_cpu(g.frame_ptr(0), g.frame_ptr(1), v.width, v.height, ranges, cc)
    for i in range(len(gc.counts)):
        assert_equal(gc.counts[i], cc.counts[i])
        assert_equal(gc.stats[i], cc.stats[i])
        assert_equal(gc.means[i], cc.means[i])
    assert_true(gc.motion() > 0, "the belt moves between frames")
    print("cells gpu equals cpu: ok", gc.gw, "x", gc.gh, "cells; brightness", gc.brightness(), "motion", gc.motion())
    v.close()

    # the whole video
    var video = VideoSource(path)
    var a = warehouse_analyzer()
    var table = scan(video, a, ranges, WAREHOUSE_CELL)
    table.write_csv(out + "/warehouse_regions.csv")
    var codes = List[Int]()
    var faces = 0
    var damaged = List[Int]()
    var unread = 0
    for i in range(table.rows()):
        if table.kind[i] == "face":
            faces += 1
        elif table.kind[i] == "pallet":
            if table.code[i] == NO_CODE:
                unread += 1
            else:
                var seen = False
                for c in codes:
                    if c == table.code[i]:
                        seen = True
                if not seen:
                    codes.append(table.code[i])
                    if table.damaged[i]:
                        damaged.append(table.code[i])
    print("pallets read:", len(codes), "damaged:", len(damaged), "rows without a code:", unread, "face rows:", faces)
    assert_equal(table.frames, video.frames)
    assert_true(len(codes) >= 10, "pallet codes read")
    assert_true(len(damaged) >= 1 and len(damaged) < len(codes), "some pallets damaged, not all")
    assert_true(faces > table.frames, "faces on most frames")
    var iv = table.intervals("pallet", damaged_only=True)
    assert_true(len(iv) >= 1, "damaged intervals")
    for t in iv:
        print("damaged in view:", t[0], "→", t[1])
    # the file holds every row (csvio.read_table turns it into the sheet's table in an app that links omxcore)
    var text = open(out + "/warehouse_regions.csv", "r").read()
    assert_equal(len(text.split("\n")) - 2, table.rows())
    print("videotable: ok", table.rows(), "rows,", table.frames, "frames")
    print("frames per s:", table.frames_per_second())
