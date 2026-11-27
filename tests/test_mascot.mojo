# mojoui.mascot: loads a real transparent PNG sprite-strip pack in pure Mojo, routes hub-and-spoke states and
# one-shot hype -> rest return, blends local (blue) vs cloud (warn) floor aura, responds to poke springs, and toggles
# cleanly with Orb via Presence.
#   pixi run mojo build -I . tests/test_mascot.mojo -o build/test_mascot && build/test_mascot

from std.testing import assert_equal, assert_true, assert_false
from mojoui.canvas import Surface
from mojoui.clock import now_ns
from mojoui.mascot import (
    Mascot, MascotClip, MascotTransition, MascotView, MascotPerch, Presence,
    MASCOT_REST, MASCOT_LISTEN, MASCOT_THINK, MASCOT_SPEAK, MASCOT_HYPE, MASCOT_NAP,
    PRESENCE_ORB, PRESENCE_MASCOT, PERCH_SIDE, mascot_state_id, mascot_state_name,
)
from mojoui.view import NO_MSG
from mojoui.theme import Palette


def opaque_count(buf: List[UInt32]) -> Int:
    var n = 0
    for v in buf:
        if (v >> 24) > 128:
            n += 1
    return n


def nonclear_count(buf: List[UInt32]) -> Int:
    var n = 0
    for v in buf:
        if (v >> 24) > 0:
            n += 1
    return n


def diff_count(a: List[UInt32], b: List[UInt32]) -> Int:
    var n = 0
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            n += 1
    return n


