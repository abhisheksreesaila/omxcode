# The GPU 2D renderer's Metal backend (goal 75 M3): mojoui.gpu2d's Frame2D (layers of runs over flat instance lists)
# drawn by Metal on the Mac, through the Objective-C runtime (no Swift, no Objective-C compiler, nothing linked: Metal is
# opened at run time, so a Mac without it simply says why and the host keeps its CPU path).
#
#   var mtl = Metal2D(atlas)                      # once: device, queue, shaders compiled, pipelines built, atlas uploaded
#   if mtl.ok: _ = mtl.render(frame, iosurface, w, h)   # a whole frame: the picture lands in that IOSurface, finished
#   MetalCanvas2D.render_scene(…)                 # a host's path: layers kept on the GPU while they don't change
#
# Each frame: one render pass with two attachments, the picture (an IOSurface-backed BGRA texture the AppKit host shows
# as a layer's contents: Core Animation reads the same memory, no copy) and a polygon accumulator (R32Float, memoryless:
# it lives in the GPU's tile memory, never in RAM). Layers set their transform as a uniform; runs are instanced draws
# (base instance = the run's first) of six pipelines built at start:
#   quad_over / quad_replace   SDF rounded boxes and capsules (gpu2d's coverage formulas, at the pixel centre)
#   glyph                      R8 atlas texture, the same bilinear sampling and 2×2 supersampling rule as execute_cpu
#   image                      nearest, from the frame's pixels (one buffer, an offset per image), blending off
#   tri + cover                a polygon: each fan triangle adds its exact coverage on gpu2d's four scan lines per pixel
#                              row into the accumulator (signed, so the fan sums to the winding), then the cover blends
#                              the colour by min(|sum|, 1) and zeroes the accumulator (programmable blending, D-7534)
# Everything is analytic at the pixel, so there's no multisampling: the picture matches execute_cpu to a fraction of a
# level. Blending is gpu2d's BLEND_OVER: src·a + dst·(1 − a) on RGB, the destination's alpha kept. Each render waits for
# its command buffer (D-7532): the picture is complete when the host hands the IOSurface over, nothing is in flight
# between frames, and a thread blocked on the GPU keeps macOS running the GPU fast (returning at "scheduled" instead let
# the GPU's clock drop: whiteboard zoom 0.8 → 2.5 ms of GPU work a frame). blocked_ms says how long the wait
# took; gpu_ms how much of it the GPU worked.

from std.ffi import external_call
from std.memory import Pointer
from mojoui.hosts.objc import cls, sel, msg, ns_string, from_ns, pool_push
from mojoui.hosts.apple_canvas import cfunc
from mojoui.text import Font
from mojoui.clock import now_ns
from std.os import getenv
from mojoui.scene import Scene, OP_TEXT, OP_FILL, OP_IMAGE, OP_CLIP, OP_UNCLIP
from mojoui.gpu2d import GlyphAtlas, Frame2D, fill_layers, PIPE_QUAD, PIPE_GLYPH, PIPE_POLY, POLY_FLOATS, BLEND_REPLACE
from mojoui.gpu2d_merge import merge_runs, append_frame

comptime RTLD_DEFAULT = -2
comptime PF_BGRA8 = 80  # MTLPixelFormatBGRA8Unorm (the IOSurface's 'BGRA')
comptime PF_R8 = 10  # MTLPixelFormatR8Unorm
comptime PF_ACC = 55  # MTLPixelFormatR32Float: the polygon accumulator
comptime MODE_OVER = 0  # pipelines: blended over (gpu2d BLEND_OVER)
comptime MODE_REPLACE = 1  # written as they are (BLEND_REPLACE)
comptime MODE_ACCUMULATE = 2  # a polygon's triangles: coverage added into the accumulator
comptime MODE_COVER = 3  # a polygon's cover: reads the picture and the accumulator, blends, zeroes the accumulator
comptime PRIM_STRIP = 4

# buffer slots (the same index in the vertex and fragment stages)
comptime B_QUADS = 0
comptime B_UNIFORM = 1  # (setVertexBytes: the layer's transform and the target size)
comptime B_GLYPHS = 2
comptime B_IMAGES = 3
comptime B_POLYS = 4
comptime B_FAN = 5
comptime B_PIXELS = 6
comptime B_OFFSETS = 7
comptime B_TRIS = 8  # (PolyPlan: the fan triangles of each polygon group, in group order)
comptime B_COVERS = 9  # (PolyPlan: the polygons of each group)
comptime BUFFERS = 10

