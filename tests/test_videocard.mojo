# mojoui.videocard (goal 41 M4): a video card's Analyze / Make a reel / Edit flow, on goal 39's warehouse footage:
#   scripts/mxbuild.sh tests/test_videocard.mojo -o build/test_videocard && G39_MEDIA=build/g39/media G39_OUT=build/g39 build/test_videocard
# Prints "videocard: ok". The editor opens from the card while its analysis runs (chips at once), the rows land as the
# card's marks and the editor's lanes, a second analysis is refused while one runs, a reel cuts the flagged frames.
from std.testing import assert_equal, assert_true, assert_false
from std.os import getenv
from std.time import sleep
from mojoui.videocard import VideoWork
from mojoui.mediacard import MediaCards
from mojoui.mediatimeline import MediaTimeline
from mojoui.sheet import Sheet
from mojoui.timeseries import TimeSeries
from mojoui.videojobs import detections_table, flag_columns
from mojoui.videoexport import Caption


def main() raises:
    var media = getenv("G39_MEDIA", "build/g39/media")
    var out = getenv("G39_OUT", "build/g39")
    var cards = MediaCards(4000, 200, most=3)
    var k = cards.add(media + "/warehouse.mp4", 0, 0, 640)
    var work = VideoWork()
    assert_true(cards.settle())
    # Edit before any analysis: the editor opens at once from the card's probe, its analysis starts, the chips meanwhile
    var ed = MediaTimeline.open_with(cards.cards[k].player.value().info, 300, 300, room_w=1200, room_h=800)
    work.prepare_editor(ed, cards, k)
    assert_true(Bool(work.analyzing), "Edit started the analysis")
    assert_true(ed.expecting and ed.blur_kind == "face", "the chips show while it runs")
    assert_equal(cards.cards[k].status, "Analyzing")
    assert_false(work.analyze(cards, k, 0), "one analysis at a time")
    assert_true("Already analyzing" in work.problem)
    var p = work.progress(cards)
    var a = work.take_analysis(cards)
    while not a:
        sleep(0.02)
        p = work.progress(cards)
        a = work.take_analysis(cards)
    assert_true(work.has_rows(media + "/warehouse.mp4"), "its rows are kept")
    assert_equal(cards.cards[k].status, "")
    assert_equal(cards.cards[k].player.value().marked, 1)
    work.feed_editor(ed)
    assert_true(Bool(ed.table) and len(ed.lanes) >= 2, "the rows became the editor's lanes")
    # Edit again: the rows at once, no new analysis
    var ed2 = MediaTimeline.open_with(cards.cards[k].player.value().info, 300, 300)
    work.prepare_editor(ed2, cards, k)
    assert_false(Bool(work.analyzing))
    assert_true(Bool(ed2.table))
    # a reel of the damaged frames (the rows as a sheet, its flag column)
    var sheet = Sheet(detections_table(work.found).share(), False)
    var flags = flag_columns(sheet)
    assert_equal(len(flags), 1)
    var path = out + "/videocard-reel.mp4"
    assert_true(work.reel(cards, k, sheet, flags[0], List[Caption](), True, path))
    assert_equal(cards.cards[k].status, "Making a reel")
    var r = work.take_reel(cards)
    while not r:
        sleep(0.05)
        r = work.take_reel(cards)
    assert_true(r.value().frames > 30, "reel frames " + String(r.value().frames))
    assert_equal(cards.cards[k].status, "")
    # a log analyzer without a log is refused with the reason
    assert_false(work.analyze(cards, k, 2))
    assert_true("needs the flight's log" in work.problem)
    print("videocard: ok (" + String(work.found.rows()) + " rows, reel " + String(r.value().frames) + " frames)")
