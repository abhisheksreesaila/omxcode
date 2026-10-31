# Pictures that stay on the GPU (goal 36b): a GPU Canvas's picture goes to the screen without a copy to the CPU.
#
# The seam: a host that can show a GPU texture owns one Presenter and makes its GL context current around a canvas's
# draw(); GPU drawing code (mojoui.gpu: PointCloud.splat/shade/paint) then either
#   - leaves its RGBA picture in CUDA memory (surface.gpu_address): the host copies it GPU→GPU into a GL texture
#     (copy_in, CUDA↔GL interop) and shows that texture, or
#   - draws straight into a GL texture with the GPU's fixed-function blending (begin_vertices/draw_vertices: points or
#     lines, additive or "over"), from vertices a Mojo kernel wrote (surface.gpu_slot).
# Ordering (D-745, D-746): copies and maps go on CUDA's legacy default stream (0); Mojo's DeviceContext stream is a
# blocking stream, so work on either waits for what was queued on the other before it (probed: a stream-0 copy waited
# 2.7 ms for a Mojo kernel). A copied texture stays mapped for CUDA until settle() sees its copy finished; the host
# shows it a frame later (one frame in flight), so the CPU queues the next frame while the GPU finishes this one.
# Today this is CUDA + OpenGL (NVIDIA on Linux, GTK's GL renderer). A Metal host (Mac) or a Vulkan/OpenCL-class phone
# GPU would implement the same five calls (acquire, copy_in, begin_vertices, draw_vertices, release through the
# busy flags) on its own textures; nothing above this file names CUDA or GL. Not built yet: only this one exists.
#
# Everything here is looked up at run time (dlopen/dlsym): a machine without libcuda or GL just reports why and the
# canvas falls back to the copy (the picture read back into the surface's CPU memory), as before.

from std.ffi import external_call, c_int, c_uint, c_char
from std.memory import Pointer
from std.time import perf_counter_ns
from std.os import getenv

comptime SLOTS = 6  # textures in the ring: one on screen, one being drawn, the rest waiting for GTK to let go
comptime VERTEX_BYTES = 12  # a painted vertex: Int32 pixel index (-1: none), then r, g, b, a as float16

comptime GL_TEXTURE_2D = 0x0DE1
comptime GL_RENDERER = 0x1F01
comptime GL_RGBA8 = 0x8058
comptime GL_RGBA16F = 0x881A
comptime GL_TEXTURE_MIN_FILTER = 0x2801
comptime GL_TEXTURE_MAG_FILTER = 0x2800
comptime GL_NEAREST = 0x2600
comptime GL_LINEAR = 0x2601
comptime GL_FRAMEBUFFER = 0x8D40
comptime GL_COLOR_ATTACHMENT0 = 0x8CE0
comptime GL_FRAMEBUFFER_COMPLETE = 0x8CD5
comptime GL_ARRAY_BUFFER = 0x8892
comptime GL_DYNAMIC_DRAW = 0x88E8
comptime GL_INT = 0x1404
comptime GL_HALF_FLOAT = 0x140B
comptime GL_POINTS = 0
comptime GL_LINES = 1
comptime GL_TRIANGLES = 4
comptime GL_BLEND = 0x0BE2
comptime GL_ONE = 1
comptime GL_SRC_ALPHA = 0x0302
comptime GL_ONE_MINUS_SRC_ALPHA = 0x0303
comptime GL_COLOR_BUFFER_BIT = 0x4000
comptime GL_VERTEX_SHADER = 0x8B31
comptime GL_FRAGMENT_SHADER = 0x8B30
comptime GL_COMPILE_STATUS = 0x8B81
comptime GL_LINK_STATUS = 0x8B82
comptime GL_TEXTURE0 = 0x84C0
comptime GL_RGBA = 0x1908
comptime GL_UNSIGNED_BYTE = 0x1401
comptime GL_PACK_ALIGNMENT = 0x0D05
comptime CU_GL_DEVICE_LIST_ALL = 1
comptime CU_REGISTER_WRITE_DISCARD = 2
comptime CU_MEMORYTYPE_DEVICE = 2
comptime CU_MEMORYTYPE_ARRAY = 3
comptime CU_MEMORYTYPE_HOST = 1


def fcall[T: RegisterPassable = Int, *A: AnyType](addr: Int, *args: *A) -> T:
    """Calls the C function at addr with this call's argument types."""
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr)
    var f = Pointer(to=raw).unsafe_bitcast[def(*a: *A) thin abi("C") -> T]()[]
    return f(*args)


def dl_open(name: String, flags: Int = 2) -> Int:
    """dlopen (flags: RTLD_NOW) called through its address: Mojo's own CPython loader declares dlopen with other types,
    and a program can't declare one C function twice (an app that uses Python and a GTK host failed to build, D-1265)."""
    var f = dl_sym(0, "dlopen")
    if f == 0:
        return 0
    var n = name
    var span = n.as_c_string_span()
    var r = fcall[Int](f, span.unsafe_ptr(), c_int(flags))
    _ = n^
    return r


def dl_sym(lib: Int, name: String) -> Int:
    var n = name
    return external_call["dlsym", Int](lib, n.as_c_string_span())


def c_text(addr: Int) -> String:
    if addr == 0:
        return String("")
    return String(unsafe_from_utf8_ptr=Pointer[c_char, MutUntrackedOrigin](unsafe_from_address=addr))


