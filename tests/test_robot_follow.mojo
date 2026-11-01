# Goal 47 (review round 1): what a fleet row's links do, tested on small tables. mojoui.links' follow reaching a card once
# per column (D-4714), mojoui.logindex (a long log's key index), trackcard.series_where / series_where_indexed (exact, or a
# refusal, never a guess), last_off_mark / row_words (a pack's per-row moment), TrackCard.limits / mark, MediaCards.named.
#   scripts/mxbuild.sh tests/test_robot_follow.mojo -o build/test_robot_follow && pixi run build/test_robot_follow [clip.mp4 clip2.mp4 paper.pdf]
# Prints "follow: ok", "index: ok", "slice: ok", "moment: ok", "card: ok", "named: ok", "page: ok" (a third argument: a PDF).
from std.testing import assert_equal, assert_true, assert_raises
from std.sys import argv
from mojoui.links import Links, Link, End, Selection, LINK_KEY
from mojoui.csvio import read_table
from mojoui.sheet import Sheet
from mojoui.logindex import build_key_index
from mojoui.trackcard import series_where, series_where_indexed, last_off_mark, row_words, TrackCards
from mojoui.mediacard import MediaCards
from mojoui.documentcard import DocumentCard, DOC_GESTURE
from mojoui.pdfsource import Box
from mojoui.canvas import Surface
from mojoui.app import Event
from mojoui.view import PAN
from themes.liquid import liquid_dark_palette
from mojoui.pygil import python_start


def sheet_of(path: String, text: String) raises -> Sheet:
    with open(path, "w") as f:
        f.write(text)
    return Sheet(read_table(path).table, False)


def log_text(episodes: List[String], per: Int) -> String:
    """A telemetry-like log: per episode `per` rows (t, a joint pair, gripper, an event column), in the order given."""
    var out = String("episode,t,joint_vel_1,joint_vel_2,gripper,gripper_event\n")
    for e in episodes:
        for i in range(per):
            var ev = String("close") if i == 2 else (String("open") if i == per - 3 else String(""))
            out += e + "," + String(Float64(i) / 15.0) + "," + String(Float64(i) * 0.01) + ",-0.5," + ("0.9" if 2 <= i < per - 3 else "0.0") + "," + ev + "\n"
    return out^


