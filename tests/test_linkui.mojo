# The link UI's parts (goal 41 M8, M9), without a window: matching columns on real sheets, a link drag from header to
# confirm (key and time), the peek's lit / dimmed cards and lines, the spring, a time lane, and a Board's tones as a
# patch (never a rebuild).
#
#   scripts/mxbuild.sh tests/test_linkui.mojo -o build/test_linkui && build/test_linkui      → linkui: ok

from std.testing import assert_equal, assert_true, assert_false
from mojoui.app import Event
from mojoui.csvio import read_table
from mojoui.diff import diff, SET_TONES
from mojoui.links import Links, Link, End, LINK_KEY, LINK_TIME
from mojoui.linkdrag import (LinkDrag, DropCard, column_values, match_columns, is_time_column, LD_LINK, LD_CANCEL, LD_OFFSET,
                             LD_COLUMN)
from mojoui.peek import Peek
from mojoui.sheet import Sheet
from mojoui.spring import Spring
from mojoui.timelane import TimeLane
from mojoui.timeseries import TimeSeries
from mojoui.view import Board, Text, BOARD_PLAIN, BOARD_DIM, BOARD_LIFT, BOARD_SOURCE, BOARD_TARGET


def write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def main() raises:
    write("/tmp/linkui_a.csv", "id,carrier\n1,Ridge\n2,Polar\n3,Ridge\n4,Atlas\n4,Atlas\n")
    write("/tmp/linkui_b.csv", "frame,code,who\n10,2,Polar\n11,3,Kite\n12,9,Polar\n13,2,Ridge\n")
    var a = Sheet(read_table("/tmp/linkui_a.csv").table, False)
    var b = Sheet(read_table("/tmp/linkui_b.csv").table, False)

    # matching columns: distinct values, stored values compared (numbers, words' codes), best first
    var ids = column_values(a, a.index("id"))
    assert_equal(len(ids), 4)
    var cands = match_columns(ids, b)
    assert_equal(cands[0].column, "code")
    assert_equal(cands[0].count.text(), "2 of 4")
    var carriers = match_columns(column_values(a, a.index("carrier")), b)
    assert_equal(carriers[0].column, "who")
    assert_equal(carriers[0].count.text(), "2 of 3")

    # a drag: picked up, over the second card, offered its columns, dropped, confirmed
    var cards: List[DropCard] = [DropCard("a", "", 0, 0, 300, 200, 0, False), DropCard("b", "", 400, 0, 300, 200, 1, False),
                                 DropCard("video.mp4", "b", 0, 300, 300, 200, 2, True)]
    var ld = LinkDrag(100)
    ld.begin("a", "", "id", ids.copy(), 50, 20)
    assert_false(ld.move(60, 40, cards))  # (still over its own card: nothing under it)
    assert_true(ld.move(500, 100, cards))
    assert_equal(ld.target, 1)
    ld.offer(cands.copy())
    assert_equal(ld.tone(1), BOARD_TARGET)
    assert_true(len(ld.views(1200)) >= 2)  # (the column at the pointer, the target's columns)
    assert_true(ld.drop())
    assert_true(ld.confirming)
    assert_true(ld.update(Event(100 + LD_LINK, "", 0)))
    assert_true(ld.confirmed)
    assert_equal(ld.line(), "LINK: a.id = b · code (2 of 4)")
    var l = ld.link()
    assert_equal(l.kind, LINK_KEY)
    assert_equal(l.label(), "a.id = b.code")
    assert_equal(ld.tone(1), BOARD_PLAIN)
    # dropped where nothing is: it just ends
    ld.begin("a", "", "id", ids.copy(), 50, 20)
    _ = ld.move(350, 250, cards)
    assert_false(ld.drop())
    assert_false(ld.busy())

    # a clock dropped on a video: a time link, its offset typed
    assert_true(is_time_column("t"))
    assert_false(is_time_column("speed"))
    ld.begin("log", "", "t", List[String](), 10, 10)
    assert_true(ld.move(100, 400, cards))
    ld.offer_time()
    assert_true(ld.drop())
    _ = ld.update(Event(100 + LD_OFFSET, "3.4", 0))
    _ = ld.update(Event(100 + LD_LINK, "", 0))
    var tl = ld.link()
    assert_equal(tl.kind, LINK_TIME)
    assert_equal(tl.offset, 3.4)
    assert_equal(tl.b.card, "log")  # (the log's clock = the video's + offset)
    assert_equal(tl.to_b(10.0), 13.4)

    # the peek: a's link reaches b, and the video showing b's table (dotted: the same table); nothing else is dimmed
    var links = Links(200)
    _ = links.add(l)
    var more = cards.copy()
    more.append(DropCard("notes", "", 800, 300, 200, 100, 3, False))
    var peek = Peek(40, 300)
    peek.show("a", more, links)
    assert_equal(peek.line(), "PEEK: lit=[b, video.mp4] dim=[notes] lines=2")
    assert_equal(peek.tone(0), BOARD_SOURCE)
    assert_equal(peek.tone(1), BOARD_LIFT)
    assert_equal(peek.tone(3), BOARD_DIM)
    assert_equal(peek.tone(9), BOARD_PLAIN)  # (not a card: the page's floating pieces)
    assert_equal(peek.say(), "a: 1 link")
    assert_true(len(peek.views()) == 3)  # (the curves' canvas and a label per line)
    var frames = 0
    while peek.step(16667) and frames < 600:
        frames += 1
    peek.close()
    frames = 0
    while not peek.settled and frames < 600:
        _ = peek.step(16667)
        frames += 1
    assert_true(peek.settled)
    assert_equal(peek.tone(0), BOARD_PLAIN)

    # the spring settles where it's aimed without a bounce (Liquid's motion)
    var s = Spring(0.0)
    s.to(1.0)
    var top = 0.0
    var n = 0
    while s.step(16667) and n < 600:
        top = max(top, s.value)
        n += 1
    assert_equal(s.value, 1.0)
    assert_true(top <= 1.01)
    assert_true(n < 60)

    # a time lane: the log on the video's clock
    var ts = TimeSeries([3.4, 3.5, 3.6, 3.7])
    ts.add("speed", [2.0, 2.5, 3.0, 3.5])
    var lane = TimeLane.of("log", ts, "speed", 3.4)
    assert_equal(lane.value_at(0.0), 2.0)
    assert_equal(lane.value_at(0.25), 3.0)
    assert_true(lane.line().startswith("LANE: log speed"))

    # a Board's tones change by a patch, never a rebuild
    var v1 = Board([Text("one"), Text("two")], 400, 300)
    var v2 = Board([Text("one"), Text("two")], 400, 300, tones=[BOARD_DIM, BOARD_LIFT])
    var d = diff(v1, v2)
    assert_false(d.rebuild)
    var found = False
    for p in d.patches:
        if p.op == SET_TONES:
            found = True
    assert_true(found)
    print("linkui: ok")