comptime POINTS_VS = """#version 300 es
layout(location = 0) in int at;
layout(location = 1) in vec4 colour;
uniform ivec2 size;
out vec4 v_colour;
void main() {
    gl_PointSize = 1.0;
    v_colour = colour;
    if (at < 0) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }
    vec2 p = (vec2(float(at % size.x), float(at / size.x)) + 0.5) / vec2(size) * 2.0 - 1.0;
    gl_Position = vec4(p, 0.0, 1.0);
}
"""

comptime POINTS_FS = """#version 300 es
precision highp float;
in vec4 v_colour;
out vec4 o;
void main() { o = v_colour; }
"""

comptime RESOLVE_VS = """#version 300 es
void main() {
    gl_Position = vec4(float((gl_VertexID & 1) * 4 - 1), float((gl_VertexID >> 1) * 4 - 1), 0.0, 1.0);
}
"""

# The added light → a pixel, as mojoui.gpu's resolve does it: light is in 1024ths (exact in float16 below 2.0),
# clamped at one, then (q * 255) / 1024 in whole numbers, so the blended picture equals the compute splat's.
comptime RESOLVE_FS = """#version 300 es
precision highp float;
precision highp int;
uniform highp sampler2D accum;
out vec4 o;
void main() {
    vec3 s = min(texelFetch(accum, ivec2(gl_FragCoord.xy), 0).rgb, vec3(1.0));
    ivec3 q = ivec3(s * 1024.0 + 0.5);
    o = vec4(vec3((q * 255) / 1024) / 255.0, 1.0);
}
"""


