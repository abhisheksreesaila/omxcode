# mojoui.stagetv (goal 77 M7d): gitaway's soft spring (≤ 2 % overshoot, 1 at 900 ms, settled ≤ 1.1 s), the TV's state
# machine (open: the box grows while the tiles' veil rises in 260 ms and the body arrives 160 ms in; a follow-up swaps the
# card under a veil; × or 12 s of quiet after she finishes closes it and the body goes when its veil is up; less motion lands
# at once), the box's rect from the bar's pill to the whole column, the Stage's layers (the TV's canvas over the column, the
# chat bar in a band at its bottom, the body only while open) and every tag it sets styled by omxqua's Counter family.
from std.testing import assert_equal, assert_true, assert_false
from mojoui.view import View, Text, Canvas, VStack, HStack, OVERLAY, CANVAS, STRETCH, END, NO_MSG
from mojoui.stage import Stage, StageChat
from mojoui.stagetv import StageTV, TVContent, StageThread, StageChips, StageMsg, soft_spring, ease_v2, tv_layout
from mojoui.stagetv import TV_YOU, TV_OMX, TV_MORPH_MS, TV_QUIET_MS
from mojoui.stagetv import pointed_parts, RecentCards, RECENT_MAX
from mojoui.pointer import Part, area_part
from themes.omxqua import omxqua_counter, counter_tv_look

comptime MS = 1000  # µs


def opened_tv() -> StageTV:
    var tv = StageTV(70, 71, on_frame=9, on_close=8)
    tv.area_w = 700
    tv.area_h = 740
    return tv^


def test_soft_spring() raises:
    var peak = 0.0
    var last = 0.0
    var back = False
    var settled_at = -1
    for ms in range(0, 1201):
        var v = soft_spring(Float64(ms) / Float64(TV_MORPH_MS))
        peak = max(peak, v)
        if v < last - 1e-9:
            back = True
            assert_true(last >= 1.0, "it only turns back after passing 1 (" + String(ms) + " ms)")
        last = v
        if abs(v - 1.0) <= 0.002 and settled_at < 0:
            settled_at = ms
        elif abs(v - 1.0) > 0.002:
            settled_at = -1
    assert_true(back, "a spring: it overshoots and comes back")
    assert_true(peak > 1.0 and peak <= 1.02, "overshoot ≤ 2 %: " + String(peak))
    assert_true(settled_at >= 0 and settled_at <= 1100, "settled (within 0.2 %) by 1.1 s: " + String(settled_at))
    assert_equal(soft_spring(1.0), 1.0)
    assert_true(abs(soft_spring(0.189) - 0.539) < 1e-9)
    assert_true(abs(soft_spring(0.014) - 0.006) < 1e-9, "0.006 at the even place, 1.4 %")
    assert_true(ease_v2(0.5) > 0.85 and ease_v2(0.5) < 0.95, "ease-v2 is quick early: " + String(ease_v2(0.5)))
    assert_equal(ease_v2(0.0), 0.0)
    assert_equal(ease_v2(1.0), 1.0)


def test_open_morph() raises:
    var tv = opened_tv()
    assert_false(tv.visible())
    var b0 = tv.box(700, 740)
    assert_equal(b0.h, 64.0)
    assert_equal(b0.y, 740.0 - 14.0 - 64.0)
    tv.open(1_000 * MS, "How a heat pump works", "iso")
    assert_true(tv.is_open)
    assert_false(tv.body, "the body arrives 160 ms in, not at once")
    _ = tv.tick(1_100 * MS)
    assert_false(tv.body)
    assert_true(tv.tiles_hidden() > 0.5 and tv.tiles_hidden() < 1.0, "the tiles fading: " + String(tv.tiles_hidden()))
    _ = tv.tick(1_160 * MS)
    assert_true(tv.body, "160 ms: the body is on screen")
    assert_equal(tv.card, "iso")
    _ = tv.tick(1_260 * MS)
    assert_true(abs(tv.tiles_hidden() - 1.0) < 1e-9, "260 ms: the tiles are gone")
    var prev = 64.0
    var peak = 0.0
    for ms in range(1_000, 2_000, 10):
        _ = tv.tick(ms * MS)
        var h = tv.box(700, 740).h
        if h < prev - 1e-6:
            assert_true(prev >= 712.0 - 1e-6, "the box only turns back past its full height")
        prev = h
        peak = max(peak, h)
    var full = 740.0 - 14.0 - 14.0  # (14 above it: the room the overshoot pokes into)
    assert_true(peak > full and (peak - 64.0) / (full - 64.0) <= 1.02, "≤ 2 % past the whole column: " + String(peak))
    _ = tv.tick(2_000 * MS)
    assert_equal(tv.box(700, 740).h, full)
    assert_equal(tv.box(700, 740).y, 14.0)
    assert_equal(tv.box(700, 740).radius, 30.0)
    # a window that has not painted yet (goal 77 M7f: a test window never shown): the size guessed from resize(w, h)
    var blind = StageTV(3, 4, on_frame=30, on_close=31)
    blind.resize(1280, 820)
    assert_true(blind.area_w > 600 and blind.area_w < 760 and blind.area_h == 768.0, "guessed " + String(blind.area_w) + " x " + String(blind.area_h))
    blind.open(1_000 * MS, "Your to-do list", "todo")
    _ = blind.tick(1_200 * MS)
    assert_true(blind.body, "the body arrives without a draw once the window's size is known")
    assert_true(blind.layout().body_h > 600, "a body as tall as the column: " + String(blind.layout().body_h))


