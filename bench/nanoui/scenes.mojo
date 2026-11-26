# nanoui's hill-climb scenes (github.com/justrach/nanoui, hillclimb/src/scenes.zig) drawn by omxcode's GPU 2D renderer
# (mojoui.gpu2d + the GL backend), headless (EGL device platform, no window), so the two can be raced on one machine.
# Same rules as nanoui's harness: 900×640 points at 2x, 30 warm-up frames, 300 measured, 3 runs, the run with the
# lowest median frame kept; every frame changes what it shows. Both sides first draw 300 ms of frames unmeasured (the
# GPU's clocks fall while nothing draws, goal 80).
#
#   frame CPU = building the frame's Scene (the app's drawing code, positions computed by hand: mojoui has no layout
#               engine, ROADMAP decision 10) + fill_batches + merge_runs (the renderer's CPU side)
#   GPU       = GL2D.render (upload + draws + resolve) + glFinish, wall time
#   cpu raster= execute_cpu: the same frame drawn by the CPU executor (single thread)
#
# Shadows are Gaussian (Painter.shadow, goal 80 M4) with nanoui's own colours, blurs and offsets.
# Held-out scenes (goal 80: ours, never the rival's; they must not regress while the race is worked on): whiteboard,
# canvas (Personal Note's seeded 645-object note), mindmap (200 topics), document (wrapped paragraphs in several faces and
# scripts, scrolled), table (10 000 rows × 6 columns, scrolled). Each frame pans or scrolls, as the app redraws it.
#   pixi run mojo run -I . bench/nanoui/scenes.mojo [scene ...]   (HC_SHOT=dir writes the last frame, PNG)
# Prints a table, and one `RESULT {json}` line per scene (docs/goals/80-check.py reads those).
from std.math import sin
from std.time import perf_counter_ns
from std.os import getenv
from std.sys import argv

from mojoui.canvas import Surface, rgba
from mojoui.text import Font
from mojoui.scene import Scene
from mojoui.gpu2d import GlyphAtlas, Frame2D, fill_batches, execute_cpu
from mojoui.gpu2d_merge import merge_runs
from mojoui.gpu2d_gl import GL2D, headless_gl33, gl_proc, B_QUAD, B_GLYPH
from mojoui.present import fcall
from std.ffi import c_uint, c_int
from mojoui.png import encode_png
from mojoui.fonttext import measure
from mojoui.ink import Stroke
from mojoui.objectlayer import ObjectLayer
from mojoui.mindmap import MindMap, MapView
from tests.test_gpu2d import Rng, mindmap_of
from tests.test_objectlayer import seeded_note
from mojoui.fonttext import TextStyle, ALIGN_LEFT, ALIGN_RIGHT

comptime W = 900
comptime H = 640
comptime K = 2.0
comptime PW = 1800
comptime PH = 1280
comptime WARMUP = 30
comptime FRAMES = 300
comptime REPEAT = 3
comptime FAMILY = "Noto Sans"
comptime BG = 0  # set in main (rgba isn't comptime)


def hsl(h: Float64) -> UInt32:
    var sat = 0.7
    var l = 0.55
    var a = sat * min(l, 1 - l)

    def f(n: Float64, hh: Float64, a: Float64, l: Float64) -> Int:
        var kk = (n + hh / 30) % 12
        var v = l - a * max(-1.0, min(min(kk - 3, 9 - kk), 1.0))
        return Int(v * 255 + 0.5)

    return rgba(f(0, h, a, l), f(8, h, a, l), f(4, h, a, l))


def fmod(x: Float64, m: Float64) -> Float64:
    return x - m * Float64(Int(x / m)) if x >= 0 else x - m * (Float64(Int(x / m)) - 1)


def boxes(mut sc: Scene, frame: Int, t: Float64):
    var shadow = rgba(0, 0, 0, 51)  # (nanoui's: black at 0.2, blur 4, 2 down)
    for r in range(20):
        for col in range(30):
            var i = Float64(r * 30 + col)
            var x = 10.0 + Float64(col) * 28
            var y = 10.0 + Float64(r) * 28 + 6 * sin(t * 3 + i * 0.1)
            sc.shadow(x, y + 2, 24, 24, 6, 4, shadow)
            sc.rect(x, y, 24, 24, hsl(fmod(t * 60 + i * 3, 360)), 6)