struct Presenter(Movable):
    """CUDA ↔ GL for one GL context (the host's, current while it calls in). ok: pictures can go GPU→GPU."""

    var ok: Bool
    var why: String  # why not (when ok is False), or what it found
    var device: Int  # the CUDA device of the GL context's GPU
    var renderer: String  # GL_RENDERER
    var cuda: Int
    var gl: Int
    var cu_ctx: Int
    var tex: List[Int]  # the ring's GL textures (0: not made yet)
    var res: List[Int]  # their CUDA registrations (0: not registered yet: only copy_in needs one)
    var tw: List[Int]
    var th: List[Int]
    var busy: List[Int]  # 1 while the host shows the texture; the host's release callback writes 0 (fixed length: stable address)
    var done: List[Int]  # a CUDA event per slot, recorded after the work that fills it (fence)
    var gl_done: List[Int]  # a GL sync object per slot when the painter filled it (fence), else 0
    var mapped: List[Int]  # 1: the slot's texture is still mapped for CUDA (its copy may still be running)
    var out: List[Int]  # scratch out-parameters for C (kept alive past each call)
    var copies: Int
    var copy_ns: Int
    var painted: Int
    var paint_ns: Int
    var full: Int  # times every slot was busy (the caller falls back to the copy for that frame)
    # the painter (hardware blending)
    var blend_ok: Bool
    var blend_why: String
    var prog_points: Int
    var prog_resolve: Int
    var loc_size: Int
    var loc_accum: Int
    var vao: Int
    var vbo: Int
    var vbo_res: Int
    var vbo_bytes: Int
    var accum: Int
    var aw: Int
    var ah: Int
    var fbo_accum: Int
    var fbo_out: Int
    var vbo_mapped: Bool

    def __init__(out self):
        self.ok = False
        self.why = "not started"
        self.device = -1
        self.renderer = ""
        self.cuda = 0
        self.gl = 0
        self.cu_ctx = 0
        self.tex = List[Int](length=SLOTS, fill=0)
        self.res = List[Int](length=SLOTS, fill=0)
        self.tw = List[Int](length=SLOTS, fill=0)
        self.th = List[Int](length=SLOTS, fill=0)
        self.busy = List[Int](length=SLOTS, fill=0)
        self.done = List[Int](length=SLOTS, fill=0)
        self.gl_done = List[Int](length=SLOTS, fill=0)
        self.mapped = List[Int](length=SLOTS, fill=0)
        self.out = List[Int](length=64, fill=0)
        self.copies = 0
        self.copy_ns = 0
        self.painted = 0
        self.paint_ns = 0
        self.full = 0
        self.blend_ok = False
        self.blend_why = "not started"
        self.prog_points = 0
        self.prog_resolve = 0
        self.loc_size = -1
        self.loc_accum = -1
        self.vao = 0
        self.vbo = 0
        self.vbo_res = 0
        self.vbo_bytes = 0
        self.accum = 0
        self.aw = 0
        self.ah = 0
        self.fbo_accum = 0
        self.fbo_out = 0
        self.vbo_mapped = False

    # ---------- C ----------

    def cu(self, name: String) -> Int:
        return dl_sym(self.cuda, name)

    def g(self, name: String) -> Int:
        return dl_sym(self.gl, name)

    def at(self, k: Int) -> Int:
        """The address of scratch out-parameter k (8 bytes each)."""
        return Int(self.out.unsafe_ptr()) + 8 * k

    def cu_error(self, r: Int32) -> String:
        _ = fcall[Int32](self.cu("cuGetErrorName"), r, self.at(63))
        return c_text(self.out[63]) + " (" + String(Int(r)) + ")"

    def push(self):
        _ = fcall[Int32](self.cu("cuCtxPushCurrent_v2"), self.cu_ctx)

    def pop(self):
        _ = fcall[Int32](self.cu("cuCtxPopCurrent_v2"), self.at(62))

    # ---------- starting ----------

    def start(mut self) -> Bool:
        """With the host's GL context current: finds its GPU's CUDA device and that device's context (the one Mojo's
        DeviceContext uses: the primary context). Sets ok/why."""
        if getenv("MOJOUI_CANVAS_GPU") == "0":
            self.why = "turned off (MOJOUI_CANVAS_GPU=0)"
            return False
        self.cuda = dl_open("libcuda.so.1")
        if self.cuda == 0:
            self.why = "no CUDA driver (libcuda.so.1)"
            return False
        self.gl = dl_open("libOpenGL.so.0")
        if self.gl == 0:
            self.gl = dl_open("libGL.so.1")
        if self.gl == 0:
            self.why = "no OpenGL library (libOpenGL.so.0)"
            return False
        var r = fcall[Int32](self.cu("cuInit"), c_uint(0))
        if r != 0:
            self.why = "cuInit failed: " + self.cu_error(r)
            return False
        self.renderer = c_text(fcall[Int](self.g("glGetString"), c_uint(GL_RENDERER)))
        self.out[0] = 0
        r = fcall[Int32](self.cu("cuGLGetDevices_v2"), self.at(0), self.at(1), c_uint(4), c_int(CU_GL_DEVICE_LIST_ALL))
        var count = self.out[0] & 0xFFFFFFFF
        if r != 0 or count == 0:
            self.why = ("the GL context (" + self.renderer + ")" if self.renderer != "" else String("no GL context")) + " isn't on a CUDA GPU: " + (self.cu_error(r) if r != 0 else String("no devices"))
            return False
        self.device = self.out[1] & 0xFFFFFFFF
        r = fcall[Int32](self.cu("cuDevicePrimaryCtxRetain"), self.at(2), c_int(self.device))
        if r != 0:
            self.why = "no CUDA context on device " + String(self.device) + ": " + self.cu_error(r)
            return False
        self.cu_ctx = self.out[2]
        self.ok = True
        self.why = "CUDA device " + String(self.device) + " → GL texture on " + self.renderer
        self.blend_ok = getenv("MOJOUI_BLEND") != "0"
        self.blend_why = "GL fixed-function blending on " + self.renderer if self.blend_ok else String("turned off (MOJOUI_BLEND=0)")
        return True

    def give_up(mut self, why: String):
        """A call failed mid-run: say so once; every canvas uses the copy from now on. Nothing is left mapped."""
        print("mojoui: GPU pictures go back to the CPU copy (" + why + ")", flush=True)
        self.unmap_all()
        self.release_cuda()  # (GL textures the toolkit may still show stay until close())
        self.ok = False
        self.blend_ok = False
        self.why = why

    def give_up_blend(mut self, why: String):
        print("mojoui: hardware blending off, the compute splat instead (" + why + ")", flush=True)
        self.unmap_vbo()
        self.blend_ok = False
        self.blend_why = why

    def unmap_vbo(mut self):
        if self.vbo_mapped and self.vbo_res != 0:
            self.push()
            self.out[1] = self.vbo_res
            _ = fcall[Int32](self.cu("cuGraphicsUnmapResources"), c_uint(1), self.at(1), 0)
            self.pop()
        self.vbo_mapped = False

    def unmap_all(mut self):
        """Gives every texture and the vertex buffer back to GL (waiting for their CUDA work first)."""
        if self.cu_ctx == 0:
            return
        for i in range(SLOTS):
            if self.mapped[i] != 0:
                _ = self.settle(i)
        self.unmap_vbo()

    def mapped_count(self) -> Int:
        var n = 1 if self.vbo_mapped else 0
        for i in range(SLOTS):
            n += self.mapped[i]
        return n

    def release_cuda(mut self):
        """Unregisters every CUDA↔GL registration and destroys the events (after unmap_all)."""
        if self.cu_ctx == 0:
            return
        self.unmap_all()
        self.push()
        for i in range(SLOTS):
            if self.res[i] != 0:
                _ = fcall[Int32](self.cu("cuGraphicsUnregisterResource"), self.res[i])
                self.res[i] = 0
            if self.done[i] != 0:
                _ = fcall[Int32](self.cu("cuEventDestroy_v2"), self.done[i])
                self.done[i] = 0
        if self.vbo_res != 0:
            _ = fcall[Int32](self.cu("cuGraphicsUnregisterResource"), self.vbo_res)
            self.vbo_res = 0
            self.vbo_bytes = 0
        self.pop()

    def close(mut self):
        """Releases everything (the window is closing, or the GPU failed): CUDA registrations and events, then the GL
        textures, buffers, programs and sync objects (the GL context must be current for those; the host unrefs it).
        Safe to call twice; ok is False afterwards."""
        self.release_cuda()
        if self.gl != 0:
            for i in range(SLOTS):
                if self.gl_done[i] != 0:
                    fcall[NoneType](self.g("glDeleteSync"), self.gl_done[i])
                    self.gl_done[i] = 0
                if self.tex[i] != 0:
                    self.out[0] = self.tex[i]
                    fcall[NoneType](self.g("glDeleteTextures"), c_int(1), self.at(0))
                    self.tex[i] = 0
            for name in ["accum", "vbo", "vao", "fbo_accum", "fbo_out"]:
                var id = self.accum if name == "accum" else (self.vbo if name == "vbo" else (self.vao if name == "vao" else (self.fbo_accum if name == "fbo_accum" else self.fbo_out)))
                if id == 0:
                    continue
                self.out[0] = id
                var del_fn = "glDeleteTextures" if name == "accum" else ("glDeleteBuffers" if name == "vbo" else ("glDeleteVertexArrays" if name == "vao" else "glDeleteFramebuffers"))
                fcall[NoneType](self.g(del_fn), c_int(1), self.at(0))
            self.accum = 0
            self.vbo = 0
            self.vao = 0
            self.fbo_accum = 0
            self.fbo_out = 0
            self.vbo_bytes = 0
            self.aw = 0
            self.ah = 0
            for prog in [self.prog_points, self.prog_resolve]:
                if prog != 0:
                    fcall[NoneType](self.g("glDeleteProgram"), c_uint(prog))
            self.prog_points = 0
            self.prog_resolve = 0
        if self.cu_ctx != 0:
            var dev = self.device
            _ = fcall[Int32](self.cu("cuDevicePrimaryCtxRelease_v2"), c_int(dev))
            self.cu_ctx = 0
        self.ok = False
        self.blend_ok = False
        self.why = "closed"

    # ---------- the texture ring ----------

    def acquire(mut self, w: Int, h: Int) -> Int:
        """A texture of w × h the host isn't showing (made or remade as needed; the GL context must be current), or -1
        when all SLOTS are still held by the toolkit."""
        var pick = -1
        for i in range(SLOTS):
            if self.busy[i] == 0 and self.mapped[i] == 0 and self.tex[i] != 0 and self.tw[i] == w and self.th[i] == h:
                return i
            if pick < 0 and self.busy[i] == 0 and self.mapped[i] == 0:
                pick = i
        if pick < 0:
            self.full += 1
            return -1
        if self.tex[pick] != 0:
            if self.res[pick] != 0:
                _ = fcall[Int32](self.cu("cuGraphicsUnregisterResource"), self.res[pick])
                self.res[pick] = 0
            self.out[0] = self.tex[pick]
            fcall[NoneType](self.g("glDeleteTextures"), c_int(1), self.at(0))
            self.tex[pick] = 0
        self.out[0] = 0
        fcall[NoneType](self.g("glGenTextures"), c_int(1), self.at(0))
        var t = self.out[0] & 0xFFFFFFFF
        fcall[NoneType](self.g("glBindTexture"), c_uint(GL_TEXTURE_2D), c_uint(t))
        fcall[NoneType](self.g("glTexParameteri"), c_uint(GL_TEXTURE_2D), c_uint(GL_TEXTURE_MIN_FILTER), c_int(GL_LINEAR))
        fcall[NoneType](self.g("glTexParameteri"), c_uint(GL_TEXTURE_2D), c_uint(GL_TEXTURE_MAG_FILTER), c_int(GL_LINEAR))
        fcall[NoneType](self.g("glTexStorage2D"), c_uint(GL_TEXTURE_2D), c_int(1), c_uint(GL_RGBA8), c_int(w), c_int(h))
        fcall[NoneType](self.g("glBindTexture"), c_uint(GL_TEXTURE_2D), c_uint(0))
        self.tex[pick] = t
        self.tw[pick] = w
        self.th[pick] = h
        return pick

    def busy_flag(self, slot: Int) -> Int:
        """The address the host's release callback writes 0 to when the toolkit lets go of the slot's texture."""
        return Int(self.busy.unsafe_ptr()) + 8 * slot

    def copy_in(mut self, slot: Int, src: Int, w: Int, h: Int) -> Bool:
        """Copies a w × h RGBA picture (rows of w pixels) from CUDA memory into the slot's texture, GPU to GPU."""
        var t0 = perf_counter_ns()
        if self.res[slot] == 0:
            var r = fcall[Int32](self.cu("cuGraphicsGLRegisterImage"), self.at(0), c_uint(self.tex[slot]), c_uint(GL_TEXTURE_2D), c_uint(CU_REGISTER_WRITE_DISCARD))
            if r != 0:
                self.give_up("cuGraphicsGLRegisterImage: " + self.cu_error(r))
                return False
            self.res[slot] = self.out[0]
        self.push()
        self.out[1] = self.res[slot]
        var r = fcall[Int32](self.cu("cuGraphicsMapResources"), c_uint(1), self.at(1), 0)
        if r == 0:
            r = fcall[Int32](self.cu("cuGraphicsSubResourceGetMappedArray"), self.at(2), self.res[slot], c_uint(0), c_uint(0))
            if r == 0:
                # CUDA_MEMCPY2D: 16 eight-byte fields (the memory types are 4-byte enums in 8-byte slots), in order:
                #  0 srcXInBytes  1 srcY  2 srcMemoryType  3 srcHost  4 srcDevice  5 srcArray  6 srcPitch
                #  7 dstXInBytes  8 dstY  9 dstMemoryType 10 dstHost 11 dstDevice 12 dstArray 13 dstPitch
                # 14 WidthInBytes 15 Height. (A Metal port: a blit from the picture's MTLBuffer into the slot's texture.)
                for k in range(16):
                    self.out[8 + k] = 0
                self.out[8 + 2] = CU_MEMORYTYPE_DEVICE
                self.out[8 + 4] = src  # the picture, rows of w pixels with no gaps
                self.out[8 + 6] = w * 4
                self.out[8 + 9] = CU_MEMORYTYPE_ARRAY
                self.out[8 + 12] = self.out[2]  # the texture's CUDA array (mapped above)
                self.out[8 + 14] = w * 4
                self.out[8 + 15] = h
                r = fcall[Int32](self.cu("cuMemcpy2DAsync_v2"), self.at(8), 0)
            if r == 0 and self.done[slot] == 0:
                r = fcall[Int32](self.cu("cuEventCreate"), self.at(0), c_uint(2))  # CU_EVENT_DISABLE_TIMING
                if r == 0:
                    self.done[slot] = self.out[0]
            if r == 0:
                r = fcall[Int32](self.cu("cuEventRecord"), self.done[slot], 0)
            if r == 0:  # (left mapped, with an event after the copy: settle() unmaps once it's done, D-746)
                self.mapped[slot] = 1
            else:  # (any failure: never leave the texture mapped)
                self.out[1] = self.res[slot]
                _ = fcall[Int32](self.cu("cuGraphicsUnmapResources"), c_uint(1), self.at(1), 0)
        self.pop()
        if r != 0:
            self.give_up("CUDA → GL copy: " + self.cu_error(r))
            return False
        self.copies += 1
        self.copy_ns += Int(perf_counter_ns() - t0)
        return True

    def settle(mut self, slot: Int) -> Int:
        """Before the toolkit draws the slot's texture: a CUDA copy into it must have finished and the texture be given
        back to GL (unmapped); waits for that, spinning (by then it's usually over). GL touching a texture while CUDA
        work is queued before an unmap makes NVIDIA's driver stall ~4.7 ms (measured, D-746), so the unmap waits until
        the copy is done. Returns the GL sync object to hand GTK with a painter-filled texture (0: none)."""
        if self.mapped[slot] != 0:
            self.push()
            _ = fcall[Int32](self.cu("cuEventSynchronize"), self.done[slot])
            self.out[1] = self.res[slot]
            _ = fcall[Int32](self.cu("cuGraphicsUnmapResources"), c_uint(1), self.at(1), 0)
            self.pop()
            self.mapped[slot] = 0
        return self.gl_done[slot]

    def download(mut self, src: Int, dst: Int, bytes: Int) -> Bool:
        """A picture left in CUDA memory, copied into CPU memory (the fallback when it can't be shown from the GPU)."""
        if self.cu_ctx == 0:
            return False
        self.push()
        var r = fcall[Int32](self.cu("cuMemcpyDtoH_v2"), dst, src, bytes)
        self.pop()
        return r == 0

    # ---------- the painter: GPU fixed-function blending ----------

    def compile(mut self, vs: String, fs: String) -> Int:
        var prog = fcall[c_uint](self.g("glCreateProgram"))
        for kind in range(2):
            var src = vs if kind == 0 else fs
            var sh = fcall[c_uint](self.g("glCreateShader"), c_uint(GL_VERTEX_SHADER if kind == 0 else GL_FRAGMENT_SHADER))
            self.out[0] = Int(src.unsafe_ptr())
            self.out[1] = src.byte_length()
            fcall[NoneType](self.g("glShaderSource"), sh, c_int(1), self.at(0), self.at(1))
            _ = src.byte_length()
            fcall[NoneType](self.g("glCompileShader"), sh)
            self.out[2] = 0
            fcall[NoneType](self.g("glGetShaderiv"), sh, c_uint(GL_COMPILE_STATUS), self.at(2))
            if self.out[2] & 0xFFFFFFFF == 0:
                var log = List[UInt8](length=1024, fill=0)
                fcall[NoneType](self.g("glGetShaderInfoLog"), sh, c_int(1023), 0, Int(log.unsafe_ptr()))
                self.blend_why = "shader didn't compile: " + c_text(Int(log.unsafe_ptr()))
                _ = len(log)
                return 0
            fcall[NoneType](self.g("glAttachShader"), prog, sh)
            fcall[NoneType](self.g("glDeleteShader"), sh)
        fcall[NoneType](self.g("glLinkProgram"), prog)
        self.out[2] = 0
        fcall[NoneType](self.g("glGetProgramiv"), prog, c_uint(GL_LINK_STATUS), self.at(2))
        if self.out[2] & 0xFFFFFFFF == 0:
            self.blend_why = "shaders didn't link"
            return 0
        return Int(prog)

    def painter_ready(mut self) -> Bool:
        """Makes the painter's programs and vertex array once (GL context current)."""
        if not self.ok or not self.blend_ok:
            return False
        if self.prog_points != 0:
            return True
        var pp = self.compile(String(POINTS_VS), String(POINTS_FS))
        var pr = self.compile(String(RESOLVE_VS), String(RESOLVE_FS)) if pp != 0 else 0
        if pp == 0 or pr == 0:
            var why = self.blend_why.copy()
            self.give_up_blend(why)
            return False
        self.prog_points = pp
        self.prog_resolve = pr
        var n1 = String("size")
        self.loc_size = Int(fcall[c_int](self.g("glGetUniformLocation"), c_uint(pp), n1.as_c_string_span()))
        var n2 = String("accum")
        self.loc_accum = Int(fcall[c_int](self.g("glGetUniformLocation"), c_uint(pr), n2.as_c_string_span()))
        self.out[0] = 0
        fcall[NoneType](self.g("glGenVertexArrays"), c_int(1), self.at(0))
        self.vao = self.out[0] & 0xFFFFFFFF
        fcall[NoneType](self.g("glGenBuffers"), c_int(1), self.at(0))
        self.vbo = self.out[0] & 0xFFFFFFFF
        fcall[NoneType](self.g("glGenFramebuffers"), c_int(1), self.at(0))
        self.fbo_accum = self.out[0] & 0xFFFFFFFF
        fcall[NoneType](self.g("glGenFramebuffers"), c_int(1), self.at(0))
        self.fbo_out = self.out[0] & 0xFFFFFFFF
        fcall[NoneType](self.g("glBindVertexArray"), c_uint(self.vao))
        fcall[NoneType](self.g("glBindBuffer"), c_uint(GL_ARRAY_BUFFER), c_uint(self.vbo))
        fcall[NoneType](self.g("glEnableVertexAttribArray"), c_uint(0))
        fcall[NoneType](self.g("glEnableVertexAttribArray"), c_uint(1))
        fcall[NoneType](self.g("glBindVertexArray"), c_uint(0))
        return True

    def begin_vertices(mut self, n: Int) -> Int:
        """A CUDA pointer to room for n vertices (VERTEX_BYTES each) in the painter's GL vertex buffer, mapped for
        CUDA until draw_vertices(); 0 when the painter can't (the caller uses the compute path)."""
        if not self.painter_ready():
            return 0
        var need = max(n, 1) * VERTEX_BYTES
        if self.vbo_bytes < need:
            if self.vbo_res != 0:
                _ = fcall[Int32](self.cu("cuGraphicsUnregisterResource"), self.vbo_res)
                self.vbo_res = 0
            fcall[NoneType](self.g("glBindBuffer"), c_uint(GL_ARRAY_BUFFER), c_uint(self.vbo))
            fcall[NoneType](self.g("glBufferData"), c_uint(GL_ARRAY_BUFFER), need, 0, c_uint(GL_DYNAMIC_DRAW))
            fcall[NoneType](self.g("glBindVertexArray"), c_uint(self.vao))
            fcall[NoneType](self.g("glVertexAttribIPointer"), c_uint(0), c_int(1), c_uint(GL_INT), c_int(VERTEX_BYTES), 0)
            fcall[NoneType](self.g("glVertexAttribPointer"), c_uint(1), c_int(4), c_uint(GL_HALF_FLOAT), UInt8(0), c_int(VERTEX_BYTES), 4)
            fcall[NoneType](self.g("glBindVertexArray"), c_uint(0))
            fcall[NoneType](self.g("glBindBuffer"), c_uint(GL_ARRAY_BUFFER), c_uint(0))
            var r = fcall[Int32](self.cu("cuGraphicsGLRegisterBuffer"), self.at(0), c_uint(self.vbo), c_uint(CU_REGISTER_WRITE_DISCARD))
            if r != 0:
                self.give_up_blend("cuGraphicsGLRegisterBuffer: " + self.cu_error(r))
                return 0
            self.vbo_res = self.out[0]
            self.vbo_bytes = need
        self.push()
        self.out[1] = self.vbo_res
        var r = fcall[Int32](self.cu("cuGraphicsMapResources"), c_uint(1), self.at(1), 0)
        if r == 0:
            r = fcall[Int32](self.cu("cuGraphicsResourceGetMappedPointer_v2"), self.at(2), self.at(3), self.vbo_res)
            if r != 0:
                _ = fcall[Int32](self.cu("cuGraphicsUnmapResources"), c_uint(1), self.at(1), 0)
        self.pop()
        if r != 0:
            self.give_up_blend("mapping the vertex buffer: " + self.cu_error(r))
            return 0
        self.vbo_mapped = True
        return self.out[2]

    def draw_vertices(mut self, slot: Int, w: Int, h: Int, n: Int, lines: Bool, over: Bool, finish: Bool = False) -> Bool:
        """After the vertices are written (and the CUDA work that wrote them finished): blends them into a float
        picture (additive: ONE, ONE; over: SRC_ALPHA, ONE_MINUS_SRC_ALPHA, in vertex order), then resolves it into the
        slot's texture. GL context current."""
        var t0 = perf_counter_ns()
        if self.vbo_mapped:
            self.push()
            self.out[1] = self.vbo_res
            var r = fcall[Int32](self.cu("cuGraphicsUnmapResources"), c_uint(1), self.at(1), 0)
            self.pop()
            self.vbo_mapped = False
            if r != 0:
                self.give_up_blend("unmapping the vertex buffer: " + self.cu_error(r))
                return False
        if self.aw != w or self.ah != h:
            if self.accum != 0:
                self.out[0] = self.accum
                fcall[NoneType](self.g("glDeleteTextures"), c_int(1), self.at(0))
            fcall[NoneType](self.g("glGenTextures"), c_int(1), self.at(0))
            self.accum = self.out[0] & 0xFFFFFFFF
            fcall[NoneType](self.g("glBindTexture"), c_uint(GL_TEXTURE_2D), c_uint(self.accum))
            fcall[NoneType](self.g("glTexParameteri"), c_uint(GL_TEXTURE_2D), c_uint(GL_TEXTURE_MIN_FILTER), c_int(GL_NEAREST))
            fcall[NoneType](self.g("glTexParameteri"), c_uint(GL_TEXTURE_2D), c_uint(GL_TEXTURE_MAG_FILTER), c_int(GL_NEAREST))
            fcall[NoneType](self.g("glTexStorage2D"), c_uint(GL_TEXTURE_2D), c_int(1), c_uint(GL_RGBA16F), c_int(w), c_int(h))
            fcall[NoneType](self.g("glBindFramebuffer"), c_uint(GL_FRAMEBUFFER), c_uint(self.fbo_accum))
            fcall[NoneType](self.g("glFramebufferTexture2D"), c_uint(GL_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_TEXTURE_2D), c_uint(self.accum), c_int(0))
            var st = fcall[c_uint](self.g("glCheckFramebufferStatus"), c_uint(GL_FRAMEBUFFER))
            if st != GL_FRAMEBUFFER_COMPLETE:
                fcall[NoneType](self.g("glBindFramebuffer"), c_uint(GL_FRAMEBUFFER), c_uint(0))
                self.give_up_blend("a float16 picture can't be drawn into (framebuffer status " + String(Int(st)) + ")")
                return False
            self.aw = w
            self.ah = h
        # 1. blend the vertices into the float picture
        fcall[NoneType](self.g("glBindFramebuffer"), c_uint(GL_FRAMEBUFFER), c_uint(self.fbo_accum))
        fcall[NoneType](self.g("glViewport"), c_int(0), c_int(0), c_int(w), c_int(h))
        fcall[NoneType](self.g("glDisable"), c_uint(0x0C11))  # GL_SCISSOR_TEST (the toolkit's state is its own context's)
        fcall[NoneType](self.g("glClearColor"), Float32(0), Float32(0), Float32(0), Float32(0))
        fcall[NoneType](self.g("glClear"), c_uint(GL_COLOR_BUFFER_BIT))
        fcall[NoneType](self.g("glEnable"), c_uint(GL_BLEND))
        if over:
            fcall[NoneType](self.g("glBlendFuncSeparate"), c_uint(GL_SRC_ALPHA), c_uint(GL_ONE_MINUS_SRC_ALPHA), c_uint(GL_ONE), c_uint(GL_ONE_MINUS_SRC_ALPHA))
        else:
            fcall[NoneType](self.g("glBlendFunc"), c_uint(GL_ONE), c_uint(GL_ONE))
        fcall[NoneType](self.g("glUseProgram"), c_uint(self.prog_points))
        fcall[NoneType](self.g("glUniform2i"), c_int(self.loc_size), c_int(w), c_int(h))
        fcall[NoneType](self.g("glBindVertexArray"), c_uint(self.vao))
        fcall[NoneType](self.g("glDrawArrays"), c_uint(GL_LINES if lines else GL_POINTS), c_int(0), c_int(n))
        fcall[NoneType](self.g("glDisable"), c_uint(GL_BLEND))
        # 2. resolve it into the slot's RGBA8 texture
        fcall[NoneType](self.g("glBindFramebuffer"), c_uint(GL_FRAMEBUFFER), c_uint(self.fbo_out))
        fcall[NoneType](self.g("glFramebufferTexture2D"), c_uint(GL_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_TEXTURE_2D), c_uint(self.tex[slot]), c_int(0))
        fcall[NoneType](self.g("glUseProgram"), c_uint(self.prog_resolve))
        fcall[NoneType](self.g("glActiveTexture"), c_uint(GL_TEXTURE0))
        fcall[NoneType](self.g("glBindTexture"), c_uint(GL_TEXTURE_2D), c_uint(self.accum))
        fcall[NoneType](self.g("glUniform1i"), c_int(self.loc_accum), c_int(0))
        fcall[NoneType](self.g("glDrawArrays"), c_uint(GL_TRIANGLES), c_int(0), c_int(3))
        fcall[NoneType](self.g("glBindTexture"), c_uint(GL_TEXTURE_2D), c_uint(0))
        fcall[NoneType](self.g("glBindVertexArray"), c_uint(0))
        fcall[NoneType](self.g("glUseProgram"), c_uint(0))
        fcall[NoneType](self.g("glBindFramebuffer"), c_uint(GL_FRAMEBUFFER), c_uint(0))
        if self.gl_done[slot] != 0:  # (the toolkit has let go of this slot: its old sync object is no longer waited on)
            fcall[NoneType](self.g("glDeleteSync"), self.gl_done[slot])
        self.gl_done[slot] = fcall[Int](self.g("glFenceSync"), c_uint(0x9117), c_uint(0))  # GL_SYNC_GPU_COMMANDS_COMPLETE
        fcall[NoneType](self.g("glFinish" if finish else "glFlush"))  # (finish: timing it, the GPU's part included)
        var err = fcall[c_uint](self.g("glGetError"))
        if err != 0:
            self.give_up_blend("GL error " + String(Int(err)))
            return False
        self.painted += 1
        self.paint_ns += Int(perf_counter_ns() - t0)
        return True

    def read_slot(mut self, slot: Int, dst: Int) -> Bool:
        """Tests: the slot's texture read back into CPU memory (rows of tw pixels, top row first)."""
        fcall[NoneType](self.g("glBindFramebuffer"), c_uint(GL_FRAMEBUFFER), c_uint(self.fbo_out if self.fbo_out != 0 else 0))
        if self.fbo_out == 0:
            self.out[0] = 0
            fcall[NoneType](self.g("glGenFramebuffers"), c_int(1), self.at(0))
            self.fbo_out = self.out[0] & 0xFFFFFFFF
            fcall[NoneType](self.g("glBindFramebuffer"), c_uint(GL_FRAMEBUFFER), c_uint(self.fbo_out))
        fcall[NoneType](self.g("glFramebufferTexture2D"), c_uint(GL_FRAMEBUFFER), c_uint(GL_COLOR_ATTACHMENT0), c_uint(GL_TEXTURE_2D), c_uint(self.tex[slot]), c_int(0))
        fcall[NoneType](self.g("glPixelStorei"), c_uint(GL_PACK_ALIGNMENT), c_int(1))
        fcall[NoneType](self.g("glReadPixels"), c_int(0), c_int(0), c_int(self.tw[slot]), c_int(self.th[slot]), c_uint(GL_RGBA), c_uint(GL_UNSIGNED_BYTE), dst)
        fcall[NoneType](self.g("glBindFramebuffer"), c_uint(GL_FRAMEBUFFER), c_uint(0))
        return fcall[c_uint](self.g("glGetError")) == 0


