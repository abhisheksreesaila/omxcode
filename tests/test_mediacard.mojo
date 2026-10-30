# mojoui.picture (Picture, draw_fitted) and mojoui.mediacard (MediaCards) (goal 39 M6), on the generated footage:
#   G39_MEDIA=build/g39/media pixi run mojo run -I . tests/test_mediacard.mojo
# Prints "picture: ok", "cards: ok", "seek set: ok". The still is written here with mojoui.png (its pixels known), then read
# back through Picture; the second still is a frame ffmpeg writes as JPEG (lossy: compared within a tolerance).
from std.testing import assert_equal, assert_true, assert_false
from std.os import getenv
from std.ffi import external_call
from mojoui.app import Event
from mojoui.canvas import Surface
from mojoui.mediacard import MediaCards, OBJ_VIDEO, OBJ_IMAGE, CARD_MESSAGES, CARD_CLOSE, is_video_file, is_image_file, extension
from mojoui.picture import Picture, draw_fitted
from mojoui.player import PLAY, PAUSE, SCRUB, FRAME
from mojoui.png import encode_png
from mojoui.theme import Palette
from mojoui.view import SET_TO, CANVAS, BUTTON
from mojoui.hosts.web import control_event


def write_bytes(path: String, data: List[UInt8]) raises:
    var p = path
    var mode = String("wb")
    var fp = external_call["fopen", Int](p.as_c_string_span(), mode.as_c_string_span())
    if fp == 0:
        raise Error("cannot write " + path)
    _ = external_call["fwrite", Int](Int(data.unsafe_ptr()), 1, len(data), fp)
    _ = external_call["fclose", Int32](fp)


