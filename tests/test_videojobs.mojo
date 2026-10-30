# mojoui.videojobs and mojoui.tablecard on the generated warehouse (goal 39 M7): analyze as a background job (progress,
# result), the rows as a table, a table card, SQL over the page's tables (the delivered shipments whose code never shows),
# Export CSV, a reel's frames from a flag column, a lookup that finds its own key, the Player's marks.
#   scripts/mxbuild.sh tests/test_videojobs.mojo -o build/test_videojobs && G39_MEDIA=build/g39/media G39_OUT=build/g39 pixi run build/test_videojobs
# Prints "videojobs: ok".
from std.testing import assert_equal, assert_true
from std.os import getenv
from omxcore import Catalog, JOB_RUNNING, JOB_DONE
from mojoui.videojobs import (analyze_job, analyzer_names, analyzer_rows, detections_table, flag_frames, segments_of, flag_columns,
                              matching_column, lookup, codes_of, marks_of, reel_job)
from mojoui.videotable import VideoTable
from mojoui.videoexport import flagged_captions
from mojoui.tablecard import TableCards, sql_name, query_table
from mojoui.sheet import Sheet, csv_cell
from mojoui.csvio import read_table
from mojoui.player import Player
from mojoui.text import Font
from mojoui.theme import Palette
from themes.liquid import liquid_palette
from mojoui.app import Event
from std.time import sleep


def main() raises:
    var media = getenv("G39_MEDIA", "build/g39/media")
    var out = getenv("G39_OUT", "build/g39")
    var src = media + "/warehouse.mp4"
    var font = Font()
    var pal = liquid_palette()

    # names and CSV cells
    assert_equal(sql_name("warehouse.mp4 · detections"), "detections")
    assert_equal(sql_name("Missing shipments"), "missing_shipments")
    assert_equal(sql_name("2024 sales"), "t2024_sales")
    assert_equal(csv_cell("a,b"), "\"a,b\"")
    assert_equal(csv_cell("say \"hi\""), "\"say \"\"hi\"\"\"")
    assert_equal(csv_cell("plain"), "plain")
    assert_equal(len(analyzer_names()), 2)
    assert_equal(analyzer_rows(0), "detections")

    # analyze as a job: it runs off this thread, its progress counts frames, its answer lands
    var job = analyze_job(src, 0)
    var polls = 0
    var saw_progress = False
    while job.poll() == JOB_RUNNING:
        var p = job.progress()
        if p.total > 0 and 0 < p.done < p.total:
            saw_progress = True
        polls += 1
        sleep(0.02)
    assert_equal(job.poll(), JOB_DONE)
    var a = job.result()
    print("analyze:", a.found.rows(), "rows,", a.found.frames, "frames in", a.milliseconds, "ms;", polls, "polls; progress seen:", saw_progress)
    assert_true(a.found.rows() > 100, "rows found")
    assert_true(a.found.frames >= 600, "every frame scanned")
    var found = a.take_found()
    var table = a.take_table()
    assert_equal(table.rows(), found.rows())
    assert_equal(table.name(0), "frame")
    assert_equal(table.name(4), "damaged")
    var det = Sheet(table^.share(), False)
    assert_equal(det.plain_text(2, 0), found.kind[0])

    # the reel's frames from the flag column equal the VideoTable's own damaged intervals
    var flags = flag_columns(det)
    assert_equal(len(flags), 1)
    var runs = flag_frames(det, flags[0], det.index("frame"))
    var want = found.intervals("pallet", damaged_only=True)
    assert_equal(len(runs), len(want))
    for i in range(len(runs)):
        assert_equal(runs[i][0], want[i][0])
        assert_equal(runs[i][1], want[i][1])
    var segs = segments_of(runs, found.fps)
    print("reel segments:", len(segs), "first", segs[0][0], "→", segs[0][1], "s")

    # shipments beside it: a table card; its key for the codes is found without being told
    var imp = read_table(media + "/shipments.csv")
    var ships = Sheet(imp.table, False)
    var key = matching_column(ships, codes_of(found))
    assert_equal(ships.name(key[0]), "pallet_code")
    assert_true(key[1] >= 10, "codes matched " + String(key[1]))
    var names = lookup(ships, key[0], ships.index("shipment"))
    assert_true(len(names) >= 20, "lookup rows")
    var caps = flagged_captions(found, "pallet", names)
    assert_true(len(caps) >= len(segs), "a caption per segment")
    assert_true(caps[0].text.startswith("S-"), "captions name shipments: " + caps[0].text)

    var tables = TableCards(4100, 230, 4)
    var k = tables.add("shipments", ships^, 0, 0, 600, 300, font, pal)
    assert_equal(tables.find("shipments"), k)
    var cat = Catalog()
    cat.add_frame("detections", det.frame)
    tables.add_to(cat)
    var q = query_table(cat, "SELECT shipment FROM shipments WHERE status = 'delivered' AND pallet_code NOT IN (SELECT code FROM detections WHERE code IS NOT NULL) ORDER BY shipment")
    print("missing:", q.rows(), "shipments")
    assert_true(q.rows() >= 1 and q.rows() < 23, "a few delivered shipments never show")
    var m = tables.add("missing", Sheet(q^.share(), False), 0, 320, 300, 300, font, pal)
    tables.cards[m].note = "a query"
    var view = tables.view(m, 1)
    _ = view
    # Export CSV through the card's own button (message base + slot·4 + 1)
    _ = tables.update(Event(tables.msg(m) + 1, "", 0), font, pal, out)
    assert_equal(tables.exported, out + "/missing.csv")
    var text = open(out + "/missing.csv", "r").read()
    assert_true(text.startswith("shipment\n"), "the header: " + text[byte=:40])
    print("missing.csv:", text.replace("\n", " "))
    var said = tables.describe(tables.canvas(m), 0, 0)
    assert_true(said.startswith("missing ("), "describe: " + said)
    # the same name again answers in the same card
    var q2 = query_table(cat, "SELECT shipment FROM shipments WHERE status = 'delivered'")
    assert_equal(tables.add("missing", Sheet(q2^.share(), False), 900, 900, 10, 10, font, pal), m)
    assert_equal(tables.cards[m].y, 320)
    # closing
    _ = tables.update(Event(tables.msg(k) + 2, "", 0), font, pal, out)
    assert_equal(tables.closed, k)
    assert_equal(len(tables), 1)

    # the Player's marks: boxes on their own frames
    var player = Player(src, 100, 100)
    player.set_marks(marks_of(found, "face"))
    var marked = 0
    for f in range(found.frames):
        if player.marks_on(f) > 0:
            marked += 1
    assert_true(marked > 300, "frames with marks: " + String(marked))
    assert_equal(player.marked, 1)

    # a reel as a job (the first segment only: M5's test makes the whole one)
    var one = List[Tuple[Float64, Float64]]()
    one.append(segs[0])
    var rj = reel_job(src, out + "/videojobs-reel.mp4", found, one, "face", "pallet", caps)
    while rj.poll() == JOB_RUNNING:
        sleep(0.02)
    assert_equal(rj.poll(), JOB_DONE)
    var reel = rj.result()
    print("reel:", reel.frames, "frames,", reel.seconds, "s in", reel.milliseconds, "ms")
    assert_equal(reel.frames, runs[0][1] - runs[0][0])
    print("videojobs: ok")