# ---------- which apps may use it ----------

def gpu_canvas_gate(declared: Bool, mut pr: Presenter) -> Bool:
    """Whether a host should probe for GPU pictures at all (before touching the toolkit or the environment): only for
    an app that declares a GPU canvas (App.GPU_CANVAS), unless turned off or a renderer that can't take a GL texture
    without a copy was chosen. Sets pr.why when not (D-752)."""
    if not declared:
        pr.why = "the app declares no GPU canvas (App.GPU_CANVAS)"
        return False
    if getenv("MOJOUI_CANVAS_GPU") == "0":
        pr.why = "turned off (MOJOUI_CANVAS_GPU=0)"
        return False
    var renderer = getenv("GSK_RENDERER")
    if renderer != "" and renderer != "gl" and renderer != "ngl" and renderer != "opengl":
        pr.why = "GSK_RENDERER=" + renderer + " (only GTK's GL renderer shows a GL texture without a copy)"
        return False
    return True


# ---------- a GL context with no window (tests, and offscreen pictures) ----------

def headless_gl(cuda_device: Int) -> Int:
    """Makes a GLES 3.2 context current on the GPU that is CUDA device cuda_device, with no window or display
    (EGL's device platform, surfaceless). Returns the EGL context (0: couldn't, e.g. not NVIDIA's EGL)."""
    var egl = dl_open("libEGL.so.1")
    if egl == 0:
        return 0
    var gpa = dl_sym(egl, "eglGetProcAddress")
    var n1 = String("eglQueryDevicesEXT")
    var query = fcall[Int](gpa, n1.as_c_string_span())
    var n2 = String("eglQueryDeviceAttribEXT")
    var attrib = fcall[Int](gpa, n2.as_c_string_span())
    var n3 = String("eglGetPlatformDisplayEXT")
    var platform = fcall[Int](gpa, n3.as_c_string_span())
    if query == 0 or attrib == 0 or platform == 0:
        return 0
    var devs = List[Int](length=16, fill=0)
    var out = List[Int](length=8, fill=0)
    if fcall[c_uint](query, c_int(16), Int(devs.unsafe_ptr()), Int(out.unsafe_ptr())) == 0:
        return 0
    var dev = 0
    for i in range(Int(out[0] & 0xFFFFFFFF)):
        out[1] = -1
        if fcall[c_uint](attrib, devs[i], c_int(0x323A), Int(out.unsafe_ptr()) + 8) != 0 and out[1] == cuda_device:  # EGL_CUDA_DEVICE_NV
            dev = devs[i]
    if dev == 0:
        return 0
    var dpy = fcall[Int](platform, c_uint(0x313F), dev, 0)  # EGL_PLATFORM_DEVICE_EXT
    if dpy == 0 or fcall[c_uint](dl_sym(egl, "eglInitialize"), dpy, Int(out.unsafe_ptr()) + 16, Int(out.unsafe_ptr()) + 24) == 0:
        return 0
    _ = fcall[c_uint](dl_sym(egl, "eglBindAPI"), c_uint(0x30A0))  # EGL_OPENGL_ES_API
    var cfg_attrs: List[Int32] = [0x3033, 0x1, 0x3040, 0x40, 0x3038]  # SURFACE_TYPE PBUFFER, RENDERABLE ES3, NONE
    if fcall[c_uint](dl_sym(egl, "eglChooseConfig"), dpy, Int(cfg_attrs.unsafe_ptr()), Int(out.unsafe_ptr()) + 32, c_int(1), Int(out.unsafe_ptr()) + 40) == 0 or (out[5] & 0xFFFFFFFF) == 0:
        return 0
    var ctx_attrs: List[Int32] = [0x3098, 3, 0x30FB, 2, 0x3038]  # MAJOR 3, MINOR 2
    var ctx = fcall[Int](dl_sym(egl, "eglCreateContext"), dpy, out[4], 0, Int(ctx_attrs.unsafe_ptr()))
    if ctx == 0:
        return 0
    if fcall[c_uint](dl_sym(egl, "eglMakeCurrent"), dpy, 0, 0, ctx) == 0:
        return 0
    _ = len(devs)
    _ = len(out)
    _ = len(cfg_attrs)
    _ = len(ctx_attrs)
    return ctx