def test_swap_and_close() raises:
    var tv = opened_tv()
    tv.open(0, "Ephemeral", "word")
    _ = tv.tick(1_000 * MS)
    assert_equal(tv.card, "word")
    tv.open(2_000 * MS, "How a heat pump works", "iso")  # a follow-up while open: the card swaps in place
    assert_true(tv.is_open)
    assert_equal(tv.card, "word", "the old card stays while its veil rises")
    _ = tv.tick(2_130 * MS)
    assert_true(tv.leaving() > 0.5 and tv.veils_card_only(), "only the card's column is veiled")
    _ = tv.tick(2_260 * MS)
    assert_equal(tv.card, "iso", "260 ms: the new card")
    assert_equal(tv.title, "How a heat pump works")
    assert_true(tv.leaving() > 0.9, "the veil lifts from here")
    _ = tv.tick(2_470 * MS)
    assert_equal(tv.leaving(), 0.0)
    assert_equal(tv.box(700, 740).h, 712.0, "a swap never moves the box")
    tv.close(3_000 * MS)
    assert_false(tv.is_open)
    assert_equal(tv.closed_by, "x")
    assert_true(tv.body, "the body fades out first")
    assert_false(tv.veils_card_only())
    _ = tv.tick(3_100 * MS)
    assert_true(tv.tiles_hidden() == 1.0, "the tiles wait 160 ms")
    _ = tv.tick(3_260 * MS)
    assert_false(tv.body, "260 ms: the body is gone")
    assert_equal(tv.card, "")
    _ = tv.tick(3_400 * MS)
    assert_true(tv.tiles_hidden() < 1.0 and tv.tiles_hidden() > 0.0, "the tiles coming back")
    _ = tv.tick(4_000 * MS)
    assert_equal(tv.tiles_hidden(), 0.0)
    assert_equal(tv.box(700, 740).h, 64.0, "back to the chat bar")
    assert_false(tv.visible())
    assert_false(tv.ticking(), "no frames once it is the bar again")


def test_quiet_closes() raises:
    var tv = opened_tv()
    tv.open(0, "Ephemeral", "word")
    tv.speaking(100 * MS, True)
    _ = tv.tick(20_000 * MS)
    assert_true(tv.is_open, "never while she speaks")
    tv.speaking(20_000 * MS, False)
    _ = tv.tick(31_000 * MS)
    assert_true(tv.is_open, "11 s of quiet: still open")
    tv.touch(31_500 * MS)  # (typing in the TV)
    _ = tv.tick(43_000 * MS)
    assert_true(tv.is_open, "the quiet starts again at a touch")
    _ = tv.tick(31_500 * MS + TV_QUIET_MS * MS)
    assert_false(tv.is_open, "12 s of quiet after the last thing: closed")
    assert_equal(tv.closed_by, "quiet")


def test_reopen_mid_close_and_reduced() raises:
    var tv = opened_tv()
    tv.open(0, "Ephemeral", "word")
    _ = tv.tick(1_000 * MS)
    tv.close(2_000 * MS)
    _ = tv.tick(2_300 * MS)
    var h = tv.box(700, 740).h
    tv.open(2_300 * MS, "Ephemeral", "word")
    assert_equal(tv.box(700, 740).h, h, "reversed from where it was: no jump")
    var r = opened_tv()
    r.set_reduced(True)
    r.open(0, "Ephemeral", "word")
    assert_true(r.body, "less motion: the body at once")
    assert_equal(r.box(700, 740).h, 712.0)
    assert_equal(r.tiles_hidden(), 1.0)
    r.show(10 * MS, "iso", "Heat pump")
    _ = r.tick(10 * MS)
    assert_equal(r.card, "iso", "a swap at once")
    r.close(20 * MS)
    assert_false(r.body)
    assert_equal(r.box(700, 740).h, 64.0)