def main() raises:
    assert_equal(mascot_state_id("rest"), MASCOT_REST)
    assert_equal(mascot_state_id("idle"), MASCOT_REST)
    assert_equal(mascot_state_id("LISTEN"), MASCOT_LISTEN)
    assert_equal(mascot_state_id("think"), MASCOT_THINK)
    assert_equal(mascot_state_id("speak"), MASCOT_SPEAK)
    assert_equal(mascot_state_id("hype"), MASCOT_HYPE)
    assert_equal(mascot_state_id("nap"), MASCOT_NAP)
    assert_equal(mascot_state_name(MASCOT_HYPE), "hype")

    # 1. Load real Omx Spirit pack (lazy: only rest.png decoded at startup)
    var t0 = now_ns()
    var mascot = Mascot.load("examples/stage/mascots/omx")
    var load_ms = Float64(now_ns() - t0) / 1e6
    assert_true(mascot.ready)
    assert_equal(mascot.name, "Omx Spirit")
    assert_equal(mascot.current(), MASCOT_REST)
    assert_equal(mascot.loaded_frames(), 16)  # only rest.png decoded so far!

    var p = Palette.plain()
    var w = 220
    var h = 220
    var buf = List[UInt32](length=w * h, fill=0)
    var s = Surface(Int(buf.unsafe_ptr()), w, h, 1.0)

    # 2. Render REST frame onto transparent canvas and benchmark one frame
    var ft0 = now_ns()
    mascot.draw(s, p)
    var draw_ms = Float64(now_ns() - ft0) / 1e6
    assert_equal(buf[0], UInt32(0))  # top-left corner stays fully transparent
    assert_true(s.again, "companion asks for the next animation frame")
    var rest_px = opaque_count(buf)
    assert_true(rest_px > 4000 and rest_px < 36000, "mascot silhouette size: " + String(rest_px))
    var rest_snap = buf.copy()

    # Measure floor aura colour in local lane vs cloud lane (directly under feet, slightly off-center)
    var foot_y = Int(Float64(h) * mascot.anchor_y) + 2
    var aura_local = buf[foot_y * w + (w // 2 + 48)]
    assert_true((aura_local >> 24) > 5, "local ground aura is visible")

    mascot.lane(True)
    for _ in range(45):
        mascot.step(0.016)
    mascot.draw(s, p)
    var aura_cloud = buf[foot_y * w + (w // 2 + 48)]
    assert_true((aura_cloud >> 24) > 5, "cloud ground aura is visible")
    # Cloud warning tone is much redder than local blue accent
    var local_r = Int(aura_local & 0xFF)
    var cloud_r = Int(aura_cloud & 0xFF)
    assert_true(cloud_r > local_r + 25, "cloud lane shifts aura toward warm warning tone: " + String(local_r) + " -> " + String(cloud_r))
    mascot.lane(False)

    # 3. State switching + lazy strip decoding
    mascot.mode(MASCOT_THINK)
    assert_equal(mascot.current(), MASCOT_THINK)
    for _ in range(25):
        mascot.step(0.02)
    mascot.draw(s, p)
    assert_true(diff_count(rest_snap, buf) > 4000, "think pose renders distinctly from rest")
    assert_equal(mascot.loaded_frames(), 32)  # rest (16) + think (16)

    mascot.mode(MASCOT_LISTEN)
    for _ in range(20):
        mascot.step(0.02)
    mascot.draw(s, p)
    assert_true(opaque_count(buf) > 4000)

    mascot.mode(MASCOT_SPEAK)
    mascot.drive(0.8)
    for _ in range(20):
        mascot.step(0.02)
    mascot.draw(s, p)
    assert_true(opaque_count(buf) > 4000)

    mascot.mode(MASCOT_NAP)
    for _ in range(20):
        mascot.step(0.02)
    mascot.draw(s, p)
    assert_true(opaque_count(buf) > 4000)

    # 4. Tap / poke -> HYPE burst with spring velocity, then auto-return to REST when one-shot completes
    mascot.poke()
    assert_equal(mascot.current(), MASCOT_HYPE)
    assert_true(mascot.squash.velocity < -1.0, "poke injects squash velocity")
    assert_true(mascot.hop.velocity < -1.0, "poke injects hop velocity")
    # Hype is 14 frames @ 18 fps = 0.778s; stepping 0.95s returns automatically to REST
    for _ in range(50):
        mascot.step(0.02)
    assert_equal(mascot.current(), MASCOT_REST)

    # 5. Hub-and-spoke explicit transition routing: LISTEN -> (listen->rest) -> REST -> (rest->think) -> THINK
    var tiny = List[UInt32](length=8 * 4, fill=0xFF88CCFF)
    var router = Mascot()
    router.ready = True
    router.clips[MASCOT_REST] = MascotClip("", 8, 4, 4, 2, 10.0, True, -1, True, tiny.copy())
    router.clips[MASCOT_LISTEN] = MascotClip("", 8, 4, 4, 2, 10.0, True, -1, True, tiny.copy())
    router.clips[MASCOT_THINK] = MascotClip("", 8, 4, 4, 2, 10.0, True, -1, True, tiny.copy())
    router.transitions.append(MascotTransition(
        MASCOT_LISTEN, MASCOT_REST,
        MascotClip("", 8, 4, 4, 2, 10.0, False, MASCOT_REST, True, tiny.copy()),
    ))
    router.transitions.append(MascotTransition(
        MASCOT_REST, MASCOT_THINK,
        MascotClip("", 8, 4, 4, 2, 10.0, False, MASCOT_THINK, True, tiny^),
    ))
    router.mode(MASCOT_LISTEN)
    assert_equal(router.current(), MASCOT_LISTEN)
    router.mode(MASCOT_THINK)
    # Must route through listen->rest first, with THINK queued!
    assert_equal(router._in_transition, 0)
    assert_equal(router._queued_target, MASCOT_THINK)
    # Complete leg 1 (0.2s) -> should enter leg 2 (rest->think, index 1)
    for _ in range(12):
        router.step(0.02)
    assert_equal(router._in_transition, 1)
    assert_equal(router._queued_target, -1)
    # Complete leg 2 (0.2s) -> arrives in THINK
    for _ in range(12):
        router.step(0.02)
    assert_equal(router._in_transition, -1)
    assert_equal(router.current(), MASCOT_THINK)

    # 6. Pluggable Presence switcher: Orb <-> Mascot
    var pres = Presence()
    assert_equal(pres.kind, PRESENCE_ORB)
    assert_false(pres.toggle())  # no pack loaded yet -> stays Orb
    pres.draw(s, p)
    var orb_snap = buf.copy()
    pres.use_mascot("examples/stage/mascots/omx")
    assert_equal(pres.kind, PRESENCE_MASCOT)
    assert_true(pres.has_mascot())
    assert_true(pres.crossfading())  # (a switch crossfades: no snap)
    pres.draw(s, p)
    var start_snap = buf.copy()  # (the crossfade's first frame: still the orb, nothing jumps)
    pres.blend.snap(0.5)  # (mid-way: both are there)
    pres.blend.to(1.0)
    pres.draw(s, p)
    var mid_snap = buf.copy()
    s.still = True  # (less motion: the crossfade lands at once)
    pres.draw(s, p)
    s.still = False
    assert_false(pres.crossfading())
    assert_true(diff_count(orb_snap, buf) > 4000, "mascot renders differently from orb")
    assert_true(diff_count(mid_snap, buf) > 1000, "mid-crossfade is not yet the mascot")
    assert_true(diff_count(mid_snap, start_snap) > 1000, "mid-crossfade is no longer the orb")
    assert_false(pres.toggle())  # back to Orb
    assert_equal(pres.kind, PRESENCE_ORB)
    assert_true(pres.toggle())   # back to Mascot
    assert_equal(pres.kind, PRESENCE_MASCOT)

    # 7. View helper check
    var v_pass = MascotView(9, 1, side=172)
    assert_equal(v_pass.nodes[0].size, 2)  # passthrough when no gesture
    var v_tap = MascotView(9, 1, side=172, on_gesture=42, hover=True)
    assert_equal(v_tap.nodes[0].msg, 42)
    assert_equal(v_tap.nodes[0].size, 3)   # interactive when gesture set, and see-through (its alpha kept on every host, D-8426)

    # 8. The perch (D-8421): a wide window shows the mascot full-size on its perch while the chat bar keeps the orb (never two
    # mascots); it grows in and fades out on a spring; a phone puts it back in the chat bar
    var seat = Presence()
    seat.load_mascot("examples/stage/mascots/omx")
    assert_false(seat.perch_shown())
    seat.arrange(False, True)  # (wide: perched, the chat bar the orb)
    assert_true(seat.perched)
    assert_equal(seat.kind, PRESENCE_ORB)
    assert_true(seat.perch_shown())
    var pw = 184
    var pbuf = List[UInt32](length=pw * pw, fill=0)
    var ps = Surface(Int(pbuf.unsafe_ptr()), pw, pw, 1.0)
    seat.draw_perch(ps, p)  # (its first frame: arriving from nothing)
    var first = opaque_count(pbuf)
    assert_true(first < 2000, "the perch starts from nothing (no snap in): " + String(first))
    for _ in range(9):  # (some 70 ms on: part way in)
        seat.perch.step(8000)
    seat.perch_ns = 0
    seat.draw_perch(ps, p)
    var part = nonclear_count(pbuf)
    assert_true(part > 0, "part way in, it shows")
    seat.perch.snap(1.0)
    seat.draw_perch(ps, p)
    var full = opaque_count(pbuf)
    assert_true(full > 6000, "the perched mascot, full-size: " + String(full))
    seat.arrange(True, False)  # (a phone: the mascot moves into the chat bar, the perch leaves)
    assert_false(seat.perched)
    assert_equal(seat.kind, PRESENCE_MASCOT)
    assert_true(seat.perch_shown(), "still leaving: the view keeps it until it has gone")
    var calm = Surface(Int(pbuf.unsafe_ptr()), pw, pw, 1.0)
    calm.still = True  # (less motion: it has gone at once)
    seat.draw_perch(calm, p)
    assert_false(seat.perch_shown())
    assert_equal(nonclear_count(pbuf), 0)
    seat.arrange(False, False)  # (the orb: no perch, the orb in the bar)
    assert_equal(seat.kind, PRESENCE_ORB)
    var bare = Presence()  # (no pack: never perched)
    bare.arrange(False, True)
    assert_false(bare.perched)
    var perch_view = MascotPerch(9, 1, on_gesture=42)
    assert_equal(perch_view.nodes[0].name, "mascot-perch")
    var found = False
    for n in perch_view.nodes:
        if n.name == "mascot" and n.msg == 42 and n.w == PERCH_SIDE:
            found = True
    assert_true(found, "the perch's canvas: full-size and pokeable")
    var leaving_view = MascotPerch(9, 1, on_gesture=NO_MSG)
    for n in leaving_view.nodes:
        if n.name == "mascot":
            assert_equal(n.size, 2)  # (passthrough while it leaves)

    print("mascot: ok (load rest.png:", load_ms, "ms, draw 220x220:", draw_ms, "ms, rest opaque:", rest_px, "px)")