comptime MSL = """
#include <metal_stdlib>
using namespace metal;

struct U { float2 view; float2 t; float k; float pad0; float2 pad1; };
struct VOut { float4 pos [[position]]; uint iid [[flat]]; };

constant float NO_CLIP_HALF = 5.0e29;

inline float4 ndc(float2 p, constant U& u) { return float4(p.x / u.view.x * 2.0 - 1.0, 1.0 - p.y / u.view.y * 2.0, 0.0, 1.0); }
inline float2 xf(float2 p, constant U& u) { return p * u.k + u.t; }
inline float2 corner(uint vid) { return float2(float(vid & 1u), float(vid >> 1)); }

// a pixel is drawn only when its centre is inside [x0, x1) x [y0, y1) of the clip, mapped by the layer's transform
inline bool clipped(float2 pc, float c0, float c1, float c2, float c3, constant U& u) {
    if (c0 > -NO_CLIP_HALF && pc.x < c0 * u.k + u.t.x) return true;
    if (c1 > -NO_CLIP_HALF && pc.y < c1 * u.k + u.t.y) return true;
    if (c2 < NO_CLIP_HALF && pc.x >= c2 * u.k + u.t.x) return true;
    if (c3 < NO_CLIP_HALF && pc.y >= c3 * u.k + u.t.y) return true;
    return false;
}

// ---- QUAD: rounded boxes and capsules (gpu2d: QUAD_FLOATS = 16) ----

vertex VOut quad_v(uint vid [[vertex_id]], uint iid [[instance_id]], device const float* q [[buffer(0)]], constant U& u [[buffer(1)]]) {
    device const float* d = q + iid * 16;
    float2 c = corner(vid);
    float2 p;
    if (d[5] < 0.5) {
        float2 o = xf(float2(d[0], d[1]), u);
        float2 s = max(float2(d[2], d[3]) * u.k, float2(0.0));
        p = o - 2.0 + c * (s + 4.0);
    } else {
        float2 a = xf(float2(d[0], d[1]), u);
        float2 b = xf(float2(d[2], d[3]), u);
        float hw = d[4] * u.k + 2.0;
        float2 dir = b - a;
        float len = length(dir);
        float2 ux = len > 1e-6 ? dir / len : float2(1.0, 0.0);
        float2 n = float2(-ux.y, ux.x);
        p = mix(a - ux * hw, b + ux * hw, c.x) + n * hw * (c.y * 2.0 - 1.0);
    }
    VOut o;
    o.pos = ndc(p, u);
    o.iid = iid;
    return o;
}

inline float quad_cov(float2 pc, device const float* d, constant U& u) {
    if (d[5] < 0.5) {
        float x = d[0] * u.k + u.t.x, y = d[1] * u.k + u.t.y, w = d[2] * u.k, h = d[3] * u.k;
        if (w <= 0.0 || h <= 0.0) return 0.0;
        float r = min(d[4] * u.k, min(w, h) / 2.0);
        float cx = pc.x, cy = pc.y;
        float vy = min(cy - y, y + h - cy) + 0.5;
        float cov = min(min(cx - x, x + w - cx) + 0.5, vy);
        if (r > 0.0) {
            float dx = max(max(x + r - cx, cx - (x + w - r)), 0.0);
            float dy = max(max(y + r - cy, cy - (y + h - r)), 0.0);
            if (dx > 0.0 && dy > 0.0) cov = min(cov, r - sqrt(dx * dx + dy * dy) + 0.5);
        }
        return cov;
    }
    float2 a = xf(float2(d[0], d[1]), u);
    float2 b = xf(float2(d[2], d[3]), u);
    float hw = d[4] * u.k;
    float2 dd = b - a;
    float len2 = dot(dd, dd);
    float t = len2 == 0.0 ? 0.0 : clamp(dot(pc - a, dd) / len2, 0.0, 1.0);
    float2 e = pc - (a + t * dd);
    return hw + 0.5 - length(e);
}

fragment float4 quad_over_f(VOut in [[stage_in]], device const float* q [[buffer(0)]], constant U& u [[buffer(1)]]) {
    device const float* d = q + in.iid * 16;
    float2 pc = in.pos.xy;
    if (clipped(pc, d[12], d[13], d[14], d[15], u)) discard_fragment();
    float cov = quad_cov(pc, d, u);
    if (cov <= 0.0) discard_fragment();
    return float4(d[8], d[9], d[10], d[11] * min(cov, 1.0));
}

fragment float4 quad_replace_f(VOut in [[stage_in]], device const float* q [[buffer(0)]], constant U& u [[buffer(1)]]) {
    device const float* d = q + in.iid * 16;
    float2 pc = in.pos.xy;
    if (clipped(pc, d[12], d[13], d[14], d[15], u)) discard_fragment();
    if (quad_cov(pc, d, u) <= 0.0) discard_fragment();
    return float4(d[8], d[9], d[10], d[11]);
}

// ---- GLYPH (GLYPH_FLOATS = 20) ----

vertex VOut glyph_v(uint vid [[vertex_id]], uint iid [[instance_id]], device const float* g [[buffer(2)]], constant U& u [[buffer(1)]]) {
    device const float* d = g + iid * 20;
    float left = d[0] * u.k + u.t.x, top = d[1] * u.k + u.t.y;
    float gw = d[6] - d[4], gh = d[7] - d[5];
    float sc = gw > 0.0 ? d[2] * u.k / gw : 0.0;
    float slant = d[12];
    float base = d[13] * u.k + u.t.y;
    float lean_top = slant * (base - top);
    float lean_bottom = slant * (base - top - gh * sc);
    float x0 = left + min(lean_bottom, 0.0) - 2.0, x1 = left + gw * sc + max(lean_top, 0.0) + 2.0;
    float y0 = top - 2.0, y1 = top + gh * sc + 2.0;
    float2 c = corner(vid);
    VOut o;
    o.pos = ndc(float2(mix(x0, x1, c.x), mix(y0, y1, c.y)), u);
    o.iid = iid;
    return o;
}

inline float texel(texture2d<float, access::read> a, int x, int y) {
    if (x < 0 || y < 0 || x >= int(a.get_width()) || y >= int(a.get_height())) return 0.0;
    return a.read(uint2(x, y)).r;
}

inline float bilinear(texture2d<float, access::read> a, float x, float y) {
    float fx0 = floor(x - 0.5), fy0 = floor(y - 0.5);
    int x0 = int(fx0), y0 = int(fy0);
    float fx = x - 0.5 - fx0, fy = y - 0.5 - fy0;
    float p = texel(a, x0, y0), q = texel(a, x0 + 1, y0), r = texel(a, x0, y0 + 1), s = texel(a, x0 + 1, y0 + 1);
    return (p * (1.0 - fx) + q * fx) * (1.0 - fy) + (r * (1.0 - fx) + s * fx) * fy;
}

fragment float4 glyph_f(VOut in [[stage_in]], device const float* g [[buffer(2)]], constant U& u [[buffer(1)]],
                        texture2d<float, access::read> atlas [[texture(0)]]) {
    device const float* d = g + in.iid * 20;
    float2 pc = in.pos.xy;
    if (clipped(pc, d[16], d[17], d[18], d[19], u)) discard_fragment();
    float left = d[0] * u.k + u.t.x, top = d[1] * u.k + u.t.y;
    float gw = d[6] - d[4], gh = d[7] - d[5];
    if (gw <= 0.0 || gh <= 0.0) discard_fragment();
    float sc = d[2] * u.k / gw;
    float base = d[13] * u.k + u.t.y;
    float row_left = left + d[12] * (base - pc.y);
    int sub = sc < 0.75 ? 2 : 1;
    float px = pc.x - 0.5, py = pc.y - 0.5;
    float cov = 0.0;
    for (int sy = 0; sy < sub; sy++) {
        for (int sx = 0; sx < sub; sx++) {
            float ax = (px + (float(sx) + 0.5) / float(sub) - row_left) / sc;
            float ay = (py + (float(sy) + 0.5) / float(sub) - top) / sc;
            if (ax >= 0.0 && ax < gw && ay >= 0.0 && ay < gh) cov += bilinear(atlas, d[4] + ax, d[5] + ay);
        }
    }
    cov = cov / float(sub * sub) * d[11];
    if (cov <= 0.003) discard_fragment();
    return float4(d[8], d[9], d[10], cov);
}

// ---- IMAGE (IMAGE_FLOATS = 12), nearest, blending off ----

vertex VOut image_v(uint vid [[vertex_id]], uint iid [[instance_id]], device const float* m [[buffer(3)]], constant U& u [[buffer(1)]]) {
    device const float* d = m + iid * 12;
    float2 o = xf(float2(d[0], d[1]), u);
    float2 s = max(float2(d[2], d[3]) * u.k, float2(0.0));
    VOut v;
    v.pos = ndc(o - 2.0 + corner(vid) * (s + 4.0), u);
    v.iid = iid;
    return v;
}

fragment float4 image_f(VOut in [[stage_in]], device const float* m [[buffer(3)]], constant U& u [[buffer(1)]],
                        device const uint* pixels [[buffer(6)]], device const uint* offsets [[buffer(7)]]) {
    device const float* d = m + in.iid * 12;
    float2 pc = in.pos.xy;
    if (clipped(pc, d[8], d[9], d[10], d[11], u)) discard_fragment();
    float x = d[0] * u.k + u.t.x, y = d[1] * u.k + u.t.y, w = d[2] * u.k, h = d[3] * u.k;
    int pw = int(d[5]), ph = int(d[6]);
    if (w <= 0.0 || h <= 0.0 || pw <= 0 || ph <= 0) discard_fragment();
    if (pc.x < x || pc.x >= x + w || pc.y < y || pc.y >= y + h) discard_fragment();
    int sy = min(ph - 1, int(floor((pc.y - y) / h * float(ph))));
    int sx = min(pw - 1, int(floor((pc.x - x) / w * float(pw))));
    uint p = pixels[offsets[int(d[4])] + uint(sy * pw + sx)];
    return float4(float(p & 255u), float((p >> 8) & 255u), float((p >> 16) & 255u), float(p >> 24)) / 255.0;
}

// ---- POLY (POLY_FLOATS = 16): coverage accumulated from the fan's triangles, then the cover ----
// Each triangle of the polygon's fan adds, to a float accumulator, its signed share of each pixel on gpu2d's four scan
// lines per pixel row (y + 0.125, 0.375, 0.625, 0.875), the span it covers on each counted exactly in x: summed over
// the fan that is the polygon's winding integrated over the pixel, which is execute_cpu's coverage wherever the winding
// is 0 or ±1 (inner edges cancel: both sides compute the crossing from the same lower end). The cover then blends the
// polygon's colour by min(|sum|, 1) and zeroes the accumulator for the next polygon (reading both attachments:
// programmable blending, the tile memory Apple GPUs have).

// one instance per piece of a polygon's strip (its item read from the group's list: a group's polygons don't overlap,
// so their pieces go in one draw, D-7536). A piece is a fan triangle, or two that share a diagonal (gpu2d's zig-zag
// stores (lo, lo+1, hi) then (lo+1, hi−1, hi)): the quad lo → lo+1 → hi−1 → hi, its diagonal's crossings cancelling
// exactly, half the instances and 4 edges a pixel instead of 6 (D-7544). Item = triangle index · 2 + (1 for a quad).
// Drawn as its box padded by half a pixel, or a lone triangle grown by a pixel's half diagonal about its incentre
// (every edge moves out 0.7072: every pixel whose square meets it) when that's smaller (D-7543); a pixel whose square
// misses the piece gets nothing from it, its crossings on the pixel's scan lines cancelling. The fragment reads the
// piece back from the fan (a cached load: per-vertex outputs that size cost more, D-7534)
struct TOut { float4 pos [[position]]; uint t [[flat]]; };

inline void piece(device const float2* fan, uint item, constant U& u, thread float2& a, thread float2& b, thread float2& c, thread float2& d) {
    uint t = item >> 1;
    a = xf(fan[t * 3], u);
    b = xf(fan[t * 3 + 1], u);
    if ((item & 1u) != 0u) {
        c = xf(fan[t * 3 + 4], u);
        d = xf(fan[t * 3 + 5], u);
    } else {
        c = xf(fan[t * 3 + 2], u);
        d = c;  // (a zero-length edge: no crossings)
    }
}

vertex TOut tri_v(uint vid [[vertex_id]], uint iid [[instance_id]], device const float2* fan [[buffer(5)]], constant U& u [[buffer(1)]],
                  device const uint* tris [[buffer(8)]]) {
    uint item = tris[iid];
    float2 a, b, c, d;
    piece(fan, item, u, a, b, c, d);
    float2 lo = min(min(a, b), min(c, d)) - 0.51, hi = max(max(a, b), max(c, d)) + 0.51;
    float2 box = hi - lo;
    float2 p;
    if (hi.x < 0.0 || hi.y < 0.0 || lo.x > u.view.x || lo.y > u.view.y) {
        p = float2(-4096.0);  // (off the canvas: every vertex at one point, an empty triangle dropped before tiling)
    } else {
        p = mix(lo, hi, corner(vid));
        if ((item & 1u) == 0u) {
            float la = length(b - c), lb = length(c - a), lc = length(a - b);
            float per = la + lb + lc;
            float area2 = abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x));
            float r = per > 0.0 ? area2 / per : 0.0;  // (the inradius: 2·area / perimeter)
            float g = r > 1e-3 ? (r + 0.7072) / r : 0.0;
            if (g > 0.0 && 0.5 * area2 * g * g < box.x * box.y) {
                float2 ic = (la * a + lb * b + lc * c) / per;
                float2 v = vid == 0u ? a : (vid == 1u ? b : c);  // (the strip's 4th vertex repeats c: its second triangle is empty)
                p = ic + (v - ic) * g;
            }
        }
    }
    TOut o;
    o.pos = ndc(p, u);
    o.t = item;
    return o;
}

struct AccOut { float acc [[color(1)]]; };

// edge p-q's share of pixel column [px, px + 1) on the four scan lines y: where it crosses (half-open in y, as
// execute_cpu counts; the crossing worked out from the lower end, so an edge two triangles share cancels exactly),
// ±(px + 1 − the crossing clamped to the pixel); summed over a closed outline: the winding integrated over the span
inline float4 shares(float2 p, float2 q, float4 y, float px) {
    float2 lo = p.y < q.y ? p : q, hi = p.y < q.y ? q : p;
    float slope = hi.y > lo.y ? (hi.x - lo.x) / (hi.y - lo.y) : 0.0;
    float4 x = lo.x + (y - lo.y) * slope;
    float4 s = (q.y > p.y ? 1.0 : -1.0) * (px + 1.0 - clamp(x, px, px + 1.0));
    return select(float4(0.0), s, (y >= lo.y) && (y < hi.y));
}

fragment AccOut tri_f(TOut in [[stage_in]], device const float2* fan [[buffer(5)]], constant U& u [[buffer(1)]]) {
    float2 a, b, c, d;
    piece(fan, in.t, u, a, b, c, d);
    float px = in.pos.x - 0.5;
    float4 y = in.pos.y - 0.5 + float4(0.125, 0.375, 0.625, 0.875);
    float4 s4 = shares(a, b, y, px) + shares(b, c, y, px) + shares(c, d, y, px) + shares(d, a, y, px);
    float sum = s4.x + s4.y + s4.z + s4.w;
    if (sum == 0.0) discard_fragment();
    AccOut o;
    o.acc = sum * 0.25;
    return o;
}

vertex VOut cover_v(uint vid [[vertex_id]], uint iid [[instance_id]], device const float* q [[buffer(4)]], constant U& u [[buffer(1)]],
                    device const uint* ids [[buffer(9)]]) {
    uint pid = ids[iid];  // (the group's polygons, as listed)
    device const float* d = q + pid * 16;
    float2 a = xf(float2(d[8], d[9]), u) - 1.5;
    float2 b = xf(float2(d[10], d[11]), u) + 1.5;
    VOut o;
    o.pos = ndc(mix(a, b, corner(vid)), u);
    o.iid = pid;
    return o;
}

struct CoverOut { float4 color [[color(0)]]; float acc [[color(1)]]; };

fragment CoverOut cover_f(VOut in [[stage_in]], device const float* q [[buffer(4)]], constant U& u [[buffer(1)]],
                          float4 dst [[color(0)]], float acc [[color(1)]]) {
    device const float* d = q + in.iid * 16;
    CoverOut o;
    o.color = dst;
    o.acc = 0.0;  // (zeroed wherever the cover runs, clipped or not, for the next polygon)
    if (acc == 0.0) discard_fragment();  // (nothing covered here and nothing to zero: most of a stroke's box)
    if (clipped(in.pos.xy, d[12], d[13], d[14], d[15], u)) return o;
    float a = min(abs(acc), 1.0) * d[7];
    if (a > 0.0) o.color = float4(d[4] * a + dst.r * (1.0 - a), d[5] * a + dst.g * (1.0 - a), d[6] * a + dst.b * (1.0 - a), dst.a);
    return o;
}
"""