def test_layout() raises:
    var l = tv_layout(700, 740, False, True)
    assert_equal(l.body_h, 740 - 14 - 64 - 14)
    assert_equal(l.thread_w, 240)  # (30 % of 664 is 199: the 240 floor)
    assert_equal(l.card_w, 700 - 36 - 16 - 240)
    var wide = tv_layout(1200, 740, False, True)
    assert_equal(wide.thread_w, Int(Float64(1200 - 36) * 0.3))
    var chat = tv_layout(1200, 740, False, False)
    assert_equal(chat.card_w, 0)
    assert_equal(chat.thread_w, 720)
    var phone = tv_layout(390, 844, True, True)
    assert_true(phone.compact and phone.card_h > 0 and phone.inset == 14)
    assert_true(phone.stacked and phone.card_w == 390 - 2 * (14 + 6), "a phone's card nearly the screen's width: " + String(phone.card_w))
    assert_false(l.stacked, "700: the card (408) beside the conversation")
    var tablet = tv_layout(560, 1128, False, True)  # (a portrait tablet's centre column: the card would keep 268 beside it)
    assert_true(tablet.stacked and tablet.card_w == 560 - 36 and tablet.card_h > 0 and tablet.inset == 0, "a narrow column stacks: " + String(tablet.card_w))


def tagged(v: View, name: String) -> List[Int]:
    var out = List[Int]()
    for k in range(len(v.nodes)):
        if v.nodes[k].name == name:
            out.append(k)
    return out^


def screen(tv: StageTV, width: Int) -> View:
    var msgs = List[StageMsg]()
    msgs.append(StageMsg(TV_YOU, "What does ephemeral mean?", "7:38"))
    msgs.append(StageMsg(TV_OMX, "Lasting a very short time.", "7:38"))
    var content = TVContent(VStack(Text("ephemeral"), spacing=0), StageThread(msgs, 240), StageChips(["What does ephemeral mean?"], 30))
    var chat = StageChat(Canvas(2, 1), "", "Ask omx", 4, 5, 6)
    return Stage(VStack(Text("top"), spacing=0), VStack(Text("left"), spacing=0), Canvas(1, 1), VStack(Text("right"), spacing=0), chat, width, 820,
                 tv=tv, content=content)


def test_stage_layers() raises:
    var tv = opened_tv()
    var closed = screen(tv, 1280)
    var centre = tagged(closed, "stage-centre")[0]
    assert_equal(closed.nodes[centre].kind, OVERLAY)
    var kids = closed.nodes[centre].children.copy()
    assert_equal(len(kids), 3, "the column, the TV's canvas, the band")
    assert_equal(closed.nodes[kids[1]].kind, CANVAS)
    assert_equal(closed.nodes[kids[1]].size, 2, "the canvas lets presses through")
    assert_equal(closed.nodes[kids[2]].x, STRETCH)
    assert_equal(closed.nodes[kids[2]].y, END)
    assert_equal(len(tagged(closed, "stage-bar")), 1)
    assert_equal(len(tagged(closed, "stage-tv")), 0, "closed: no body")
    assert_equal(closed.nodes[kids[1]].msg2, NO_MSG, "closed: no frames")
    tv.open(0, "Ephemeral", "word")
    _ = tv.tick(200 * MS)
    var open = screen(tv, 1280)
    assert_equal(len(tagged(open, "stage-tv")), 1, "open: the body")
    assert_equal(len(tagged(open, "stage-tv-card")), 1)
    assert_equal(len(tagged(open, "stage-tv-thread")), 1)
    assert_equal(len(tagged(open, "stage-bar")), 1, "the same chat bar")
    var c2 = tagged(open, "stage-centre")[0]
    assert_equal(open.nodes[open.nodes[c2].children[1]].msg2, 9, "frames while open")
    var phone = screen(tv, 390)
    assert_equal(len(tagged(phone, "stage-tv")), 1)
    var plain = Stage(VStack(Text("t"), spacing=0), VStack(Text("l"), spacing=0), Canvas(1, 1), VStack(Text("r"), spacing=0),
                      StageChat(Canvas(2, 1), "", "Ask", 4, 5, 6), 1280, 820)
    assert_true(plain.nodes[tagged(plain, "stage-centre")[0]].kind != OVERLAY, "no TV: M7a's column as it was")