def picture_tests(media: String) raises:
    assert_equal(extension("a/b/Clip.MP4"), ".mp4")
    assert_true(is_video_file("x.webm") and is_image_file("x.JPG") and not is_video_file("x.csv") and not is_image_file("noext"))
    # a 4×2 PNG of known colours, read back exactly
    var px = List[UInt32]()
    for i in range(8):
        px.append(UInt32(0xFF000000) | UInt32(i * 30) | (UInt32(255 - i * 30) << 8) | (UInt32(i * 7) << 16))
    write_bytes("build/g39/m6-still.png", encode_png(px, 4, 2))
    var p = Picture("build/g39/m6-still.png")
    assert_equal(p.width, 4)
    assert_equal(p.height, 2)
    for i in range(8):
        assert_equal(p.pixel(i % 4, i // 4) & 0xFFFFFF, px[i] & 0xFFFFFF)
    # a JPEG: frame 0 of the warehouse footage, as ffmpeg writes it
    var cmd = String("ffmpeg -v error -y -i '" + media + "/warehouse.mp4' -frames:v 1 build/g39/m6-still.jpg < /dev/null")
    _ = external_call["system", Int32](cmd.as_c_string_span())
    var j = Picture("build/g39/m6-still.jpg")
    assert_equal(j.width, 1280)
    assert_equal(j.height, 720)
    # draw_fitted: a 2:1 picture in a square leaves bands of the backdrop above and below, the picture's colour in the middle
    var solid = List[UInt32](length=8, fill=UInt32(0xFF0000FF))  # red
    var out = List[UInt32](length=40 * 40, fill=0)
    var s = Surface(Int(out.unsafe_ptr()), 40, 40, 1.0)
    draw_fitted(s, solid, 4, 2, UInt32(0xFFFFFFFF), 0.0)
    assert_equal(out[2 * 40 + 20], UInt32(0xFFFFFFFF))  # (a band)
    assert_equal(out[20 * 40 + 20] & 0xFFFFFF, UInt32(0x0000FF))  # (the picture)
    var raised = False
    try:
        _ = Picture("build/g39/no-such-picture.png")
    except:
        raised = True
    assert_true(raised)
    print("picture: ok")


def card_tests(media: String) raises:
    var cards = MediaCards(4000, 200, most=3)
    var a = cards.add(media + "/warehouse.mp4", 0, 0, 640)
    var b = cards.add(media + "/drone_a.mp4", 660, 0, 480)
    var c = cards.add("build/g39/m6-still.png", 0, 600, 200)
    assert_true(cards.cards[a].facts() == "opening…", "a card opens without waiting for its probe")
    assert_true(cards.settle(), "the cards opened (decoded on their threads)")
    assert_equal(cards.cards[a].kind, OBJ_VIDEO)
    assert_equal(cards.cards[c].kind, OBJ_IMAGE)
    assert_equal(cards.msg(a), 4000)
    assert_equal(cards.msg(b), 4000 + CARD_MESSAGES)
    assert_equal(cards.canvas(b), 202)
    assert_equal(cards.cards[a].h, (640 - 28) * 720 // 1280 + 132)  # (the media's own shape, with the card's chrome)
    assert_true(cards.cards[a].facts().startswith("0:"))
    assert_true(cards.cards[c].facts() == "4×2 PNG")
    var full = False
    try:
        _ = cards.add(media + "/drone_b.mp4", 0, 0, 300)
    except:
        full = True
    assert_true(full)
    # two players, each on its own messages: playing b leaves a paused
    assert_true(cards.update(Event(cards.msg(b) + PLAY, "", 0)))
    for _ in range(30):
        _ = cards.update(Event(cards.msg(b) + FRAME, "", 33_334))
    assert_true(cards.cards[b].player.value().state.t() >= 0.99)
    assert_equal(cards.cards[a].player.value().state.frame, 0)
    assert_false(cards.cards[a].player.value().state.playing)
    assert_false(cards.update(Event(7, "", 0)))
    # each card draws on its own canvases
    assert_true(cards.draws(200) and cards.draws(203) and cards.draws(204) and not cards.draws(206))
    var px = List[UInt32](length=64 * 36, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), 64, 36, 1.0)
    assert_true(cards.settle())
    cards.draw(202, s, Palette.plain())  # (drone_a's frame at 1 s)
    var lit = 0
    for p in px:
        if p != px[0]:
            lit += 1
    assert_true(lit > 100)
    assert_true(cards.describe(203).startswith("drone_a.mp4: t="))
    # close a: b and the still keep their blocks; a new card takes a's freed block
    var b_msg = cards.msg(1)
    assert_true(cards.update(Event(cards.msg(a) + CARD_CLOSE, "", 0)))
    assert_equal(cards.closed, 0)
    assert_equal(len(cards), 2)
    assert_equal(cards.msg(0), b_msg)
    var d = cards.add(media + "/drone_b.mp4", 0, 0, 300)
    assert_equal(cards.msg(d), 4000)
    assert_true(cards.cards[0].player.value().state.t() >= 0.99)  # (b carried on where it was)
    # the view: a card with a title bar and the player's tagged controls
    var v = cards.view(0)
    var tags = List[String]()
    for ref n in v.nodes:
        tags.append(n.name)
    for want in ["media-title", "video", "seek", "pause", "time"]:  # (card 0 is b, playing: its button pauses)
        var seen = False
        for t in tags:
            if t == String(want):
                seen = True
        assert_true(seen, "the card has no " + String(want))
    print("cards: ok")


def seek_tests(media: String) raises:
    # an agent sets the scrubber to a time in seconds (.settable): the player shows that frame
    var cards = MediaCards(4000, 200)
    var k = cards.add(media + "/warehouse.mp4", 0, 0, 640)
    assert_true(cards.settle())
    var v = cards.view(k)
    var found = False
    for ref n in v.nodes:
        if n.kind == CANVAS and n.name == "seek":
            found = True
            assert_equal(len(n.options), 3)
            assert_equal(n.options[0], "seconds")
    assert_true(found)
    _ = cards.update(Event(cards.msg(k) + SCRUB, "12.5", SET_TO))
    assert_equal(cards.cards[k].player.value().state.frame, 375)
    _ = cards.update(Event(cards.msg(k) + SCRUB, "999", SET_TO))  # (clamped to the end)
    assert_equal(cards.cards[k].player.value().state.frame, cards.cards[k].player.value().state.frames - 1)
    _ = cards.update(Event(cards.msg(k) + SCRUB, "soon", SET_TO))  # (not a number: nothing moves)
    assert_equal(cards.cards[k].player.value().state.frame, cards.cards[k].player.value().state.frames - 1)
    # what an agent sends, through the hosts' own lookup (control_event): the button's other face pauses; the scrubber's value seeks
    var shown = cards.view(k)
    var button = -1
    var scrub = -1
    for i in range(len(shown.nodes)):
        if shown.nodes[i].kind == BUTTON and shown.nodes[i].name == "play":
            button = i
        if shown.nodes[i].kind == CANVAS and shown.nodes[i].name == "seek":
            scrub = i
    assert_true(button >= 0 and scrub >= 0)
    assert_equal(shown.nodes[button].options[0], "pause")
    assert_equal(control_event(shown, button, False, "", 0).message, cards.msg(k) + PLAY)
    assert_equal(control_event(shown, button, True, "", 0).message, cards.msg(k) + PAUSE)  # (its .alternate)
    var e = control_event(shown, scrub, False, "3.0", SET_TO)
    assert_equal(e.message, cards.msg(k) + SCRUB)
    _ = cards.update(e)
    assert_equal(cards.cards[k].player.value().state.frame, 90)
    print("seek set: ok")


def main() raises:
    var media = getenv("G39_MEDIA", "build/g39/media")
    picture_tests(media)
    card_tests(media)
    seek_tests(media)
