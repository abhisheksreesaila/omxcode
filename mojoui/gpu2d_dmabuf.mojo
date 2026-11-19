"""The GPU 2D renderer's ring textures as dmabufs (goal 75, D-7570), for zero-copy presentation: a host hands a frame
straight to the compositor (GTK graphics offload: a Wayland subsurface), so the toolkit neither composites it nor waits
on its fence.

- Each ring texture is exported once (EGL_MESA_image_dma_buf_export on an EGLImage of the GL texture) and the fd kept
  until the texture is remade or closed.
- After each frame the frame's fence goes into the dmabuf itself (EGL_ANDROID_native_fence_sync → a sync file →
  DMA_BUF_IOCTL_IMPORT_SYNC_FILE, as a write fence): the compositor's implicit sync waits for our frame on the GPU,
  nobody's CPU does.

Linux only; `ok` is False (and `why` says why) when the EGL display lacks an extension. The GL context the textures
belong to must be current for start(), export() and fence()."""

from std.ffi import c_int, c_uint, external_call
from std.memory import Pointer
from std.os import getenv
from mojoui.present import fcall, dl_open, dl_sym, c_text

comptime EGL_EXTENSIONS = 0x3055
comptime EGL_NONE = 0x3038
comptime EGL_GL_TEXTURE_2D_KHR = 0x30B1
comptime EGL_GL_TEXTURE_LEVEL_KHR = 0x30BC
comptime EGL_SYNC_NATIVE_FENCE_ANDROID = 0x3144
comptime EGL_SYNC_NATIVE_FENCE_FD_ANDROID = 0x3145
comptime EGL_NO_NATIVE_FENCE_FD_ANDROID = -1
# DMA_BUF_IOCTL_IMPORT_SYNC_FILE = _IOW('b', 3, struct dma_buf_import_sync_file { __u32 flags; __s32 fd; })
comptime DMA_BUF_IOCTL_IMPORT_SYNC_FILE = 0x40086203
comptime DMA_BUF_SYNC_WRITE = 2

comptime E_CREATE_IMAGE = 0
comptime E_DESTROY_IMAGE = 1
comptime E_QUERY = 2
comptime E_EXPORT = 3
comptime E_CREATE_SYNC = 4
comptime E_DESTROY_SYNC = 5
comptime E_DUP_FENCE = 6
comptime E_GET_CURRENT_CONTEXT = 7
comptime E_QUERY_STRING = 8
comptime E_FLUSH = 9  # (glFlush: the native fence must reach the GPU before its fd exists)


def _i32(x: Int) -> Int:
    """The low 32 bits of an 8-byte out-parameter a C int was written into, signed."""
    var v = x & 0xFFFFFFFF
    return v - (1 << 32) if v >= 0x80000000 else v


