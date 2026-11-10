# The globe with no window: render pictures of it on a GPU node (a batch job, a map server's back end).
#   pixi run mojo build -I examples/globe -I . examples/globe/render.mojo -o build/globe-render
#   build/globe-render --out globe.png [--size 1920x1080] [--lon -30] [--lat 25] [--zoom 1] [--hour 14.5]
#                      [--layers 15] [--frames 24] [--spin 2]   (frames: a day, one picture per step, globe-000.png …;
#                      spin: degrees the view turns east each frame)
# Prints what it did as JSON lines, with the GPU's time per picture.

from mojoui.gpu import Gpu
from mojoui.png import encode_png
from mojoui.clock import now_ns
from mojoui.shared import arguments
from earth import world, globe, Knobs8, DEG, WORDS, LAYER_FLIGHTS, LAYER_SUN, LAYER_GRID, LAYER_LIGHTS
from std.math import log, floor


def flag(name: String, fallback: String) -> String:
    var args = arguments()
    for i in range(len(args) - 1):
        if String(args[i]) == name:
            return String(args[i + 1])
    return fallback


def number(name: String, fallback: Float64) -> Float64:
    try:
        return Float64(flag(name, String(fallback)))
    except:
        return fallback


def main() raises:
    var size = flag("--size", "1920x1080")
    var parts = size.split("x")
    var w = Int(parts[0])
    var h = Int(parts[1])
    var out = flag("--out", "globe.png")
    var frames = Int(number("--frames", 1))
    var t0 = now_ns()
    var data = List[UInt32](length=WORDS, fill=0)
    var built = world(data)
    var gpu = Gpu()
    var busiest = built.busiest
    gpu.set_data(data^)
    var ready = Float64(now_ns() - t0) / 1e6
    print('{"device": "' + gpu.name + '", "reports": ' + String(built.reports) + ', "data_ms": ' + String(Int(ready)) + "}")
    for f in range(frames):
        var hour = number("--hour", 14.5)
        hour = hour - 24.0 * floor(hour / 24.0)  # (the cube has 24 slices)
        if frames > 1:
            hour = 24.0 * Float64(f) / Float64(frames)
        var k = Knobs8(
            Float32((number("--lon", -30) + number("--spin", 0) * Float64(f)) / DEG), Float32(number("--lat", 25) / DEG),
            Float32(0.42 * Float64(min(w, h)) * number("--zoom", 1)), Float32(hour),
            Float32(Int(number("--layers", Float64(LAYER_FLIGHTS | LAYER_SUN | LAYER_GRID | LAYER_LIGHTS)))),
            Float32(1.0 / log(1.0 + Float64(busiest))), Float32(-16.5 / DEG), Float32(1),
        )
        var pic = gpu.render_with[globe](w, h, k)
        var name = out
        if frames > 1:
            var n = String(f)
            while n.byte_length() < 3:
                n = "0" + n
            name = out.replace(".png", "-" + n + ".png")
        var png = encode_png(pic.pixels, w, h)
        with open(name, "w") as file:
            file.write_bytes(Span(unsafe_ptr=png.unsafe_ptr(), length=len(png)))
        print('{"file": "' + name + '", "hour": ' + String(hour) + ', "gpu_ms": ' + String(pic.milliseconds) + "}")