def text(mut sc: Scene, frame: Int, t: Float64):
    var st = TextStyle(FAMILY, 400, False, 13)
    var ink = rgba(29, 29, 31)
    for r in range(15):
        for col in range(20):
            var i = r * 20 + col
            sc.run(st, String((frame * 7 + i * 13) % 10000), 10.0 + Float64(col) * 44, 10.0 + Float64(r) * 24 + 13, ink, ALIGN_LEFT)


def row(mut sc: Scene, i: Int, y: Float64):
    var ink = rgba(29, 29, 31)
    sc.run(TextStyle(FAMILY, 400, False, 13), "Row " + String(i) + " — a line of a long list", 12, y + 18.5, ink, ALIGN_LEFT)
    sc.run(TextStyle(FAMILY, 400, False, 12), String(i * 7 % 100), Float64(W) - 12, y + 18.5, ink, ALIGN_RIGHT)


def scroll(mut sc: Scene, frame: Int, t: Float64):
    """A plain column of 1000 rows, clipped, moving every frame: every row is drawn, as nanoui's scene lays out all
    1000 (the renderer, not the app, decides what the clip hides)."""
    var offset = fmod(t * 600, 28.0 * 1000 - 640)
    sc.push_clip(0, 0, Float64(W), Float64(H))
    for i in range(1000):
        row(sc, i, Float64(i) * 28 - offset)
    sc.pop_clip()


