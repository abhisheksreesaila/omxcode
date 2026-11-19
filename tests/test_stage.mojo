# mojoui.stage (goal 77 M7a): the columns at a width (1 : 2.75 : 1, sides ≥ 200; no right column under 1000; one column at
# 760 or narrower), the regions in order with their roles, the shaded bands only beside a desktop's centre, and every tag
# the Stage and its parts set styled by omxqua's Counter family (light and night).
from std.testing import assert_equal, assert_true, assert_false
from mojoui.view import View, Text, Canvas, VStack, HStack, SCROLL, NO_MSG
from mojoui.stage import Stage, StageClock, StageLabel, StageCard, StageRow, StageList, StageAvatar, StagePill, StageChat, StageNote
from mojoui.stage import stage_layout, stage_compact, STAGE_PHONE, STAGE_NARROW
from themes.omxqua import omxqua_counter, counter_ground, counter_shade


def tagged(v: View, name: String) -> List[Int]:
    var out = List[Int]()
    for k in range(len(v.nodes)):
        if v.nodes[k].name == name:
            out.append(k)
    return out^


def tags(v: View) -> List[String]:
    var out = List[String]()
    for n in v.nodes:
        if n.name != "" and n.name not in out:
            out.append(n.name)
    return out^


def screen(width: Int) -> View:
    var compact = stage_compact(width)
    var top = HStack(StageAvatar("All", 0, 1), StageAvatar("A", 2, 2), StagePill("settings", "Settings", 3, compact), spacing=8)
    var left = VStack(StageClock("10:59", "Wednesday, November 18", "9° · clear", compact), StageLabel("pin", "Pinned"),
                      StageList([StageCard("map-pin", "Pinned", "A day in Lisbon", "3 stops", 3, on_unpin=9)], compact), StageNote("Nothing else today"), spacing=10)
    var right = VStack(StageLabel("zap", "Live"), StageList([StageRow("timer", "Pasta", "7:20", 4), StageRow("car", "Traffic", "Roads are clear", 3)]), spacing=10)
    var chat = StageChat(Canvas(2, 1), "", "Ask omx, or just say “omx”", 4, 5, 6)
    return Stage(top, left, Canvas(1, 1), right, chat, width)


def test_layout_desktop() raises:
    var l = stage_layout(1280)
    assert_false(l.compact)
    assert_true(l.right)
    # 1280 − 36 − 36 = 1208 shared 1 : 2.75 : 1 → 254 | 700 | 254
    assert_equal(l.side, 254)
    assert_equal(l.centre, 700)
    var ratio = Float64(l.centre) / Float64(l.side)
    assert_true(2.7 < ratio < 2.8, "centre ≈ 2.75 × a side: " + String(ratio))
    var w = stage_layout(1000)  # (the first width with a right column)
    assert_true(w.right)
    assert_true(w.side >= 200)
    assert_equal(2 * 18 + 2 * 18 + 2 * w.side + w.centre, 1000)


def test_layout_side_minimum() raises:
    var l = stage_layout(1010)  # (free 938 / 4.75 = 197.5: the sides hold at 200)
    assert_equal(l.side, 200)
    assert_equal(l.centre, 1010 - 72 - 400)


def test_layout_narrow_and_phone() raises:
    var n = stage_layout(STAGE_NARROW - 1)
    assert_false(n.compact)
    assert_false(n.right)
    assert_true(n.side >= 180)
    assert_equal(n.side + n.centre, 999 - 36 - 18)
    var edge = stage_layout(STAGE_PHONE + 1)
    assert_false(edge.compact)
    var p = stage_layout(STAGE_PHONE)
    assert_true(p.compact)
    var phone = stage_layout(390)
    assert_true(phone.compact)
    assert_equal(phone.side, 390 - 28)
    assert_true(stage_compact(390))
    assert_false(stage_compact(761))


def test_regions_desktop() raises:
    var v = screen(1280)
    for r in ["stage-top", "stage-left", "stage-centre", "stage-right", "stage-panel", "stage-bar"]:
        assert_equal(len(tagged(v, r)), 1, r)
    var left = tagged(v, "stage-left")[0]
    var centre = tagged(v, "stage-centre")[0]
    var right = tagged(v, "stage-right")[0]
    assert_true(left < centre < right, "left, centre, right in that order")
    assert_equal(v.nodes[left].w, 254)
    assert_equal(v.nodes[right].w, 254)
    assert_equal(len(tagged(v, "stage-side")), 2, "a shaded band each side")
    var bands = tagged(v, "stage-side")
    assert_equal(v.nodes[bands[0]].w, 18 + 254 + 9)
    assert_equal(v.nodes[bands[1]].w, 9 + 254 + 18)
    # the panel sits above the bar inside the centre column
    assert_true(tagged(v, "stage-panel")[0] < tagged(v, "stage-bar")[0])
    assert_equal(v.nodes[tagged(v, "stage-bar")[0]].h, 64)
    assert_equal(len(tagged(v, "stage-phone-bar")), 0)


def test_regions_narrow() raises:
    var v = screen(900)
    assert_equal(len(tagged(v, "stage-right")), 0, "no right column under 1000")
    assert_equal(len(tagged(v, "stage-side")), 1, "the left band only")
    assert_equal(len(tagged(v, "stage-left")), 1)


def test_regions_phone() raises:
    var v = screen(390)
    var order = List[Int]()
    for r in ["stage-top", "stage-left", "stage-centre", "stage-right", "stage-bar"]:
        assert_equal(len(tagged(v, r)), 1, r)
        order.append(tagged(v, r)[0])
    for i in range(1, len(order)):
        assert_true(order[i - 1] < order[i], "stacked top, left, centre, right, bar")
    assert_equal(len(tagged(v, "stage-side")), 0, "no shade on a phone")
    assert_equal(len(tagged(v, "stage-list-row")), 1, "pins in a row")
    assert_equal(len(tagged(v, "stage-clock-time-compact")), 1)
    # the bar sits outside the scroll (fixed at the bottom), the regions inside it
    var scroll = -1
    for k in range(len(v.nodes)):
        if v.nodes[k].kind == SCROLL:
            scroll = k
    assert_true(scroll >= 0)
    var strip = tagged(v, "stage-phone-bar")[0]
    assert_true(strip > tagged(v, "stage-right")[0])
    assert_true(tagged(v, "stage-bar")[0] > strip)


def test_counter_styles_every_tag() raises:
    for dark in [False, True]:
        var look = omxqua_counter(dark).look.copy()
        for width in [1280, 900, 390]:
            for t in tags(screen(width)):
                assert_true(look.surface(t) >= 0, "no Counter role for tag " + t)
        var panel = look.surfaces[look.surface("stage-panel")].copy()
        assert_equal(panel.fill, counter_ground(dark))
        assert_equal(panel.radius_top, 30)
        assert_true(len(panel.shadows) >= 1, "the stage wears a soft shadow")
        var side = look.surfaces[look.surface("stage-side")].copy()
        assert_equal(side.fill, counter_shade(dark))
        assert_true((side.fill >> 24) < 255, "the shade lets the room show through")
        var bar = look.surfaces[look.surface("stage-bar")].copy()
        assert_equal(bar.radius_top, 32)
        assert_equal(bar.fill, omxqua_counter(dark).palette.card)


def main() raises:
    test_layout_desktop()
    test_layout_side_minimum()
    test_layout_narrow_and_phone()
    test_regions_desktop()
    test_regions_narrow()
    test_regions_phone()
    test_counter_styles_every_tag()
    print("test_stage: 7 tests passed")