struct DmabufExport(Movable):
    """Per ring slot: the dmabuf exported from its GL texture (fd -1: none), with its layout."""

    var ok: Bool
    var why: String
    var dpy: Int
    var ctx: Int
    var fp: List[Int]
    var fd: List[Int]
    var tex: List[Int]  # the GL texture each fd came from (a remade texture is exported again)
    var fourcc: List[Int]
    var modifier: List[Int]
    var stride: List[Int]
    var offset: List[Int]
    var fenced: Int  # frames whose fence went into their dmabuf, and fences that didn't (then the host shows the frame
    var unfenced: Int  # the other way)
    var out: List[Int]

    def __init__(out self, slots: Int):
        self.ok = False
        self.why = "not started"
        self.dpy = 0
        self.ctx = 0
        self.fp = List[Int](length=10, fill=0)
        self.fd = List[Int](length=slots, fill=-1)
        self.tex = List[Int](length=slots, fill=0)
        self.fourcc = List[Int](length=slots, fill=0)
        self.modifier = List[Int](length=slots, fill=0)
        self.stride = List[Int](length=slots, fill=0)
        self.offset = List[Int](length=slots, fill=0)
        self.fenced = 0
        self.unfenced = 0
        self.out = List[Int](length=8, fill=0)

    def at(self, k: Int) -> Int:
        return Int(self.out.unsafe_ptr()) + 8 * k

    def start(mut self, dpy: Int) -> Bool:
        """The EGL display the current GL context is on (a host's, e.g. gdk_wayland_display_get_egl_display): its
        extensions checked, the entry points found. MOJOUI_DMABUF=0 turns it off."""
        if getenv("MOJOUI_DMABUF") == "0":
            self.why = "turned off (MOJOUI_DMABUF=0)"
            return False
        if dpy == 0:
            self.why = "no EGL display"
            return False
        var egl = dl_open("libEGL.so.1")
        if egl == 0:
            self.why = "no libEGL"
            return False
        var gpa = dl_sym(egl, "eglGetProcAddress")
        self.fp[E_GET_CURRENT_CONTEXT] = dl_sym(egl, "eglGetCurrentContext")
        self.fp[E_QUERY_STRING] = dl_sym(egl, "eglQueryString")
        if gpa == 0 or self.fp[E_GET_CURRENT_CONTEXT] == 0 or self.fp[E_QUERY_STRING] == 0:
            self.why = "libEGL lacks eglGetProcAddress"
            return False
        var exts = c_text(fcall[Int](self.fp[E_QUERY_STRING], dpy, c_int(EGL_EXTENSIONS)))
        var need: List[String] = ["EGL_KHR_image_base", "EGL_KHR_gl_texture_2D_image", "EGL_MESA_image_dma_buf_export", "EGL_ANDROID_native_fence_sync"]
        for n in need:
            if exts.find(n) < 0:
                self.why = "the EGL display lacks " + n
                return False
        var names: List[String] = ["eglCreateImageKHR", "eglDestroyImageKHR", "eglExportDMABUFImageQueryMESA", "eglExportDMABUFImageMESA",
                                   "eglCreateSyncKHR", "eglDestroySyncKHR", "eglDupNativeFenceFDANDROID"]
        for i in range(len(names)):
            self.fp[i] = fcall[Int](gpa, names[i].as_c_string_span())
            if self.fp[i] == 0:
                self.why = "no " + names[i]
                return False
        var gl = dl_open("libOpenGL.so.0")
        var flush = String("glFlush")
        self.fp[E_FLUSH] = dl_sym(gl, flush) if gl != 0 else 0
        if self.fp[E_FLUSH] == 0:
            self.fp[E_FLUSH] = fcall[Int](gpa, flush.as_c_string_span())
        self.ctx = fcall[Int](self.fp[E_GET_CURRENT_CONTEXT])
        if self.ctx == 0 or self.fp[E_FLUSH] == 0:
            self.why = "no current EGL context"
            return False
        self.dpy = dpy
        self.ok = True
        self.why = "dmabuf export (EGL_MESA_image_dma_buf_export) with native fences in the dmabuf"
        return True

    def forget(mut self, slot: Int):
        """The slot's texture is going away: its dmabuf fd is closed."""
        if self.fd[slot] >= 0:
            _ = external_call["close", c_int](c_int(self.fd[slot]))
        self.fd[slot] = -1
        self.tex[slot] = 0

    def export(mut self, slot: Int, tex: Int) -> Bool:
        """The slot's GL texture `tex` as a one-plane dmabuf (exported once per texture; the fd and layout kept)."""
        if not self.ok:
            return False
        if self.fd[slot] >= 0 and self.tex[slot] == tex:
            return True
        self.forget(slot)
        var attrs: List[Int32] = [EGL_GL_TEXTURE_LEVEL_KHR, 0, EGL_NONE]
        var image = fcall[Int](self.fp[E_CREATE_IMAGE], self.dpy, self.ctx, c_uint(EGL_GL_TEXTURE_2D_KHR), tex, Int(attrs.unsafe_ptr()))
        _ = len(attrs)
        if image == 0:
            self.why = "eglCreateImageKHR on the ring texture failed"
            return False
        for k in range(8):
            self.out[k] = 0
        var ok = fcall[c_uint](self.fp[E_QUERY], self.dpy, image, self.at(0), self.at(1), self.at(2)) != 0
        var planes = _i32(self.out[1])
        if ok and planes == 1:
            self.out[3] = -1
            ok = fcall[c_uint](self.fp[E_EXPORT], self.dpy, image, self.at(3), self.at(4), self.at(5)) != 0
        else:
            ok = False
            if planes != 1:
                self.why = "the texture exports as " + String(planes) + " planes"
        _ = fcall[c_uint](self.fp[E_DESTROY_IMAGE], self.dpy, image)
        var fd = _i32(self.out[3])
        if not ok or fd < 0:
            if self.why.find("planes") < 0:
                self.why = "eglExportDMABUFImageMESA failed"
            return False
        self.fd[slot] = fd
        self.tex[slot] = tex
        self.fourcc[slot] = self.out[0] & 0xFFFFFFFF
        self.modifier[slot] = self.out[2]
        self.stride[slot] = _i32(self.out[4])
        self.offset[slot] = _i32(self.out[5])
        return True

    def fence(mut self, slot: Int) -> Bool:
        """After the slot's frame is queued: a native fence for it, imported into the slot's dmabuf as a write fence
        (whoever reads the dmabuf with implicit sync waits for the frame on the GPU). Flushes. False: the dmabuf carries
        no fence for this frame (the caller must not hand it out as a dmabuf)."""
        if not self.ok or self.fd[slot] < 0:
            return False
        var attrs: List[Int32] = [EGL_SYNC_NATIVE_FENCE_FD_ANDROID, EGL_NO_NATIVE_FENCE_FD_ANDROID, EGL_NONE]
        var sync = fcall[Int](self.fp[E_CREATE_SYNC], self.dpy, c_uint(EGL_SYNC_NATIVE_FENCE_ANDROID), Int(attrs.unsafe_ptr()))
        _ = len(attrs)
        if sync == 0:
            self.unfenced += 1
            return False
        fcall[NoneType](self.fp[E_FLUSH])
        var sfd = Int(fcall[c_int](self.fp[E_DUP_FENCE], self.dpy, sync))
        _ = fcall[c_uint](self.fp[E_DESTROY_SYNC], self.dpy, sync)
        if sfd < 0:
            self.unfenced += 1
            return False
        var arg: List[Int32] = [DMA_BUF_SYNC_WRITE, Int32(sfd)]
        var r = Int(external_call["ioctl", c_int, num_fixed_args=2](c_int(self.fd[slot]), UInt64(DMA_BUF_IOCTL_IMPORT_SYNC_FILE), Int(arg.unsafe_ptr())))
        _ = len(arg)
        _ = external_call["close", c_int](c_int(sfd))
        if r != 0:
            self.unfenced += 1
            return False
        self.fenced += 1
        return True

    def close(mut self):
        for i in range(len(self.fd)):
            self.forget(i)
        self.ok = False
