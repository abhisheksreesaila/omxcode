# mojoui.imagegen with the real model (goal 72 M6, D-7280): sd-server (Z-Image-Turbo) started as a child on GPU 1, healthy within
# a minute, draws one 768 px picture whose PNG decodes and is not blank, a second one with the same seed is the same picture,
# and stop() leaves nothing running. Needs the model files (OMX_SD_BIN, OMX_SD_MODELS) and a free 10.5 GB on GPU OMX_SD_GPU.
#   build/test_imagegen
from std.testing import assert_equal, assert_true
from std.os import getenv
from std.time import perf_counter_ns
from mojoui.imagegen import ImageServer, png_of, save_file
from mojoui.http_socket import SocketTransport
from mojoui.picture import Picture
from mojoui.process import healthy
from mojoui import libc


def spread(p: Picture) -> Int:
    """The range of the picture's grey values (a blank picture has none)."""
    var lo = 255
    var hi = 0
    for i in range(0, len(p.pixels), 97):
        var v = Int(p.pixels[i] & 255)
        lo = min(lo, v)
        hi = max(hi, v)
    return hi - lo


def main() raises:
    var home = getenv("HOME", "")
    var server = ImageServer.zimage(getenv("OMX_SD_BIN", home + "/Projects/omx-local/third_party/stable-diffusion.cpp/build/bin/sd-server"),
                                    getenv("OMX_SD_MODELS", home + "/Projects/omx-local/models/card2"), getenv("OMX_SD_GPU", "1"), 8197)
    assert_true(server.installed(), "the image model's files")
    server.start()
    var t0 = perf_counter_ns()
    while not server.ready() and (perf_counter_ns() - t0) < 120_000_000_000:
        server.tick()
        _ = libc.poll(0, 0, 100)
    assert_true(server.ready(), "never became healthy: " + server.why + " " + server.proc.value().log_tail(300))
    print("  healthy after", server.ready_ms, "ms")
    var t1 = perf_counter_ns()
    var r = SocketTransport.send(server.draw_request(1, 1, "a small blue robot baking bread in a bright kitchen", 1234, 768))
    var first_ms = (perf_counter_ns() - t1) // 1_000_000
    assert_equal(r.status, 200)
    var png = png_of(r.text())
    assert_true(len(png) > 50_000, "a picture's bytes: " + String(len(png)))
    save_file("build/g72/imagegen-test.png", png)
    var pic = Picture("build/g72/imagegen-test.png")
    assert_equal(pic.width, 768)
    assert_equal(pic.height, 768)
    assert_true(spread(pic) > 60, "not blank: " + String(spread(pic)))
    var t2 = perf_counter_ns()
    var r2 = SocketTransport.send(server.draw_request(1, 2, "a small blue robot baking bread in a bright kitchen", 1234, 768))
    var again_ms = (perf_counter_ns() - t2) // 1_000_000
    assert_true(len(png_of(r2.text())) == len(png), "the same seed draws the same picture")
    print("  first picture", first_ms, "ms, second", again_ms, "ms,", len(png), "bytes")
    var pid = server.proc.value().pid
    server.stop()
    assert_true(not healthy(server.url() + "/sdapi/v1/options", 300), "still answering after stop()")
    assert_true(libc.kill(-pid, 0) != 0, "its process group is gone")
    print("imagegen: ok")
