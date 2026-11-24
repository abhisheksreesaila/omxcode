# The GL backend of the GPU 2D renderer (goal 75 M2): a Frame2D (mojoui.gpu2d's batches) drawn by OpenGL into an RGBA8
# texture, over a GL context someone else made current (GTK's GdkGLContext in the GTK host; an EGL context in tests).
#
#   var gl = GL2D()
#   gl.start(es)                          # once, context current: GL entry points, 5 programs, buffers (no compile later)
#   gl.upload_atlas(atlas)                # once: GlyphAtlas → an R8 texture
#   var slot = gl.acquire(w, h)           # a ring texture the toolkit isn't showing (-1: all held)
#   gl.render(frame, gl.tex[slot], w, h)  # each frame: one upload per pipeline, the runs, the MSAA resolve into it
#   gl.fence(slot)                        # a GL sync object for whoever shows the texture
#
# How each pipeline draws (the instance layouts and the coverage rules are mojoui/gpu2d.mojo's header):
#   QUAD, GLYPH: one instanced triangle per shape, holding its box padded by 1.5 px (every pixel with coverage is wholly
#     inside it, so all its samples are covered: the shader's coverage alone makes the edge, exactly as the CPU
#     executor). One triangle, not a two-triangle strip: with one colour sample (mixed samples, below) a pixel on a
#     strip's diagonal would be blended twice, each time with part of the coverage. The fragment shader runs at the pixel centre (gl_FragCoord), tests the clip there, and computes the
#     box SDF / capsule distance / glyph bilinear (+2×2 supersamples when shrunk) with the CPU executor's formulas;
#     glyphs read the R8 atlas with texelFetch (the bilinear done by hand: the same weights as GlyphAtlas.coverage).
#   IMAGE: one draw per image (few), its texture bound; nearest texel by the pixel-centre rule; blending off.
#   POLY: stencil and cover with 8 stencil samples a pixel: the fan into the stencil (front faces INCR_WRAP, back
#     DECR_WRAP: non-zero winding), then the bounds (one triangle) where stencil ≠ 0 (op ZERO: the cover clears what it
#     covers). The target: with NV_framebuffer_mixed_samples (NVIDIA), the ring texture itself is the colour buffer (1
#     sample) and each cover fragment's alpha is scaled by the share of its pixel's 8 stencil samples that passed
#     (coverage modulation): the edge's anti-aliasing with no MSAA colour buffer and no resolve, which at the idle
#     memory clock the light per-frame load leaves the GPU in (P8, 405 MHz) cost ~1.5 ms a frame at 1699×1384.
#     Elsewhere: an 8× MSAA colour + stencil target resolved (blit) into the texture.
#     Polygons whose cover triangles miss each other's bounds (and that share a clip) share one fan draw and one cover
#     draw: groups planned once when a layer is uploaded (plan_polys: by overlap depth for runs up to LEVELS_UP_TO
#     polygons, consecutive ones beyond), the covers per vertex (3 per polygon, no attribute re-pointing per group); a
#     clip is the scissor (by the pixel-centre rule), so neither the fan nor the cover leaves stencil outside it.
#   Before upload, GPU2D regroups a changed layer's runs (mojoui.gpu2d_merge.merge_runs: runs of one pipeline that only
#     non-overlapping runs keep apart become one; the CPU executor draws both the same, to the pixel).
# Pixels: row 0 of the texture is the picture's top row (y down: NDC y = 2·y/h − 1, no flip), as mojoui.present's
# textures and as GTK's GdkGLTexture reads them; glReadPixels returns rows top first. Colours stay straight alpha
# (BLEND_OVER = glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ZERO, ONE): the destination's alpha kept), the
# texture holds what SurfacePainter would (an opaque canvas: alpha 255 everywhere its fill reached).
# Shaders are GLSL 3.30 core or GLSL ES 3.00 (whichever context the host has): one body, two first lines.

from std.ffi import c_int, c_uint, c_char
from std.memory import Pointer
from std.os import getenv
from std.time import perf_counter_ns
from mojoui.present import fcall, dl_open, dl_sym, c_text
from mojoui.text import Font
from mojoui.scene import Scene, OP_TEXT, OP_RUN, OP_FILL, OP_IMAGE, OP_CLIP, OP_UNCLIP
from mojoui.gpu2d import (glyph_pages, DYN_ROWS, layer_traits, Frame2D, GlyphAtlas, fill_batches, fill_layers, PIPE_QUAD, PIPE_GLYPH, PIPE_IMAGE, PIPE_POLY, QUAD_FLOATS, GLYPH_FLOATS,
                          IMAGE_FLOATS, POLY_FLOATS, BLEND_OVER, BLEND_REPLACE, NO_CLIP)
from mojoui.gpu2d_merge import merge_runs, append_frame
from mojoui.gpu2d_dmabuf import DmabufExport
from mojoui.gpu2d_tiles import TILE_MIN_OPS, Tiles, TilePlan, TileDraw, TileRead, TILE, TILE_TEX, _pack
from mojoui.viewsnap import snap_take, set_renderer_id, fnv, rle_decode, snapshots_expected
from max.algorithm import parallelize
from std.sys.info import num_logical_cores

comptime RING = 6  # textures in the ring: one on screen, one being drawn, the rest waiting for the toolkit to let go

comptime GL_TEXTURE_2D = 0x0DE1
comptime GL_RENDERER = 0x1F01
comptime GL_VERSION = 0x1F02
comptime GL_RGBA8 = 0x8058
comptime GL_RGBA16F = 0x881A
comptime GL_R8 = 0x8229
comptime GL_RED = 0x1903
comptime GL_RGBA = 0x1908
comptime GL_UNSIGNED_BYTE = 0x1401
comptime GL_FLOAT = 0x1406
comptime GL_TEXTURE_MIN_FILTER = 0x2801
comptime GL_TEXTURE_MAG_FILTER = 0x2800
comptime GL_TEXTURE_WRAP_S = 0x2802
comptime GL_TEXTURE_WRAP_T = 0x2803
comptime GL_CLAMP_TO_EDGE = 0x812F
comptime GL_NEAREST = 0x2600
comptime GL_LINEAR = 0x2601
comptime GL_FRAMEBUFFER = 0x8D40
comptime GL_READ_FRAMEBUFFER = 0x8CA8
comptime GL_DRAW_FRAMEBUFFER = 0x8CA9
comptime GL_RENDERBUFFER = 0x8D41
comptime GL_COLOR_ATTACHMENT0 = 0x8CE0
comptime GL_DEPTH_STENCIL_ATTACHMENT = 0x821A
comptime GL_DEPTH24_STENCIL8 = 0x88F0
comptime GL_FRAMEBUFFER_COMPLETE = 0x8CD5
comptime GL_ARRAY_BUFFER = 0x8892
comptime GL_STREAM_DRAW = 0x88E0
comptime GL_TRIANGLES = 4
comptime GL_TRIANGLE_STRIP = 5
comptime GL_BLEND = 0x0BE2
comptime GL_STENCIL_TEST = 0x0B90
comptime GL_SCISSOR_TEST = 0x0C11
comptime GL_DEPTH_TEST = 0x0B71
comptime GL_CULL_FACE = 0x0B44
comptime GL_DITHER = 0x0BD0
comptime GL_ZERO = 0
comptime GL_ONE = 1
comptime GL_SRC_ALPHA = 0x0302
comptime GL_ONE_MINUS_SRC_ALPHA = 0x0303
comptime GL_ALWAYS = 0x0207
comptime GL_NOTEQUAL = 0x0205
comptime GL_KEEP = 0x1E00
comptime GL_INCR_WRAP = 0x8507
comptime GL_DECR_WRAP = 0x8508
comptime GL_FRONT = 0x0404
comptime GL_BACK = 0x0405
comptime GL_COLOR_BUFFER_BIT = 0x4000
comptime GL_STENCIL_BUFFER_BIT = 0x0400
comptime GL_VERTEX_SHADER = 0x8B31
comptime GL_FRAGMENT_SHADER = 0x8B30
comptime GL_COMPILE_STATUS = 0x8B81
comptime GL_LINK_STATUS = 0x8B82
comptime GL_TEXTURE0 = 0x84C0
comptime GL_PACK_ALIGNMENT = 0x0D05
comptime GL_UNPACK_ALIGNMENT = 0x0CF5
comptime GL_MAX_SAMPLES = 0x8D57
comptime GL_SYNC_GPU_COMMANDS_COMPLETE = 0x9117
comptime GL_SYNC_FLUSH_COMMANDS_BIT = 0x1
comptime GL_EXTENSIONS = 0x1F03
comptime GL_NUM_EXTENSIONS = 0x821D
comptime GL_ALPHA = 0x1906

# the GL entry points, looked up once (start): their indexes into GL2D.fp
comptime F_GET_STRING = 0
comptime F_GET_ERROR = 1
comptime F_GET_INTEGERV = 2
comptime F_ENABLE = 3
comptime F_DISABLE = 4
comptime F_VIEWPORT = 5
comptime F_SCISSOR = 6
comptime F_CLEAR_COLOR = 7
comptime F_CLEAR_STENCIL = 8
comptime F_CLEAR = 9
comptime F_COLOR_MASK = 10
comptime F_STENCIL_MASK = 11
comptime F_STENCIL_FUNC = 12
comptime F_STENCIL_OP = 13
comptime F_STENCIL_OP_SEPARATE = 14
comptime F_BLEND_FUNC_SEPARATE = 15
comptime F_GEN_TEXTURES = 16
comptime F_DELETE_TEXTURES = 17
comptime F_BIND_TEXTURE = 18
comptime F_TEX_PARAMETERI = 19
comptime F_TEX_STORAGE_2D = 20
comptime F_TEX_SUB_IMAGE_2D = 21
comptime F_PIXEL_STOREI = 22
comptime F_ACTIVE_TEXTURE = 23
comptime F_GEN_FRAMEBUFFERS = 24
comptime F_DELETE_FRAMEBUFFERS = 25
comptime F_BIND_FRAMEBUFFER = 26
comptime F_FRAMEBUFFER_TEXTURE_2D = 27
comptime F_FRAMEBUFFER_RENDERBUFFER = 28
comptime F_CHECK_FRAMEBUFFER_STATUS = 29
comptime F_GEN_RENDERBUFFERS = 30
comptime F_DELETE_RENDERBUFFERS = 31
comptime F_BIND_RENDERBUFFER = 32
comptime F_RENDERBUFFER_STORAGE_MS = 33
comptime F_BLIT_FRAMEBUFFER = 34
comptime F_GEN_BUFFERS = 35
comptime F_DELETE_BUFFERS = 36
comptime F_BIND_BUFFER = 37
comptime F_BUFFER_DATA = 38
comptime F_GEN_VERTEX_ARRAYS = 39
comptime F_DELETE_VERTEX_ARRAYS = 40
comptime F_BIND_VERTEX_ARRAY = 41
comptime F_ENABLE_VERTEX_ATTRIB_ARRAY = 42
comptime F_VERTEX_ATTRIB_POINTER = 43
comptime F_VERTEX_ATTRIB_DIVISOR = 44
comptime F_CREATE_PROGRAM = 45
comptime F_CREATE_SHADER = 46
comptime F_SHADER_SOURCE = 47
comptime F_COMPILE_SHADER = 48
comptime F_GET_SHADERIV = 49
comptime F_GET_SHADER_INFO_LOG = 50
comptime F_ATTACH_SHADER = 51
comptime F_DELETE_SHADER = 52
comptime F_LINK_PROGRAM = 53
comptime F_GET_PROGRAMIV = 54
comptime F_DELETE_PROGRAM = 55
comptime F_USE_PROGRAM = 56
comptime F_GET_UNIFORM_LOCATION = 57
comptime F_UNIFORM_2F = 58
comptime F_UNIFORM_3F = 59
comptime F_UNIFORM_4F = 60
comptime F_UNIFORM_1I = 61
comptime F_DRAW_ARRAYS = 62
comptime F_DRAW_ARRAYS_INSTANCED = 63
comptime F_FENCE_SYNC = 64
comptime F_DELETE_SYNC = 65
comptime F_CLIENT_WAIT_SYNC = 66
comptime F_FLUSH = 67
comptime F_FINISH = 68
comptime F_READ_PIXELS = 69
comptime F_BUFFER_SUB_DATA = 70
comptime F_GET_STRINGI = 71
comptime F_MAP_BUFFER_RANGE = 72
comptime F_UNMAP_BUFFER = 73
comptime F_COUNT = 74
comptime C_BYTES = 0  # (D-7965) counters after the entry points'
comptime C_MULTI = 1
comptime C_EXT = 2
comptime C_BASE = 3
comptime BOX_VERTS = 3  # a quad's or glyph's box: one triangle holding it (D-7972: cut to clip and scissor)
comptime KIND_QUAD = 0  # (D-7971) GPU time kinds
comptime KIND_GLYPH = 1
comptime KIND_POLY = 2
comptime KIND_IMAGE = 3
comptime KIND_CLEAR = 4
comptime KIND_TILES = 5
comptime GL_PIXEL_UNPACK_BUFFER = 0x88EC
comptime GL_MAP_WRITE_BIT = 0x0002
comptime GL_MAP_INVALIDATE_BUFFER_BIT = 0x0008
comptime GL_MAP_UNSYNCHRONIZED_BIT = 0x0020


def _gl_names() -> List[String]:
    return ["glGetString", "glGetError", "glGetIntegerv", "glEnable", "glDisable", "glViewport", "glScissor", "glClearColor",
            "glClearStencil", "glClear", "glColorMask", "glStencilMask", "glStencilFunc", "glStencilOp", "glStencilOpSeparate",
            "glBlendFuncSeparate", "glGenTextures", "glDeleteTextures", "glBindTexture", "glTexParameteri", "glTexStorage2D",
            "glTexSubImage2D", "glPixelStorei", "glActiveTexture", "glGenFramebuffers", "glDeleteFramebuffers",
            "glBindFramebuffer", "glFramebufferTexture2D", "glFramebufferRenderbuffer", "glCheckFramebufferStatus",
            "glGenRenderbuffers", "glDeleteRenderbuffers", "glBindRenderbuffer", "glRenderbufferStorageMultisample",
            "glBlitFramebuffer", "glGenBuffers", "glDeleteBuffers", "glBindBuffer", "glBufferData", "glGenVertexArrays",
            "glDeleteVertexArrays", "glBindVertexArray", "glEnableVertexAttribArray", "glVertexAttribPointer",
            "glVertexAttribDivisor", "glCreateProgram", "glCreateShader", "glShaderSource", "glCompileShader", "glGetShaderiv",
            "glGetShaderInfoLog", "glAttachShader", "glDeleteShader", "glLinkProgram", "glGetProgramiv", "glDeleteProgram",
            "glUseProgram", "glGetUniformLocation", "glUniform2f", "glUniform3f", "glUniform4f", "glUniform1i", "glDrawArrays",
            "glDrawArraysInstanced", "glFenceSync", "glDeleteSync", "glClientWaitSync", "glFlush", "glFinish", "glReadPixels",
            "glBufferSubData", "glGetStringi", "glMapBufferRange", "glUnmapBuffer"]


# ---- the shaders (one body; GLSL 3.30 core or ES 3.00 first lines) ----

comptime HEAD_CORE = "#version 330 core\n"
comptime HEAD_ES = "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n"

# QUAD: 0 a,b,c,d  1 radius,shape  2 colour  3 clip
comptime QUAD_VS = """
layout(location = 0) in vec4 a_geom;
layout(location = 1) in vec4 a_par;
layout(location = 2) in vec4 a_col;
layout(location = 3) in vec4 a_clip;
uniform vec2 vp;
uniform vec3 xf;
uniform vec4 lim;
flat out vec4 v_geom;
flat out vec2 v_par;
flat out vec4 v_col;
flat out vec4 v_clip;
flat out float v_hole;
void main() {
    v_hole = 0.0;
    float k = xf.z;
    vec2 t = xf.xy;
    v_clip = a_clip * k + vec4(t, t);
    v_col = a_col;
    // (D-7972) one triangle holding the box (it must: a seam between two would blend twice under coverage
    // modulation), the box first cut to the clip and to the scissor (lim): pixels outside them were discarded anyway
    vec2 corner = vec2(gl_VertexID == 1 ? 2.0 : 0.0, gl_VertexID == 2 ? 2.0 : 0.0);
    vec2 p;
    if (a_par.y < 0.5) {
        float x = a_geom.x * k + t.x;
        float y = a_geom.y * k + t.y;
        float w = a_geom.z * k;
        float h = a_geom.w * k;
        v_geom = vec4(x, y, w, h);
        v_par = vec2(min(a_par.x * k, min(w, h) * 0.5), 0.0);
        v_hole = a_par.z * k;
        if (w <= 0.0 || h <= 0.0) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }
        vec2 lo = max(max(vec2(x, y) - 1.5, v_clip.xy - 0.5), lim.xy - 0.5);
        vec2 hi = min(min(vec2(x + w, y + h) + 1.5, v_clip.zw + 0.5), lim.zw + 0.5);
        if (hi.x <= lo.x || hi.y <= lo.y) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }
        p = mix(lo, hi, corner);
    } else {
        vec2 A = a_geom.xy * k + t;
        vec2 B = a_geom.zw * k + t;
        float hw = a_par.x * k;
        v_geom = vec4(A, B);
        v_par = vec2(hw, 1.0);
        vec2 d = B - A;
        float L = length(d);
        vec2 u = L > 1e-6 ? d / L : vec2(1.0, 0.0);
        vec2 n = vec2(-u.y, u.x);
        float e = hw + 1.5;
        p = A - u * e + u * ((L + 2.0 * e) * corner.x) + n * (e * (corner.y * 2.0 - 1.0));
    }
    gl_Position = vec4(p / vp * 2.0 - 1.0, 0.0, 1.0);
}
"""

# (D-7972) the shaders before two-triangle boxes: MOJOUI_GL_ONE_TRI=1 (the comparison tests/test_boxverts draws)
comptime QUAD_VS_ONE_TRI = """
layout(location = 0) in vec4 a_geom;
layout(location = 1) in vec4 a_par;
layout(location = 2) in vec4 a_col;
layout(location = 3) in vec4 a_clip;
uniform vec2 vp;
uniform vec3 xf;
flat out vec4 v_geom;
flat out vec2 v_par;
flat out vec4 v_col;
flat out vec4 v_clip;
flat out float v_hole;
void main() {
    v_hole = 0.0;
    float k = xf.z;
    vec2 t = xf.xy;
    v_clip = a_clip * k + vec4(t, t);
    v_col = a_col;
    vec2 corner = vec2(gl_VertexID == 1 ? 2.0 : 0.0, gl_VertexID == 2 ? 2.0 : 0.0);  // (one triangle holding the box)
    vec2 p;
    if (a_par.y < 0.5) {
        float x = a_geom.x * k + t.x;
        float y = a_geom.y * k + t.y;
        float w = a_geom.z * k;
        float h = a_geom.w * k;
        v_geom = vec4(x, y, w, h);
        v_par = vec2(min(a_par.x * k, min(w, h) * 0.5), 0.0);
        if (w <= 0.0 || h <= 0.0) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }
        p = mix(vec2(x, y) - 1.5, vec2(x + w, y + h) + 1.5, corner);
    } else {
        vec2 A = a_geom.xy * k + t;
        vec2 B = a_geom.zw * k + t;
        float hw = a_par.x * k;
        v_geom = vec4(A, B);
        v_par = vec2(hw, 1.0);
        vec2 d = B - A;
        float L = length(d);
        vec2 u = L > 1e-6 ? d / L : vec2(1.0, 0.0);
        vec2 n = vec2(-u.y, u.x);
        float e = hw + 1.5;
        p = A - u * e + u * ((L + 2.0 * e) * corner.x) + n * (e * (corner.y * 2.0 - 1.0));
    }
    gl_Position = vec4(p / vp * 2.0 - 1.0, 0.0, 1.0);
}
"""

comptime GLYPH_VS_ONE_TRI = """
layout(location = 0) in vec4 a_box;
layout(location = 1) in vec4 a_uv;
layout(location = 2) in vec4 a_col;
layout(location = 3) in vec4 a_sl;
layout(location = 4) in vec4 a_clip;
uniform vec2 vp;
uniform vec3 xf;
flat out vec4 g_box;
flat out vec4 g_uv;
flat out float g_base;
flat out vec4 v_col;
flat out vec4 v_clip;
void main() {
    float k = xf.z;
    vec2 t = xf.xy;
    float left = a_box.x * k + t.x;
    float top = a_box.y * k + t.y;
    float gw = a_uv.z - a_uv.x;
    float gh = a_uv.w - a_uv.y;
    float sc = gw > 0.0 ? a_box.z * k / gw : 1.0;
    float slant = a_sl.x;
    float base = a_sl.y * k + t.y;
    g_box = vec4(left, top, sc, slant);
    g_uv = vec4(a_uv.xy, gw, gh);
    g_base = base;
    v_col = a_col;
    v_clip = a_clip * k + vec4(t, t);
    if (gw <= 0.0 || gh <= 0.0) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }
    float lean_top = slant * (base - top);
    float lean_bottom = slant * (base - top - gh * sc);
    vec2 lo = vec2(left + min(lean_bottom, 0.0), top) - 1.5;
    vec2 hi = vec2(left + gw * sc + max(lean_top, 0.0), top + gh * sc) + 1.5;
    vec2 corner = vec2(gl_VertexID == 1 ? 2.0 : 0.0, gl_VertexID == 2 ? 2.0 : 0.0);  // (one triangle holding the box)
    vec2 p = mix(lo, hi, corner);
    gl_Position = vec4(p / vp * 2.0 - 1.0, 0.0, 1.0);
}
"""