@always_inline
def _send[T: RegisterPassable = Int, *A: AnyType](f: Int, obj: Int, s: Int, *args: *A) -> T:
    """objc_msgSend at a known address with a selector already looked up (the per-frame calls: no dlsym, no lookup)."""
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=f)
    var fp = Pointer(to=raw).unsafe_bitcast[def(o: Int, s: Int, *a: *A) thin abi("C") -> T]()[]
    return fp(obj, s, *args)


@always_inline
def _copy(memcpy_addr: Int, dst: Int, src: Int, n: Int):
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=memcpy_addr)
    var fp = Pointer(to=raw).unsafe_bitcast[def(d: Int, s: Int, n: Int) thin abi("C") -> Int]()[]
    _ = fp(dst, src, n)


def _sym(handle: Int, name: String) -> Int:
    var n = name
    return external_call["dlsym", Int](handle, n.as_c_string_span())


def _error_text(err: Int) -> String:
    if err == 0:
        return "(no error object)"
    return from_ns(msg(err, "localizedDescription"))


struct Metal2D(Movable):
    """Metal for mojoui.gpu2d: everything made once at start (see the top of this file). `ok` False: no Metal here
    (`why` says what failed) and render does nothing."""

    var ok: Bool
    var why: String
    var name: String  # the device's name (the report)
    var f: Int  # objc_msgSend
    var memcpy: Int
    var media_time: Int  # CACurrentMediaTime (0 without QuartzCore: the waits aren't timed)
    var device: Int
    var queue: Int
    var library: Int
    var p_quad_over: Int
    var p_quad_replace: Int
    var p_glyph: Int
    var p_image: Int
    var p_tri: Int
    var p_cover: Int
    var atlas: Int  # the R8 texture
    var whole: GpuBuffers  # render()'s buffers (a whole frame at once: the readback check's path)
    var whole_plan: PolyPlan  # (and its polygon groups)
    var cur_pipe: Int  # the pass's current pipeline
    var uniform: List[Float32]  # U: view w, h; t x, y; k; pad
    var acc: Int  # the polygon accumulator (R32Float, memoryless), acc_w × acc_h
    var acc_w: Int
    var acc_h: Int
    var targets: List[Int]  # IOSurfaces wrapped as textures so far, and the textures (same index)
    var target_tex: List[Int]
    var frames: Int
    var gpu_ms: Float64  # the last frame's GPU time (GPUEndTime − GPUStartTime), for the report
    var wake_buf: Int  # (wake(): a 16-byte buffer a blit fills)
    var last_commit_ns: Int  # when the last command buffer went to the GPU
    var woken: Int  # wakes sent (the report)
    var idle_ms: Float64  # the last frame: how long the GPU had nothing from us before its commit (a wake counts)
    var wait_before_ms: Float64  # the last frame: commit → the GPU starting it (ms)
    var wait_after_ms: Float64  # the GPU done → this thread running again (ms)
    var blocked_ms: Float64  # the last frame: how long this thread waited for its command buffer (ms)
    var drawn_groups: Int  # polygon groups drawn (on the canvas) since the last pass began
    # classes and selectors of the per-frame calls
    var c_rpd: Int
    var s_rpd: Int
    var s_color_attachments: Int
    var s_at_index: Int
    var s_set_texture: Int
    var s_set_load: Int
    var s_set_store: Int
    var s_set_clear_color: Int
    var s_command_buffer: Int
    var s_encoder: Int
    var s_set_pipe: Int
    var s_set_vbuf: Int
    var s_set_fbuf: Int
    var s_set_vbytes: Int
    var s_set_fbytes: Int
    var s_set_ftex: Int
    var s_draw_inst: Int
    var s_end: Int
    var s_commit: Int
    var s_wait: Int
    var s_status: Int
    var s_contents: Int
    var s_gpu_start: Int
    var s_gpu_end: Int
    var s_texture: Int
    var s_present: Int

    def __init__(out self, atlas: GlyphAtlas):
        self.ok = False
        self.why = ""
        self.name = ""
        self.f = _sym(RTLD_DEFAULT, "objc_msgSend")
        self.memcpy = _sym(RTLD_DEFAULT, "memcpy")
        self.media_time = _sym(RTLD_DEFAULT, "CACurrentMediaTime")
        self.device = 0
        self.queue = 0
        self.library = 0
        self.p_quad_over = 0
        self.p_quad_replace = 0
        self.p_glyph = 0
        self.p_image = 0
        self.p_tri = 0
        self.p_cover = 0
        self.atlas = 0
        self.whole = GpuBuffers()
        self.whole_plan = PolyPlan()
        self.cur_pipe = 0
        self.uniform = List[Float32](length=8, fill=0)
        self.acc = 0
        self.acc_w = 0
        self.acc_h = 0
        self.targets = List[Int]()
        self.target_tex = List[Int]()
        self.frames = 0
        self.gpu_ms = 0
        self.drawn_groups = 0
        self.wake_buf = 0
        self.last_commit_ns = 0
        self.woken = 0
        self.idle_ms = 0
        self.wait_before_ms = 0
        self.wait_after_ms = 0
        self.blocked_ms = 0
        self.c_rpd = 0
        self.s_rpd = sel("renderPassDescriptor")
        self.s_color_attachments = sel("colorAttachments")
        self.s_at_index = sel("objectAtIndexedSubscript:")
        self.s_set_texture = sel("setTexture:")
        self.s_set_load = sel("setLoadAction:")
        self.s_set_store = sel("setStoreAction:")
        self.s_set_clear_color = sel("setClearColor:")
        self.s_command_buffer = sel("commandBuffer")
        self.s_encoder = sel("renderCommandEncoderWithDescriptor:")
        self.s_set_pipe = sel("setRenderPipelineState:")
        self.s_set_vbuf = sel("setVertexBuffer:offset:atIndex:")
        self.s_set_fbuf = sel("setFragmentBuffer:offset:atIndex:")
        self.s_set_vbytes = sel("setVertexBytes:length:atIndex:")
        self.s_set_fbytes = sel("setFragmentBytes:length:atIndex:")
        self.s_set_ftex = sel("setFragmentTexture:atIndex:")
        self.s_draw_inst = sel("drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:")
        self.s_end = sel("endEncoding")
        self.s_commit = sel("commit")
        self.s_wait = sel("waitUntilCompleted")
        self.s_status = sel("status")
        self.s_contents = sel("contents")
        self.s_gpu_start = sel("GPUStartTime")
        self.s_gpu_end = sel("GPUEndTime")
        self.s_texture = sel("texture")
        self.s_present = sel("presentDrawable:")
        self.ok = self._start(atlas)

    def _start(mut self, atlas: GlyphAtlas) -> Bool:
        """Device, queue, library, pipelines and the atlas; False (and `why`) at the first failure."""
        if self.f == 0 or self.memcpy == 0:
            self.why = "no objc_msgSend/memcpy"
            return False
        var path = String("/System/Library/Frameworks/Metal.framework/Metal")
        var cpath = path.as_c_string_span()
        var handle = cfunc("dlopen", Int(cpath.ptr()), 9)  # RTLD_LAZY | RTLD_GLOBAL (looked up: no new import)
        if handle == 0:
            self.why = "no Metal framework"
            return False
        var create = _sym(handle, "MTLCreateSystemDefaultDevice")
        if create == 0:
            self.why = "no MTLCreateSystemDefaultDevice"
            return False
        var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=create)
        var make = Pointer(to=raw).unsafe_bitcast[def() thin abi("C") -> Int]()[]
        self.device = make()
        if self.device == 0:
            self.why = "no Metal device"
            return False
        _ = path.byte_length()
        self.c_rpd = cls("MTLRenderPassDescriptor")
        self.name = from_ns(msg(self.device, "name"))
        self.queue = msg(self.device, "newCommandQueue")
        if self.queue == 0:
            self.why = "no command queue"
            return False
        var err = List[Int](length=1, fill=0)
        self.library = msg(self.device, "newLibraryWithSource:options:error:", ns_string(MSL), 0, Int(err.unsafe_ptr()))
        if self.library == 0:
            self.why = "shaders didn't compile: " + _error_text(err[0])
            return False
        self.p_quad_over = self._pipeline("quad_v", "quad_over_f", MODE_OVER)
        self.p_quad_replace = self._pipeline("quad_v", "quad_replace_f", MODE_REPLACE)
        self.p_glyph = self._pipeline("glyph_v", "glyph_f", MODE_OVER)
        self.p_image = self._pipeline("image_v", "image_f", MODE_REPLACE)
        self.p_tri = self._pipeline("tri_v", "tri_f", MODE_ACCUMULATE)
        self.p_cover = self._pipeline("cover_v", "cover_f", MODE_COVER)
        if self.p_quad_over == 0 or self.p_quad_replace == 0 or self.p_glyph == 0 or self.p_image == 0 or self.p_tri == 0 or self.p_cover == 0:
            if self.why == "":
                self.why = "a pipeline failed"
            return False
        # the atlas: one R8 texture, uploaded once
        var td = msg(cls("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", PF_R8, atlas.width, atlas.height, 0)
        _ = msg(td, "setUsage:", 1)  # ShaderRead
        _ = msg(td, "setStorageMode:", 0)  # Shared
        self.atlas = msg(self.device, "newTextureWithDescriptor:", td)
        if self.atlas == 0:
            self.why = "no atlas texture"
            return False
        var region = List[Int](length=6, fill=0)  # MTLRegion {origin x, y, z; size w, h, d} (48 bytes: passed by address)
        region[3] = atlas.width
        region[4] = atlas.height
        region[5] = 1
        _ = msg[NoneType](self.atlas, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", Int(region.unsafe_ptr()), 0, Int(atlas.bytes.unsafe_ptr()), atlas.width)
        _ = len(region)
        _ = len(atlas.bytes)
        self.wake_buf = msg(self.device, "newBufferWithLength:options:", 16, 32)  # (Private)
        return True

    def _pipeline(mut self, vname: String, fname: String, mode: Int) -> Int:
        """A pipeline over the two attachments: the picture (BGRA) and the polygon accumulator (R32Float)."""
        var vf = msg(self.library, "newFunctionWithName:", ns_string(vname))
        var ff = msg(self.library, "newFunctionWithName:", ns_string(fname))
        if vf == 0 or ff == 0:
            self.why = "no shader function " + (vname if vf == 0 else fname)
            return 0
        var pd = msg(msg(cls("MTLRenderPipelineDescriptor"), "alloc"), "init")
        _ = msg(pd, "setVertexFunction:", vf)
        _ = msg(pd, "setFragmentFunction:", ff)
        var cas = msg(pd, "colorAttachments")
        var c0 = msg(cas, "objectAtIndexedSubscript:", 0)
        var c1 = msg(cas, "objectAtIndexedSubscript:", 1)
        _ = msg(c0, "setPixelFormat:", PF_BGRA8)
        _ = msg(c1, "setPixelFormat:", PF_ACC)
        if mode == MODE_OVER:  # gpu2d's BLEND_OVER: RGB = src·a + dst·(1 − a); alpha = dst's
            _ = msg(c0, "setBlendingEnabled:", 1)
            _ = msg(c0, "setRgbBlendOperation:", 0)
            _ = msg(c0, "setAlphaBlendOperation:", 0)
            _ = msg(c0, "setSourceRGBBlendFactor:", 4)  # SourceAlpha
            _ = msg(c0, "setDestinationRGBBlendFactor:", 5)  # OneMinusSourceAlpha
            _ = msg(c0, "setSourceAlphaBlendFactor:", 0)  # Zero
            _ = msg(c0, "setDestinationAlphaBlendFactor:", 1)  # One
        if mode == MODE_ACCUMULATE:  # the accumulator adds; the picture is left alone
            _ = msg(c0, "setWriteMask:", 0)
            _ = msg(c1, "setBlendingEnabled:", 1)
            _ = msg(c1, "setRgbBlendOperation:", 0)
            _ = msg(c1, "setAlphaBlendOperation:", 0)
            _ = msg(c1, "setSourceRGBBlendFactor:", 1)
            _ = msg(c1, "setDestinationRGBBlendFactor:", 1)
            _ = msg(c1, "setSourceAlphaBlendFactor:", 1)
            _ = msg(c1, "setDestinationAlphaBlendFactor:", 1)
        elif mode != MODE_COVER:
            _ = msg(c1, "setWriteMask:", 0)
        var err = List[Int](length=1, fill=0)
        var p = msg(self.device, "newRenderPipelineStateWithDescriptor:error:", pd, Int(err.unsafe_ptr()))
        if p == 0:
            self.why = "pipeline " + fname + ": " + _error_text(err[0])
        _ = msg(pd, "release")
        _ = msg(vf, "release")
        _ = msg(ff, "release")
        return p

    def upload(self, frame: Frame2D, plan: PolyPlan, mut gb: GpuBuffers, tail: Bool = False):
        """A frame's batches into a set of GPU buffers: the four instance lists, the polygon fans, the images' pixels and
        where each starts, the polygon groups' lists. tail: only what was added since the last upload (a layer that grew)."""
        upload_frame(self.device, self.f, self.s_contents, self.memcpy, frame, gb, tail)
        upload_plan(self.device, self.f, self.s_contents, self.memcpy, plan, gb, tail)

    def _acc_target(mut self, w: Int, h: Int) -> Bool:
        """The polygon accumulator, w × h R32Float in tile memory only (memoryless; private memory if refused)."""
        if self.acc != 0 and self.acc_w == w and self.acc_h == h:
            return True
        if self.acc != 0:
            _ = msg(self.acc, "release")
            self.acc = 0
        var td = msg(cls("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", PF_ACC, w, h, 0)
        _ = msg(td, "setUsage:", 4)  # RenderTarget
        _ = msg(td, "setStorageMode:", 3)  # Memoryless
        self.acc = msg(self.device, "newTextureWithDescriptor:", td)
        if self.acc == 0:
            _ = msg(td, "setStorageMode:", 2)  # Private
            self.acc = msg(self.device, "newTextureWithDescriptor:", td)
        self.acc_w = w
        self.acc_h = h
        return self.acc != 0

    def target_for(mut self, io: Int, w: Int, h: Int) -> Int:
        """The IOSurface wrapped as a BGRA render texture (made once per IOSurface; the wrap keeps it alive). The six
        most recent wraps are kept: a host's ring has three, and a resize makes three more."""
        for i in range(len(self.targets)):
            if self.targets[i] == io:
                return self.target_tex[i]
        var td = msg(cls("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", PF_BGRA8, w, h, 0)
        _ = msg(td, "setUsage:", 5)  # RenderTarget | ShaderRead
        _ = msg(td, "setStorageMode:", 0)  # Shared (an IOSurface's memory)
        var t = msg(self.device, "newTextureWithDescriptor:iosurface:plane:", td, io, 0)
        if t == 0:
            return 0
        if len(self.targets) >= 6:
            _ = msg(self.target_tex[0], "release")
            _ = self.targets.pop(0)
            _ = self.target_tex.pop(0)
        self.targets.append(io)
        self.target_tex.append(t)
        return t

    def forget(mut self, io: Int):
        """The host is releasing IOSurface `io`: its wrap goes first."""
        for i in range(len(self.targets)):
            if self.targets[i] == io:
                _ = msg(self.target_tex[i], "release")
                _ = self.targets.pop(i)
                _ = self.target_tex.pop(i)
                return

    def render(mut self, frame: Frame2D, io: Int, w: Int, h: Int, drawable: Int = 0) -> Bool:
        """Draws a whole frame into IOSurface `io` (w × h pixels, BGRA) — or into a CAMetalLayer drawable, presented when
        the GPU is done — and waits for the GPU to finish. False: not drawn."""
        if not self.ok:
            return False
        var tex = _send(self.f, drawable, self.s_texture) if drawable != 0 else self.target_for(io, w, h)
        if tex == 0 or not self._acc_target(w, h):
            return False
        plan_polys(frame, self.whole_plan)
        upload_frame(self.device, self.f, self.s_contents, self.memcpy, frame, self.whole)
        upload_plan(self.device, self.f, self.s_contents, self.memcpy, self.whole_plan, self.whole)
        var pool = pool_push()
        var cb = 0
        var enc = self._begin_pass(tex, w, h, cb)
        if enc == 0:
            cfunc[NoneType]("objc_autoreleasePoolPop", pool)
            return False
        self._bind(enc, self.whole.bufs)
        var plan = PolyPlan()  # (swapped out while self is borrowed mutably)
        swap(plan, self.whole_plan)
        for li in range(len(frame.layers)):
            ref layer = frame.layers[li]
            self._draw_layer(enc, frame, plan, li, layer.dx, layer.dy, layer.k)
        swap(plan, self.whole_plan)
        return self._finish(pool, cb, enc, drawable)

    def render_layers(mut self, layers: List[GpuLayer], n: Int, io: Int, w: Int, h: Int, drawable: Int = 0) -> Bool:
        """Draws layers[0 : n] (each one Scene layer's batches in its own buffers, uploaded when it changed; its
        transform this frame in layers[i].dx/dy/k) into IOSurface `io` — or, with `drawable`, into that CAMetalLayer
        drawable's texture, presented when the GPU is done — and waits for the GPU. False: not drawn."""
        if not self.ok:
            return False
        var tex = _send(self.f, drawable, self.s_texture) if drawable != 0 else self.target_for(io, w, h)
        if tex == 0 or not self._acc_target(w, h):
            return False
        var pool = pool_push()
        var cb = 0
        var enc = self._begin_pass(tex, w, h, cb)
        if enc == 0:
            cfunc[NoneType]("objc_autoreleasePoolPop", pool)
            return False
        for i in range(n):
            ref L = layers[i]
            if len(L.frame.runs) == 0:
                continue
            self._bind(enc, L.gpu.bufs)
            for li in range(len(L.frame.layers)):
                self._draw_layer(enc, L.frame, L.plan, li, L.dx, L.dy, L.k)
        return self._finish(pool, cb, enc, drawable)

    def _begin_pass(mut self, tex: Int, w: Int, h: Int, mut cb: Int) -> Int:
        """One render pass: the picture (`tex`) cleared and stored, the accumulator cleared (and never stored); its encoder."""
        var f = self.f
        var rpd = _send(f, self.c_rpd, self.s_rpd)
        var cas = _send(f, rpd, self.s_color_attachments)
        var ca = _send(f, cas, self.s_at_index, 0)
        _send[NoneType](f, ca, self.s_set_texture, tex)
        _send[NoneType](f, ca, self.s_set_load, 2)  # Clear
        _send[NoneType](f, ca, self.s_set_store, 1)  # Store
        _send[NoneType](f, ca, self.s_set_clear_color, Float64(0), Float64(0), Float64(0), Float64(0))  # (four doubles: d0–d3)
        var cacc = _send(f, cas, self.s_at_index, 1)
        _send[NoneType](f, cacc, self.s_set_texture, self.acc)
        _send[NoneType](f, cacc, self.s_set_load, 2)  # Clear (to 0)
        _send[NoneType](f, cacc, self.s_set_store, 0)  # DontCare
        _send[NoneType](f, cacc, self.s_set_clear_color, Float64(0), Float64(0), Float64(0), Float64(0))
        cb = _send(f, self.queue, self.s_command_buffer)
        var enc = _send(f, cb, self.s_encoder, rpd)
        if enc == 0:
            return 0
        _send[NoneType](f, enc, self.s_set_ftex, self.atlas, 0)
        self.cur_pipe = 0
        self.drawn_groups = 0
        self.uniform[0] = Float32(w)
        self.uniform[1] = Float32(h)
        return enc

    def _bind(self, enc: Int, bufs: List[Int]):
        for slot in range(BUFFERS):
            if slot != B_UNIFORM and bufs[slot] != 0:
                _send[NoneType](self.f, enc, self.s_set_vbuf, bufs[slot], 0, slot)
                _send[NoneType](self.f, enc, self.s_set_fbuf, bufs[slot], 0, slot)

    def _use(mut self, enc: Int, pipe: Int):
        if self.cur_pipe != pipe:
            self.cur_pipe = pipe
            _send[NoneType](self.f, enc, self.s_set_pipe, pipe)

    def _draw_layer(mut self, enc: Int, frame: Frame2D, plan: PolyPlan, li: Int, dx: Float64, dy: Float64, k: Float64):
        """Layer li of a frame's runs (its buffers bound), through the transform (dx, dy, k); polygon runs group by
        group as `plan` says (each group: its triangles' coverage, then its covers)."""
        ref layer = frame.layers[li]
        if layer.runs == 0:
            return
        var f = self.f
        self.uniform[2] = Float32(dx)
        self.uniform[3] = Float32(dy)
        self.uniform[4] = Float32(k)
        var up = Int(self.uniform.unsafe_ptr())
        _send[NoneType](f, enc, self.s_set_vbytes, up, 32, B_UNIFORM)
        _send[NoneType](f, enc, self.s_set_fbytes, up, 32, B_UNIFORM)
        for ri in range(layer.first_run, layer.first_run + layer.runs):
            var run = frame.runs[ri]
            if run.count <= 0:
                continue
            if run.pipe == PIPE_POLY:
                var vw = Float64(self.uniform[0])
                var vh = Float64(self.uniform[1])
                for g in range(plan.run_first[ri], plan.run_first[ri + 1]):
                    var b = 4 * g
                    # (a group whose bounds, padded by the cover's 1.5 px, miss the canvas draws nothing)
                    if (Float64(plan.bounds[b]) * k + dx > vw + 2 or Float64(plan.bounds[b + 1]) * k + dy > vh + 2
                            or Float64(plan.bounds[b + 2]) * k + dx < -2 or Float64(plan.bounds[b + 3]) * k + dy < -2):
                        continue
                    self.drawn_groups += 1
                    if plan.groups[b + 1] > 0:  # (one instance per fan triangle, its coverage added)
                        self._use(enc, self.p_tri)
                        _send[NoneType](f, enc, self.s_draw_inst, PRIM_STRIP, 0, 4, plan.groups[b + 1], plan.groups[b])
                    self._use(enc, self.p_cover)
                    _send[NoneType](f, enc, self.s_draw_inst, PRIM_STRIP, 0, 4, plan.groups[b + 3], plan.groups[b + 2])
                continue
            var pipe: Int
            if run.pipe == PIPE_QUAD:
                pipe = self.p_quad_replace if run.blend == BLEND_REPLACE else self.p_quad_over
            elif run.pipe == PIPE_GLYPH:
                pipe = self.p_glyph
            else:
                pipe = self.p_image
            self._use(enc, pipe)
            _send[NoneType](f, enc, self.s_draw_inst, PRIM_STRIP, 0, 4, run.count, run.first)
        _ = len(self.uniform)

    def wake(mut self):
        """Input reached a GPU canvas: when the GPU has been idle (30 ms since the last frame went to it), a tiny blit
        goes now, unwaited, so the GPU powers up while the CPU runs the app's update, paints the Scene and builds the
        batches; the frame's own commit then finds it awake (D-7540). After idle the GPU took 4.6–4.7 ms from commit
        to starting a frame, against ~0.5 ms when warm."""
        if not self.ok or self.wake_buf == 0 or Int(now_ns()) - self.last_commit_ns < 30_000_000:
            return
        var cb = msg(self.queue, "commandBuffer")
        if cb == 0:
            return
        var enc = msg(cb, "blitCommandEncoder")
        if enc != 0:
            _ = msg[NoneType](enc, "fillBuffer:range:value:", self.wake_buf, 0, 16, UInt8(0))
            _ = msg[NoneType](enc, "endEncoding")
        _ = msg[NoneType](cb, "commit")
        self.last_commit_ns = Int(now_ns())
        self.woken += 1

    def _now(self) -> Float64:
        if self.media_time == 0:
            return 0
        var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=self.media_time)
        var fp = Pointer(to=raw).unsafe_bitcast[def() thin abi("C") -> Float64]()[]
        return fp()

    def _finish(mut self, pool: Int, cb: Int, enc: Int, drawable: Int = 0) -> Bool:
        """Ends the pass, commits and waits for the GPU (the picture is complete when this returns); a drawable is
        presented as soon as the GPU is done with it."""
        var f = self.f
        _send[NoneType](f, enc, self.s_end)
        if drawable != 0:
            _send[NoneType](f, cb, self.s_present, drawable)
        _send[NoneType](f, cb, self.s_commit)
        var t_commit = self._now()  # (the clock GPUStartTime and GPUEndTime are on)
        self.idle_ms = Float64(Int(now_ns()) - self.last_commit_ns) / 1e6
        self.last_commit_ns = Int(now_ns())
        _send[NoneType](f, cb, self.s_wait)
        var t_back = self._now()
        var status = _send(f, cb, self.s_status)
        var g0 = _send[Float64](f, cb, self.s_gpu_start)
        var g1 = _send[Float64](f, cb, self.s_gpu_end)
        self.gpu_ms = (g1 - g0) * 1000.0
        self.wait_before_ms = (g0 - t_commit) * 1000.0 if t_commit > 0 else 0.0
        self.wait_after_ms = (t_back - g1) * 1000.0 if t_back > 0 else 0.0
        self.blocked_ms = (t_back - t_commit) * 1000.0 if t_commit > 0 else 0.0
        cfunc[NoneType]("objc_autoreleasePoolPop", pool)
        if status != 4:  # MTLCommandBufferStatusCompleted
            if self.frames == 0:
                print("mojoui: gpu2d Metal: the first frame's command buffer ended with status " + String(status), flush=True)
            return False
        self.frames += 1
        return True


struct GpuBuffers(Movable):
    """GPU buffers for one frame's (or one layer's) batches, one per B_* slot (shared memory), grown when too small."""

    var bufs: List[Int]
    var caps: List[Int]  # their sizes in bytes
    var used: List[Int]  # bytes holding the last upload (a tail upload copies only past it)
    var offsets: List[UInt32]  # IMAGE: where each image's pixels start in B_PIXELS (in pixels)

    def __init__(out self):
        self.bufs = List[Int](length=BUFFERS, fill=0)
        self.caps = List[Int](length=BUFFERS, fill=0)
        self.used = List[Int](length=BUFFERS, fill=0)
        self.offsets = List[UInt32]()


def _ensure(device: Int, mut gb: GpuBuffers, slot: Int, nbytes: Int) -> Bool:
    """Buffer `slot` holds at least nbytes (grown by half again when it doesn't: a new buffer, the old released — safe:
    every render waits for the GPU before it returns). True: it was replaced (its contents are gone)."""
    if gb.caps[slot] >= nbytes and gb.bufs[slot] != 0:
        return False
    var size = max(nbytes + nbytes // 2, 16384)
    if gb.bufs[slot] != 0:
        _ = msg(gb.bufs[slot], "release")
    gb.bufs[slot] = msg(device, "newBufferWithLength:options:", size, 0)  # (Shared: the CPU writes, the GPU reads)
    gb.caps[slot] = size if gb.bufs[slot] != 0 else 0
    gb.used[slot] = 0
    return True


def _put(device: Int, f: Int, s_contents: Int, memcpy: Int, mut gb: GpuBuffers, slot: Int, src: Int, nbytes: Int, tail: Bool = False):
    """nbytes from src into buffer `slot`; tail: only the bytes past what it held (the rest is the same), unless the
    buffer had to grow."""
    if nbytes <= 0:
        gb.used[slot] = 0
        return
    var fresh = _ensure(device, gb, slot, nbytes)
    if gb.bufs[slot] == 0:
        return
    var from_ = gb.used[slot] if tail and not fresh and gb.used[slot] <= nbytes else 0
    if nbytes > from_:
        _copy(memcpy, _send(f, gb.bufs[slot], s_contents) + from_, src + from_, nbytes - from_)
    gb.used[slot] = nbytes


def upload_frame(device: Int, f: Int, s_contents: Int, memcpy: Int, frame: Frame2D, mut gb: GpuBuffers, tail: Bool = False):
    _put(device, f, s_contents, memcpy, gb, B_QUADS, Int(frame.quads.unsafe_ptr()), len(frame.quads) * 4, tail)
    _put(device, f, s_contents, memcpy, gb, B_GLYPHS, Int(frame.glyphs.unsafe_ptr()), len(frame.glyphs) * 4, tail)
    _put(device, f, s_contents, memcpy, gb, B_IMAGES, Int(frame.images.unsafe_ptr()), len(frame.images) * 4, tail)
    _put(device, f, s_contents, memcpy, gb, B_POLYS, Int(frame.polys.unsafe_ptr()), len(frame.polys) * 4, tail)
    _put(device, f, s_contents, memcpy, gb, B_FAN, Int(frame.fan.unsafe_ptr()), len(frame.fan) * 4, tail)
    if len(frame.pixels) > 0 and not tail:  # (a grown layer adds no images: append_frame refuses them)
        gb.offsets.clear()
        var total = 0
        for ref px in frame.pixels:
            gb.offsets.append(UInt32(total))
            total += len(px)
        _ = _ensure(device, gb, B_PIXELS, total * 4)
        if gb.bufs[B_PIXELS] != 0:
            var base = _send(f, gb.bufs[B_PIXELS], s_contents)
            for i in range(len(frame.pixels)):
                ref px = frame.pixels[i]
                _copy(memcpy, base + Int(gb.offsets[i]) * 4, Int(px.unsafe_ptr()), len(px) * 4)
            gb.used[B_PIXELS] = total * 4
        _put(device, f, s_contents, memcpy, gb, B_OFFSETS, Int(gb.offsets.unsafe_ptr()), len(gb.offsets) * 4)


def upload_plan(device: Int, f: Int, s_contents: Int, memcpy: Int, plan: PolyPlan, mut gb: GpuBuffers, tail: Bool = False):
    _put(device, f, s_contents, memcpy, gb, B_TRIS, Int(plan.tris.unsafe_ptr()), len(plan.tris) * 4, tail)
    _put(device, f, s_contents, memcpy, gb, B_COVERS, Int(plan.covers.unsafe_ptr()), len(plan.covers) * 4, tail)


comptime LEVELS_UP_TO = 512  # polygon runs this long are grouped by exact overlap depth (all pairs); longer: by a grid
comptime GRID = 64  # (the grid's cells per side over a long run's bounds)
comptime TILES = 64  # (tiles per side a depth's polygons are split by, at most)
comptime COVER_PAD_PX = 1.5  # cover_v's pad around a polygon's bounds, in pixels (the triangles reach 1 px past them)
comptime KEEP_ZOOMED_OUT = 0.25  # a layer reused further out than this from the zoom it was built at is built again: a
# plan's pads (and merge_runs' 4 px) are in the units of the zoom it was made at


struct PolyPlan(Movable):
    """A frame's polygon runs as groups (D-7536): polygons whose padded bounds don't meet share a group, drawn as one
    triangle draw (every fan triangle of the group, listed in `tris`) and one cover draw (its polygons, in `covers`).
    A polygon goes one group after the last group holding an earlier polygon it meets (overlap depth), so overlapping
    polygons keep painter's order and the rest share groups: a page of ink is tens of draws, not two per stroke. A depth's
    polygons are split by tiles half a canvas wide (by their middles) and each group keeps its bounds, so a frame skips
    the groups off the canvas: a panned page sends only what's on screen through the GPU's geometry (D-7543)."""

    var tris: List[UInt32]  # strip pieces, group by group: fan triangle index · 2, + 1 for a quad of it and the next (D-7544)
    var covers: List[UInt32]  # polygon indexes, group by group
    var groups: List[Int]  # 4 per group: first in tris, how many; first in covers, how many
    var bounds: List[Float32]  # 4 per group: its polygons' bounds (x0, y0, x1, y1, layer units): off-canvas groups are skipped
    var run_first: List[Int]  # per run of the frame: its first group (one more entry at the end: the total)

    def __init__(out self):
        self.tris = List[UInt32]()
        self.covers = List[UInt32]()
        self.groups = List[Int]()
        self.bounds = List[Float32]()
        self.run_first = List[Int]()

    def clear(mut self):
        self.tris.clear()
        self.covers.clear()
        self.groups.clear()
        self.bounds.clear()
        self.run_first.clear()


@always_inline
def _boxes_meet(q: List[Float32], i: Int, j: Int, pad: Float32) -> Bool:
    var a = i * POLY_FLOATS + 8
    var b = j * POLY_FLOATS + 8
    var p2 = 2 * pad
    return not (q[a] > q[b + 2] + p2 or q[b] > q[a + 2] + p2 or q[a + 1] > q[b + 3] + p2 or q[b + 1] > q[a + 3] + p2)


def plan_polys(frame: Frame2D, mut plan: PolyPlan, from_run: Int = 0):
    """The polygon groups of a frame's runs into `plan`. Pads: the cover's 1.5 px at the most zoomed-out transform the
    layer is drawn with before it's built again (KEEP_ZOOMED_OUT), in the layer's units, so the grouping holds under any
    transform it's kept for. from_run > 0: runs before it are planned already (a layer that grew): only the rest."""
    var r0 = 0
    if from_run > 0 and len(plan.run_first) == from_run + 1:
        _ = plan.run_first.pop()
        r0 = from_run
    else:
        plan.clear()
    ref q = frame.polys
    for li in range(len(frame.layers)):
        ref layer = frame.layers[li]
        var pad = Float32(COVER_PAD_PX / KEEP_ZOOMED_OUT / layer.k) if layer.k > 0 else Float32(COVER_PAD_PX / KEEP_ZOOMED_OUT)
        for ri in range(layer.first_run, layer.first_run + layer.runs):
            if ri < r0:
                continue
            plan.run_first.append(len(plan.groups) // 4)
            var run = frame.runs[ri]
            if run.pipe != PIPE_POLY or run.count <= 0:
                continue
            var n = run.count
            var level = List[Int](length=n, fill=0)
            var top = 0
            if n <= LEVELS_UP_TO:
                for i in range(n):
                    var lv = 0
                    for j in range(i):
                        if level[j] + 1 > lv and _boxes_meet(q, run.first + i, run.first + j, pad):
                            lv = level[j] + 1
                    level[i] = lv
                    top = max(top, lv)
            else:  # (a cell remembers the highest group that covers it: polygons that share no cell can't meet)
                var x0: Float32 = 3e38
                var y0: Float32 = 3e38
                var x1: Float32 = -3e38
                var y1: Float32 = -3e38
                for i in range(n):
                    var at = (run.first + i) * POLY_FLOATS + 8
                    x0 = min(x0, q[at] - pad)
                    y0 = min(y0, q[at + 1] - pad)
                    x1 = max(x1, q[at + 2] + pad)
                    y1 = max(y1, q[at + 3] + pad)
                var cw = max((x1 - x0) / Float32(GRID), Float32(1e-6))
                var ch = max((y1 - y0) / Float32(GRID), Float32(1e-6))
                var cell = List[Int](length=GRID * GRID, fill=-1)
                for i in range(n):
                    var at = (run.first + i) * POLY_FLOATS + 8
                    var cx0 = min(max(Int((q[at] - pad - x0) / cw), 0), GRID - 1)
                    var cy0 = min(max(Int((q[at + 1] - pad - y0) / ch), 0), GRID - 1)
                    var cx1 = min(max(Int((q[at + 2] + pad - x0) / cw), 0), GRID - 1)
                    var cy1 = min(max(Int((q[at + 3] + pad - y0) / ch), 0), GRID - 1)
                    var lv = 0
                    for cy in range(cy0, cy1 + 1):
                        for cx in range(cx0, cx1 + 1):
                            lv = max(lv, cell[cy * GRID + cx] + 1)
                    for cy in range(cy0, cy1 + 1):
                        for cx in range(cx0, cx1 + 1):
                            cell[cy * GRID + cx] = lv
                    level[i] = lv
                    top = max(top, lv)
            # tiles half a canvas wide (in the layer's units at the zoom it's planned at), by a polygon's middle
            var tile = Float32(max(frame.width, frame.height)) / 2 / Float32(layer.k if layer.k > 0 else 1.0)
            var ox: Float32 = 3e38
            var oy: Float32 = 3e38
            for i in range(n):
                var at = (run.first + i) * POLY_FLOATS + 8
                ox = min(ox, q[at])
                oy = min(oy, q[at + 1])
            var keys = List[Int](capacity=n)  # (depth, tile, painter's order)
            for i in range(n):
                var at = (run.first + i) * POLY_FLOATS + 8
                var tx = min(Int(((q[at] + q[at + 2]) / 2 - ox) / tile), TILES - 1)
                var ty = min(Int(((q[at + 1] + q[at + 3]) / 2 - oy) / tile), TILES - 1)
                keys.append(((level[i] * TILES + ty) * TILES + tx) * n + i)
            sort(keys)
            var cur = -1
            for z in range(n):
                var key = keys[z] // n
                var i = keys[z] - key * n
                var at = (run.first + i) * POLY_FLOATS
                var t0 = Int(q[at]) // 3
                var nt = Int(q[at + 1]) // 3
                if nt <= 0:
                    continue
                if key != cur:
                    cur = key
                    plan.groups.append(len(plan.tris))
                    plan.groups.append(0)
                    plan.groups.append(len(plan.covers))
                    plan.groups.append(0)
                    for zz in range(4):
                        plan.bounds.append(q[at + 8 + zz])
                var pieces = 0
                var t = t0
                ref fan = frame.fan
                while t < t0 + nt:  # (pairs sharing their diagonal as quads: checked, not assumed)
                    var v = 6 * t
                    if (t + 1 < t0 + nt and fan[v + 6] == fan[v + 2] and fan[v + 7] == fan[v + 3]
                            and fan[v + 10] == fan[v + 4] and fan[v + 11] == fan[v + 5]):
                        plan.tris.append(UInt32(2 * t + 1))
                        t += 2
                    else:
                        plan.tris.append(UInt32(2 * t))
                        t += 1
                    pieces += 1
                plan.covers.append(UInt32(run.first + i))
                var gb = len(plan.groups) - 4
                plan.groups[gb + 1] += pieces
                plan.groups[gb + 3] += 1
                var bb = len(plan.bounds) - 4
                plan.bounds[bb] = min(plan.bounds[bb], q[at + 8])
                plan.bounds[bb + 1] = min(plan.bounds[bb + 1], q[at + 9])
                plan.bounds[bb + 2] = max(plan.bounds[bb + 2], q[at + 10])
                plan.bounds[bb + 3] = max(plan.bounds[bb + 3], q[at + 11])
    plan.run_first.append(len(plan.groups) // 4)


struct GpuLayer(Movable):
    """One Scene layer as the GPU holds it: its batches (a Frame2D of that layer alone, runs merged), its polygon groups,
    its own buffers, the zoom it was built at and the transform it's drawn with this frame. Kept between frames while
    the layer doesn't change."""

    var frame: Frame2D
    var plan: PolyPlan
    var gpu: GpuBuffers
    var valid: Bool
    var built_k: Float64
    var dx: Float64
    var dy: Float64
    var k: Float64

    def __init__(out self):
        self.frame = Frame2D()
        self.plan = PolyPlan()
        self.gpu = GpuBuffers()
        self.valid = False
        self.built_k = 1
        self.dx = 0
        self.dy = 0
        self.k = 1


def read_iosurface(io: Int, w: Int, h: Int) -> List[UInt32]:
    """An IOSurface's pixels (BGRA bytes) as gpu2d's RGBA UInt32s (R in the low byte), w × h: the readback check's."""
    var out = List[UInt32](length=w * h, fill=0)
    _ = cfunc[Int32]("IOSurfaceLock", io, UInt32(1), 0)  # read-only
    var base = cfunc("IOSurfaceGetBaseAddress", io)
    var row = cfunc("IOSurfaceGetBytesPerRow", io)
    for y in range(h):
        var p = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=base + y * row)
        for x in range(w):
            var v = p.unsafe_offset(x)[]
            out[y * w + x] = (v & 0xFF00FF00) | ((v >> 16) & 0xFF) | ((v & 0xFF) << 16)
    _ = cfunc[Int32]("IOSurfaceUnlock", io, UInt32(1), 0)
    return out^


def metal_device_name() -> String:
    """The system's Metal device's name, or "" when this Mac has none (or no Metal at all): the cheap probe a host runs
    at start, before it says which backend it has (mojoui.gpu2d_backend); the pipelines are built when first needed."""
    var path = String("/System/Library/Frameworks/Metal.framework/Metal")
    var cpath = path.as_c_string_span()
    var handle = cfunc("dlopen", Int(cpath.ptr()), 9)
    _ = path.byte_length()
    if handle == 0:
        return ""
    var create = _sym(handle, "MTLCreateSystemDefaultDevice")
    if create == 0:
        return ""
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=create)
    var make = Pointer(to=raw).unsafe_bitcast[def() thin abi("C") -> Int]()[]
    var device = make()
    if device == 0:
        return ""
    var name = from_ns(msg(device, "name"))
    _ = msg(device, "release")
    return name if name != "" else String("Metal")


struct MetalCanvas2D(Movable):
    """What a host keeps to draw .gpu() canvases with Metal: the font and its atlas, the Metal pipelines, the Scene the
    app paints into (and last frame's, to compare), and the layers as the GPU holds them, with the GL backend's rules
    (D-7533, D-7538): a layer Scene.same_layer finds unchanged keeps its batches and buffers and is drawn through its
    new transform when its batches don't depend on it (no text, fills, images or clips) and it isn't zoomed out more
    than 4× from where it was built, or when it didn't move; a layer that only gained ops at its end (a finished
    stroke) gets just those built, planned and uploaded after the rest; any other changed layer is built alone
    (fill_layers), its runs merged (merge_runs), planned and uploaded."""

    var font: Font
    var atlas: GlyphAtlas
    var metal: Metal2D
    var scene: Scene  # this frame's (the app paints into it)
    var prev: Scene  # last frame's
    var scratch: Frame2D  # (a changed layer's batches as built, before merge_runs)
    var frame: Frame2D  # a whole frame's batches (the CPU fallback and the readback check)
    var layers: List[GpuLayer]
    var owner: Int  # the canvas the layers belong to (another canvas drawing starts them again)
    var merge: Bool  # merge_runs on (MOJOUI_GPU2D_MERGE=0: the runs as built)
    var rebuilt: Int  # layers built and uploaded / reused as they were / grown this frame
    var kept: Int
    var grown: Int
    var groups: Int  # polygon groups drawn this frame
    var build_ms: Float64  # this frame's layer building, planning and uploading (ms)

    def __init__(out self):
        var font = Font()
        var atlas = GlyphAtlas(font)
        self.metal = Metal2D(atlas)
        self.font = font^
        self.atlas = atlas^
        self.scene = Scene(0, 0, 1)
        self.prev = Scene(0, 0, 1)
        self.scratch = Frame2D()
        self.frame = Frame2D()
        self.layers = List[GpuLayer]()
        self.owner = -1
        self.merge = getenv("MOJOUI_GPU2D_MERGE") != "0"
        self.rebuilt = 0
        self.kept = 0
        self.grown = 0
        self.groups = 0
        self.build_ms = 0

    def render_scene(mut self, owner: Int, io: Int, w: Int, h: Int, drawable: Int = 0) -> Bool:
        """This frame's Scene (painted by the app into self.scene) into IOSurface `io` on the GPU: layers that changed
        are built (or grown) and uploaded, the others kept (the rules above); then one pass draws them all in order.
        Call end_frame afterwards (whatever this returned)."""
        self.rebuilt = 0
        self.kept = 0
        self.grown = 0
        self.groups = 0
        var t0 = Int(now_ns())
        ref sc = self.scene
        var n = sc.layers()
        var cached = owner == self.owner and sc.w == self.prev.w and sc.h == self.prev.h and sc.k == self.prev.k
        while len(self.layers) < n:
            self.layers.append(GpuLayer())
        var open = 0  # (clips left open by earlier layers)
        for i in range(n):
            var span = sc.layer_range(i)
            var fixed = open == 0  # (its batches don't depend on its transform)
            for op in range(span[0], span[1]):
                var kind = Int(sc.kinds[op])
                if kind == OP_TEXT or kind == OP_FILL or kind == OP_IMAGE:
                    fixed = False
                elif kind == OP_CLIP:
                    fixed = False
                    open += 1
                elif kind == OP_UNCLIP:
                    fixed = False
                    open = max(open - 1, 0)
            ref L = self.layers[i]
            var known = cached and L.valid and i < self.prev.layers()
            var same_place = known and sc.layer_tx[i] == self.prev.layer_tx[i] and sc.layer_ty[i] == self.prev.layer_ty[i] and sc.layer_tk[i] == self.prev.layer_tk[i]
            var done = False
            if known and sc.same_layer(i, self.prev, i):
                var near = sc.layer_tk[i] >= L.built_k * KEEP_ZOOMED_OUT
                if same_place or (fixed and near):
                    self.kept += 1
                    done = True
            if not done and same_place and len(L.frame.layers) == 1 and len(L.frame.runs) < 96 and len(L.frame.images) == 0:
                var shared = sc.appends(i, self.prev, i)  # (a layer that only grew: its new ops alone, after the rest)
                if shared >= 0:
                    fill_layers(self.scratch, sc, self.atlas, self.font, i, i + 1, shared)
                    var r = append_frame(L.frame, self.scratch)
                    if r >= 0:
                        L.frame.layers[0].key = sc.layer_keys[i].copy()
                        L.frame.layers[0].version = sc.layer_versions[i]
                        plan_polys(L.frame, L.plan, r)
                        self.metal.upload(L.frame, L.plan, L.gpu, True)
                        self.grown += 1
                        done = True
            if not done:
                if self.merge:
                    fill_layers(self.scratch, sc, self.atlas, self.font, i, i + 1)
                    merge_runs(self.scratch, L.frame)
                else:
                    fill_layers(L.frame, sc, self.atlas, self.font, i, i + 1)
                plan_polys(L.frame, L.plan)
                self.metal.upload(L.frame, L.plan, L.gpu)
                L.valid = True
                L.built_k = sc.layer_tk[i]
                self.rebuilt += 1
            L.dx = sc.layer_tx[i]
            L.dy = sc.layer_ty[i]
            L.k = sc.layer_tk[i]
            self.groups += len(L.plan.groups) // 4
        for i in range(n, len(self.layers)):
            self.layers[i].valid = False
        self.owner = owner
        self.build_ms = Float64(Int(now_ns()) - t0) / 1e6
        return self.metal.render_layers(self.layers, n, io, w, h, drawable)

    def end_frame(mut self):
        """This frame's Scene becomes last frame's (its memory: next frame's to paint into)."""
        swap(self.scene, self.prev)