def list(mut sc: Scene, frame: Int, t: Float64):
    """A virtual list of 100 000 rows scrolled to another row each frame: only the rows in view are drawn."""
    var first = (frame * 3) % (100_000 - 40)
    for k in range(H // 28 + 1):
        row(sc, first + k, Float64(k) * 28)


def dashboard(mut sc: Scene, frame: Int, t: Float64):
    var ink = rgba(29, 29, 31)
    var white = rgba(255, 255, 255)
    var shadow = rgba(0, 0, 0, 31)  # (nanoui's: black at 0.12, blur 16, 4 down)
    var track = rgba(0xE0, 0xE0, 0xE5)
    var blue = rgba(0x0A, 0x84, 0xFF)
    for r in range(3):
        for col in range(4):
            var i = r * 4 + col
            var v = 0.5 + 0.5 * sin(t * 2 + Float64(i))
            var x = 16.0 + Float64(col) * 212
            var y = 16.0 + Float64(r) * 142
            sc.shadow(x, y + 4, 200, 130, 12, 16, shadow)
            sc.rect(x, y, 200, 130, white, 12)
            sc.run(TextStyle(FAMILY, 400, False, 13), "Metric " + String(i), x + 14, y + 28, ink, ALIGN_LEFT)
            sc.run(TextStyle(FAMILY, 700, False, 28), String(Int(v * 1000)), x + 14, y + 70, ink, ALIGN_LEFT)
            sc.rect(x + 14, y + 86, 172, 6, track, 3)
            sc.rect(x + 14, y + 86, 172 * v, 6, blue, 3)
            sc.run(TextStyle(FAMILY, 400, False, 11), "updated " + String(frame % 60) + "s ago", x + 14, y + 113, ink, ALIGN_LEFT)


comptime RACE = ["boxes", "text", "scroll", "list", "dashboard"]
comptime HELD = ["whiteboard", "canvas", "mindmap", "document", "table"]


struct Held(Movable):
    """What the held-out scenes keep between frames, as their apps do: stroke outlines, the note, the map, the
    document's wrapped lines."""

    var strokes: List[List[Float64]]
    var colors: List[UInt32]
    var note: ObjectLayer
    var map: MindMap
    var lines: List[String]
    var styles: List[TextStyle]
    var ys: List[Float64]  # each line's top, layout px (line pitch 1.4 × its size)

    def __init__(out self, font: Font):
        self.strokes = List[List[Float64]]()
        self.colors = List[UInt32]()
        var rng = Rng(75)
        var palette: List[UInt32] = [0xFF222222, 0xFFB0602A, 0xFF2A60B0, 0xE02A9040]
        for i in range(200):
            var s = Stroke(1.5 + rng.real(0, 5), palette[i % 4])
            var x = rng.real(0, 1000)
            var y = rng.real(0, 700)
            var dx = rng.real(-1, 1)
            var dy = rng.real(-1, 1)
            var n = 20 + Int(rng.real(0, 60))
            for k in range(n):
                dx += rng.real(-0.4, 0.4)
                dy += rng.real(-0.4, 0.4)
                x += dx * 3
                y += dy * 3
                s.add(x, y, 0.3 + 0.7 * abs(sin(Float64(k) * 0.15)))
            self.strokes.append(s.outline())
            self.colors.append(s.color)
        self.note = seeded_note()
        self.map = mindmap_of(200)
        self.lines = List[String]()
        self.styles = List[TextStyle]()
        self.ys = List[Float64]()
        var faces: List[String] = ["Geist", "Source Serif 4", "IBM Plex Sans", "Literata"]
        var paras: List[String] = [
            "The renderer turns a display list into a few instanced draws: rectangles, glyphs, images and polygons, each with its own pipeline and a clip.",
            "Text is shaped once, kept, and placed from a glyph atlas at device pixels, so a zoomed page stays sharp instead of scaling a bitmap.",
            "नमस्ते दुनिया — हिंदी में एक पंक्ति, 漢字とかな交じりの文, 한국어 문장 하나, and a few words in English to mix the scripts on one line.",
            "Numbers change every frame in a live table: 1,204.50, 98.6 %, 3 × 7 = 21, and dates like 2026-11-22 shift as the data moves.",
        ]
        for i in range(160):
            var st = TextStyle(faces[i % 4], 700 if i % 9 == 0 else 400, i % 13 == 5, 22.0 if i % 9 == 0 else 15.0)
            var words = paras[i % 4].split(" ")
            var line = String()
            for w in words:
                var cand = String(w) if line == "" else line + " " + String(w)
                if measure(st, cand) > 840 and line != "":
                    self.lines.append(line)
                    self.styles.append(st)
                    line = String(w)
                else:
                    line = cand
            if line != "":
                self.lines.append(line)
                self.styles.append(st)
        var y = 0.0
        for i in range(len(self.lines)):
            self.ys.append(y)
            y += self.styles[i].size * 1.4
        self.ys.append(y)


def held_scene(which: String, frame: Int, t: Float64, mut sc: Scene, mut held: Held, font: Font):
    var ink = rgba(29, 29, 31)
    if which == "whiteboard":
        sc.begin_layer("ink")
        sc.layer_transform((-40 - 30 * sin(t)) * K, -25 * K, 0.9 * K)
        for i in range(len(held.strokes)):
            sc.polygon(held.strokes[i], held.colors[i])
    elif which == "canvas":
        var k = 0.45 * K
        sc.begin_layer("note")
        held.note.paint(sc, font, 20 + 200 * sin(t), 30, Float64(PW) / k, Float64(PH) / k, k)
    elif which == "mindmap":
        sc.begin_layer("map")
        held.map.paint(sc, font, MapView(Float64(PW) / 2 + 120 * sin(t), Float64(PH) / 2, 0.8 * K))
    elif which == "document":
        var y0 = fmod(t * 600, held.ys[len(held.lines)] - Float64(H))
        var k = 0
        while held.ys[k + 1] < y0:
            k += 1
        while k < len(held.lines) and held.ys[k] < y0 + Float64(H):
            sc.run(held.styles[k], held.lines[k], 30, held.ys[k] - y0 + held.styles[k].size * 1.1, ink, ALIGN_LEFT)
            k += 1
    else:  # table
        var first = (frame * 3) % (10_000 - 40)
        var grid = rgba(220, 220, 226)
        var zebra = rgba(250, 250, 252)
        var st = TextStyle(FAMILY, 400, False, 12)
        for k in range(H // 24 + 1):
            var r = first + k
            var y = Float64(k) * 24
            if r % 2 == 1:
                sc.rect(0, y, Float64(W), 24, zebra, 0)
            sc.rect(0, y + 23, Float64(W), 1, grid, 0)
            sc.run(st, String(r), 12, y + 16, ink, ALIGN_LEFT)
            for c in range(1, 6):
                var x = Float64(c) * 150
                sc.rect(x, y, 1, 24, grid, 0)
                var v = (r * 7919 + c * 104729 + frame * 31) % 1_000_000
                sc.run(st, String(v // 100) + "." + String(v % 100), x + 138, y + 16, ink, ALIGN_RIGHT)


def build(which: String, frame: Int, mut held: Held, font: Font) -> Scene:
    var t = Float64(frame) / 120
    var sc = Scene(PW, PH, K)
    sc.begin_layer("ui")
    sc.layer_transform(0, 0, K)
    sc.fill(rgba(245, 245, 247) if which != "canvas" and which != "mindmap" and which != "whiteboard" else rgba(255, 255, 255))
    if which == "boxes":
        boxes(sc, frame, t)
    elif which == "text":
        text(sc, frame, t)
    elif which == "scroll":
        scroll(sc, frame, t)
    elif which == "list":
        list(sc, frame, t)
    elif which == "dashboard":
        dashboard(sc, frame, t)
    else:
        held_scene(which, frame, t, sc, held, font)
    return sc^


struct Stamps(Movable):
    """GL timestamp queries (glQueryCounter, core GL 3.3) at the frame's stage boundaries: start, after the uploads,
    after the draws, after the resolve. Read after glFinish."""

    var ids: List[UInt32]
    var counter: Int
    var get: Int

    def __init__(out self):
        self.ids = List[UInt32](length=4, fill=0)
        self.counter = gl_proc("glQueryCounter")
        self.get = gl_proc("glGetQueryObjectui64v")
        fcall[NoneType](gl_proc("glGenQueries"), c_int(4), Int(self.ids.unsafe_ptr()))

    def mark(self, i: Int):
        fcall[NoneType](self.counter, c_uint(self.ids[i]), c_uint(0x8E28))  # GL_TIMESTAMP

    def ms(self, i: Int, j: Int) -> Float64:
        var a = List[UInt64](length=2, fill=0)
        fcall[NoneType](self.get, c_uint(self.ids[i]), c_uint(0x8866), Int(a.unsafe_ptr()))  # GL_QUERY_RESULT
        fcall[NoneType](self.get, c_uint(self.ids[j]), c_uint(0x8866), Int(a.unsafe_ptr()) + 8)
        return Float64(Int(a[1]) - Int(a[0])) / 1e6


def median(mut v: List[Float64]) -> Float64:
    sort(v)
    return v[len(v) // 2]


def p95(mut v: List[Float64]) -> Float64:
    sort(v)
    return v[min(len(v) - 1, Int(Float64(len(v)) * 0.95))]


def run_scene(which: String, mut gl: GL2D, atlas: GlyphAtlas, font: Font, tex: Int, mut held: Held) raises -> List[Float64]:
    """One run: [frame CPU median, p95, scene build median, batches median, GPU median, GPU p95, instances]."""
    var built = Frame2D()
    var f = Frame2D()
    var frame_ms = List[Float64]()
    var build_ms = List[Float64]()
    var batch_ms = List[Float64]()
    var gpu_ms = List[Float64]()
    var up_ms = List[Float64]()
    var draw_ms = List[Float64]()
    var res_ms = List[Float64]()
    var stamps = Stamps()
    var ops = 0
    # (goal 80) the GPU drops to idle clocks while nothing draws (the CPU raster between scenes): 300 ms of frames first,
    # unmeasured, so every run starts at the clocks the work keeps it at. glrun.zig does the same for nanoui.
    var warm0 = perf_counter_ns()
    var wi = 0
    while perf_counter_ns() - warm0 < 300_000_000:
        var sc = build(which, wi, held, font)
        fill_batches(built, sc, atlas, font)
        merge_runs(built, f)
        _ = gl.render(f, tex, PW, PH)
        gl.finish()
        wi += 1
    for i in range(WARMUP + FRAMES):
        var t0 = perf_counter_ns()
        var sc = build(which, i, held, font)
        var t1 = perf_counter_ns()
        fill_batches(built, sc, atlas, font)
        merge_runs(built, f)
        var t2 = perf_counter_ns()
        if not gl.render(f, tex, PW, PH):
            raise Error("render: " + gl.why)
        gl.finish()
        var t3 = perf_counter_ns()
        if i >= WARMUP and i % 10 == 0:  # (every 10th frame again, in stages, timestamped on the GPU: the split)
            stamps.mark(0)
            gl.sync_pages()
            _ = gl.begin(tex, PW, PH)
            gl.stream(0, B_QUAD, f.quads)
            gl.stream(0, B_GLYPH, f.glyphs)
            gl.plan_polys(f, 0)
            stamps.mark(1)
            gl.layer(f, 0, False)
            stamps.mark(2)
            _ = gl.end(tex, PW, PH)
            stamps.mark(3)
            gl.finish()
            up_ms.append(stamps.ms(0, 1))
            draw_ms.append(stamps.ms(1, 2))
            res_ms.append(stamps.ms(2, 3))
        if i >= WARMUP:
            frame_ms.append(Float64(t2 - t0) / 1e6)
            build_ms.append(Float64(t1 - t0) / 1e6)
            batch_ms.append(Float64(t2 - t1) / 1e6)
            gpu_ms.append(Float64(t3 - t2) / 1e6)
        ops = 0
        for r in f.runs:
            ops += r.count
    var fm = frame_ms.copy()
    var gm = gpu_ms.copy()
    return [median(frame_ms), p95(fm), median(build_ms), median(batch_ms), median(gpu_ms), p95(gm), Float64(ops), median(up_ms), median(draw_ms),
            median(res_ms)]


def cpu_raster_ms(which: String, atlas: GlyphAtlas, font: Font, mut held: Held) raises -> Float64:
    """The CPU executor drawing the same frames (60 measured after 10: it is the slow path)."""
    var px = List[UInt32](length=PW * PH, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), PW, PH, K)
    var built = Frame2D()
    var times = List[Float64]()
    for i in range(70):
        var sc = build(which, i, held, font)
        fill_batches(built, sc, atlas, font)
        var t0 = perf_counter_ns()
        execute_cpu(built, atlas, s)
        if i >= 10:
            times.append(Float64(perf_counter_ns() - t0) / 1e6)
    _ = len(px)
    return median(times)


def r3(v: Float64) -> String:
    return String(round(v, 4))


def main() raises:
    var names = List[String]()
    var args = argv()
    for i in range(1, len(args)):
        names.append(String(args[i]))
    if len(names) == 0:
        for n in materialize[RACE]():
            names.append(n)
        for n in materialize[HELD]():
            names.append(n)
    var ctx = headless_gl33()
    if ctx == 0:
        raise Error("no headless GL 3.3 context")
    var gl = GL2D()
    if not gl.start(False):
        raise Error("GL2D.start: " + gl.why)
    print("omxcode gpu2d ·", gl.why, "·", FRAMES, "frames after", WARMUP, "of warm-up ·", W, "×", H, "at", K, "x · headless")
    var font = Font()
    var atlas = GlyphAtlas(font)
    gl.upload_atlas(atlas)
    var held = Held(font)
    var tex = gl.make_texture(PW, PH)
    print("scene      frameCPU  p95     build   batches GPU     GPUp95  cpuRaster instances")
    for n in names:
        var best = run_scene(n, gl, atlas, font, tex, held)
        for _ in range(REPEAT - 1):
            var r = run_scene(n, gl, atlas, font, tex, held)
            if r[0] < best[0]:
                best = r^
        var raster = cpu_raster_ms(n, atlas, font, held)
        print(n, "\t", r3(best[0]), "\t", r3(best[1]), "\t", r3(best[2]), "\t", r3(best[3]), "\t", r3(best[4]), "\t", r3(best[5]), "\t", r3(raster), "\t", Int(best[6]))
        print("RESULT {\"scene\": \"" + n + "\", \"frame_med\": " + r3(best[0]) + ", \"frame_p95\": " + r3(best[1]) + ", \"gpu_med\": "
              + r3(best[4]) + ", \"gpu_p95\": " + r3(best[5]) + ", \"raster_med\": " + r3(raster) + ", \"instances\": " + String(Int(best[6]))
              + ", \"gpu_upload\": " + r3(best[7]) + ", \"gpu_draw\": " + r3(best[8]) + ", \"gpu_resolve\": " + r3(best[9]) + "}")
        var shot = getenv("HC_SHOT")
        if shot != "":
            var px = List[UInt32](length=PW * PH, fill=0)
            _ = gl.read(tex, PW, PH, Int(px.unsafe_ptr()))
            with open(shot + "/omx-" + n + ".png", "w") as fh:
                fh.write_bytes(encode_png(px, PW, PH))
    gl.delete(17, tex)