comptime QUAD_FS = """
flat in vec4 v_geom;
flat in vec2 v_par;
flat in vec4 v_col;
flat in vec4 v_clip;
flat in float v_hole;
uniform int replace;
out vec4 o;
void main() {
    vec2 c = gl_FragCoord.xy;
    if (c.x < v_clip.x || c.y < v_clip.y || c.x >= v_clip.z || c.y >= v_clip.w) discard;
    float cov;
    if (v_par.y < 0.5) {
        float x = v_geom.x;
        float y = v_geom.y;
        float w = v_geom.z;
        float h = v_geom.w;
        // (D-7973) the middle an opaque cover will hide: left out
        if (v_hole > 0.0 && c.x > x + v_hole + 0.5 && c.x < x + w - v_hole - 0.5 && c.y > y + v_hole + 0.5 && c.y < y + h - v_hole - 0.5) discard;
        float r = v_par.x;
        float vy = min(c.y - y, y + h - c.y) + 0.5;
        cov = min(min(c.x - x, x + w - c.x) + 0.5, vy);
        if (r > 0.0) {
            float dx = max(max(x + r - c.x, c.x - (x + w - r)), 0.0);
            float dy = max(max(y + r - c.y, c.y - (y + h - r)), 0.0);
            if (dx > 0.0 && dy > 0.0) cov = min(cov, r - sqrt(dx * dx + dy * dy) + 0.5);
        }
    } else {
        vec2 A = v_geom.xy;
        vec2 d = v_geom.zw - A;
        float l2 = dot(d, d);
        float s = l2 == 0.0 ? 0.0 : clamp(dot(c - A, d) / l2, 0.0, 1.0);
        cov = v_par.x + 0.5 - length(c - (A + s * d));
    }
    if (cov <= 0.0) discard;
    o = replace != 0 ? v_col : vec4(v_col.rgb, v_col.a * min(cov, 1.0));
}
"""

# GLYPH: 0 x,y,w,h  1 u0,v0,u1,v1  2 colour  3 slant,baseline  4 clip
comptime GLYPH_VS = """
layout(location = 0) in vec4 a_box;
layout(location = 1) in vec4 a_uv;
layout(location = 2) in vec4 a_col;
layout(location = 3) in vec4 a_sl;
layout(location = 4) in vec4 a_clip;
uniform vec2 vp;
uniform vec3 xf;
uniform vec4 lim;
flat out vec4 g_box;
flat out vec4 g_uv;
flat out float g_base;
flat out vec4 v_col;
flat out vec4 v_clip;
void main() {
    float k = xf.z;
    vec2 t = xf.xy;
    float left = a_box.x * k + t.x;
    float top = a_box.y * k + t.y;
    float gw = a_uv.z - a_uv.x;
    float gh = a_uv.w - a_uv.y;
    float sc = gw > 0.0 ? a_box.z * k / gw : 1.0;
    float slant = a_sl.x;
    float base = a_sl.y * k + t.y;
    g_box = vec4(left, top, sc, slant);
    g_uv = vec4(a_uv.xy, gw, gh);
    g_base = base;
    v_col = a_col;
    v_clip = a_clip * k + vec4(t, t);
    if (gw <= 0.0 || gh <= 0.0) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }
    float lean_top = slant * (base - top);
    float lean_bottom = slant * (base - top - gh * sc);
    vec2 lo = vec2(left + min(lean_bottom, 0.0), top) - 1.5;
    vec2 hi = vec2(left + gw * sc + max(lean_top, 0.0), top + gh * sc) + 1.5;
    vec2 corner = vec2(gl_VertexID == 1 ? 2.0 : 0.0, gl_VertexID == 2 ? 2.0 : 0.0);  // (D-7972: one triangle over the box cut to clip and scissor)
    lo = max(max(lo, v_clip.xy - 0.5), lim.xy - 0.5);
    hi = min(min(hi, v_clip.zw + 0.5), lim.zw + 0.5);
    if (hi.x <= lo.x || hi.y <= lo.y) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }
    vec2 p = mix(lo, hi, corner);
    gl_Position = vec4(p / vp * 2.0 - 1.0, 0.0, 1.0);
}
"""

comptime GLYPH_FS = """
flat in vec4 g_box;
flat in vec4 g_uv;
flat in float g_base;
flat in vec4 v_col;
flat in vec4 v_clip;
uniform sampler2D atlas;
out vec4 o;
float at(ivec2 p, ivec2 n) {
    if (p.x < 0 || p.y < 0 || p.x >= n.x || p.y >= n.y) return 0.0;
    return texelFetch(atlas, p, 0).r;
}
float bil(vec2 q, ivec2 n) {
    vec2 f0 = floor(q - 0.5);
    ivec2 i = ivec2(f0);
    vec2 f = q - 0.5 - f0;
    float a = at(i, n);
    float b = at(i + ivec2(1, 0), n);
    float c = at(i + ivec2(0, 1), n);
    float d = at(i + ivec2(1, 1), n);
    return (a * (1.0 - f.x) + b * f.x) * (1.0 - f.y) + (c * (1.0 - f.x) + d * f.x) * f.y;
}
void main() {
    vec2 c = gl_FragCoord.xy;
    if (c.x < v_clip.x || c.y < v_clip.y || c.x >= v_clip.z || c.y >= v_clip.w) discard;
    ivec2 n = textureSize(atlas, 0);
    float sc = g_box.z;
    int sub = sc < 0.75 ? 2 : 1;
    float fs = float(sub);
    float row_left = g_box.x + g_box.w * (g_base - c.y);
    float px = c.x - 0.5;
    float py = c.y - 0.5;
    float cov = 0.0;
    for (int sy = 0; sy < sub; sy++) {
        for (int sx = 0; sx < sub; sx++) {
            float ax = (px + (float(sx) + 0.5) / fs - row_left) / sc;
            float ay = (py + (float(sy) + 0.5) / fs - g_box.y) / sc;
            if (ax >= 0.0 && ax < g_uv.z && ay >= 0.0 && ay < g_uv.w) cov += bil(vec2(g_uv.x + ax, g_uv.y + ay), n);
        }
    }
    cov = cov / (fs * fs) * v_col.a;
    if (cov <= 0.003) discard;
    o = vec4(v_col.rgb, cov);
}
"""

# IMAGE: uniforms per draw (few images; each its own texture)
comptime IMAGE_VS = """
uniform vec2 vp;
uniform vec3 xf;
uniform vec4 rect;
uniform vec4 clip;
flat out vec4 v_rect;
flat out vec4 v_clip;
void main() {
    float k = xf.z;
    vec2 t = xf.xy;
    v_rect = vec4(rect.xy * k + t, rect.zw * k);
    v_clip = clip * k + vec4(t, t);
    vec2 corner = vec2(gl_VertexID == 1 ? 2.0 : 0.0, gl_VertexID == 2 ? 2.0 : 0.0);  // (one triangle holding the box)
    vec2 p = mix(v_rect.xy - 1.5, v_rect.xy + v_rect.zw + 1.5, corner);
    gl_Position = vec4(p / vp * 2.0 - 1.0, 0.0, 1.0);
}
"""

comptime IMAGE_FS = """
flat in vec4 v_rect;
flat in vec4 v_clip;
uniform sampler2D img;
out vec4 o;
void main() {
    vec2 c = gl_FragCoord.xy;
    if (c.x < v_clip.x || c.y < v_clip.y || c.x >= v_clip.z || c.y >= v_clip.w) discard;
    if (c.x < v_rect.x || c.y < v_rect.y || c.x >= v_rect.x + v_rect.z || c.y >= v_rect.y + v_rect.w) discard;
    ivec2 n = textureSize(img, 0);
    int sx = min(n.x - 1, int(floor((c.x - v_rect.x) / v_rect.z * float(n.x))));
    int sy = min(n.y - 1, int(floor((c.y - v_rect.y) / v_rect.w * float(n.y))));
    o = texelFetch(img, ivec2(sx, sy), 0);
}
"""

# POLY: the fan (x, y per vertex) into the stencil; then the cover (instanced: 1 colour, 2 bounds)
comptime FAN_VS = """
layout(location = 0) in vec2 a_pos;
uniform vec2 vp;
uniform vec3 xf;
void main() {
    vec2 p = a_pos * xf.z + xf.xy;
    gl_Position = vec4(p / vp * 2.0 - 1.0, 0.0, 1.0);
}
"""

comptime FAN_FS = """
out vec4 o;
void main() { o = vec4(0.0); }
"""

comptime COVER_VS = """
layout(location = 1) in vec4 a_col;
layout(location = 2) in vec4 a_bounds;
uniform vec2 vp;
uniform vec3 xf;
flat out vec4 v_col;
void main() {
    v_col = a_col;
    vec2 lo = a_bounds.xy * xf.z + xf.xy;  // (bounds padded when planned, in the layer's units: see plan_polys)
    vec2 hi = a_bounds.zw * xf.z + xf.xy;
    int c = gl_VertexID - (gl_VertexID / 3) * 3;  // (3 vertices per polygon: one triangle holding its bounds)
    vec2 corner = vec2(c == 1 ? 2.0 : 0.0, c == 2 ? 2.0 : 0.0);
    vec2 p = mix(lo, hi, corner);
    gl_Position = vec4(p / vp * 2.0 - 1.0, 0.0, 1.0);
}
"""

comptime COVER_FS = """
flat in vec4 v_col;
out vec4 o;
void main() { o = v_col; }  // (no discard: the stencil test runs before the shader)
"""

# TILE (D-7940): a kept raster tile (premultiplied, mojoui.gpu2d_tiles) drawn under its layer's transform. One triangle
# holds the draw's rect; a pixel is drawn when its centre is in the clip and its content point falls in the tile (each
# pixel belongs to exactly one tile); nearest texel at 1:1, bilinear when scaled (the border ring holds the neighbours).
comptime TILE_VS = """
uniform vec2 vp;
uniform vec4 rect;
void main() {
    vec2 corner = vec2(gl_VertexID == 1 ? 2.0 : 0.0, gl_VertexID == 2 ? 2.0 : 0.0);
    vec2 p = mix(rect.xy - 1.5, rect.zw + 1.5, corner);
    gl_Position = vec4(p / vp * 2.0 - 1.0, 0.0, 1.0);
}
"""

comptime TILE_FS = """
uniform sampler2D tile;
uniform vec4 clip;
uniform vec4 map;
uniform vec2 org;
uniform int lin;
out vec4 o;
void main() {
    vec2 p = gl_FragCoord.xy;
    if (p.x < clip.x || p.y < clip.y || p.x >= clip.z || p.y >= clip.w) discard;
    vec2 q = (p - map.yz) / map.x - org;
    if (q.x < 0.0 || q.y < 0.0 || q.x >= map.w || q.y >= map.w) discard;
    vec2 tc = q + 1.0;
    if (lin == 0) o = texelFetch(tile, ivec2(floor(tc)), 0);
    else o = texture(tile, tc / (map.w + 2.0));
}
"""

comptime P_QUAD = 0
comptime P_GLYPH = 1
comptime P_IMAGE = 2
comptime P_FAN = 3
comptime P_COVER = 4
comptime PROGRAMS = 5

# buffers / vertex arrays: one each for quads, glyphs, the fan, the covers (images use none)
comptime B_QUAD = 0
comptime B_GLYPH = 1
comptime B_FAN = 2
comptime B_COVER = 3
comptime B_INDIRECT = 4  # (GLES: the fans' draw commands for glMultiDrawArraysIndirectEXT; no vertex array)
comptime VAOS = 4
comptime BUFFERS = 5


def _pixel_lo(e: Float64, limit: Int) -> Int:
    """The first pixel whose centre is at or past e (clamped to 0 … limit)."""
    if e <= -NO_CLIP * 0.5:
        return 0
    var c = e - 0.5
    var i = Int(c)
    if Float64(i) < c:
        i += 1
    return min(max(i, 0), limit)


comptime LEVELS_UP_TO = 512  # polygon runs this long are grouped by overlap depth (all pairs tested); longer: in order
comptime COVER_FLOATS = 24  # a polygon's cover: 3 vertices × (r, g, b, a, bounds x0, y0, x1, y1)


def _tri_meets(lx: Float32, ly: Float32, wx: Float32, wy: Float32, bx0: Float32, by0: Float32, bx1: Float32, by1: Float32) -> Bool:
    """Whether the triangle (lx, ly), (lx + wx, ly), (lx, ly + wy) reaches the box [bx0, bx1] × [by0, by1]."""
    if bx1 < lx or by1 < ly or bx0 > lx + wx or by0 > ly + wy or wx <= 0 or wy <= 0:
        return False
    var px = max(bx0, lx)  # (the box's point nearest the triangle's corner, in the quadrant the triangle is in)
    var py = max(by0, ly)
    return (px - lx) / wx + (py - ly) / wy <= 1


def _covers_meet(b: List[Float32], i: Int, j: Int, pad: Float32) -> Bool:
    """Polygons i and j can't share a stencil group: one's cover triangle (its bounds padded by `pad`, legs twice their
    size) reaches the other's bounds (where its fan's samples are). b holds 8 numbers per polygon: bounds x0, y0, x1, y1,
    then the cover triangle's box x0, y0, x1, y1 (a quick reject)."""
    var pi = b.unsafe_ptr() + 8 * i
    var pj = b.unsafe_ptr() + 8 * j
    if pi[4] > pj[6] or pj[4] > pi[6] or pi[5] > pj[7] or pj[5] > pi[7]:
        return False
    var e = pad * 0.25
    if _tri_meets(pi[4], pi[5], pi[6] - pi[4], pi[7] - pi[5], pj[0] - e, pj[1] - e, pj[2] + e, pj[3] + e):
        return True
    return _tri_meets(pj[4], pj[5], pj[6] - pj[4], pj[7] - pj[5], pi[0] - e, pi[1] - e, pi[2] + e, pi[3] + e)


