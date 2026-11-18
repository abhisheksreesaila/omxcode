# mojoui.camera (goal 77 M6): the browser's end (the web hub, fed here the way hosts/web.py feeds it) and this machine's own camera.
#   pixi run python scripts/g77_scene.py           (once: build/g77/scene.jpg)
#   scripts/mxbuild.sh tests/test_camera.mojo -o build/test_camera && build/test_camera [web|desktop]
# The desktop case needs /dev/video0 (or $MOJOUI_CAMERA); without one it prints `camera desktop: BLOCKED …` and the web case alone decides.
from std.os import getenv
from std.os.path import exists
from std.sys import argv
from std.testing import assert_equal, assert_true
from mojoui.camera import Camera, CAM_OFF, CAM_STARTING, CAM_READY, CAM_FAILED
from mojoui.clock import now_ns
from mojoui.grounding import image_size
from mojoui.webcamera import camera_init, camera_wants, camera_request, camera_push, camera_fail, camera_frames
from mojoui import libc


def read_all(path: String) raises -> List[UInt8]:
    var f = open(path, "r")
    var b = f.read_bytes()
    f.close()
    return b^


def web() raises:
    var jpg = read_all("build/g77/scene.jpg")
    var none = Camera()  # (no hub yet: this would be a desktop camera)
    assert_equal(none.source(), "desktop")
    assert_true(camera_init() != 0, "the hub is made")
    assert_equal(camera_init(), 0)
    var cam = Camera()
    assert_equal(cam.source(), "browser")
    assert_equal(cam.state(), CAM_OFF)
    assert_equal(camera_wants(), 0)
    cam.start()
    assert_equal(camera_wants(), 1)  # (the host tells the page to open its camera)
    assert_equal(cam.state(), CAM_STARTING)
    assert_equal(camera_request(), 0)  # a stream nobody asked for isn't started: nothing is requested until snapshot()
    assert_true(not cam.tick(), "no frame before a snapshot")
    cam.snapshot()
    assert_equal(camera_request(), 1)
    assert_true(cam.waiting(), "waiting for the page's still")
    assert_true(not cam.tick(), "nothing has landed")
    # the page answers request 1 (hosts/web.py hands the frame over as it arrives)
    camera_push(Int(jpg.unsafe_ptr()), len(jpg), 1, 1280, 720)
    assert_true(cam.tick(), "the frame landed")
    assert_equal(len(cam.jpeg), len(jpg))
    for i in range(0, len(jpg), 997):
        assert_equal(cam.jpeg[i], jpg[i])
    assert_equal(cam.width, 1280)
    assert_equal(cam.height, 720)
    assert_equal(cam.state(), CAM_READY)
    assert_true(not cam.waiting(), "no longer waiting")
    assert_true(not cam.tick(), "a frame is taken once")
    # an older answer doesn't satisfy a newer request
    cam.snapshot()
    assert_equal(camera_request(), 2)
    assert_true(not cam.tick(), "frame 1 isn't the answer to request 2")
    camera_push(Int(jpg.unsafe_ptr()), len(jpg), 2, 1280, 720)
    assert_true(cam.tick(), "request 2 answered")
    assert_equal(cam.seq, 2)
    # a refusal says why
    var refused = Camera()
    refused.start()
    refused.snapshot()
    camera_fail(101)
    assert_true(not refused.tick(), "no frame")
    assert_equal(refused.state(), CAM_FAILED)
    assert_true(refused.problem.find("refused") >= 0, refused.problem)
    cam.stop()
    assert_equal(camera_wants(), 0)
    assert_equal(cam.state(), CAM_OFF)
    print("camera web: ok, a still lands only when asked for, once; refusal says so")


def desktop() raises:
    var dev = getenv("MOJOUI_CAMERA", "/dev/video0")
    if not exists(dev):
        print("camera desktop: BLOCKED no camera on this machine (" + dev + ")")
        return
    var cam = Camera()
    assert_equal(cam.source(), "desktop")
    cam.snapshot()
    var t0 = now_ns()
    var got = False
    while now_ns() - t0 < 8_000_000_000:
        if cam.tick():
            got = True
            break
        _ = libc.usleep(20000)
    assert_true(got, "a frame arrived: " + cam.problem)
    var first_ms = Float64(now_ns() - t0) / 1e6
    assert_true(len(cam.jpeg) > 5000 and cam.jpeg[0] == 255 and cam.jpeg[1] == 216, "a JPEG")
    var size = image_size(cam.jpeg)
    assert_true(size[0] >= 640 and size[1] >= 360, "its size " + String(size[0]) + "x" + String(size[1]))
    assert_equal(cam.width, size[0])
    # a snapshot is a frame written after the request, not the last one kept
    var asked = now_ns()
    cam.snapshot()
    var second = False
    var t1 = now_ns()
    while now_ns() - t1 < 4_000_000_000:
        if cam.tick():
            second = True
            break
        _ = libc.usleep(10000)
    assert_true(second, "a second frame")
    var again_ms = Float64(now_ns() - asked) / 1e6
    assert_true(cam.arrived_ns > asked, "the frame is newer than the request")
    var path = cam.path
    assert_true(exists(path), "the frame file is there while the camera runs")
    cam.stop()
    assert_true(not exists(path), "the frame file is deleted at stop()")
    print("camera desktop: ok,", size[0], "x", size[1], "JPEG of", len(cam.jpeg), "bytes; first frame after", first_ms, "ms (with the 1.3 s warm-up), a fresh one", again_ms, "ms after a request")


def main() raises:
    var which = String(argv()[1]) if len(argv()) > 1 else String("all")
    if which == "all" or which == "desktop":  # (first: a Camera made after the web hub exists is the browser's)
        desktop()
    if which == "all" or which == "web":
        web()