def main() raises:
    # follow: one card reached through two columns reacts once (the first path) and is followed on through both; a cycle
    # ends; nothing comes back to the selection's own card
    var links = Links()
    _ = links.add(Link.key(End("answer", "episode"), End("fleet", "episode")))
    _ = links.add(Link.key(End("answer", "clip"), End("fleet", "clip")))
    _ = links.add(Link.key(End("fleet", "episode"), End("telemetry", "episode")))
    _ = links.add(Link.key(End("fleet", "clip"), End("episode", "file")))
    _ = links.add(Link.key(End("telemetry", "episode"), End("answer", "episode")))  # (a cycle back to the selection)
    var sel = Selection("answer", "answer", 0, "episode", "F1").with_row(["episode", "clip"], ["F1", "clips/F1.mp4"])
    var fs = links.follow(sel)
    var to_fleet = 0
    var tele = False
    var file = False
    for f in fs:
        assert_true(f.card != "answer", "never back to the selection")
        if f.card == "fleet":
            to_fleet += 1
        if f.card == "telemetry" and f.value == "F1":
            tele = True
        if f.card == "episode" and f.column == "file" and f.value == "clips/F1.mp4":
            file = True
    assert_equal(to_fleet, 1)
    assert_true(tele and file, "both paths followed on: the log's key and the clip's file")
    assert_equal(len(fs), 3)
    print("follow: ok")

    # index: a grouped log (5,000 rows) indexes every key to its one run; an interleaved one says it isn't grouped;
    # a number key isn't indexed
    var eps = List[String]()
    for k in range(50):
        eps.append("E" + String(1000 + k))
    var grouped = sheet_of("/tmp/test_robot_follow_g.csv", log_text(eps, 100))
    var ix = build_key_index(grouped, "episode")
    assert_true(ix.grouped and ix.problem == "" and ix.rows == 5000 and len(ix.count) == 50, "grouped index")
    var span = ix.span_of(grouped.code_of(0, "E1007"))
    assert_true(span[0] == 700 and span[1] == 100, "E1007 is rows 700–799")
    assert_equal(ix.span_of(-5)[0], -1)
    var mixed = List[String]()
    for k in range(10):
        mixed.append("A" if k % 2 == 0 else "B")
    var inter = sheet_of("/tmp/test_robot_follow_i.csv", log_text(mixed, 3))
    var ix2 = build_key_index(inter, "episode")
    var a_runs = ix2.span_of(inter.code_of(0, "A"))
    assert_true(not ix2.grouped and a_runs[0] == 0 and a_runs[1] == 15, "interleaved: not grouped, every row counted")
    var ix3 = build_key_index(grouped, "joint_vel_2")
    assert_true(ix3.problem != "", "a number column isn't indexed")
    print("index: ok")

    # slice: the index's slice equals the scan's, row for row; an interleaved log through an index raises (never a part);
    # the scan finds every run of an interleaved key; marks come from the event column
    var a = series_where(grouped, "episode", "E1007")
    var b = series_where_indexed(grouped, "episode", "E1007", ix)
    assert_equal(a[0].rows(), 100)
    assert_equal(b[0].rows(), 100)
    for i in range(100):
        assert_equal(a[0].times[i], b[0].times[i])
        assert_equal(a[0].column("gripper")[i], b[0].column("gripper")[i])
    assert_equal(len(b[1]), 2)
    assert_true(b[1][0].on and not b[1][1].on, "close, then open")
    with assert_raises():
        _ = series_where_indexed(inter, "episode", "A", ix2)
    assert_equal(series_where(inter, "episode", "A")[0].rows(), 15)
    var nums = sheet_of("/tmp/test_robot_follow_n.csv", "id,t,v\n1,0,5\n2,0,6\n1,0.1,7\n")
    assert_equal(series_where(nums, "id", "1")[0].rows(), 2)
    print("slice: ok")

    # moment: the last "off" event of a recording and its row's numbers, read without building its series
    var m = last_off_mark(grouped, "episode", "E1007", ix)
    assert_true(abs(m[0] - 97.0 / 15.0) < 1e-6 and m[1] == 797 and abs(m[2] - 99.0 / 15.0) < 1e-6, "open at row 797")
    var words = row_words(grouped, 797)
    assert_true(words.find("joint_vel_1 0.97") >= 0 and words.find("gripper 0") >= 0, words)
    print("moment: ok")

    # card: a multichannel log shows lanes; a spec table's names set its lanes' limits; marks land on the lanes
    var tracks = TrackCards(4200, 250, 2)
    var k = tracks.add("telemetry", b[0].copy(), "/v/e.mp4", 0, 0, 900, 400)
    assert_true(Bool(tracks.cards[k].lanes), "lanes for a multichannel log")
    var names: List[String] = ["joint_vel_1", "joint_vel_2", "nothing"]
    var vals: List[Float64] = [2.175, 2.61, 9.0]
    assert_equal(tracks.cards[k].limits(names, vals), 2)
    assert_equal(tracks.cards[k].lanes.value().lanes[0].limit, 2.61)
    tracks.cards[k].mark(b[1].copy())
    assert_equal(len(tracks.cards[k].lanes.value().marks), 2)
    print("card: ok")

    # named: the card called "episode" plays a new file in place (same slot, place, name)
    var clip = String(argv()[1]) if len(argv()) > 1 else String("build/g47/full/clips/F00118.mp4")
    var clip2 = String(argv()[2]) if len(argv()) > 2 else String("build/g47/full/clips/F00119.mp4")
    var media = MediaCards(5000, 300, 4)
    var v = media.named("episode", clip, 10, 20, 640)
    var slot = media.cards[v].slot
    var w = media.named("episode", clip2, 999, 999, 100)
    assert_equal(v, w)
    assert_equal(media.cards[w].slot, slot)
    assert_equal(media.cards[w].path, clip2)
    assert_equal(media.cards[w].title(), "episode")
    assert_true(media.cards[w].x == 10 and media.cards[w].y == 20 and media.cards[w].w == 640, "same place")
    assert_equal(len(media), 1)
    print("named: ok")

    # page: a zoomed page panned to a box near its top-right corner leaves no blank canvas beside it; at fit it is centred;
    # a drag still moves a zoomed page (goal 41's numbers)
    var pdf = String(argv()[3]) if len(argv()) > 3 else String("build/g47/full/paper/droid-paper.pdf")
    python_start()
    var doc = DocumentCard(pdf, 6000, 400, 0, 0, 420)
    var cw = 400
    var chh = 520
    var buf = List[UInt32](length=cw * chh, fill=0)
    var surf = Surface(Int(buf.unsafe_ptr()), cw, chh, 1.0)
    doc.draw(surf, liquid_dark_palette())
    doc.highlight(14, Box(444.5, 119.0, 118.8, 9.9))  # (at fit: centred, nothing moved)
    assert_true(doc.pan_x == 0.0 and doc.pan_y == 0.0, "fit: centred")
    doc.set_zoom(1.95)
    doc.highlight(14, Box(444.5, 119.0, 118.8, 9.9))
    var pg = doc.page_to_canvas(Box(0, 0, doc.pdf.size(14)[0], doc.pdf.size(14)[1]), cw, chh, 1.0)
    assert_true(pg.x <= 0.5 and pg.x + pg.w >= Float64(cw) - 0.5 and pg.y <= 0.5 and pg.y + pg.h >= Float64(chh) - 0.5, "no blank beside a zoomed page")
    var hb = doc.page_to_canvas(Box(444.5, 119.0, 118.8, 9.9), cw, chh, 1.0)
    assert_true(hb.y >= 0 and hb.y + hb.h <= Float64(chh) and hb.x < Float64(cw), "the marked line in view")
    doc.set_zoom(1.0)
    doc.set_zoom(1.25)
    var c1 = doc.page_to_canvas(Box(306, 396, 0, 0), cw, chh, 1.0)
    _ = doc.update(Event(6000 + DOC_GESTURE, "", PAN, x=200, y=200, dx=30, dy=-20))
    var c2 = doc.page_to_canvas(Box(306, 396, 0, 0), cw, chh, 1.0)
    assert_true(abs(c2.x - c1.x - 30) < 0.5 and abs(c2.y - c1.y + 20) < 0.5, "a drag moves a zoomed page")
    _ = len(buf)
    print("page: ok")