struct GL2D(Movable):
    """The GL backend over the current context. ok: start() worked (why says what it found, or why not)."""

    var ok: Bool
    var why: String
    var es: Bool
    var renderer: String
    var version: String
    var lib: Int
    var fp: List[Int]
    var prog: List[Int]
    var loc_vp: List[Int]
    var loc_xf: List[Int]
    var loc_lim: List[Int]  # (D-7972) each program's scissor-rect uniform (-1: none), and what was sent to it
    var lim_set: List[Float32]
    var loc_replace: Int
    var loc_atlas: Int
    var loc_img: Int
    var loc_rect: Int
    var loc_clip: Int
    var vao: List[Int]
    var empty_vao: Int  # (images: no attributes)
    var lvbo: List[Int]  # BUFFERS buffers per cached layer (buffer set), 0 until used
    var lcap: List[Int]  # each buffer's store and how much of it holds data (bytes): an append writes past the end
    var lsize: List[Int]
    # per buffer set: its polygon runs' stencil groups, planned when uploaded (plan_polys): 9 numbers each (run index,
    # first fan vertex, fan vertices, first cover vertex, cover vertices, clip x0, y0, x1, y1), in run order; and where
    # run r's groups start (pg_first[set][r] … pg_first[set][r + 1])
    var pgroups: List[List[Float64]]
    var pg_first: List[List[Int]]
    var fan_stage: List[Float32]  # (plan_polys's staging: the fans in group order, the covers)
    var indirect: Bool  # multi_draw is glMultiDrawArraysIndirectEXT (GLES): the (first, count) ranges as commands in B_INDIRECT
    var multi_draw: Int  # glMultiDrawArrays (GL) / glMultiDrawArraysEXT or …IndirectEXT (GLES): a group's scattered fans in one call,
    # nothing copied (0: not there; plan_polys then copies the fans into group order)
    var md_first: List[List[Int32]]  # per buffer set, with multi_draw: each polygon's first fan vertex and fan vertex count, group by group
    var md_count: List[List[Int32]]
    var md_on: List[Bool]  # per buffer set: its groups draw their fans by multi_draw (fan first/count index md_first)
    var cov_stage: List[Float32]
    var uploaded: Int  # bytes uploaded this frame
    var plan_ns: Int  # this frame's polygon planning (plan_polys, CPU) and buffer uploads (glBufferData calls)
    var upload_ns: Int
    var cur_prog: Int  # (within a frame: the program in use, the blend in force)
    var cur_blend: Int
    var atlas_tex: Int
    var atlas_w: Int
    var atlas_dyn: Int
    var pages_version: Int  # the GlyphPages version last uploaded into the atlas's dynamic rows (goal 79)
    var img_tex: List[Int]
    var img_w: List[Int]
    var img_h: List[Int]
    var samples: Int  # stencil (raster) samples per pixel; MSAA mode: colour samples too
    var mixed: Bool  # NV_framebuffer_mixed_samples: 1 colour sample (the ring texture itself), `samples` stencil samples,
    # each fragment's alpha × the share of its raster samples that pass (coverage modulation): no MSAA colour, no resolve
    var cov_mod: Int  # glCoverageModulationNV
    var vp_w: Int  # the size every program's `vp` uniform holds
    var vp_h: Int
    var xf_set: List[Float32]  # the transform each program's `xf` holds (3 per program)
    var msaa_fbo: Int
    var msaa_color: Int
    var msaa_ds: Int
    var mw: Int
    var mh: Int
    var resolve_fbo: Int
    var last_tex_checked: Int
    # the ring of textures handed to the toolkit
    var tex: List[Int]
    var tw: List[Int]
    var th: List[Int]
    var busy: List[Int]  # 1 while the toolkit shows it; its release callback writes 0 (fixed length: stable addresses)
    var sync: List[Int]  # the GL fence after the frame that filled the slot (0: none)
    var full: Int  # times every slot was held
    var next_slot: Int  # where acquire() looks first
    var out: List[Int]  # scratch out-parameters (8 bytes each)
    var frames: Int
    var timer: List[Int]  # glGenQueries, glBeginQuery, glEndQuery, glGetQueryObjectui64v (or GLES's …EXT), when there
    var timing: Bool  # each frame's GPU time measured (a time-elapsed query around it; framebench turns it on)
    var q_free: List[Int]  # query objects free, and ended but not read yet
    var q_pending: List[Int]
    var gpu_ns: Int  # what the last gpu_time() read
    var poly_groups: Int  # stencil-and-cover groups last frame (fan + cover draws each)
    var draws: Int  # GL draw calls last frame
    var dmabuf: DmabufExport  # the ring textures as dmabufs, when a host starts it (dmabuf.start; D-7570)
    var cw: Int  # the size of what is being drawn into now (the frame's target, or a tile: D-7940)
    var ch: Int
    var tile_prog: Int  # (D-7940) the tile program and its uniforms; the tile target (its own fbo, stencil, MSAA colour)
    var tl_vp: Int
    var tl_rect: Int
    var tl_clip: Int
    var tl_map: Int
    var tl_org: Int
    var tl_lin: Int
    var tl_tex: Int
    var tile_fbo: Int
    var tile_ds: Int
    var tile_color: Int
    var tile_tex: List[Int]  # by tile slot (0: not made yet)
    var box_verts: Int  # (D-7972) vertices per quad/glyph box (6; 3 with MOJOUI_GL_ONE_TRI=1)
    var state_cache: Bool  # (D-7966) MOJOUI_GL_CACHE=0: every run sets all its state (the comparison)
    var base_instance: Int  # glDrawArraysInstancedBaseInstance (GL_ARB_base_instance), 0: none
    var run_vao: Int  # within a layer's runs: the vertex array, array buffer, attribute base, replace flag and
    var run_buf: Int  # texture last set (-1: unknown)
    var run_pointed: Int
    var run_replace: Int
    var run_tex: Int
    var vao_buf: List[Int]  # (D-7966) per vertex array: the buffer its attributes point at from offset 0 (-1: unknown)
    var kinds_on: Bool  # (D-7971) MOJOUI_GPU_KINDS=1: GPU timestamps round each run and clear, summed per kind
    var kq: List[Int]  # timestamp queries: pairs (before, after) and the pair's kind
    var kk: List[Int]
    var kn: Int  # pairs used this frame
    var kqc: Int  # glQueryCounter
    var counting: Bool  # (D-7965) MOJOUI_GL_COUNT=1
    var counts: List[Int]
    var unpack_buf: Int  # (D-7956) the pixel-unpack buffer a snapshot's tiles are decoded into (0: not made yet)
    var unpack_cap: Int  # its storage's size (kept between restores: new storage cost ~2.7 ms each time, measured)
    var unpack_sync: Int  # a fence after the last uploads from it (0: none)
    var span_t0: Int  # (diagnosis, MOJOUI_GPU_SPAN=1) when the frame's GPU query began on the CPU's clock
    var span_log: Bool
    var timing_open: Bool  # this frame's time-elapsed query already begun (tile rasters before the frame are in it)
    var lim: List[Int]  # (D-7940) a partial tile raster's scissor (x0, y0, x1, y1), every draw kept inside it; empty: none

    def __init__(out self):
        self.ok = False
        self.why = "not started"
        self.es = False
        self.renderer = ""
        self.version = ""
        self.lib = 0
        self.fp = List[Int](length=F_COUNT, fill=0)
        self.prog = List[Int](length=PROGRAMS, fill=0)
        self.loc_vp = List[Int](length=PROGRAMS, fill=-1)
        self.loc_xf = List[Int](length=PROGRAMS, fill=-1)
        self.loc_lim = List[Int](length=PROGRAMS, fill=-1)
        self.lim_set = List[Float32](length=4 * PROGRAMS, fill=-1e30)
        self.loc_replace = -1
        self.loc_atlas = -1
        self.loc_img = -1
        self.loc_rect = -1
        self.loc_clip = -1
        self.vao = List[Int](length=VAOS, fill=0)
        self.empty_vao = 0
        self.lvbo = List[Int]()
        self.lcap = List[Int]()
        self.lsize = List[Int]()
        self.pgroups = List[List[Float64]]()
        self.pg_first = List[List[Int]]()
        self.fan_stage = List[Float32]()
        self.multi_draw = 0
        self.indirect = False
        self.md_first = List[List[Int32]]()
        self.md_count = List[List[Int32]]()
        self.md_on = List[Bool]()
        self.cov_stage = List[Float32]()
        self.uploaded = 0
        self.plan_ns = 0
        self.upload_ns = 0
        self.cur_prog = -1
        self.cur_blend = -1
        self.atlas_tex = 0
        self.pages_version = -1
        self.atlas_w = 0
        self.atlas_dyn = 0
        self.img_tex = List[Int]()
        self.img_w = List[Int]()
        self.img_h = List[Int]()
        self.samples = 8
        self.mixed = False
        self.cov_mod = 0
        self.vp_w = 0
        self.vp_h = 0
        self.xf_set = List[Float32](length=3 * PROGRAMS, fill=-1e30)
        self.msaa_fbo = 0
        self.msaa_color = 0
        self.msaa_ds = 0
        self.mw = 0
        self.mh = 0
        self.resolve_fbo = 0
        self.last_tex_checked = 0
        self.tex = List[Int](length=RING, fill=0)
        self.tw = List[Int](length=RING, fill=0)
        self.th = List[Int](length=RING, fill=0)
        self.busy = List[Int](length=RING, fill=0)
        self.sync = List[Int](length=RING, fill=0)
        self.full = 0
        self.next_slot = 0
        self.out = List[Int](length=16, fill=0)
        self.frames = 0
        self.timer = List[Int]()
        self.timing = False
        self.q_free = List[Int]()
        self.q_pending = List[Int]()
        self.gpu_ns = -1
        self.poly_groups = 0
        self.draws = 0
        self.dmabuf = DmabufExport(RING)
        self.cw = 0
        self.ch = 0
        self.tile_prog = 0
        self.tl_vp = -1
        self.tl_rect = -1
        self.tl_clip = -1
        self.tl_map = -1
        self.tl_org = -1
        self.tl_lin = -1
        self.tl_tex = -1
        self.tile_fbo = 0
        self.tile_ds = 0
        self.tile_color = 0
        self.tile_tex = List[Int]()
        self.unpack_buf = 0
        self.counting = getenv("MOJOUI_GL_COUNT") == "1"
        self.kinds_on = getenv("MOJOUI_GPU_KINDS") == "1"
        self.kq = List[Int]()
        self.kk = List[Int]()
        self.kn = 0
        self.kqc = 0
        self.state_cache = getenv("MOJOUI_GL_CACHE") != "0"
        self.box_verts = BOX_VERTS
        self.base_instance = 0
        self.run_vao = -1
        self.run_buf = -1
        self.run_pointed = -1
        self.run_replace = -1
        self.run_tex = -1
        self.vao_buf = List[Int](length=8, fill=-1)
        self.counts = List[Int](length=F_COUNT + 4, fill=0)
        self.unpack_cap = 0
        self.unpack_sync = 0
        self.timing_open = False
        self.span_t0 = 0
        self.span_log = getenv("MOJOUI_GPU_SPAN") == "1"
        self.lim = List[Int]()

    def at(self, k: Int) -> Int:
        return Int(self.out.unsafe_ptr()) + 8 * k

    def f(self, i: Int) -> Int:
        if self.counting:  # (MOJOUI_GL_COUNT=1, D-7965: calls per entry point; the array is written through its address)
            Pointer[Int, MutUntrackedOrigin](unsafe_from_address=Int(self.counts.unsafe_ptr()) + 8 * i)[] += 1
        return self.fp[i]

    def count_extra(self, slot: Int, n: Int):
        """(D-7965) A counter beyond the entry points: C_BYTES (bytes uploaded), C_MULTI (multi-draw calls), C_EXT
        (other extension calls)."""
        if self.counting:
            Pointer[Int, MutUntrackedOrigin](unsafe_from_address=Int(self.counts.unsafe_ptr()) + 8 * (F_COUNT + slot))[] += n

    def kind_mark(mut self) -> Int:
        """(D-7971) A GPU timestamp now; its query's index (-1 when off)."""
        if not self.kinds_on or len(self.timer) != 4:
            return -1
        if self.kqc == 0:
            self.kqc = gl_proc("glQueryCounter")
        if self.kn >= len(self.kq):
            self.out[0] = 0
            fcall[NoneType](self.timer[0], c_int(1), self.at(0))
            self.kq.append(Int(self.out[0] & 0xFFFFFFFF))
            self.kk.append(-1)
        var q = self.kn
        self.kn += 1
        fcall[NoneType](self.kqc, c_uint(self.kq[q]), c_uint(0x8E28))
        return q

    def kind_end(mut self, q0: Int, kind: Int):
        """The span from mark q0 to now counts for `kind` (KIND_*)."""
        if q0 < 0:
            return
        var q1 = self.kind_mark()
        self.kk[q0] = kind
        self.kk[q1] = -2  # (an end mark)

    def kinds_line(mut self) -> String:
        """This frame's GPU time per kind (waits for the GPU), then the marks are reset."""
        var sums = List[Int](length=6, fill=0)
        var counts = List[Int](length=6, fill=0)
        var q = 0
        while q + 1 < self.kn:
            if self.kk[q] >= 0:
                self.out[0] = 0
                fcall[NoneType](self.timer[3], c_uint(self.kq[q]), c_uint(0x8866), self.at(0))
                var a = self.out[0]
                self.out[0] = 0
                fcall[NoneType](self.timer[3], c_uint(self.kq[q + 1]), c_uint(0x8866), self.at(0))
                sums[self.kk[q]] += self.out[0] - a
                counts[self.kk[q]] += 1
                q += 2
            else:
                q += 1
        self.kn = 0
        var names = ["quad", "glyph", "poly", "image", "clear", "tiles"]
        var line = String("GPUKINDS:")
        for k in range(6):
            line += " " + names[k] + "=" + String(Float64(sums[k]) / 1e6) + "ms/" + String(counts[k])
        return line

    def counts_reset(mut self):
        for q in range(len(self.counts)):
            self.counts[q] = 0

    def counts_line(self) -> String:
        """This frame's GL calls so far: total, draws, bytes uploaded, state changes."""
        var total = 0
        for q in range(F_COUNT):
            total += self.counts[q]
        total += self.counts[F_COUNT + C_MULTI] + self.counts[F_COUNT + C_EXT] + self.counts[F_COUNT + C_BASE]
        var draws = self.counts[F_DRAW_ARRAYS] + self.counts[F_DRAW_ARRAYS_INSTANCED] + self.counts[F_COUNT + C_MULTI] + self.counts[F_COUNT + C_BASE]
        return ("calls " + String(total) + " draws " + String(draws) + " (instanced " + String(self.counts[F_DRAW_ARRAYS_INSTANCED]) + ", multi "
                + String(self.counts[F_COUNT + C_MULTI]) + ", base-instance " + String(self.counts[F_COUNT + C_BASE]) + ") bytes " + String(self.counts[F_COUNT + C_BYTES]) + " uploads "
                + String(self.counts[F_BUFFER_SUB_DATA] + self.counts[F_BUFFER_DATA] + self.counts[F_TEX_SUB_IMAGE_2D]) + " (bufferdata "
                + String(self.counts[F_BUFFER_DATA]) + ") program " + String(self.counts[F_USE_PROGRAM]) + " texbind " + String(self.counts[F_BIND_TEXTURE])
                + " fbo " + String(self.counts[F_BIND_FRAMEBUFFER]) + " fbtex " + String(self.counts[F_FRAMEBUFFER_TEXTURE_2D]) + " scissor "
                + String(self.counts[F_SCISSOR]) + " enable/disable " + String(self.counts[F_ENABLE] + self.counts[F_DISABLE]) + " blend "
                + String(self.counts[F_BLEND_FUNC_SEPARATE]) + " uniform " + String(self.counts[F_UNIFORM_2F] + self.counts[F_UNIFORM_3F] + self.counts[F_UNIFORM_4F] + self.counts[F_UNIFORM_1I])
                + " vao " + String(self.counts[F_BIND_VERTEX_ARRAY]) + " bindbuf " + String(self.counts[F_BIND_BUFFER]) + " attrib "
                + String(self.counts[F_VERTEX_ATTRIB_POINTER] + self.counts[F_ENABLE_VERTEX_ATTRIB_ARRAY]) + " clear " + String(self.counts[F_CLEAR])
                + " stencil " + String(self.counts[F_STENCIL_FUNC] + self.counts[F_STENCIL_OP] + self.counts[F_STENCIL_OP_SEPARATE] + self.counts[F_STENCIL_MASK])
                + " viewport " + String(self.counts[F_VIEWPORT]) + " geterror " + String(self.counts[F_GET_ERROR]))

    def gen(mut self, which: Int) -> Int:
        """glGen*(1, &id) → id."""
        self.out[0] = 0
        fcall[NoneType](self.f(which), c_int(1), self.at(0))
        return self.out[0] & 0xFFFFFFFF

    def delete(mut self, which: Int, id: Int):
        if id == 0:
            return
        self.out[0] = id
        fcall[NoneType](self.f(which), c_int(1), self.at(0))

    def error(self) -> Int:
        return Int(fcall[c_uint](self.f(F_GET_ERROR)))

    # ---------- starting ----------

    def start(mut self, es: Bool) -> Bool:
        """With a GL 3.3+ core (or GLES 3.0+: es) context current: the entry points, the programs, the buffers."""
        if getenv("MOJOUI_GPU2D") == "0":
            self.why = "turned off (MOJOUI_GPU2D=0)"
            return False
        self.es = es
        self.lib = dl_open("libOpenGL.so.0")
        if self.lib == 0:
            self.lib = dl_open("libGL.so.1")
        if self.lib == 0:
            self.lib = dl_open("libGLESv2.so.2")
        if self.lib == 0:
            self.why = "no OpenGL library"
            return False
        var names = _gl_names()
        for i in range(F_COUNT):
            self.fp[i] = dl_sym(self.lib, names[i])
            if self.fp[i] == 0:
                self.why = "no " + names[i] + " in the GL library"
                return False
        self.renderer = c_text(fcall[Int](self.f(F_GET_STRING), c_uint(GL_RENDERER)))
        self.version = c_text(fcall[Int](self.f(F_GET_STRING), c_uint(GL_VERSION)))
        set_renderer_id(fnv(c_text(fcall[Int](self.f(F_GET_STRING), c_uint(0x1F00))) + "|" + self.renderer + "|" + self.version))  # (D-7956: snapshot keys)
        if self.renderer == "":
            self.why = "no GL context current"
            return False
        var low = self.renderer.lower()
        if low.find("llvmpipe") >= 0 or low.find("softpipe") >= 0 or low.find("swrast") >= 0 or low.find("software") >= 0:
            self.why = "a software GL (" + self.renderer + "): the CPU path is faster"
            return False
        self.out[0] = 0
        fcall[NoneType](self.f(F_GET_INTEGERV), c_uint(GL_NUM_EXTENSIONS), self.at(0))
        var has_mixed = False
        var has_multi = not es  # (desktop GL: core since 1.4; GLES: GL_EXT_multi_draw_arrays)
        var has_indirect = False  # (GLES: GL_EXT_multi_draw_indirect, what NVIDIA's GLES has instead)
        for i in range(Int(self.out[0] & 0xFFFFFFFF)):
            var ext = c_text(fcall[Int](self.f(F_GET_STRINGI), c_uint(GL_EXTENSIONS), c_uint(i)))
            if getenv("MOJOUI_GPU2D_EXTENSIONS") == "1":  # (diagnostics: what the context offers)
                print("gpu2d GL extension: " + ext)
            if ext == "GL_NV_framebuffer_mixed_samples":
                has_mixed = True
            elif ext == "GL_EXT_multi_draw_arrays":
                has_multi = True
            elif ext == "GL_ARB_base_instance" and not es and getenv("MOJOUI_GL_BASEINSTANCE") != "0":
                self.base_instance = gl_proc("glDrawArraysInstancedBaseInstance")
            elif ext == "GL_EXT_base_instance" and es and getenv("MOJOUI_GL_BASEINSTANCE") != "0":
                self.base_instance = gl_proc("glDrawArraysInstancedBaseInstanceEXT")
            elif ext == "GL_EXT_multi_draw_indirect" or (ext == "GL_ARB_multi_draw_indirect" and getenv("MOJOUI_GPU2D_INDIRECT") == "1"):
                has_indirect = True  # (desktop GL takes the indirect path only when asked: tests cover it there)
        if has_indirect and not es:
            has_multi = False
        if has_multi and getenv("MOJOUI_GPU2D_MULTIDRAW") != "0":
            self.multi_draw = dl_sym(self.lib, "glMultiDrawArrays") if not es else 0
            if self.multi_draw == 0:
                self.multi_draw = gl_proc("glMultiDrawArraysEXT" if es else "glMultiDrawArrays")
        elif has_indirect and getenv("MOJOUI_GPU2D_MULTIDRAW") != "0":
            self.multi_draw = gl_proc("glMultiDrawArraysIndirectEXT" if es else "glMultiDrawArraysIndirect")
            self.indirect = self.multi_draw != 0
        if has_mixed and getenv("MOJOUI_GPU2D_MIXED") != "0":
            self.cov_mod = gl_proc("glCoverageModulationNV")
            self.mixed = self.cov_mod != 0
        var want = 8  # (mixed samples on the 3090: 8 stencil samples is the most a 1-sample colour target takes)
        var s = getenv("MOJOUI_GPU2D_MSAA")
        if s != "":
            try:
                want = Int(s)
            except:
                want = 8
        self.out[0] = 0
        fcall[NoneType](self.f(F_GET_INTEGERV), c_uint(GL_MAX_SAMPLES), self.at(0))
        var most = Int(self.out[0] & 0xFFFFFFFF)
        self.samples = max(min(want, most), 1)
        _ = self.error()
        var head = String(HEAD_ES) if es else String(HEAD_CORE)
        var one_tri = getenv("MOJOUI_GL_ONE_TRI") == "1"
        self.box_verts = 3 if one_tri else BOX_VERTS
        var srcs: List[String] = [String(QUAD_VS_ONE_TRI) if one_tri else String(QUAD_VS), String(QUAD_FS), String(GLYPH_VS_ONE_TRI) if one_tri else String(GLYPH_VS), String(GLYPH_FS), String(IMAGE_VS), String(IMAGE_FS),
                                  String(FAN_VS), String(FAN_FS), String(COVER_VS), String(COVER_FS)]
        for p in range(PROGRAMS):
            var prog = self.compile(head + srcs[2 * p], head + srcs[2 * p + 1])
            if prog == 0:
                return False
            self.prog[p] = prog
            self.loc_vp[p] = self.uniform(prog, "vp")
            self.loc_xf[p] = self.uniform(prog, "xf")
            self.loc_lim[p] = self.uniform(prog, "lim")
        self.loc_replace = self.uniform(self.prog[P_QUAD], "replace")
        self.loc_atlas = self.uniform(self.prog[P_GLYPH], "atlas")
        self.loc_img = self.uniform(self.prog[P_IMAGE], "img")
        self.loc_rect = self.uniform(self.prog[P_IMAGE], "rect")
        self.loc_clip = self.uniform(self.prog[P_IMAGE], "clip")
        self.tile_prog = self.compile(head + String(TILE_VS), head + String(TILE_FS))
        if self.tile_prog == 0:
            return False
        self.tl_vp = self.uniform(self.tile_prog, "vp")
        self.tl_rect = self.uniform(self.tile_prog, "rect")
        self.tl_clip = self.uniform(self.tile_prog, "clip")
        self.tl_map = self.uniform(self.tile_prog, "map")
        self.tl_org = self.uniform(self.tile_prog, "org")
        self.tl_lin = self.uniform(self.tile_prog, "lin")
        self.tl_tex = self.uniform(self.tile_prog, "tile")
        # vertex arrays: instanced vec4 groups (re-pointed per run), the fan's vec2 per vertex
        for b in range(VAOS):
            self.vao[b] = self.gen(F_GEN_VERTEX_ARRAYS)
            fcall[NoneType](self.f(F_BIND_VERTEX_ARRAY), c_uint(self.vao[b]))
            fcall[NoneType](self.f(F_BIND_BUFFER), c_uint(GL_ARRAY_BUFFER), c_uint(self.buf(0, b)))
            var groups = 4 if b == B_QUAD else (5 if b == B_GLYPH else (1 if b == B_FAN else 2))
            for gi in range(groups):
                var loc = gi + 1 if b == B_COVER else gi
                fcall[NoneType](self.f(F_ENABLE_VERTEX_ATTRIB_ARRAY), c_uint(loc))
                if b != B_FAN and b != B_COVER:  # (quads, glyphs: one per instance; fans, covers: per vertex)
                    fcall[NoneType](self.f(F_VERTEX_ATTRIB_DIVISOR), c_uint(loc), c_uint(1))
            if b == B_FAN:
                fcall[NoneType](self.f(F_VERTEX_ATTRIB_POINTER), c_uint(0), c_int(2), c_uint(GL_FLOAT), UInt8(0), c_int(8), 0)
        fcall[NoneType](self.f(F_BIND_VERTEX_ARRAY), c_uint(0))
        fcall[NoneType](self.f(F_BIND_BUFFER), c_uint(GL_ARRAY_BUFFER), c_uint(0))
        self.empty_vao = self.gen(F_GEN_VERTEX_ARRAYS)
        self.resolve_fbo = self.gen(F_GEN_FRAMEBUFFERS)
        self.msaa_fbo = self.gen(F_GEN_FRAMEBUFFERS)
        # time-elapsed queries (core GL 3.3; GLES: EXT_disjoint_timer_query), for timing frames on the GPU
        var sfx = "EXT" if es else ""
        for nm in ["glGenQueries", "glBeginQuery", "glEndQuery", "glGetQueryObjectui64v"]:
            var fp = dl_sym(self.lib, nm) if not es else 0
            self.timer.append(fp if fp != 0 else gl_proc(nm + sfx))
        if self.timer[0] == 0 or self.timer[1] == 0 or self.timer[2] == 0 or self.timer[3] == 0:
            self.timer.clear()
        var err = self.error()
        if err != 0:
            self.why = "GL error " + String(err) + " while starting"
            return False
        self.ok = True
        self.why = (("GLES " if es else "GL ") + self.version + " on " + self.renderer + ", "
                    + (String(self.samples) + "× stencil samples, 1× colour (NV_framebuffer_mixed_samples)" if self.mixed else String(self.samples) + "× MSAA")
                    + ((", multi-draw (indirect)" if self.indirect else ", multi-draw") if self.multi_draw != 0 else ""))
        return True

    def uniform(self, prog: Int, name: String) -> Int:
        var n = name
        return Int(fcall[c_int](self.f(F_GET_UNIFORM_LOCATION), c_uint(prog), n.as_c_string_span()))

    def compile(mut self, vs: String, fs: String) -> Int:
        var prog = Int(fcall[c_uint](self.f(F_CREATE_PROGRAM)))
        for kind in range(2):
            var src = vs if kind == 0 else fs
            var sh = fcall[c_uint](self.f(F_CREATE_SHADER), c_uint(GL_VERTEX_SHADER if kind == 0 else GL_FRAGMENT_SHADER))
            self.out[0] = Int(src.unsafe_ptr())
            self.out[1] = src.byte_length()
            fcall[NoneType](self.f(F_SHADER_SOURCE), sh, c_int(1), self.at(0), self.at(1))
            fcall[NoneType](self.f(F_COMPILE_SHADER), sh)
            _ = src.byte_length()
            self.out[2] = 0
            fcall[NoneType](self.f(F_GET_SHADERIV), sh, c_uint(GL_COMPILE_STATUS), self.at(2))
            if self.out[2] & 0xFFFFFFFF == 0:
                var log = List[UInt8](length=2048, fill=0)
                fcall[NoneType](self.f(F_GET_SHADER_INFO_LOG), sh, c_int(2047), 0, Int(log.unsafe_ptr()))
                self.why = ("vertex" if kind == 0 else "fragment") + " shader didn't compile: " + c_text(Int(log.unsafe_ptr()))
                _ = len(log)
                return 0
            fcall[NoneType](self.f(F_ATTACH_SHADER), c_uint(prog), sh)
            fcall[NoneType](self.f(F_DELETE_SHADER), sh)
        fcall[NoneType](self.f(F_LINK_PROGRAM), c_uint(prog))
        self.out[2] = 0
        fcall[NoneType](self.f(F_GET_PROGRAMIV), c_uint(prog), c_uint(GL_LINK_STATUS), self.at(2))
        if self.out[2] & 0xFFFFFFFF == 0:
            self.why = "shaders didn't link"
            return 0
        return prog

    def upload_atlas(mut self, atlas: GlyphAtlas):
        """The glyph atlas as an R8 texture (once)."""
        if self.atlas_tex != 0:
            return
        self.atlas_w = atlas.width
        self.atlas_dyn = atlas.dyn_y0
        self.atlas_tex = self.gen(F_GEN_TEXTURES)
        fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(self.atlas_tex))
        self.tex_params(GL_NEAREST)
        fcall[NoneType](self.f(F_TEX_STORAGE_2D), c_uint(GL_TEXTURE_2D), c_int(1), c_uint(GL_R8), c_int(atlas.width), c_int(atlas.height))
        fcall[NoneType](self.f(F_PIXEL_STOREI), c_uint(GL_UNPACK_ALIGNMENT), c_int(1))
        fcall[NoneType](self.f(F_TEX_SUB_IMAGE_2D), c_uint(GL_TEXTURE_2D), c_int(0), c_int(0), c_int(0), c_int(atlas.width), c_int(atlas.height),
                        c_uint(GL_RED), c_uint(GL_UNSIGNED_BYTE), Int(atlas.bytes.unsafe_ptr()))
        fcall[NoneType](self.f(F_PIXEL_STOREI), c_uint(GL_UNPACK_ALIGNMENT), c_int(4))
        fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(0))

    def sync_pages(mut self):
        """fonttext's glyphs packed since the last upload (GlyphPages' rows in use) into the atlas's dynamic rows."""
        if self.atlas_tex == 0:
            return
        var pg = glyph_pages(self.atlas_w)
        if pg[].version == self.pages_version or pg[].used == 0:
            return
        fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(self.atlas_tex))
        fcall[NoneType](self.f(F_PIXEL_STOREI), c_uint(GL_UNPACK_ALIGNMENT), c_int(1))
        fcall[NoneType](self.f(F_TEX_SUB_IMAGE_2D), c_uint(GL_TEXTURE_2D), c_int(0), c_int(0), c_int(self.atlas_dyn), c_int(self.atlas_w), c_int(min(pg[].used, DYN_ROWS)),
                        c_uint(GL_RED), c_uint(GL_UNSIGNED_BYTE), Int(pg[].bytes.unsafe_ptr()))
        fcall[NoneType](self.f(F_PIXEL_STOREI), c_uint(GL_UNPACK_ALIGNMENT), c_int(4))
        fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(0))
        self.pages_version = pg[].version

    def tex_params(self, filt: Int):
        fcall[NoneType](self.f(F_TEX_PARAMETERI), c_uint(GL_TEXTURE_2D), c_uint(GL_TEXTURE_MIN_FILTER), c_int(filt))
        fcall[NoneType](self.f(F_TEX_PARAMETERI), c_uint(GL_TEXTURE_2D), c_uint(GL_TEXTURE_MAG_FILTER), c_int(filt))
        fcall[NoneType](self.f(F_TEX_PARAMETERI), c_uint(GL_TEXTURE_2D), c_uint(GL_TEXTURE_WRAP_S), c_int(GL_CLAMP_TO_EDGE))
        fcall[NoneType](self.f(F_TEX_PARAMETERI), c_uint(GL_TEXTURE_2D), c_uint(GL_TEXTURE_WRAP_T), c_int(GL_CLAMP_TO_EDGE))

    def make_texture(mut self, w: Int, h: Int) -> Int:
        """An RGBA8 texture of w × h (linear filtering: the toolkit may scale it)."""
        var t = self.gen(F_GEN_TEXTURES)
        fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(t))
        self.tex_params(GL_LINEAR)
        fcall[NoneType](self.f(F_TEX_STORAGE_2D), c_uint(GL_TEXTURE_2D), c_int(1), c_uint(GL_RGBA8), c_int(w), c_int(h))
        fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(0))
        return t

    # ---------- the ring ----------

    def acquire(mut self, w: Int, h: Int) -> Int:
        """The next ring texture the toolkit isn't holding, round the ring (made or remade at w × h as needed), or -1
        when all are held. Round, not the first free one: the toolkit lets go of a texture when it has queued its last
        frame with it, not when the GPU has drawn that frame; drawing into it again at once made our frame wait behind
        the toolkit's (measured: a steady 3.2 ms GPU wait a frame for 0.23 ms of work)."""
        var pick = -1
        for k in range(RING):
            var i = (self.next_slot + k) % RING
            if self.busy[i] == 0:
                pick = i
                break
        if pick < 0:
            self.full += 1
            return -1
        self.next_slot = (pick + 1) % RING
        if self.tex[pick] != 0 and self.tw[pick] == w and self.th[pick] == h:
            return pick
        self.dmabuf.forget(pick)
        self.delete(F_DELETE_TEXTURES, self.tex[pick])
        self.tex[pick] = self.make_texture(w, h)
        self.tw[pick] = w
        self.th[pick] = h
        return pick

    def busy_flag(self, slot: Int) -> Int:
        """The address the toolkit's release callback writes 0 to when it lets go of the slot's texture."""
        return Int(self.busy.unsafe_ptr()) + 8 * slot

    def fence(mut self, slot: Int) -> Int:
        """A GL sync object after everything queued so far (the slot's frame), kept with the slot; flushed."""
        if self.sync[slot] != 0:
            fcall[NoneType](self.f(F_DELETE_SYNC), self.sync[slot])
        self.sync[slot] = fcall[Int](self.f(F_FENCE_SYNC), c_uint(GL_SYNC_GPU_COMMANDS_COMPLETE), c_uint(0))
        fcall[NoneType](self.f(F_FLUSH))
        return self.sync[slot]

    def wait(mut self, slot: Int):
        """Blocks until the slot's frame is done on the GPU (framebench: the GPU's part counted in the frame)."""
        if self.sync[slot] == 0:
            fcall[NoneType](self.f(F_FINISH))
            return
        # (polled with a zero timeout: a blocking wait sleeps in steps on NVIDIA's driver, measured 0.4 / 1.9 / 3.2 ms
        # whatever the frame; spinning sees the end of the frame's GPU work within microseconds)
        var flags = c_uint(GL_SYNC_FLUSH_COMMANDS_BIT)
        var until = perf_counter_ns() + 2_000_000_000
        while perf_counter_ns() < until:
            var r = Int(fcall[c_uint](self.f(F_CLIENT_WAIT_SYNC), self.sync[slot], flags, UInt64(0)))
            if r == 0x911A or r == 0x911C or r == 0x911D:  # ALREADY_SIGNALED, CONDITION_SATISFIED, WAIT_FAILED
                return
            flags = c_uint(0)

    def gpu_time(mut self, last_only: Bool = True) -> Int:
        """The GPU time (ns) of the last frame timed (last_only), or of every frame timed since the last call, summed;
        each frame's time-elapsed query is read (one whose frame hasn't finished on the GPU waits for it) and freed.
        -1 when the context has no timer queries or nothing was timed."""
        if len(self.timer) != 4 or len(self.q_pending) == 0:
            return -1
        var total = 0
        for qid in self.q_pending:
            self.out[0] = 0
            fcall[NoneType](self.timer[3], c_uint(qid), c_uint(0x8866), self.at(0))  # GL_QUERY_RESULT
            total = self.out[0] if last_only else total + self.out[0]
            if self.span_log:
                print("GPUSPAN: gpu " + String(Float64(self.out[0]) / 1e6), flush=True)
            self.q_free.append(qid)
        self.q_pending.clear()
        self.gpu_ns = total
        return total

    def finish(self):
        fcall[NoneType](self.f(F_FINISH))

    # ---------- a frame ----------

    def target(mut self, w: Int, h: Int) -> Bool:
        """The MSAA colour + depth/stencil target of w × h (remade when the size changes)."""
        if self.mw == w and self.mh == h and self.msaa_ds != 0:
            return True
        self.delete(F_DELETE_RENDERBUFFERS, self.msaa_color)
        self.delete(F_DELETE_RENDERBUFFERS, self.msaa_ds)
        self.msaa_color = 0
        self.msaa_ds = self.gen(F_GEN_RENDERBUFFERS)
        if not self.mixed:  # (mixed samples: the colour is the ring texture itself, attached each frame)
            self.msaa_color = self.gen(F_GEN_RENDERBUFFERS)
            fcall[NoneType](self.f(F_BIND_RENDERBUFFER), c_uint(GL_RENDERBUFFER), c_uint(self.msaa_color))
            fcall[NoneType](self.f(F_RENDERBUFFER_STORAGE_MS), c_uint(GL_RENDERBUFFER), c_int(self.samples), c_uint(GL_RGBA8), c_int(w), c_int(h))
        fcall[NoneType](self.f(F_BIND_RENDERBUFFER), c_uint(GL_RENDERBUFFER), c_uint(self.msaa_ds))
        fcall[NoneType](self.f(F_RENDERBUFFER_STORAGE_MS), c_uint(GL_RENDERBUFFER), c_int(self.samples), c_uint(GL_DEPTH24_STENCIL8), c_int(w), c_int(h))
        fcall[NoneType](self.f(F_BIND_RENDERBUFFER), c_uint(GL_RENDERBUFFER), c_uint(0))
        fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(self.msaa_fbo))
        if not self.mixed:
            fcall[NoneType](self.f(F_FRAMEBUFFER_RENDERBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_RENDERBUFFER), c_uint(self.msaa_color))
        fcall[NoneType](self.f(F_FRAMEBUFFER_RENDERBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(GL_DEPTH_STENCIL_ATTACHMENT), c_uint(GL_RENDERBUFFER), c_uint(self.msaa_ds))
        var st = GL_FRAMEBUFFER_COMPLETE
        if not self.mixed:  # (mixed: checked once a texture is attached, in render)
            st = Int(fcall[c_uint](self.f(F_CHECK_FRAMEBUFFER_STATUS), c_uint(GL_FRAMEBUFFER)))
        fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(0))
        if st != GL_FRAMEBUFFER_COMPLETE:
            self.why = "the MSAA target isn't complete (status " + String(st) + ")"
            self.delete(F_DELETE_RENDERBUFFERS, self.msaa_ds)
            self.msaa_ds = 0
            return False
        self.mw = w
        self.mh = h
        return True

    def buf(mut self, set: Int, b: Int) -> Int:
        """Buffer b (B_QUAD, B_GLYPH, B_FAN, B_COVER) of buffer set `set` (one set per cached layer), made on first use."""
        while len(self.lvbo) < BUFFERS * (set + 1):
            self.lvbo.append(0)
            self.lcap.append(0)
            self.lsize.append(0)
        var i = BUFFERS * set + b
        if self.lvbo[i] == 0:
            self.lvbo[i] = self.gen(F_GEN_BUFFERS)
        return self.lvbo[i]

    def stream(mut self, set: Int, b: Int, data: List[Float32], append: Bool = False):
        """A layer's data for one buffer (stream_raw)."""
        self.stream_raw(set, b, Int(data.unsafe_ptr()), len(data) * 4, append)
        _ = len(data)

    def stream_raw(mut self, set: Int, b: Int, addr: Int, n: Int, append: Bool = False):
        """n bytes at addr into buffer b of set `set`. Whole (append False): the store orphaned (a fresh one, half as big
        again as needed, so later appends fit; no wait on draws still reading the old one), then filled. append: only
        what's past what the buffer holds (a layer that grew), written after it; the whole when it doesn't fit."""
        _ = self.buf(set, b)
        var i = BUFFERS * set + b
        var target = c_uint(0x8F3F if b == B_INDIRECT else GL_ARRAY_BUFFER)  # (GL_DRAW_INDIRECT_BUFFER)
        var t0 = perf_counter_ns()
        fcall[NoneType](self.f(F_BIND_BUFFER), target, c_uint(self.lvbo[i]))
        var have = self.lsize[i]
        if append and have <= n and n <= self.lcap[i]:
            if n > have:
                fcall[NoneType](self.f(F_BUFFER_SUB_DATA), target, have, n - have, addr + have)
                self.count_extra(C_BYTES, n - have)
                self.uploaded += n - have
        elif n > 0:
            var cap = max(n + n // 2, 65536)
            fcall[NoneType](self.f(F_BUFFER_DATA), target, cap, 0, c_uint(GL_STREAM_DRAW))
            fcall[NoneType](self.f(F_BUFFER_SUB_DATA), target, 0, n, addr)
            self.count_extra(C_BYTES, n)
            self.lcap[i] = cap
            self.uploaded += n
        self.lsize[i] = n
        if b == B_INDIRECT:
            fcall[NoneType](self.f(F_BIND_BUFFER), target, c_uint(0))
        self.upload_ns += Int(perf_counter_ns() - t0)

    def point(self, b: Int, first: Int):
        """Points the instanced attributes of vertex array b at instance `first` (its VAO and buffer bound)."""
        var floats = QUAD_FLOATS if b == B_QUAD else GLYPH_FLOATS
        var stride = floats * 4
        var groups = 4 if b == B_QUAD else 5
        for gi in range(groups):
            var loc = gi
            var off = first * stride + gi * 16
            fcall[NoneType](self.f(F_VERTEX_ATTRIB_POINTER), c_uint(loc), c_int(4), c_uint(GL_FLOAT), UInt8(0), c_int(stride), off)

    def _run_forget(mut self):
        self.run_vao = -1
        self.run_buf = -1
        self.run_pointed = -1
        self.run_replace = -1
        self.run_tex = -1

    def _run_draw(mut self, b: Int, set: Int, first: Int, count: Int):
        """(D-7966) An instanced run of vertex array b from buffer set `set`. With base instances the array's attributes
        point at its buffer's start once (a vertex array keeps them: binding it is enough while its buffer is the same)
        and each run names its first instance; else they are pointed at the run's first (GL 3.3)."""
        var bufid = self.buf(set, b)
        var vao = self.vao[b]
        if not self.state_cache or self.run_vao != vao:
            fcall[NoneType](self.f(F_BIND_VERTEX_ARRAY), c_uint(vao))
            self.run_vao = vao
        if self.state_cache and self.base_instance != 0:
            if self.vao_buf[b] != bufid:
                fcall[NoneType](self.f(F_BIND_BUFFER), c_uint(GL_ARRAY_BUFFER), c_uint(bufid))
                self.point(b, 0)
                self.vao_buf[b] = bufid
            fcall[NoneType](self.base_instance, c_uint(GL_TRIANGLES), c_int(0), c_int(self.box_verts), c_int(count), c_uint(first))
            self.count_extra(C_BASE, 1)
        else:
            fcall[NoneType](self.f(F_BIND_BUFFER), c_uint(GL_ARRAY_BUFFER), c_uint(bufid))
            self.point(b, first)
            self.vao_buf[b] = -1
            fcall[NoneType](self.f(F_DRAW_ARRAYS_INSTANCED), c_uint(GL_TRIANGLES), c_int(0), c_int(self.box_verts), c_int(count))
        self.draws += 1

    def vao_point(mut self, b: Int, bufid: Int) -> Bool:
        """(D-7966) Vertex array b (bound) must point at bufid from offset 0: True when it must be (re)pointed now (the
        buffer bound for it), False when it already does (nothing to set)."""
        if self.state_cache and self.vao_buf[b] == bufid:
            return False
        fcall[NoneType](self.f(F_BIND_BUFFER), c_uint(GL_ARRAY_BUFFER), c_uint(bufid))
        self.vao_buf[b] = bufid
        return True

    def use(mut self, p: Int, w: Int, h: Int, mut cur: Int):
        if cur == p:
            return
        cur = p
        fcall[NoneType](self.f(F_USE_PROGRAM), c_uint(self.prog[p]))

    def set_xf(mut self, p: Int, tx: Float32, ty: Float32, tk: Float32):
        """Program p's layer transform (current program), sent only when it changed (uniforms stay with a program)."""
        if self.xf_set[3 * p] == tx and self.xf_set[3 * p + 1] == ty and self.xf_set[3 * p + 2] == tk:
            return
        self.xf_set[3 * p] = tx
        self.xf_set[3 * p + 1] = ty
        self.xf_set[3 * p + 2] = tk
        fcall[NoneType](self.f(F_UNIFORM_3F), c_int(self.loc_xf[p]), tx, ty, tk)

    def set_lim(mut self, p: Int):
        """(D-7972) Program p's (current) scissor rect: a partial raster's part, else the whole target: boxes are cut to
        it before the triangle that holds them is built."""
        if self.loc_lim[p] < 0:
            return
        var x0 = Float32(self.lim[0]) if len(self.lim) == 4 else Float32(0)
        var y0 = Float32(self.lim[1]) if len(self.lim) == 4 else Float32(0)
        var x1 = Float32(self.lim[2]) if len(self.lim) == 4 else Float32(self.cw)
        var y1 = Float32(self.lim[3]) if len(self.lim) == 4 else Float32(self.ch)
        if self.lim_set[4 * p] == x0 and self.lim_set[4 * p + 1] == y0 and self.lim_set[4 * p + 2] == x1 and self.lim_set[4 * p + 3] == y1:
            return
        self.lim_set[4 * p] = x0
        self.lim_set[4 * p + 1] = y0
        self.lim_set[4 * p + 2] = x1
        self.lim_set[4 * p + 3] = y1
        fcall[NoneType](self.f(F_UNIFORM_4F), c_int(self.loc_lim[p]), x0, y0, x1, y1)

    def set_sizes(mut self, w: Int, h: Int):
        """Every program's `vp` (the target's size), when it changed."""
        if self.vp_w == w and self.vp_h == h:
            return
        self.vp_w = w
        self.vp_h = h
        for p in range(PROGRAMS):
            fcall[NoneType](self.f(F_USE_PROGRAM), c_uint(self.prog[p]))
            fcall[NoneType](self.f(F_UNIFORM_2F), c_int(self.loc_vp[p]), Float32(w), Float32(h))
        fcall[NoneType](self.f(F_USE_PROGRAM), c_uint(self.prog[P_GLYPH]))
        fcall[NoneType](self.f(F_UNIFORM_1I), c_int(self.loc_atlas), c_int(0))
        fcall[NoneType](self.f(F_USE_PROGRAM), c_uint(self.prog[P_IMAGE]))
        fcall[NoneType](self.f(F_UNIFORM_1I), c_int(self.loc_img), c_int(0))

    def images(mut self, frame: Frame2D):
        """The frame's images as textures (re-filled each frame: they're few and small)."""
        for i in range(len(frame.pixels)):
            if i >= len(self.img_tex):
                self.img_tex.append(0)
                self.img_w.append(0)
                self.img_h.append(0)
        # (sizes come from the instances: pw, ph)
        var n = len(frame.images) // IMAGE_FLOATS
        for j in range(n):
            var at = j * IMAGE_FLOATS
            var which = Int(frame.images[at + 4])
            var pw = Int(frame.images[at + 5])
            var ph = Int(frame.images[at + 6])
            if which < 0 or which >= len(frame.pixels) or pw <= 0 or ph <= 0 or len(frame.pixels[which]) < pw * ph:
                continue
            if self.img_tex[which] == 0 or self.img_w[which] != pw or self.img_h[which] != ph:
                self.delete(F_DELETE_TEXTURES, self.img_tex[which])
                var t = self.gen(F_GEN_TEXTURES)
                fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(t))
                self.tex_params(GL_NEAREST)
                fcall[NoneType](self.f(F_TEX_STORAGE_2D), c_uint(GL_TEXTURE_2D), c_int(1), c_uint(GL_RGBA8), c_int(pw), c_int(ph))
                self.img_tex[which] = t
                self.img_w[which] = pw
                self.img_h[which] = ph
            fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(self.img_tex[which]))
            fcall[NoneType](self.f(F_TEX_SUB_IMAGE_2D), c_uint(GL_TEXTURE_2D), c_int(0), c_int(0), c_int(0), c_int(pw), c_int(ph),
                            c_uint(GL_RGBA), c_uint(GL_UNSIGNED_BYTE), Int(frame.pixels[which].unsafe_ptr()))
        fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(0))

    def render(mut self, frame: Frame2D, tex: Int, w: Int, h: Int) -> Bool:
        """Draws the frame's runs (each layer through its transform) into the RGBA8 texture tex of w × h: cleared to
        transparent black first. Leaves the context's state at GL's defaults for what it touched (no program, vertex
        array, framebuffer, blend, stencil or scissor). (begin + layer + end, with everything uploaded.)"""
        self.sync_pages()
        if not self.begin(tex, w, h):
            return False
        self.layer(frame, 0, True)
        return self.end(tex, w, h)

    def begin(mut self, tex: Int, w: Int, h: Int) -> Bool:
        """Starts a frame into tex (w × h): the target bound and cleared. Then layer() for each cached layer, then end()."""
        if not self.ok or w <= 0 or h <= 0:
            return False
        if not self.target(w, h):
            return False
        self.frames += 1
        self.draws = 0
        self.poly_groups = 0
        self.uploaded = 0
        self.plan_ns = 0
        self.upload_ns = 0
        self.cur_prog = -1
        self.cur_blend = -1
        fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(self.msaa_fbo))
        if self.mixed:  # (the ring texture is the colour buffer: drawn into directly, nothing to resolve)
            fcall[NoneType](self.f(F_FRAMEBUFFER_TEXTURE_2D), c_uint(GL_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_TEXTURE_2D), c_uint(tex), c_int(0))
            if self.frames == 1 or tex != self.last_tex_checked:
                self.last_tex_checked = tex
                var st = Int(fcall[c_uint](self.f(F_CHECK_FRAMEBUFFER_STATUS), c_uint(GL_FRAMEBUFFER)))
                if st != GL_FRAMEBUFFER_COMPLETE:  # (then plain MSAA from now on: its own colour buffer and a resolve)
                    fcall[NoneType](self.f(F_FRAMEBUFFER_TEXTURE_2D), c_uint(GL_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_TEXTURE_2D), c_uint(0), c_int(0))
                    fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(0))
                    print("mojoui: gpu2d: a mixed-samples target isn't complete (status " + String(st) + "): plain MSAA instead", flush=True)
                    self.mixed = False
                    self.why = self.why.replace("× stencil samples, 1× colour (NV_framebuffer_mixed_samples)", "× MSAA")
                    self.mw = 0
                    self.delete(F_DELETE_RENDERBUFFERS, self.msaa_ds)
                    self.msaa_ds = 0
                    return self.begin(tex, w, h)
            fcall[NoneType](self.cov_mod, c_uint(GL_ALPHA))
            self.count_extra(C_EXT, 1)
        self.cw = w
        self.ch = h
        self.timer_begin()
        self.set_sizes(w, h)
        fcall[NoneType](self.f(F_VIEWPORT), c_int(0), c_int(0), c_int(w), c_int(h))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_SCISSOR_TEST))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_DEPTH_TEST))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_CULL_FACE))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_DITHER))
        fcall[NoneType](self.f(F_COLOR_MASK), UInt8(1), UInt8(1), UInt8(1), UInt8(1))
        fcall[NoneType](self.f(F_STENCIL_MASK), c_uint(0xFF))
        fcall[NoneType](self.f(F_CLEAR_COLOR), Float32(0), Float32(0), Float32(0), Float32(0))
        fcall[NoneType](self.f(F_CLEAR_STENCIL), c_int(0))
        fcall[NoneType](self.f(F_CLEAR), c_uint(GL_COLOR_BUFFER_BIT | GL_STENCIL_BUFFER_BIT))
        fcall[NoneType](self.f(F_BLEND_FUNC_SEPARATE), c_uint(GL_SRC_ALPHA), c_uint(GL_ONE_MINUS_SRC_ALPHA), c_uint(GL_ZERO), c_uint(GL_ONE))
        return True

    def layer(mut self, frame: Frame2D, set: Int, upload: Bool, append_from: Int = -1):
        """Draws a frame's runs from buffer set `set`, uploading its instances first when `upload` (a layer that changed;
        an unchanged one draws from what it uploaded before, through its current transform). append_from ≥ 0: the frame
        is what this set last uploaded with runs added from run append_from on (instances, fans and points appended at
        the ends of their lists): only those are uploaded and planned."""
        var w = self.cw
        var h = self.ch
        self._run_forget()
        if upload:
            var add = append_from >= 0 and self.multi_draw != 0 and set < len(self.pgroups)
            self.stream(set, B_QUAD, frame.quads, add)
            self.stream(set, B_GLYPH, frame.glyphs, add)
            self.plan_polys(frame, set, append_from if add else 0)
        if len(frame.images) > 0:
            self.images(frame)
        self._run_forget()  # (uploads and images bound buffers and textures of their own)
        var cur = self.cur_prog
        for li in range(len(frame.layers)):
            ref layer = frame.layers[li]
            var tx = Float32(layer.dx)
            var ty = Float32(layer.dy)
            var tk = Float32(layer.k)
            for ri in range(layer.first_run, layer.first_run + layer.runs):
                var run = frame.runs[ri]
                if run.count <= 0:
                    continue
                if run.blend != self.cur_blend:
                    self.cur_blend = run.blend
                    fcall[NoneType](self.f(F_ENABLE if run.blend == BLEND_OVER else F_DISABLE), c_uint(GL_BLEND))
                var km = self.kind_mark()
                var kind_of = KIND_QUAD if run.pipe == PIPE_QUAD else (KIND_GLYPH if run.pipe == PIPE_GLYPH else (KIND_IMAGE if run.pipe == PIPE_IMAGE else KIND_POLY))
                if run.pipe == PIPE_QUAD:
                    self.use(P_QUAD, w, h, cur)
                    self.set_xf(P_QUAD, tx, ty, tk)
                    self.set_lim(P_QUAD)
                    var rep = 1 if run.blend == BLEND_REPLACE else 0
                    if not self.state_cache or rep != self.run_replace:
                        fcall[NoneType](self.f(F_UNIFORM_1I), c_int(self.loc_replace), c_int(rep))
                        self.run_replace = rep
                    self._run_draw(B_QUAD, set, run.first, run.count)
                elif run.pipe == PIPE_GLYPH:
                    self.use(P_GLYPH, w, h, cur)
                    self.set_xf(P_GLYPH, tx, ty, tk)
                    self.set_lim(P_GLYPH)
                    if not self.state_cache or self.run_tex != self.atlas_tex:
                        fcall[NoneType](self.f(F_ACTIVE_TEXTURE), c_uint(GL_TEXTURE0))
                        fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(self.atlas_tex))
                        self.run_tex = self.atlas_tex
                    self._run_draw(B_GLYPH, set, run.first, run.count)
                elif run.pipe == PIPE_IMAGE:
                    self.use(P_IMAGE, w, h, cur)
                    self.set_xf(P_IMAGE, tx, ty, tk)
                    fcall[NoneType](self.f(F_ACTIVE_TEXTURE), c_uint(GL_TEXTURE0))
                    fcall[NoneType](self.f(F_BIND_VERTEX_ARRAY), c_uint(self.empty_vao))
                    for i in range(run.first, run.first + run.count):
                        var at = i * IMAGE_FLOATS
                        var which = Int(frame.images[at + 4])
                        if which < 0 or which >= len(self.img_tex) or self.img_tex[which] == 0:
                            continue
                        fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(self.img_tex[which]))
                        fcall[NoneType](self.f(F_UNIFORM_4F), c_int(self.loc_rect), frame.images[at], frame.images[at + 1], frame.images[at + 2], frame.images[at + 3])
                        fcall[NoneType](self.f(F_UNIFORM_4F), c_int(self.loc_clip), frame.images[at + 8], frame.images[at + 9], frame.images[at + 10], frame.images[at + 11])
                        fcall[NoneType](self.f(F_DRAW_ARRAYS_INSTANCED), c_uint(GL_TRIANGLES), c_int(0), c_int(3), c_int(1))
                        self.draws += 1
                    self._run_forget()
                else:
                    self.polys(set, ri, tx, ty, tk, w, h, cur)
                    self._run_forget()
                self.kind_end(km, kind_of)
        self.cur_prog = cur
        self._run_forget()

    def timer_begin(mut self):
        """This frame's GPU time: a time-elapsed query from here to end() (begun once a frame; tile rasters drawn before
        the frame's target is bound are inside it, D-7940)."""
        if self.timing_open or not self.timing or len(self.timer) != 4:
            return
        if len(self.q_free) == 0:
            if len(self.q_pending) >= 16:
                _ = self.gpu_time()
            else:
                self.out[0] = 0
                fcall[NoneType](self.timer[0], c_int(1), self.at(0))
                self.q_free.append(self.out[0] & 0xFFFFFFFF)
        var qid = self.q_free.pop()
        fcall[NoneType](self.timer[1], c_uint(0x88BF), c_uint(qid))  # GL_TIME_ELAPSED
        self.q_pending.append(qid)
        self.timing_open = True
        self.span_t0 = Int(perf_counter_ns())

    # ---------- raster tiles (D-7940, mojoui.gpu2d_tiles) ----------

    def tile_texture(mut self, slot: Int) -> Int:
        """Tile slot's texture (TILE_TEX², RGBA8, premultiplied; made on first use)."""
        while len(self.tile_tex) <= slot:
            self.tile_tex.append(0)
        if self.tile_tex[slot] == 0:
            var t = self.gen(F_GEN_TEXTURES)
            fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(t))
            self.tex_params(GL_LINEAR)
            # (8 bits, as the frame: tried half floats, the frame's own per-item rounding differs from them as much; D-7940)
            fcall[NoneType](self.f(F_TEX_STORAGE_2D), c_uint(GL_TEXTURE_2D), c_int(1), c_uint(GL_RGBA8), c_int(TILE_TEX), c_int(TILE_TEX))
            fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(0))
            self.tile_tex[slot] = t
        return self.tile_tex[slot]

    def tile_target(mut self) -> Bool:
        """The tile target (once): its framebuffer and a TILE_TEX² stencil (and, without mixed samples, MSAA colour)."""
        if self.tile_fbo != 0:
            return True
        self.tile_fbo = self.gen(F_GEN_FRAMEBUFFERS)
        self.tile_ds = self.gen(F_GEN_RENDERBUFFERS)
        fcall[NoneType](self.f(F_BIND_RENDERBUFFER), c_uint(GL_RENDERBUFFER), c_uint(self.tile_ds))
        fcall[NoneType](self.f(F_RENDERBUFFER_STORAGE_MS), c_uint(GL_RENDERBUFFER), c_int(self.samples), c_uint(GL_DEPTH24_STENCIL8), c_int(TILE_TEX), c_int(TILE_TEX))
        if not self.mixed:
            self.tile_color = self.gen(F_GEN_RENDERBUFFERS)
            fcall[NoneType](self.f(F_BIND_RENDERBUFFER), c_uint(GL_RENDERBUFFER), c_uint(self.tile_color))
            fcall[NoneType](self.f(F_RENDERBUFFER_STORAGE_MS), c_uint(GL_RENDERBUFFER), c_int(self.samples), c_uint(GL_RGBA8), c_int(TILE_TEX), c_int(TILE_TEX))
        fcall[NoneType](self.f(F_BIND_RENDERBUFFER), c_uint(GL_RENDERBUFFER), c_uint(0))
        fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(self.tile_fbo))
        fcall[NoneType](self.f(F_FRAMEBUFFER_RENDERBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(GL_DEPTH_STENCIL_ATTACHMENT), c_uint(GL_RENDERBUFFER), c_uint(self.tile_ds))
        if not self.mixed:
            fcall[NoneType](self.f(F_FRAMEBUFFER_RENDERBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_RENDERBUFFER), c_uint(self.tile_color))
        fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(0))
        return self.error() == 0

    def raster_tile(mut self, mut frame: Frame2D, set: Int, slot: Int, ox: Float64, oy: Float64, rx0: Int = 0, ry0: Int = 0,
                    rx1: Int = TILE_TEX, ry1: Int = TILE_TEX) -> Bool:
        """frame (one layer's batches built in content px, mojoui.gpu2d.fill_layers(content_k=…)) into tile slot's
        texture, moved by (ox, oy), cleared first, premultiplied (RGB = Σ c·a over, A = coverage over): drawn later
        with (ONE, ONE − SRC_ALPHA) it gives what drawing the ops straight onto the frame does."""
        if not self.ok or not self.tile_target():
            return False
        var tex = self.tile_texture(slot)
        self.timer_begin()
        fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(self.tile_fbo))
        if self.mixed:
            fcall[NoneType](self.f(F_FRAMEBUFFER_TEXTURE_2D), c_uint(GL_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_TEXTURE_2D), c_uint(tex), c_int(0))
            fcall[NoneType](self.cov_mod, c_uint(GL_ALPHA))
            self.count_extra(C_EXT, 1)
        self.cw = TILE_TEX
        self.ch = TILE_TEX
        self.set_sizes(TILE_TEX, TILE_TEX)
        fcall[NoneType](self.f(F_VIEWPORT), c_int(0), c_int(0), c_int(TILE_TEX), c_int(TILE_TEX))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_SCISSOR_TEST))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_DEPTH_TEST))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_CULL_FACE))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_DITHER))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_STENCIL_TEST))
        fcall[NoneType](self.f(F_COLOR_MASK), UInt8(1), UInt8(1), UInt8(1), UInt8(1))
        fcall[NoneType](self.f(F_STENCIL_MASK), c_uint(0xFF))
        var partial = rx0 > 0 or ry0 > 0 or rx1 < TILE_TEX or ry1 < TILE_TEX
        if partial:  # (only the stale part: cleared and drawn inside the scissor, the rest of the picture kept)
            self.lim = [rx0, ry0, rx1, ry1]
            fcall[NoneType](self.f(F_ENABLE), c_uint(GL_SCISSOR_TEST))
            fcall[NoneType](self.f(F_SCISSOR), c_int(rx0), c_int(ry0), c_int(rx1 - rx0), c_int(ry1 - ry0))
        var kc = self.kind_mark()
        fcall[NoneType](self.f(F_CLEAR_COLOR), Float32(0), Float32(0), Float32(0), Float32(0))
        fcall[NoneType](self.f(F_CLEAR_STENCIL), c_int(0))
        fcall[NoneType](self.f(F_CLEAR), c_uint(GL_COLOR_BUFFER_BIT | GL_STENCIL_BUFFER_BIT))
        self.kind_end(kc, KIND_CLEAR)
        fcall[NoneType](self.f(F_BLEND_FUNC_SEPARATE), c_uint(GL_SRC_ALPHA), c_uint(GL_ONE_MINUS_SRC_ALPHA), c_uint(GL_ONE), c_uint(GL_ONE_MINUS_SRC_ALPHA))
        self.cur_prog = -1
        self.cur_blend = -1
        var saved = List[Float64]()
        for li in range(len(frame.layers)):
            saved.append(frame.layers[li].dx)
            saved.append(frame.layers[li].dy)
        self._move_layers(frame, ox, oy)
        self.layer(frame, set, True)
        self._unmove_layers(frame, saved)
        self.lim = List[Int]()
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_BLEND))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_SCISSOR_TEST))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_STENCIL_TEST))
        if not self.mixed:
            fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_DRAW_FRAMEBUFFER), c_uint(self.resolve_fbo))
            fcall[NoneType](self.f(F_FRAMEBUFFER_TEXTURE_2D), c_uint(GL_DRAW_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_TEXTURE_2D), c_uint(tex), c_int(0))
            fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_READ_FRAMEBUFFER), c_uint(self.tile_fbo))
            fcall[NoneType](self.f(F_BLIT_FRAMEBUFFER), c_int(0), c_int(0), c_int(TILE_TEX), c_int(TILE_TEX), c_int(0), c_int(0), c_int(TILE_TEX), c_int(TILE_TEX),
                            c_uint(GL_COLOR_BUFFER_BIT), c_uint(GL_NEAREST))
        else:
            fcall[NoneType](self.f(F_FRAMEBUFFER_TEXTURE_2D), c_uint(GL_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_TEXTURE_2D), c_uint(0), c_int(0))
        fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(0))
        return True

    def _move_layers(self, mut frame: Frame2D, ox: Float64, oy: Float64):
        for li in range(len(frame.layers)):
            frame.layers[li].dx = ox
            frame.layers[li].dy = oy

    def _unmove_layers(self, mut frame: Frame2D, saved: List[Float64]):
        for li in range(len(frame.layers)):
            frame.layers[li].dx = saved[2 * li]
            frame.layers[li].dy = saved[2 * li + 1]

    def _tile_fb(mut self, slot: Int) -> Int:
        """Tile slot's texture bound as the colour of the resolve framebuffer (scissor off), for a clear, a read or a copy."""
        var tex = self.tile_texture(slot)
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_SCISSOR_TEST))
        fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(self.resolve_fbo))
        fcall[NoneType](self.f(F_FRAMEBUFFER_TEXTURE_2D), c_uint(GL_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_TEXTURE_2D), c_uint(tex), c_int(0))
        return tex

    def upload_tile_part(mut self, slot: Int, x0: Int, y0: Int, w: Int, h: Int, src: Int) -> Bool:
        """(D-7956) A restored snapshot tile: slot's texture cleared to transparent, then w × h pixels (rows packed,
        premultiplied RGBA8) put at texture px (x0, y0)."""
        if not self.ok:
            return False
        var tex = self._tile_fb(slot)
        fcall[NoneType](self.f(F_VIEWPORT), c_int(0), c_int(0), c_int(TILE_TEX), c_int(TILE_TEX))
        fcall[NoneType](self.f(F_CLEAR_COLOR), Float32(0), Float32(0), Float32(0), Float32(0))
        fcall[NoneType](self.f(F_CLEAR), c_uint(GL_COLOR_BUFFER_BIT))
        fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(0))
        if w > 0 and h > 0:
            fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(tex))
            fcall[NoneType](self.f(F_PIXEL_STOREI), c_uint(GL_UNPACK_ALIGNMENT), c_int(1))
            fcall[NoneType](self.f(F_TEX_SUB_IMAGE_2D), c_uint(GL_TEXTURE_2D), c_int(0), c_int(x0), c_int(y0), c_int(w), c_int(h), c_uint(GL_RGBA), c_uint(GL_UNSIGNED_BYTE), src)
            fcall[NoneType](self.f(F_PIXEL_STOREI), c_uint(GL_UNPACK_ALIGNMENT), c_int(4))
            fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(0))
        return self.error() == 0

    def unpack_map(mut self, n: Int) -> Int:
        """(D-7956) A pixel-unpack buffer of at least n bytes, left bound and mapped for writing (its storage kept between
        restores, fenced: a map waits for the last uploads from it): its address, 0 when it can't be. Fill it, unpack_unmap(), then upload_tile_unpacked
        from offsets in it: the copies to the textures are the GPU's (DMA), not this thread's."""
        if not self.ok or n <= 0:
            return 0
        if self.unpack_buf == 0:
            self.unpack_buf = self.gen(F_GEN_BUFFERS)
        fcall[NoneType](self.f(F_BIND_BUFFER), c_uint(GL_PIXEL_UNPACK_BUFFER), c_uint(self.unpack_buf))
        var access = GL_MAP_WRITE_BIT
        if n > self.unpack_cap:
            fcall[NoneType](self.f(F_BUFFER_DATA), c_uint(GL_PIXEL_UNPACK_BUFFER), n, 0, c_uint(GL_STREAM_DRAW))
            self.unpack_cap = n
            if self.unpack_sync != 0:
                fcall[NoneType](self.f(F_DELETE_SYNC), self.unpack_sync)
                self.unpack_sync = 0
        else:
            # the storage kept: the last uploads from it must have read it first (long done: a restore is once an open)
            if self.unpack_sync != 0:
                _ = fcall[c_uint](self.f(F_CLIENT_WAIT_SYNC), self.unpack_sync, c_uint(1), UInt64(1000000000))
                fcall[NoneType](self.f(F_DELETE_SYNC), self.unpack_sync)
                self.unpack_sync = 0
            access |= GL_MAP_UNSYNCHRONIZED_BIT
        var addr = fcall[Int](self.f(F_MAP_BUFFER_RANGE), c_uint(GL_PIXEL_UNPACK_BUFFER), 0, n, c_uint(access))
        if addr == 0:
            fcall[NoneType](self.f(F_BIND_BUFFER), c_uint(GL_PIXEL_UNPACK_BUFFER), c_uint(0))
            _ = self.error()
        return addr

    def unpack_unmap(mut self) -> Bool:
        """The mapped unpack buffer handed back (still bound for the uploads); False: its contents were lost."""
        return fcall[UInt8](self.f(F_UNMAP_BUFFER), c_uint(GL_PIXEL_UNPACK_BUFFER)) != 0

    def unpack_done(mut self):
        """The uploads issued: fenced (the next map waits for them to have read it), the buffer unbound."""
        if self.unpack_sync == 0:
            self.unpack_sync = fcall[Int](self.f(F_FENCE_SYNC), c_uint(GL_SYNC_GPU_COMMANDS_COMPLETE), c_uint(0))
        fcall[NoneType](self.f(F_BIND_BUFFER), c_uint(GL_PIXEL_UNPACK_BUFFER), c_uint(0))

    def upload_tile_unpacked(mut self, slot: Int, x0: Int, y0: Int, w: Int, h: Int, offset: Int, clear: Bool) -> Bool:
        """(D-7956) As upload_tile_part, the pixels at `offset` in the bound unpack buffer; the texture cleared to
        transparent first only when `clear` (the part doesn't cover it)."""
        if not self.ok:
            return False
        var tex = self._tile_fb(slot) if clear else self.tile_texture(slot)
        if clear:
            fcall[NoneType](self.f(F_VIEWPORT), c_int(0), c_int(0), c_int(TILE_TEX), c_int(TILE_TEX))
            fcall[NoneType](self.f(F_CLEAR_COLOR), Float32(0), Float32(0), Float32(0), Float32(0))
            fcall[NoneType](self.f(F_CLEAR), c_uint(GL_COLOR_BUFFER_BIT))
            fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(0))
        if w > 0 and h > 0:
            fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(tex))
            fcall[NoneType](self.f(F_PIXEL_STOREI), c_uint(GL_UNPACK_ALIGNMENT), c_int(1))
            fcall[NoneType](self.f(F_TEX_SUB_IMAGE_2D), c_uint(GL_TEXTURE_2D), c_int(0), c_int(x0), c_int(y0), c_int(w), c_int(h), c_uint(GL_RGBA), c_uint(GL_UNSIGNED_BYTE), offset)
            fcall[NoneType](self.f(F_PIXEL_STOREI), c_uint(GL_UNPACK_ALIGNMENT), c_int(4))
            fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(0))
        return True

    def read_tile_part(mut self, slot: Int, x0: Int, y0: Int, w: Int, h: Int, dst: Int) -> Bool:
        """(D-7956) w × h pixels of slot's texture from texture px (x0, y0) into dst (rows packed)."""
        if not self.ok:
            return False
        _ = self._tile_fb(slot)
        fcall[NoneType](self.f(F_PIXEL_STOREI), c_uint(GL_PACK_ALIGNMENT), c_int(1))
        fcall[NoneType](self.f(F_READ_PIXELS), c_int(x0), c_int(y0), c_int(w), c_int(h), c_uint(GL_RGBA), c_uint(GL_UNSIGNED_BYTE), dst)
        fcall[NoneType](self.f(F_PIXEL_STOREI), c_uint(GL_PACK_ALIGNMENT), c_int(4))
        fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(0))
        return self.error() == 0

    def draw_tiles(mut self, draws: List[TileDraw]):
        """Kept tiles onto the frame being drawn (between begin and end), premultiplied over what's there, the frame's
        alpha kept."""
        if len(draws) == 0:
            return
        fcall[NoneType](self.f(F_USE_PROGRAM), c_uint(self.tile_prog))
        self.cur_prog = -1
        self.cur_blend = -1
        fcall[NoneType](self.f(F_ENABLE), c_uint(GL_BLEND))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_SCISSOR_TEST))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_STENCIL_TEST))
        fcall[NoneType](self.f(F_BLEND_FUNC_SEPARATE), c_uint(GL_ONE), c_uint(GL_ONE_MINUS_SRC_ALPHA), c_uint(GL_ZERO), c_uint(GL_ONE))
        fcall[NoneType](self.f(F_UNIFORM_2F), c_int(self.tl_vp), Float32(self.cw), Float32(self.ch))
        fcall[NoneType](self.f(F_UNIFORM_1I), c_int(self.tl_tex), c_int(0))
        fcall[NoneType](self.f(F_ACTIVE_TEXTURE), c_uint(GL_TEXTURE0))
        fcall[NoneType](self.f(F_BIND_VERTEX_ARRAY), c_uint(self.empty_vao))
        for ref d in draws:
            if d.slot < 0 or d.slot >= len(self.tile_tex) or self.tile_tex[d.slot] == 0:
                continue
            var x0 = Float64(d.i) * TILE * d.s + d.tx
            var y0 = Float64(d.j) * TILE * d.s + d.ty
            var x1 = Float64(d.i + 1) * TILE * d.s + d.tx
            var y1 = Float64(d.j + 1) * TILE * d.s + d.ty
            x0 = max(x0, d.cx0)
            y0 = max(y0, d.cy0)
            x1 = min(x1, d.cx1)
            y1 = min(y1, d.cy1)
            if x1 <= x0 or y1 <= y0:
                continue
            fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(self.tile_tex[d.slot]))
            fcall[NoneType](self.f(F_UNIFORM_4F), c_int(self.tl_rect), Float32(x0), Float32(y0), Float32(x1), Float32(y1))
            fcall[NoneType](self.f(F_UNIFORM_4F), c_int(self.tl_clip), Float32(d.cx0), Float32(d.cy0), Float32(d.cx1), Float32(d.cy1))
            fcall[NoneType](self.f(F_UNIFORM_4F), c_int(self.tl_map), Float32(d.s), Float32(d.tx), Float32(d.ty), Float32(TILE))
            fcall[NoneType](self.f(F_UNIFORM_2F), c_int(self.tl_org), Float32(Float64(d.i) * TILE), Float32(Float64(d.j) * TILE))
            fcall[NoneType](self.f(F_UNIFORM_1I), c_int(self.tl_lin), c_int(0 if d.s == 1.0 else 1))
            fcall[NoneType](self.f(F_DRAW_ARRAYS_INSTANCED), c_uint(GL_TRIANGLES), c_int(0), c_int(3), c_int(1))
            self.draws += 1
        fcall[NoneType](self.f(F_BLEND_FUNC_SEPARATE), c_uint(GL_SRC_ALPHA), c_uint(GL_ONE_MINUS_SRC_ALPHA), c_uint(GL_ZERO), c_uint(GL_ONE))
        fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(0))

    def end(mut self, tex: Int, w: Int, h: Int) -> Bool:
        """Finishes the frame: MSAA resolved into tex (mixed samples: tex was drawn into), GL state back to defaults."""
        if self.timing_open:
            fcall[NoneType](self.timer[2], c_uint(0x88BF))
            self.timing_open = False
            if self.span_log:
                print("GPUSPAN: cpu " + String(Float64(Int(perf_counter_ns()) - self.span_t0) / 1e6), flush=True)
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_BLEND))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_SCISSOR_TEST))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_STENCIL_TEST))
        if not self.mixed:
            fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_DRAW_FRAMEBUFFER), c_uint(self.resolve_fbo))
            fcall[NoneType](self.f(F_FRAMEBUFFER_TEXTURE_2D), c_uint(GL_DRAW_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_TEXTURE_2D), c_uint(tex), c_int(0))
            fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_READ_FRAMEBUFFER), c_uint(self.msaa_fbo))
            fcall[NoneType](self.f(F_BLIT_FRAMEBUFFER), c_int(0), c_int(0), c_int(w), c_int(h), c_int(0), c_int(0), c_int(w), c_int(h),
                            c_uint(GL_COLOR_BUFFER_BIT), c_uint(GL_NEAREST))
        else:  # (the texture leaves the framebuffer: the toolkit samples it next)
            fcall[NoneType](self.f(F_FRAMEBUFFER_TEXTURE_2D), c_uint(GL_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_TEXTURE_2D), c_uint(0), c_int(0))
        fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(0))
        fcall[NoneType](self.f(F_BIND_TEXTURE), c_uint(GL_TEXTURE_2D), c_uint(0))
        fcall[NoneType](self.f(F_BIND_VERTEX_ARRAY), c_uint(0))
        fcall[NoneType](self.f(F_BIND_BUFFER), c_uint(GL_ARRAY_BUFFER), c_uint(0))
        fcall[NoneType](self.f(F_USE_PROGRAM), c_uint(0))
        self.cur_prog = -1
        var err = self.error()
        if err != 0:
            self.why = "GL error " + String(err) + " while drawing"
            return False
        return True

    def plan_polys(mut self, frame: Frame2D, set: Int, from_run: Int = 0):
        """A layer's polygon runs as stencil groups, uploaded: the fans into B_FAN (as built), a cover triangle per
        polygon into B_COVER, the groups kept (pgroups). Polygons share a group (one fan draw, one cover draw) when no
        cover triangle of one reaches another's bounds and they share a clip. A run of up to LEVELS_UP_TO polygons is
        grouped by overlap depth: a polygon goes one group after the last group holding an earlier polygon it overlaps,
        so overlapping polygons keep their order and the rest share groups (a mind map's 300 branches: ~20 groups, not
        ~230 in paint order). Longer runs (a page of ink): groups of consecutive polygons. With multi_draw a group's
        fans are drawn where they lie, as (first, count) ranges; without it, a group whose polygons aren't consecutive
        gets its fans copied into group order. Covers are the bounds padded by 1 px at the layer's zoom when planned,
        in its units (the fans' samples lie inside the bounds whatever the zoom, so the grouping holds under any later
        transform). from_run > 0: the runs before it were planned and uploaded already (a layer that grew): only the
        rest is planned, their covers and fans appended to the buffers."""
        var t_plan = perf_counter_ns()
        while len(self.pgroups) <= set:
            self.pgroups.append(List[Float64]())
            self.pg_first.append(List[Int]())
            self.md_first.append(List[Int32]())
            self.md_count.append(List[Int32]())
            self.md_on.append(False)
        var md = self.multi_draw != 0
        var add = from_run > 0 and md and len(self.pg_first[set]) == from_run + 1
        var r0 = from_run if add else 0
        ref q = frame.polys
        # 1. per polygon run: each polygon's group key (overlap depth, then clip), in drawing order
        var order = List[Int]()  # per run: its polygons (indexes within the run) in drawing order, and their keys
        var keys_of = List[Int]()
        var run_at = List[Int](length=len(frame.runs) + 1, fill=0)  # run r's entries: order[run_at[r] : run_at[r + 1]]
        var clips = List[Float32]()  # every distinct clip (x0, y0, x1, y1), for the groups' scissors
        var clip_of = List[Int]()  # per polygon of the frame: its clip's index
        var pads = List[Float32](length=len(frame.runs), fill=1.0)
        var moved = False
        for i in range(len(q) // POLY_FLOATS):
            var at = i * POLY_FLOATS
            var id = -1
            for c in range(len(clips) // 4):
                if clips[4 * c] == q[at + 12] and clips[4 * c + 1] == q[at + 13] and clips[4 * c + 2] == q[at + 14] and clips[4 * c + 3] == q[at + 15]:
                    id = c
                    break
            if id < 0:
                id = len(clips) // 4
                for z in range(4):
                    clips.append(q[at + 12 + z])
            clip_of.append(id)
        var nclips = max(len(clips) // 4, 1)
        for li in range(len(frame.layers)):
            ref layer = frame.layers[li]
            var pad = Float32(1.0 / layer.k) if layer.k > 0 else Float32(1.0)
            for ri in range(layer.first_run, layer.first_run + layer.runs):
                pads[ri] = pad
                run_at[ri] = len(order)
                var run = frame.runs[ri]
                if ri < r0 or run.pipe != PIPE_POLY or run.count <= 0:
                    continue
                var n = run.count
                var b = List[Float32](capacity=8 * n)  # (per polygon: its bounds, its cover triangle's box)
                for i in range(n):
                    var at = (run.first + i) * POLY_FLOATS
                    for z in range(4):
                        b.append(q[at + 8 + z])
                    var lx = q[at + 8] - pad
                    var ly = q[at + 9] - pad
                    b.append(lx)
                    b.append(ly)
                    b.append(lx + 2 * (q[at + 10] + pad - lx))
                    b.append(ly + 2 * (q[at + 11] + pad - ly))
                var level = List[Int](length=n, fill=0)
                if n <= LEVELS_UP_TO:
                    for i in range(n):
                        var lv = 0
                        for j in range(i):
                            if level[j] + 1 > lv and _covers_meet(b, i, j, pad):
                                lv = level[j] + 1
                        level[i] = lv
                else:  # (in order: a new group when a polygon meets one in the current group, or the clip changes)
                    var g = 0
                    var g0 = 0
                    for i in range(n):
                        var split = i > g0 and (clip_of[run.first + i] != clip_of[run.first + g0] or i - g0 >= 256)
                        if not split:
                            for j in range(g0, i):
                                if _covers_meet(b, i, j, pad):
                                    split = True
                                    break
                        if split:
                            g += 1
                            g0 = i
                        level[i] = g
                var keys = List[Int](capacity=n)
                for i in range(n):
                    keys.append((level[i] * nclips + clip_of[run.first + i]) * n + i)
                sort(keys)
                for z in range(n):
                    var key = keys[z] // n
                    var i = keys[z] - key * n
                    if i != z:
                        moved = True
                    order.append(i)
                    keys_of.append(key)
        run_at[len(frame.runs)] = len(order)
        # 2. the groups and covers; the fans as (first, count) ranges (multi_draw), as built, or copied in group order
        var copy = moved and not md
        var groups = List[Float64]()
        var first = List[Int](length=len(frame.runs) + 1, fill=0)
        var mdf = List[Int32]()
        var mdc = List[Int32]()
        var cov_base = 0  # (appending: the cover vertices already uploaded)
        if add:
            swap(groups, self.pgroups[set])
            swap(mdf, self.md_first[set])
            swap(mdc, self.md_count[set])
            for r in range(from_run):
                first[r] = self.pg_first[set][r]
            cov_base = self.lsize[BUFFERS * set + B_COVER] // 32
        self.fan_stage.clear()
        self.cov_stage.clear()
        for ri in range(r0, len(frame.runs)):
            first[ri] = len(groups) // 9
            var run = frame.runs[ri]
            var pad = pads[ri]
            var cur = -1
            for z in range(run_at[ri], run_at[ri + 1]):
                var i = run.first + order[z]
                var at = i * POLY_FLOATS
                var fan0 = Int(q[at])
                var nf = Int(q[at + 1])
                if keys_of[z] != cur:
                    cur = keys_of[z]
                    var c = clip_of[i]
                    groups.append(Float64(ri))
                    groups.append(Float64(len(mdf) if md else (len(self.fan_stage) // 2 if copy else fan0)))
                    groups.append(0)
                    groups.append(Float64(cov_base + len(self.cov_stage) // 8))
                    groups.append(0)
                    for zz in range(4):
                        groups.append(Float64(clips[4 * c + zz]))
                if md:
                    mdf.append(Int32(fan0))
                    mdc.append(Int32(nf))
                elif copy:
                    var src = frame.fan.unsafe_ptr()
                    for v in range(2 * fan0, 2 * (fan0 + nf)):
                        self.fan_stage.append(src[v])
                for _ in range(3):
                    for zz in range(4):
                        self.cov_stage.append(q[at + 4 + zz])
                    self.cov_stage.append(q[at + 8] - pad)
                    self.cov_stage.append(q[at + 9] - pad)
                    self.cov_stage.append(q[at + 10] + pad)
                    self.cov_stage.append(q[at + 11] + pad)
                var last = len(groups) - 9
                groups[last + 2] += Float64(1 if md else nf)
                groups[last + 4] += 3
        first[len(frame.runs)] = len(groups) // 9
        self.plan_ns += Int(perf_counter_ns() - t_plan)
        var covers = List[Float32]()  # (swapped out and back: stream reads it while self is borrowed mutably)
        swap(covers, self.cov_stage)
        if add:  # (the new covers go after the ones uploaded: the buffer's size says where)
            var i = BUFFERS * set + B_COVER
            var have = self.lsize[i]
            if have + len(covers) * 4 <= self.lcap[i]:
                fcall[NoneType](self.f(F_BIND_BUFFER), c_uint(GL_ARRAY_BUFFER), c_uint(self.lvbo[i]))
                if len(covers) > 0:
                    fcall[NoneType](self.f(F_BUFFER_SUB_DATA), c_uint(GL_ARRAY_BUFFER), have, len(covers) * 4, Int(covers.unsafe_ptr()))
                    self.count_extra(C_BYTES, len(covers) * 4)
                self.lsize[i] = have + len(covers) * 4
                self.uploaded += len(covers) * 4
                swap(covers, self.cov_stage)
            else:  # (no room: everything again)
                swap(covers, self.cov_stage)
                swap(groups, self.pgroups[set])
                swap(mdf, self.md_first[set])
                swap(mdc, self.md_count[set])
                self.plan_polys(frame, set, 0)
                return
        else:
            self.stream(set, B_COVER, covers)
            swap(covers, self.cov_stage)
        if copy:
            var fans = List[Float32]()
            swap(fans, self.fan_stage)
            self.stream(set, B_FAN, fans)
            swap(fans, self.fan_stage)
        else:
            self.stream(set, B_FAN, frame.fan, add)
        if md and self.indirect:  # (the commands: count, instances 1, first, 0 per polygon, as the ranges)
            var cmds = List[UInt32](capacity=4 * len(mdf))
            for k in range(len(mdf)):
                cmds.append(UInt32(Int(mdc[k])))
                cmds.append(1)
                cmds.append(UInt32(Int(mdf[k])))
                cmds.append(0)
            self.stream_raw(set, B_INDIRECT, Int(cmds.unsafe_ptr()), len(cmds) * 4, add)
            _ = len(cmds)
        self.pgroups[set] = groups^
        self.pg_first[set] = first^
        self.md_first[set] = mdf^
        self.md_count[set] = mdc^
        self.md_on[set] = md

    def polys(mut self, set: Int, ri: Int, tx: Float32, ty: Float32, tk: Float32, w: Int, h: Int, mut cur: Int):
        """Polygon run ri of buffer set `set` by stencil and cover, group by group (planned by plan_polys): the group's
        fans into the stencil, then its covers where the stencil isn't zero, zeroing it as they go."""
        if set >= len(self.pgroups) or ri + 1 >= len(self.pg_first[set]):
            return
        var g0 = self.pg_first[set][ri]
        var g1 = self.pg_first[set][ri + 1]
        if g1 <= g0:
            return
        fcall[NoneType](self.f(F_ENABLE), c_uint(GL_STENCIL_TEST))
        fcall[NoneType](self.f(F_ENABLE), c_uint(GL_SCISSOR_TEST))
        # the vertex arrays point at this set's buffers once for the run (fans: x, y; covers: colour, bounds)
        fcall[NoneType](self.f(F_BIND_VERTEX_ARRAY), c_uint(self.vao[B_COVER]))
        if self.vao_point(B_COVER, self.buf(set, B_COVER)):
            fcall[NoneType](self.f(F_VERTEX_ATTRIB_POINTER), c_uint(1), c_int(4), c_uint(GL_FLOAT), UInt8(0), c_int(32), 0)
            fcall[NoneType](self.f(F_VERTEX_ATTRIB_POINTER), c_uint(2), c_int(4), c_uint(GL_FLOAT), UInt8(0), c_int(32), 16)
        fcall[NoneType](self.f(F_BIND_VERTEX_ARRAY), c_uint(self.vao[B_FAN]))
        if self.vao_point(B_FAN, self.buf(set, B_FAN)):
            fcall[NoneType](self.f(F_VERTEX_ATTRIB_POINTER), c_uint(0), c_int(2), c_uint(GL_FLOAT), UInt8(0), c_int(8), 0)
        if self.indirect and self.md_on[set]:
            fcall[NoneType](self.f(F_BIND_BUFFER), c_uint(0x8F3F), c_uint(self.buf(set, B_INDIRECT)))
        var sx0 = -1
        var sy0 = -1
        var sx1 = -1
        var sy1 = -1
        for g in range(g0, g1):
            ref gr = self.pgroups[set]
            var at = g * 9
            var fan0 = Int(gr[at + 1])
            var fan_n = Int(gr[at + 2])
            var cov0 = Int(gr[at + 3])
            var cov_n = Int(gr[at + 4])
            # the clip as the scissor (pixel centres inside [x0, x1) × [y0, y1))
            var c0 = gr[at + 5]
            var c1 = gr[at + 6]
            var c2 = gr[at + 7]
            var c3 = gr[at + 8]
            var x0 = _pixel_lo(c0 * Float64(tk) + Float64(tx), w) if c0 > -NO_CLIP * 0.5 else 0
            var y0 = _pixel_lo(c1 * Float64(tk) + Float64(ty), h) if c1 > -NO_CLIP * 0.5 else 0
            var x1 = _pixel_lo(c2 * Float64(tk) + Float64(tx), w) if c2 < NO_CLIP * 0.5 else w
            var y1 = _pixel_lo(c3 * Float64(tk) + Float64(ty), h) if c3 < NO_CLIP * 0.5 else h
            if len(self.lim) == 4:  # (a partial tile raster: never outside its part)
                x0 = max(x0, self.lim[0])
                y0 = max(y0, self.lim[1])
                x1 = min(x1, self.lim[2])
                y1 = min(y1, self.lim[3])
            if x1 <= x0 or y1 <= y0 or fan_n <= 0:
                continue
            if x0 != sx0 or y0 != sy0 or x1 != sx1 or y1 != sy1:
                sx0 = x0
                sy0 = y0
                sx1 = x1
                sy1 = y1
                fcall[NoneType](self.f(F_SCISSOR), c_int(x0), c_int(y0), c_int(x1 - x0), c_int(y1 - y0))
            # 1. the fans into the stencil: front faces +1, back faces −1 (wrapping), no colour
            self.use(P_FAN, w, h, cur)
            self.set_xf(P_FAN, tx, ty, tk)
            fcall[NoneType](self.f(F_COLOR_MASK), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
            fcall[NoneType](self.f(F_STENCIL_FUNC), c_uint(GL_ALWAYS), c_int(0), c_uint(0xFF))
            fcall[NoneType](self.f(F_STENCIL_OP_SEPARATE), c_uint(GL_FRONT), c_uint(GL_KEEP), c_uint(GL_KEEP), c_uint(GL_INCR_WRAP))
            fcall[NoneType](self.f(F_STENCIL_OP_SEPARATE), c_uint(GL_BACK), c_uint(GL_KEEP), c_uint(GL_KEEP), c_uint(GL_DECR_WRAP))
            fcall[NoneType](self.f(F_BIND_VERTEX_ARRAY), c_uint(self.vao[B_FAN]))
            if self.md_on[set] and self.indirect:  # (fan0: the group's first command, fan_n: its polygons)
                fcall[NoneType](self.multi_draw, c_uint(GL_TRIANGLES), 16 * fan0, c_int(fan_n), c_int(0))
                self.count_extra(C_MULTI, 1)
            elif self.md_on[set]:  # (fan0: the group's first entry in md_first/md_count, fan_n: its polygons)
                fcall[NoneType](self.multi_draw, c_uint(GL_TRIANGLES), Int(self.md_first[set].unsafe_ptr()) + 4 * fan0,
                                Int(self.md_count[set].unsafe_ptr()) + 4 * fan0, c_int(fan_n))
                self.count_extra(C_MULTI, 1)
            else:
                fcall[NoneType](self.f(F_DRAW_ARRAYS), c_uint(GL_TRIANGLES), c_int(fan0), c_int(fan_n))
            # 2. the covers where the stencil isn't zero, zeroing it as they go
            self.use(P_COVER, w, h, cur)
            self.set_xf(P_COVER, tx, ty, tk)
            fcall[NoneType](self.f(F_COLOR_MASK), UInt8(1), UInt8(1), UInt8(1), UInt8(1))
            fcall[NoneType](self.f(F_STENCIL_FUNC), c_uint(GL_NOTEQUAL), c_int(0), c_uint(0xFF))
            fcall[NoneType](self.f(F_STENCIL_OP), c_uint(GL_ZERO), c_uint(GL_ZERO), c_uint(GL_ZERO))
            fcall[NoneType](self.f(F_BIND_VERTEX_ARRAY), c_uint(self.vao[B_COVER]))
            fcall[NoneType](self.f(F_DRAW_ARRAYS), c_uint(GL_TRIANGLES), c_int(cov0), c_int(cov_n))
            self.draws += 2
            self.poly_groups += 1
        if self.indirect and self.md_on[set]:
            fcall[NoneType](self.f(F_BIND_BUFFER), c_uint(0x8F3F), c_uint(0))
        fcall[NoneType](self.f(F_DISABLE), c_uint(GL_STENCIL_TEST))
        if len(self.lim) == 4:  # (back to the partial raster's scissor for the runs after)
            fcall[NoneType](self.f(F_SCISSOR), c_int(self.lim[0]), c_int(self.lim[1]), c_int(self.lim[2] - self.lim[0]), c_int(self.lim[3] - self.lim[1]))
        else:
            fcall[NoneType](self.f(F_DISABLE), c_uint(GL_SCISSOR_TEST))

    def read(mut self, tex: Int, w: Int, h: Int, dst: Int) -> Bool:
        """Tests: a texture read back into CPU memory (rows of w RGBA pixels, top row first)."""
        fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(self.resolve_fbo))
        fcall[NoneType](self.f(F_FRAMEBUFFER_TEXTURE_2D), c_uint(GL_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_TEXTURE_2D), c_uint(tex), c_int(0))
        fcall[NoneType](self.f(F_PIXEL_STOREI), c_uint(GL_PACK_ALIGNMENT), c_int(1))
        fcall[NoneType](self.f(F_READ_PIXELS), c_int(0), c_int(0), c_int(w), c_int(h), c_uint(GL_RGBA), c_uint(GL_UNSIGNED_BYTE), dst)
        fcall[NoneType](self.f(F_BIND_FRAMEBUFFER), c_uint(GL_FRAMEBUFFER), c_uint(0))
        return self.error() == 0

    def close(mut self):
        """Every GL object this made (the context current). ok is False afterwards; safe to call twice."""
        if self.fp[F_DELETE_TEXTURES] == 0:
            return
        self.dmabuf.close()
        for i in range(RING):
            if self.sync[i] != 0:
                fcall[NoneType](self.f(F_DELETE_SYNC), self.sync[i])
                self.sync[i] = 0
            self.delete(F_DELETE_TEXTURES, self.tex[i])
            self.tex[i] = 0
        for i in range(len(self.img_tex)):
            self.delete(F_DELETE_TEXTURES, self.img_tex[i])
            self.img_tex[i] = 0
        self.delete(F_DELETE_TEXTURES, self.atlas_tex)
        self.atlas_tex = 0
        if self.unpack_sync != 0:
            fcall[NoneType](self.f(F_DELETE_SYNC), self.unpack_sync)
            self.unpack_sync = 0
        if self.unpack_buf != 0:
            self.delete(F_DELETE_BUFFERS, self.unpack_buf)
            self.unpack_buf = 0
            self.unpack_cap = 0
        for i in range(len(self.lvbo)):
            self.delete(F_DELETE_BUFFERS, self.lvbo[i])
            self.lvbo[i] = 0
        for b in range(VAOS):
            self.delete(F_DELETE_VERTEX_ARRAYS, self.vao[b])
            self.vao[b] = 0
        self.delete(F_DELETE_VERTEX_ARRAYS, self.empty_vao)
        self.empty_vao = 0
        self.delete(F_DELETE_RENDERBUFFERS, self.msaa_color)
        self.delete(F_DELETE_RENDERBUFFERS, self.msaa_ds)
        self.msaa_color = 0
        self.msaa_ds = 0
        self.mw = 0
        self.mh = 0
        self.delete(F_DELETE_FRAMEBUFFERS, self.msaa_fbo)
        self.delete(F_DELETE_FRAMEBUFFERS, self.resolve_fbo)
        self.msaa_fbo = 0
        self.resolve_fbo = 0
        for p in range(PROGRAMS):
            if self.prog[p] != 0:
                fcall[NoneType](self.f(F_DELETE_PROGRAM), c_uint(self.prog[p]))
                self.prog[p] = 0
        self.ok = False
        self.why = "closed"


def _fills(f: Frame2D) -> Int:
    """What a layer's pixel-replacing runs do to the canvas's alpha (GPU2D.fills): -1 when any writes translucency (a
    fill with alpha < 1, an image with a pixel whose alpha < 255), else 1 when one is an opaque fill, else 0."""
    var out = 0
    for r in range(len(f.runs)):
        var run = f.runs[r]
        if run.blend != BLEND_REPLACE:
            continue
        if run.pipe == PIPE_QUAD:
            for i in range(run.first, run.first + run.count):
                if f.quads[i * QUAD_FLOATS + 11] < 1.0:
                    return -1
                out = 1
        elif run.pipe == PIPE_IMAGE:
            for i in range(run.first, run.first + run.count):
                var which = Int(f.images[i * IMAGE_FLOATS + 4])
                if which < 0 or which >= len(f.pixels):
                    return -1
                for px in f.pixels[which]:
                    if px >> 24 != 0xFF:
                        return -1
    return out


comptime CACHES = 8  # canvases whose layer caches GPU2D keeps at once (the least recently drawn goes beyond)


struct LayerCache(Movable):
    """One canvas's cached layers (GPU2D.draw): batches, the zoom each was built at, what its fills do to alpha, and
    the GL buffer set each layer's buffers live in (sets are never shared between canvases)."""

    var owner: Int
    var frames: List[Frame2D]
    var built: Int
    var built_k: List[Float64]
    var built_resets: List[Int]  # GlyphPages.resets when each layer was built (D-7930)
    var fills: List[Int]
    var sets: List[Int]
    var used: Int  # GPU2D.stamp when it last drew

    def __init__(out self):
        self.owner = 0
        self.frames = List[Frame2D]()
        self.built = 0
        self.built_k = List[Float64]()
        self.built_resets = List[Int]()
        self.fills = List[Int]()
        self.sets = List[Int]()
        self.used = 0


struct GPU2D(Movable):
    """What a host keeps for its .gpu() canvases: the GL backend, the baked font and its atlas (uploaded once), and the
    last frame's batches and GPU buffers per layer. draw() rebuilds and uploads only the layers that changed since the
    canvas's last frame (Scene.same_layer); a layer that only moved (a pan, a zoom) is drawn again from its buffers
    through its new transform, unless its batches depend on the transform (a fill: the whole canvas; clips; text only
    on its zoom, the face picked at the size on screen: a text layer is reused through a pan, D-7578). At the idle clocks the light load leaves the GPU in, re-sending a page
    of ink every frame cost more than drawing it (2.3 MB of stencil vertices for the judged whiteboard)."""

    var gl: GL2D
    var font: Font
    var atlas: GlyphAtlas
    var traced: Int
    var frames: List[Frame2D]  # layer i's batches, as built for the canvas `owner` last drew
    var built: Int  # how many of `frames` hold the owner's last frame's layers
    var owner: Int  # the canvas the cache is for (another canvas drawing rebuilds every layer)
    var batch_ns: Int  # the last frame's batching (only the layers that changed)
    var render_ns: Int  # the last frame's uploads + draws (CPU side; the GPU's part when the caller waits)
    var rebuilt: Int  # layers rebuilt / reused / grown (only their new ops built and uploaded) last frame
    var reused: Int
    var grown: Int
    var scratch: Frame2D  # a changed layer's batches as built, before merge_runs regroups them into frames[i]
    var merge: Bool  # merge_runs on (MOJOUI_GPU2D_MERGE=0: the runs as built, for comparisons)
    var runs_built: Int  # runs before / after merging, last frame's rebuilt layers
    var runs_merged: Int
    var fills: List[Int]  # per cached layer: what its pixel-replacing runs do to the canvas's alpha: 1 an opaque fill
    # (OP_FILL, alpha 1), -1 something translucent replaces pixels (a fill with alpha < 1, an image with a pixel whose
    # alpha < 255), 0 neither
    var opaque: Bool  # the last frame is opaque everywhere (a layer fills it opaquely, none replaces with translucency):
    # a host may hand it over as an opaque texture (the toolkit then skips its alpha conversion and blending)
    var built_k: List[Float64]  # the zoom each cached layer was built at (merge_runs pads boxes by 4 px at that zoom:
    var built_resets: List[Int]  # GlyphPages.resets when each layer was built (D-7930)
    # a layer reused more than 4× further out is rebuilt, so its pads stay ≥ 1 px)
    var sets: List[Int]  # the GL buffer set of each of the owner's layers
    var others: List[LayerCache]  # other canvases' caches, kept while they don't draw (D-7561: two .gpu() canvases on one
    # screen each keep their layers; the least recently drawn of more than CACHES canvases is dropped)
    var next_set: Int  # GL buffer sets handed out so far; sets freed by a dropped cache are reused first
    var free_sets: List[Int]
    var stamp: Int
    var tiles: Tiles  # (D-7940) tiled layers' kept raster tiles (mojoui.gpu2d_tiles), the frames their batches are built in
    var tile_frames: List[Frame2D]
    var tile_set: Int  # the GL buffer set tile rasters upload into (one at a time)
    var tiles_on: Bool  # MOJOUI_GPU2D_TILES=0: tiled layers drawn directly (for comparisons)
    var prewarmed: Bool  # (D-7961) the snapshot restore's buffer and textures made
    var tile_ns: Int  # last frame's tile work (plan + batches + raster submission, CPU side)
    var more: Bool  # the last frame left tile work for later frames: a host draws again
    var tile_trace: Bool  # MOJOUI_TILE_TRACE=1: each frame's tile work printed
    var tile_merge: Bool  # tiles' runs regrouped before rasterizing (MOJOUI_TILE_MERGE=1)
    var layer_times: Bool  # MOJOUI_GPU2D_LAYER_TIMES=1 (diagnosis): GPU timestamps between layers, printed each frame
    var qc: Int  # glQueryCounter
    var ts_q: List[Int]
    var ts_frames: Int
    var t_plan: Int  # (trace) last frame's tile planning, batch building, merging, raster submission (ns), ops built
    var t_fill: Int
    var t_merge: Int
    var t_raster: Int
    var t_ops: Int

    def __init__(out self):
        self.gl = GL2D()
        self.font = Font()
        self.atlas = GlyphAtlas(self.font)
        self.traced = 0
        self.frames = List[Frame2D]()
        self.built = 0
        self.owner = 0
        self.batch_ns = 0
        self.render_ns = 0
        self.rebuilt = 0
        self.reused = 0
        self.grown = 0
        self.scratch = Frame2D()
        self.merge = getenv("MOJOUI_GPU2D_MERGE") != "0"
        self.runs_built = 0
        self.runs_merged = 0
        self.built_k = List[Float64]()
        self.built_resets = List[Int]()
        self.fills = List[Int]()
        self.opaque = False
        self.sets = List[Int]()
        self.others = List[LayerCache]()
        self.next_set = 0
        self.free_sets = List[Int]()
        self.stamp = 0
        self.tiles = Tiles()
        self.tile_frames = List[Frame2D]()
        self.tile_set = -1
        self.tiles_on = getenv("MOJOUI_GPU2D_TILES") != "0"
        self.prewarmed = False
        self.tile_ns = 0
        self.more = False
        self.tile_trace = getenv("MOJOUI_TILE_TRACE") == "1"
        self.tile_merge = getenv("MOJOUI_TILE_MERGE") == "1"
        self.layer_times = getenv("MOJOUI_GPU2D_LAYER_TIMES") == "1"
        self.qc = 0
        self.ts_q = List[Int]()
        self.ts_frames = 0
        self.t_plan = 0
        self.t_fill = 0
        self.t_merge = 0
        self.t_raster = 0
        self.t_ops = 0

    def caches(self) -> Int:
        """How many canvases' layer caches are kept (the one drawn last included)."""
        return len(self.others) + (1 if self.owner != 0 else 0)

    def _switch(mut self, owner: Int):
        """Makes `owner`'s cache the active one (self.frames …): the active one is stashed, owner's taken from the stash
        (or a fresh one, with no layers built)."""
        if owner == self.owner:
            return
        var mine = LayerCache()
        mine.owner = self.owner
        swap(mine.frames, self.frames)
        swap(mine.built_k, self.built_k)
        swap(mine.built_resets, self.built_resets)
        swap(mine.fills, self.fills)
        swap(mine.sets, self.sets)
        mine.built = self.built
        mine.used = self.stamp
        var found = -1
        for k in range(len(self.others)):
            if self.others[k].owner == owner:
                found = k
        var theirs = LayerCache()
        if found >= 0:
            swap(theirs, self.others[found])
            _ = self.others.pop(found)
        theirs.owner = owner
        swap(self.frames, theirs.frames)
        swap(self.built_k, theirs.built_k)
        swap(self.built_resets, theirs.built_resets)
        swap(self.fills, theirs.fills)
        swap(self.sets, theirs.sets)
        self.built = theirs.built
        self.owner = owner
        if mine.owner != 0:
            self.others.append(mine^)
        else:  # (owner 0 is no canvas in particular: never kept, its buffer sets reused)
            for st in mine.sets:
                self.free_sets.append(st)
        while len(self.others) >= CACHES:  # (the least recently drawn goes; its buffer sets are reused)
            var old = 0
            for k in range(len(self.others)):
                if self.others[k].used < self.others[old].used:
                    old = k
            for st in self.others[old].sets:
                self.free_sets.append(st)
            _ = self.others.pop(old)

    def start(mut self, es: Bool) -> Bool:
        """With the host's GL context current: programs, buffers, the atlas. False: gl.why says why."""
        if not self.gl.start(es):
            return False
        self.gl.upload_atlas(self.atlas)
        if self.gl.error() != 0:
            self.gl.ok = False
            self.gl.why = "the glyph atlas didn't upload"
            return False
        return True

    def _stamp(mut self, at: Int):
        """(diagnosis) a GPU timestamp query after layer `at`."""
        if self.qc == 0:
            self.qc = gl_proc("glQueryCounter")
        while len(self.ts_q) <= at:
            self.gl.out[0] = 0
            fcall[NoneType](self.gl.timer[0], c_int(1), self.gl.at(0))
            self.ts_q.append(self.gl.out[0] & 0xFFFFFFFF)
        fcall[NoneType](self.qc, c_uint(self.ts_q[at]), c_uint(0x8E28))  # GL_TIMESTAMP

    def _stamps(mut self, scene: Scene, n: Int):
        """(diagnosis) each layer's GPU time this frame (waits for the GPU)."""
        self.ts_frames += 1
        var line = String("LAYERTIMES:")
        self.gl.out[0] = 0
        fcall[NoneType](self.gl.timer[3], c_uint(self.ts_q[PASS_PRE]), c_uint(0x8866), self.gl.at(0))
        var pre = self.gl.out[0]
        self.gl.out[0] = 0
        fcall[NoneType](self.gl.timer[3], c_uint(self.ts_q[0]), c_uint(0x8866), self.gl.at(0))
        line += " tiles=" + String(Float64(self.gl.out[0] - pre) / 1e6)
        var prev = 0
        for i in range(n + 1):
            self.gl.out[0] = 0
            fcall[NoneType](self.gl.timer[3], c_uint(self.ts_q[i]), c_uint(0x8866), self.gl.at(0))
            var t = self.gl.out[0]
            if i > 0:
                line += " " + scene.layer_keys[i - 1] + "=" + String(Float64(t - prev) / 1e6)
            prev = t
        self.gl.out[0] = 0
        fcall[NoneType](self.gl.timer[3], c_uint(self.ts_q[PASS_END]), c_uint(0x8866), self.gl.at(0))
        line += " end=" + String(Float64(self.gl.out[0] - prev) / 1e6) + " total=" + String(Float64(self.gl.out[0] - pre) / 1e6)
        print(line, flush=True)

    def _raster_plan(mut self, scene: Scene, mut plan: TilePlan) -> Bool:
        """plan's tiles: every tile's batches built (content px at its zoom), the glyph pages uploaded once, then each
        tile rastered (D-7940). A glyph-page reset while building builds them all again on the fresh pages."""
        var n = len(plan.rasters)
        if n == 0:
            return True
        if self.tile_set < 0:
            if len(self.free_sets) > 0:
                self.tile_set = self.free_sets.pop()
            else:
                self.tile_set = self.next_set
                self.next_set += 1
        while len(self.tile_frames) < n:
            self.tile_frames.append(Frame2D())
        var pg = glyph_pages(self.atlas.width)
        var c0 = perf_counter_ns()
        for attempt in range(2):
            var r0 = pg[].resets
            for r in range(n):
                ref tr = plan.rasters[r]
                self.t_ops += len(tr.ops)
                fill_layers(self.tile_frames[r], scene, self.atlas, self.font, tr.layer, tr.layer + 1, 0, tr.ops, tr.k)
            if pg[].resets == r0:
                break
            if attempt == 1:
                print("GLYPHPAGES: one frame's tiles need more glyphs than the pages hold (" + String(DYN_ROWS) + " rows)", flush=True)
        var c1 = perf_counter_ns()
        self.t_fill += Int(c1 - c0)
        self.gl.sync_pages()
        for r in range(n):
            ref tr = plan.rasters[r]
            var m0 = perf_counter_ns()
            if self.tile_merge:  # (as a changed layer: runs regrouped, the same pixels, fewer draws)
                merge_runs(self.tile_frames[r], self.scratch)
                swap(self.scratch, self.tile_frames[r])
            var m1 = perf_counter_ns()
            self.t_merge += Int(m1 - m0)
            if not self.gl.raster_tile(self.tile_frames[r], self.tile_set, tr.slot, Float64(-tr.i * TILE + 1), Float64(-tr.j * TILE + 1), tr.rx0, tr.ry0, tr.rx1, tr.ry1):
                return False
            self.t_raster += Int(perf_counter_ns() - m1)
        return True

    def _prewarm(mut self, w: Int, h: Int):
        """(D-7961) The unpack buffer and a w × h window's worth of tile textures made now (once), not in the first
        restore's frame."""
        self.prewarmed = True
        var t0 = perf_counter_ns()
        var nx = w // TILE + 2
        var ny = h // TILE + 2
        var bytes = (w + 2 * TILE_TEX) * (h + 2 * TILE_TEX) * 4
        var a = self.gl.unpack_map(bytes)
        if a != 0:
            _ = self.gl.unpack_unmap()
            self.gl.unpack_done()
        for q in range(nx * ny):  # (made and written once: the driver gives a texture its memory at the first write)
            _ = self.gl.upload_tile_unpacked(q, 0, 0, 0, 0, 0, True)
        self.gl.unpack_done()
        if self.tiles.snap_log:
            print("SNAP: prewarmed " + String(nx * ny) + " tile textures and " + String(bytes // 1048576) + " MB in " + String(Float64(Int(perf_counter_ns() - t0)) / 1e6) + " ms", flush=True)

    def _snap_restore(mut self, scene: Scene, i: Int, owner: Int, w: Int, h: Int, path: String):
        """(D-7956) Tiled layer i's snapshot from path, when every part of its key matches: its tiles uploaded as the
        layer's fallback tiling (mojoui.viewsnap, gpu2d_tiles.Tiles.snap_restored)."""
        var t0 = perf_counter_ns()
        var snap = snap_take(path)
        var tr = perf_counter_ns()
        if not snap.ok:
            if self.tiles.snap_log:
                print("SNAP: none at " + path, flush=True)
            return
        var want = self.tiles.snap_key(scene, i, w, h)
        if not snap.key.same(want):
            if self.tiles.snap_log:
                print("SNAP: refused (" + snap.key.why_not(want) + " differs) " + path, flush=True)
            return
        # every tile's pixels decoded at once (a piece of the tiles per core) straight into a mapped pixel-unpack
        # buffer, then each uploaded from its offset there: the copies are the GPU's, this thread only issues them
        var keys = List[Int]()
        var slots = List[Int]()
        var at = List[Int]()  # per tile kept: its RLE in the file, its bytes, its pixel count, its offset in the buffer
        var nb = List[Int]()
        var npx = List[Int]()
        var off = List[Int]()
        var which = List[Int]()
        var total = 0
        for q in range(len(snap.tiles)):
            ref t = snap.tiles[q]
            if t.w == 0 or t.h == 0:
                continue
            if t.x0 < 0 or t.y0 < 0 or t.x0 + t.w > TILE_TEX or t.y0 + t.h > TILE_TEX:
                if self.tiles.snap_log:
                    print("SNAP: refused (a tile outside its texture) " + path, flush=True)
                return
            at.append(t.at)
            nb.append(t.n)
            npx.append(t.w * t.h)
            off.append(total)
            which.append(q)
            total += 4 * t.w * t.h
        for _ in range(len(which)):
            var slot = self.tiles.snap_slot(scene, i, owner)
            if slot < 0:
                for sl in slots:
                    self.tiles.free.append(sl)
                return
            slots.append(slot)
        var t1 = perf_counter_ns()
        var dec_ns = 0
        var count = len(which)
        var m0 = perf_counter_ns()
        var base = self.gl.unpack_map(total)
        var map_ns = Int(perf_counter_ns() - m0)
        var mapped = base != 0
        var px = List[UInt8]()
        if not mapped:  # (no mapping: decoded into memory here, uploaded from it)
            px = List[UInt8](unsafe_uninit_length=max(total, 4))
            base = Int(px.unsafe_ptr())
        var good = List[Bool](length=max(count, 1), fill=False)
        var src = Int(snap.bytes.unsafe_ptr())
        var ap = Int(at.unsafe_ptr())
        var bp = Int(nb.unsafe_ptr())
        var pp = Int(npx.unsafe_ptr())
        var op = Int(off.unsafe_ptr())
        var gp = Int(good.unsafe_ptr())

        def work(k: Int) {imm}:
            var a_ = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=ap)
            var b_ = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=bp)
            var p_ = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=pp)
            var o_ = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=op)
            var g_ = Pointer[Bool, MutUntrackedOrigin](unsafe_from_address=gp)
            g_.unsafe_offset(k)[] = rle_decode(src + a_.unsafe_offset(k)[], b_.unsafe_offset(k)[], base + o_.unsafe_offset(k)[], p_.unsafe_offset(k)[])

        var d0 = perf_counter_ns()
        if count > 0:
            parallelize(work, count, min(count, num_logical_cores()))
        dec_ns = Int(perf_counter_ns() - d0)
        _ = len(at)
        _ = len(nb)
        _ = len(npx)
        _ = len(px)
        var all_good = True
        for k in range(count):
            all_good = all_good and good[k]
        if mapped and not self.gl.unpack_unmap():
            all_good = False
        if not all_good:
            if mapped:
                self.gl.unpack_done()
            if self.tiles.snap_log:
                print("SNAP: refused (a tile doesn't decode) " + path, flush=True)
            for sl in slots:
                self.tiles.free.append(sl)
            return
        var u0 = perf_counter_ns()
        for k in range(count):
            ref t = snap.tiles[which[k]]
            var covers = t.x0 == 0 and t.y0 == 0 and t.w == TILE_TEX and t.h == TILE_TEX
            var ok = self.gl.upload_tile_unpacked(slots[k], t.x0, t.y0, t.w, t.h, off[k], not covers) if mapped else self.gl.upload_tile_part(slots[k], t.x0, t.y0, t.w, t.h, base + off[k])
            if not ok:
                if mapped:
                    self.gl.unpack_done()
                for sl in slots:
                    self.tiles.free.append(sl)
                return
            keys.append(_pack(t.i, t.j))
        if mapped:
            self.gl.unpack_done()
        if self.gl.error() != 0:
            for sl in slots:
                self.tiles.free.append(sl)
            return
        var up_ns = Int(perf_counter_ns() - u0)
        _ = len(snap.bytes)
        var e0 = perf_counter_ns()
        var parts = List[Int]()
        for k in range(count):
            ref t = snap.tiles[which[k]]
            parts += [t.x0, t.y0, t.w, t.h]
        self.tiles.snap_restored(scene, i, owner, w, h, keys, slots, parts)
        if self.tiles.snap_log:
            print("SNAP: restore took " + String(Float64(Int(perf_counter_ns() - t0)) / 1e6) + " ms (read " + String(Float64(Int(tr - t0)) / 1e6)
                  + ", slots " + String(Float64(Int(t1 - tr)) / 1e6) + ", map " + String(Float64(map_ns) / 1e6) + ", decode " + String(Float64(dec_ns) / 1e6) + ", restored " + String(Float64(Int(perf_counter_ns() - e0)) / 1e6) + ", upload " + String(Float64(up_ns) / 1e6) + (" from a mapped buffer" if mapped else "")
                  + ", " + String(len(snap.bytes)) + " bytes)", flush=True)

    def draw(mut self, scene: Scene, prev: Scene, owner: Int, w: Int, h: Int) -> Int:
        """The scene into a free ring texture of w × h, fenced: its slot, or -1 (every texture still held, or GL
        failed: gl.ok then False and gl.why says why). `prev` is the scene this canvas (`owner`) drew last, when the
        last draw here was its (else every layer is built)."""
        var slot = self.gl.acquire(w, h)
        if slot < 0:
            return -1
        var t0 = perf_counter_ns()
        self.stamp += 1
        if self.gl.counting:
            self.gl.counts_reset()
        self._switch(owner)
        if not self.prewarmed and self.stamp >= 2 and self.tiles_on and snapshots_expected():
            self._prewarm(w, h)
        var n = scene.layers()
        while len(self.frames) < n:
            self.frames.append(Frame2D())
            self.built_k.append(1.0)
            self.built_resets.append(-1)
            self.fills.append(0)
        while len(self.sets) < n:  # (this canvas's own GL buffers for each layer)
            if len(self.free_sets) > 0:
                self.sets.append(self.free_sets.pop())
            else:
                self.sets.append(self.next_set)
                self.next_set += 1
        var cached = owner == self.owner and self.built > 0 and prev.w == scene.w and prev.h == scene.h and prev.k == scene.k
        var dirty = List[Bool](length=n, fill=True)
        var grew = List[Int](length=n, fill=-1)  # a layer that only grew: the first run added (its upload starts there)
        var open = 0  # clips left open by earlier layers
        self.rebuilt = 0
        self.reused = 0
        self.grown = 0
        self.runs_built = 0
        self.runs_merged = 0
        var pg = glyph_pages(self.atlas.width)
        var resets0 = pg[].resets
        var tiled = List[Bool](length=n, fill=False)  # (D-7940) layers drawn from kept raster tiles this frame
        self.tiles.begin_frame()
        self.more = False
        for i in range(n):
            var span = scene.layer_range(i)
            var tr = layer_traits(scene, i, open)  # (D-7930: shared with the Metal renderer)
            open = tr.open
            if scene.layer_tiled[i] and tr.fixed and self.tiles_on and owner != 0 and (span[1] - span[0] >= TILE_MIN_OPS or scene.layer_hold[i]
                                                                                    or self.tiles.has_snap(scene.layer_keys[i], owner)):
                tiled[i] = True
                dirty[i] = False
                self.fills[i] = 0
                self.built_resets[i] = -1  # (its frames[i] isn't kept: if it stops being tiled, it is built again)
                self.frames[i].clear()
                continue
            var fixed = tr.fixed
            var zoom_bound = tr.zoom_bound
            # a layer whose glyphs were placed before GlyphPages last filled and started again points at slots other glyphs
            # now hold: it is never kept or grown, it is built again
            var stale = tr.runs and i < len(self.built_resets) and self.built_resets[i] != pg[].resets
            var keep = cached and i < self.built and i < prev.layers() and scene.same_layer(i, prev, i) and not stale
            if keep and len(self.frames[i].layers) == 1:
                var same_place = (scene.layer_tx[i] == prev.layer_tx[i] and scene.layer_ty[i] == prev.layer_ty[i]
                                  and scene.layer_tk[i] == prev.layer_tk[i])
                var has_images = len(self.frames[i].images) > 0
                var near = scene.layer_tk[i] >= self.built_k[i] * 0.25
                var zoom_ok = not zoom_bound or scene.layer_tk[i] == self.built_k[i]
                if (same_place or (fixed and near and zoom_ok)) and not has_images:
                    self.frames[i].layers[0].dx = scene.layer_tx[i]
                    self.frames[i].layers[0].dy = scene.layer_ty[i]
                    self.frames[i].layers[0].k = scene.layer_tk[i]
                    dirty[i] = False
            if dirty[i] and not stale and cached and i < self.built and i < prev.layers() and len(self.frames[i].layers) == 1 and self.gl.multi_draw != 0:
                # a layer that only grew (a finished stroke joining the page), in the same place: its new ops alone,
                # added after what's kept (and uploaded after it), unless the layer has collected many such runs
                var same_place = (scene.layer_tx[i] == prev.layer_tx[i] and scene.layer_ty[i] == prev.layer_ty[i]
                                  and scene.layer_tk[i] == prev.layer_tk[i] and Float64(self.frames[i].layers[0].dx) == scene.layer_tx[i]
                                  and Float64(self.frames[i].layers[0].dy) == scene.layer_ty[i] and Float64(self.frames[i].layers[0].k) == scene.layer_tk[i])
                if same_place and len(self.frames[i].runs) < 96 and len(self.frames[i].images) == 0:
                    var shared = scene.appends(i, prev, i)
                    if shared >= 0:
                        fill_layers(self.scratch, scene, self.atlas, self.font, i, i + 1, shared)
                        var r = append_frame(self.frames[i], self.scratch)
                        if r >= 0:
                            grew[i] = r
                            self.frames[i].layers[0].key = scene.layer_keys[i].copy()
                            self.frames[i].layers[0].version = scene.layer_versions[i]
                            self.grown += 1
                            self.runs_built += len(self.scratch.runs)
                            self.runs_merged += len(self.scratch.runs)
                            continue
            if dirty[i]:
                if self.merge:  # (built into scratch, regrouped into the layer's frame: fewer draws, same pixels)
                    fill_layers(self.scratch, scene, self.atlas, self.font, i, i + 1)
                    self.runs_built += len(self.scratch.runs)
                    merge_runs(self.scratch, self.frames[i])
                else:
                    fill_layers(self.frames[i], scene, self.atlas, self.font, i, i + 1)
                    self.runs_built += len(self.frames[i].runs)
                self.runs_merged += len(self.frames[i].runs)
                self.built_k[i] = scene.layer_tk[i]
                self.built_resets[i] = pg[].resets
                self.rebuilt += 1
            else:
                self.reused += 1
        if pg[].resets != resets0:
            # GlyphPages filled while this frame was being built and started again: every layer with glyphs placed
            # before that (built earlier this frame, or kept) is built once more on the fresh pages (D-7930)
            var resets1 = pg[].resets
            for i in range(n):
                if not tiled[i] and self.built_resets[i] != resets1 and layer_traits(scene, i, 0).runs:
                    fill_layers(self.frames[i], scene, self.atlas, self.font, i, i + 1)
                    self.built_k[i] = scene.layer_tk[i]
                    self.built_resets[i] = resets1
                    dirty[i] = True
                    grew[i] = -1
                    self.rebuilt += 1
            if pg[].resets != resets1:
                print("GLYPHPAGES: one frame needs more glyphs than the pages hold (" + String(DYN_ROWS) + " rows)", flush=True)
        var full = False
        var see_through = False
        for i in range(n):
            if dirty[i] and not tiled[i]:  # (rebuilt or grown: what its replacing runs do, again)
                self.fills[i] = _fills(self.frames[i])
            full = full or self.fills[i] == 1
            see_through = see_through or self.fills[i] < 0
        self.opaque = full and not see_through
        self.owner = owner
        self.built = n
        var t1 = perf_counter_ns()
        # (D-7940) tiled layers: the tiles to rasterize (their batches built first, then the glyph pages uploaded once,
        # then each rastered), and what to draw where
        var tile_draws = List[List[TileDraw]]()
        for i in range(n):
            tile_draws.append(List[TileDraw]())
        var tt0 = perf_counter_ns()
        if self.layer_times:
            self._stamp(PASS_PRE)
        self.t_plan = 0
        self.t_fill = 0
        self.t_merge = 0
        self.t_raster = 0
        self.t_ops = 0
        for i in range(n):
            if not tiled[i]:
                continue
            var p0 = perf_counter_ns()
            var want = self.tiles.restore_want(scene, i, owner, w, h)
            if want != "":
                self._snap_restore(scene, i, owner, w, h, want)
            var plan = self.tiles.plan(scene, i, owner, w, h)
            self.t_plan += Int(perf_counter_ns() - p0)
            if not self._raster_plan(scene, plan):
                self.gl.ok = False
                self.built = 0
                return -1
            for rd in plan.reads:  # (D-7956: the settled view's tiles read back for its snapshot, one a frame)
                if rd.w > 0 and rd.h > 0:
                    var px = List[UInt32](length=rd.w * rd.h, fill=0)
                    if self.gl.read_tile_part(rd.slot, rd.x0, rd.y0, rd.w, rd.h, Int(px.unsafe_ptr())):
                        self.tiles.save_add(rd, Int(px.unsafe_ptr()))
                    _ = len(px)
                else:
                    self.tiles.save_add(rd, 0)
            tile_draws[i] = plan.draws.copy()
        self.more = self.tiles.more
        self.tile_ns = Int(perf_counter_ns() - tt0)
        if self.tile_trace and (self.tiles.rastered > 0 or self.tiles.damaged > 0):
            print("TILES: rastered " + String(self.tiles.rastered) + " damaged " + String(self.tiles.damaged) + " drawn " + String(self.tiles.drawn)
                  + " more " + String(self.more) + " tile_ms " + String(Float64(self.tile_ns) / 1e6) + " (plan " + String(Float64(self.t_plan) / 1e6)
                  + " fill " + String(Float64(self.t_fill) / 1e6) + " merge " + String(Float64(self.t_merge) / 1e6) + " raster " + String(Float64(self.t_raster) / 1e6)
                  + " ops " + String(self.t_ops) + ")" + " batch_ms " + String(Float64(t1 - t0) / 1e6), flush=True)
        var tq0 = perf_counter_ns()
        self.gl.sync_pages()
        var tq1 = perf_counter_ns()
        if not self.gl.begin(self.gl.tex[slot], w, h):
            self.gl.ok = False
            self.built = 0
            return -1
        if self.layer_times:
            self._stamp(0)
        for i in range(n):
            if tiled[i]:
                var kt = self.gl.kind_mark()
                self.gl.draw_tiles(tile_draws[i])
                self.gl.kind_end(kt, KIND_TILES)
            else:
                self.gl.layer(self.frames[i], self.sets[i], dirty[i], grew[i])
            if self.layer_times:
                self._stamp(i + 1)
        var tq2 = perf_counter_ns()
        if not self.gl.end(self.gl.tex[slot], w, h):
            self.gl.ok = False
            self.built = 0
            return -1
        if self.layer_times:
            self._stamp(PASS_END)
            self._stamps(scene, n)
        _ = self.gl.fence(slot)
        if self.gl.kinds_on:
            print(self.gl.kinds_line() + " · tiles rastered " + String(self.tiles.rastered), flush=True)
        if self.gl.counting:
            print("GLCOUNT: " + self.gl.counts_line() + " · tiles rastered " + String(self.tiles.rastered) + " layers rebuilt " + String(self.rebuilt)
                  + " cpu " + String(Float64(Int(perf_counter_ns() - t0)) / 1e6) + " ms", flush=True)
        if self.tile_trace:
            print("G2DPARTS: pages " + String(Float64(tq1 - tq0) / 1e6) + " layers " + String(Float64(tq2 - tq1) / 1e6) + " end " + String(Float64(perf_counter_ns() - tq2) / 1e6), flush=True)
        self.batch_ns = Int(t1 - t0)
        self.render_ns = Int(perf_counter_ns() - t1)
        if self.tile_trace:
            print("G2D: batch " + String(Float64(self.batch_ns) / 1e6) + " tiles " + String(Float64(self.tile_ns) / 1e6) + " render+tiles " + String(Float64(self.render_ns) / 1e6)
                  + " layers " + String(n) + " rebuilt " + String(self.rebuilt) + " draws " + String(self.gl.draws), flush=True)
        if getenv("MOJOUI_STARTUP_TRACE") != "" and self.traced < 3:
            self.traced += 1
            print("STARTUP: gpu2d frame: batches " + String(Float64(self.batch_ns) / 1e6) + " ms, render " + String(Float64(self.render_ns) / 1e6) + " ms", flush=True)
        return slot


comptime PASS_PRE = 60  # (diagnosis) timestamp slots: before the tile rasters, after the frame's end (resolve)
comptime PASS_END = 61


def gl_proc(name: String) -> Int:
    """An extension's entry point for the current context: EGL's eglGetProcAddress (GTK on Wayland, the headless
    context), else GLX's; 0 when neither knows it."""
    var n = name
    var egl = dl_open("libEGL.so.1")
    if egl != 0:
        var gpa = dl_sym(egl, "eglGetProcAddress")
        if gpa != 0:
            var p = fcall[Int](gpa, n.as_c_string_span())
            if p != 0:
                return p
    var glx = dl_open("libGLX.so.0")
    if glx != 0:
        var gpa = dl_sym(glx, "glXGetProcAddressARB")
        if gpa != 0:
            return fcall[Int](gpa, n.as_c_string_span())
    return 0


# ---------- a GL 3.3 core context with no window (tests, offscreen pictures) ----------


def headless_gl33() -> Int:
    """Makes a desktop GL 3.3 core context current with no window or display: EGL's device platform (the first GPU
    device whose display starts), surfaceless. Returns the EGL context (0: couldn't)."""
    var egl = dl_open("libEGL.so.1")
    if egl == 0:
        return 0
    var gpa = dl_sym(egl, "eglGetProcAddress")
    var n1 = String("eglQueryDevicesEXT")
    var query = fcall[Int](gpa, n1.as_c_string_span())
    var n3 = String("eglGetPlatformDisplayEXT")
    var platform = fcall[Int](gpa, n3.as_c_string_span())
    if query == 0 or platform == 0:
        return 0
    var devs = List[Int](length=16, fill=0)
    var out = List[Int](length=16, fill=0)
    if fcall[c_uint](query, c_int(16), Int(devs.unsafe_ptr()), Int(out.unsafe_ptr())) == 0:
        return 0
    var ndev = Int(out[0] & 0xFFFFFFFF)
    var cfg_attrs: List[Int32] = [0x3033, 0x1, 0x3040, 0x8, 0x3038]  # SURFACE_TYPE PBUFFER, RENDERABLE_TYPE OPENGL_BIT, NONE
    var ctx_attrs: List[Int32] = [0x3098, 3, 0x30FB, 3, 0x30FD, 1, 0x3038]  # MAJOR 3, MINOR 3, PROFILE_MASK CORE
    for i in range(ndev):
        var dpy = fcall[Int](platform, c_uint(0x313F), devs[i], 0)  # EGL_PLATFORM_DEVICE_EXT
        if dpy == 0 or fcall[c_uint](dl_sym(egl, "eglInitialize"), dpy, Int(out.unsafe_ptr()) + 16, Int(out.unsafe_ptr()) + 24) == 0:
            continue
        if fcall[c_uint](dl_sym(egl, "eglBindAPI"), c_uint(0x30A2)) == 0:  # EGL_OPENGL_API
            continue
        out[5] = 0
        if fcall[c_uint](dl_sym(egl, "eglChooseConfig"), dpy, Int(cfg_attrs.unsafe_ptr()), Int(out.unsafe_ptr()) + 32, c_int(1), Int(out.unsafe_ptr()) + 40) == 0 or (out[5] & 0xFFFFFFFF) == 0:
            continue
        var ctx = fcall[Int](dl_sym(egl, "eglCreateContext"), dpy, out[4], 0, Int(ctx_attrs.unsafe_ptr()))
        if ctx == 0:
            continue
        if fcall[c_uint](dl_sym(egl, "eglMakeCurrent"), dpy, 0, 0, ctx) == 0:
            continue
        _ = len(devs)
        _ = len(out)
        _ = len(cfg_attrs)
        _ = len(ctx_attrs)
        return ctx
    return 0