def test_counter_styles_tv_tags() raises:
    var tv = opened_tv()
    tv.open(0, "Ephemeral", "word")
    _ = tv.tick(200 * MS)
    var chat_only = opened_tv()
    chat_only.open(0)
    _ = chat_only.tick(200 * MS)
    for dark in [False, True]:
        var look = omxqua_counter(dark).look.copy()
        for v in [screen(tv, 1280), screen(chat_only, 1280), screen(tv, 390)]:
            for n in v.nodes:
                if n.name.startswith("stage-tv") or n.name.startswith("stage-msg"):
                    assert_true(look.surface(n.name) >= 0, "no Counter role for tag " + n.name)
        var tl = counter_tv_look(dark)
        assert_equal(tl.card, omxqua_counter(dark).palette.card)
        assert_true(len(tl.shadows) >= 1)


def test_pointer_leaves_hidden_tiles_out() raises:
    var parts: List[Part] = [area_part("tiles", "weather", ["weather"], "stage-tiles", 0, 0, 10, 10, 100, 100),
                             Part("card1", "word", ["ephemeral"], False, True)]
    var tv = opened_tv()
    assert_equal(len(pointed_parts(tv, parts, "stage-tiles")), 2, "closed: the tiles can be pointed at")
    tv.open(0, "Ephemeral", "word")
    var open = pointed_parts(tv, parts, "stage-tiles")
    assert_equal(len(open), 1, "open: the hidden tiles are left out")
    assert_equal(open[0].card, "card1", "the TV's card stays")
    tv.close(1_000 * MS)
    _ = tv.tick(1_100 * MS)
    assert_true(tv.hides_tiles(), "closing: still veiled (the tiles wait 160 ms)")
    _ = tv.tick(2_000 * MS)
    assert_equal(len(pointed_parts(tv, parts, "stage-tiles")), 2, "closed again: back")


def test_target_and_recent() raises:
    """StageTV.target (what an app lets her point at, D-7864): the card on screen, the one a swap is bringing in (never the one
    leaving), "" once closed. RecentCards (omx's Recent, lifted for the review of M7f): newest first, a card shown again moves to
    the front once, at most RECENT_MAX kept; others() leaves the TV's card out and offers at most RECENT_MAX - 1, by the index a
    pill's message carries."""
    var tv = opened_tv()
    assert_equal(tv.target(), "")
    tv.open(0, "Ephemeral", "word")
    _ = tv.tick(1_000 * MS)
    assert_equal(tv.target(), "word")
    tv.open(2_000 * MS, "Heat pump", "iso")
    _ = tv.tick(2_130 * MS)
    assert_equal(tv.card, "word", "the old card is still on screen under its veil")
    assert_equal(tv.target(), "iso", "a swap's target, not the card leaving")
    _ = tv.tick(2_470 * MS)
    assert_equal(tv.target(), "iso")
    tv.close(3_000 * MS)
    _ = tv.tick(3_400 * MS)
    assert_equal(tv.target(), "", "closed: nothing to point at")

    var r = RecentCards()
    assert_equal(len(r.others("")), 0)
    r.show("card1", "Ephemeral")
    r.show("todo", "Your to-do list")
    r.show("card1", "Ephemeral again")  # (shown again: to the front, once, with its new title)
    assert_equal(len(r.keys), 2)
    assert_equal(r.keys[0], "card1")
    assert_equal(r.titles[0], "Ephemeral again")
    assert_equal(r.keys[1], "todo")
    var o = r.others("card1")
    assert_equal(len(o), 1)
    assert_equal(r.keys[o[0]], "todo")
    for i in range(8):
        r.show("news" + String(i), "")
    assert_equal(len(r.keys), RECENT_MAX)
    assert_equal(r.keys[0], "news7")
    assert_equal(r.keys[RECENT_MAX - 1], "news3")
    assert_equal(r.label(0), "news7", "no title: the key")
    var shown = r.others("news7")
    assert_equal(len(shown), RECENT_MAX - 1)
    assert_equal(r.keys[shown[0]], "news6")
    assert_equal(len(r.others("elsewhere")), RECENT_MAX - 1, "the TV on another card: still at most four offered")


def main() raises:
    test_soft_spring()
    test_open_morph()
    test_swap_and_close()
    test_quiet_closes()
    test_reopen_mid_close_and_reduced()
    test_layout()
    test_stage_layers()
    test_counter_styles_tv_tags()
    test_pointer_leaves_hidden_tiles_out()
    test_target_and_recent()
    print("test_stagetv: 10 tests passed")
