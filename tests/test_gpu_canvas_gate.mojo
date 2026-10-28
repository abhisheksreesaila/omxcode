# Goal 36b review item 1: only an app that declares a GPU canvas (App.GPU_CANVAS) lets the host probe for CUDA↔GL and
# switch GTK's renderer and the GPU device; any other app keeps GTK's renderer and its environment untouched.
# Run: pixi run mojo run -I . tests/test_gpu_canvas_gate.mojo
from std.testing import assert_equal, assert_true, assert_false
from std.ffi import external_call, c_int
from std.os import getenv
from mojoui.present import Presenter, gpu_canvas_gate


def setenv(name: String, value: String):
    var n = name
    var v = value
    _ = external_call["setenv", c_int](n.as_c_string_span(), v.as_c_string_span(), c_int(1))


def unsetenv(name: String):
    var n = name
    _ = external_call["unsetenv", c_int](n.as_c_string_span())


def main() raises:
    unsetenv("GSK_RENDERER")
    unsetenv("MOJOUI_GPU_DEVICE")
    unsetenv("MOJOUI_CANVAS_GPU")
    var pr = Presenter()
    assert_false(gpu_canvas_gate(False, pr), "an app without a GPU canvas is never probed")
    assert_true(pr.why.find("GPU_CANVAS") >= 0, pr.why)
    assert_equal(getenv("GSK_RENDERER"), "", "GTK's renderer untouched")
    assert_equal(getenv("MOJOUI_GPU_DEVICE"), "", "the GPU device untouched")
    print("  no GPU canvas declared: " + pr.why + "; GSK_RENDERER and MOJOUI_GPU_DEVICE unset")
    var on = Presenter()
    assert_true(gpu_canvas_gate(True, on), "a GPU-canvas app is probed")
    setenv("MOJOUI_CANVAS_GPU", "0")
    var off = Presenter()
    assert_false(gpu_canvas_gate(True, off))
    assert_true(off.why.find("turned off") >= 0)
    unsetenv("MOJOUI_CANVAS_GPU")
    setenv("GSK_RENDERER", "vulkan")
    var vk = Presenter()
    assert_false(gpu_canvas_gate(True, vk))
    assert_equal(getenv("GSK_RENDERER"), "vulkan", "a renderer someone chose is kept")
    print("  declared: probed; MOJOUI_CANVAS_GPU=0 or GSK_RENDERER=vulkan: not (" + vk.why + ")")
    print("gpu canvas gate: ok")
