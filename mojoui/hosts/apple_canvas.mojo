# What the Mac and iPhone hosts share for Canvas views: points and rects returned by
# value, C calls looked up at run time, and turning pixels into a CGImage.
#
# On arm64, a struct of two (or four) doubles comes back from objc_msgSend in d0–d1
# (d0–d3), the same as Apple's CGPoint/CGRect: checked in the disassembly (docs/journal.md).

from std.ffi import external_call
from std.memory import Pointer

from mojoui.hosts.objc import cls, msg, ns_data, ns_number, ns_string

comptime RTLD_DEFAULT = -2


@fieldwise_init
struct CGPoint(Copyable, Movable, RegisterPassable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct CGRect(Copyable, Movable, RegisterPassable):
    var x: Float64
    var y: Float64
    var width: Float64
    var height: Float64


def cfunc[T: RegisterPassable = Int, *A: AnyType](name: String, *args: *A) -> T:
    """Calls a C function by name (looked up at run time, so the app links nothing new),
    e.g. cfunc("CGImageRelease", image)."""
    var n = name
    var addr = external_call["dlsym", Int](RTLD_DEFAULT, n.as_c_string_span())
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr)
    var f = Pointer(to=raw).unsafe_bitcast[def(*a: *A) thin abi("C") -> T]()[]
    return f(*args)


def cg_image(pixels: List[UInt32], width: Int, height: Int) -> Int:
    """A CGImage (caller releases it) holding a copy of RGBA pixels."""
    comptime PREMULTIPLIED_LAST = UInt32(1)  # kCGImageAlphaPremultipliedLast: bytes R, G, B, A
    var data = msg(cls("NSData"), "dataWithBytes:length:", Int(pixels.unsafe_ptr()), len(pixels) * 4)  # a CFData too
    _ = len(pixels)
    var provider = cfunc("CGDataProviderCreateWithCFData", data)
    var space = cfunc("CGColorSpaceCreateDeviceRGB")
    var image = cfunc(
        "CGImageCreate", width, height, 8, 32, width * 4, space, PREMULTIPLIED_LAST, provider, 0, UInt8(0), Int32(0)
    )
    cfunc[NoneType]("CGColorSpaceRelease", space)
    cfunc[NoneType]("CGDataProviderRelease", provider)
    return image


def io_surface(width: Int, height: Int) -> Int:
    """An IOSurface of width × height pixels, bytes B, G, R, A (the caller releases it: CFRelease). Its memory is one
    the GPU and the CPU share (Apple silicon), and Core Animation shows it as a layer's contents without copying it:
    the Mac's way for a GPU picture to reach the screen (D-5311). 0 if it couldn't be made."""
    var d = msg(cls("NSMutableDictionary"), "dictionary")
    var row = cfunc("IOSurfaceAlignProperty", ns_string("IOSurfaceBytesPerRow"), width * 4)
    _ = msg(d, "setObject:forKey:", ns_number(width), ns_string("IOSurfaceWidth"))
    _ = msg(d, "setObject:forKey:", ns_number(height), ns_string("IOSurfaceHeight"))
    _ = msg(d, "setObject:forKey:", ns_number(4), ns_string("IOSurfaceBytesPerElement"))
    _ = msg(d, "setObject:forKey:", ns_number(row), ns_string("IOSurfaceBytesPerRow"))
    _ = msg(d, "setObject:forKey:", ns_number(0x42475241), ns_string("IOSurfacePixelFormat"))  # 'BGRA'
    # whole pages (16 KB on Apple silicon): Metal only lends the GPU memory in pages (wrap_host_memory refused 614400 bytes)
    _ = msg(d, "setObject:forKey:", ns_number((row * height + 16383) // 16384 * 16384), ns_string("IOSurfaceAllocSize"))
    return cfunc("IOSurfaceCreate", d)


comptime MISSES = 3  # draws an IOSurface is offered for before a canvas that never used one counts as a CPU canvas


struct AppleCanvas(Copyable, Movable):
    """One Canvas on screen: its image view and the pixels last drawn."""

    var node: Int
    var view: Int
    var pixels: List[UInt32]
    var wpx: Int
    var hpx: Int
    var drawn: Int  # version last drawn (-1: none)
    var pinch: Float64  # magnification so far in the current pinch (Mac)
    var moved: Bool  # the current press became a drag (so its end is a RELEASE, and it wasn't a tap)
    var last_x: Float64  # where the pointer was at the last mouse event (a drag's deltas run from it)
    var last_y: Float64
    # The Mac with its GPU (D-5311): three IOSurfaces the GPU draws into in turn (one on screen, one being drawn, one
    # spare), the layer showing the latest, and how many pictures went to the screen that way
    var surfaces: List[Int]
    var sw: Int  # their size in pixels
    var sh: Int
    var next: Int  # the one to try first next frame
    var locked: Int  # the one offered to this draw (-1: none)
    var layer: Int  # a sublayer of the canvas view whose contents are an IOSurface (0: not made yet)
    var gpu_frames: Int
    var cpu_only: Bool  # offered IOSurfaces for MISSES draws and never drew into one: a CPU canvas, not offered again
    var misses: Int  # draws offered an IOSurface that didn't use it, while none ever has
    var retired: List[Int]  # IOSurfaces of the old size, released after the next draw (when the GPU has let go of them)

    def __init__(out self, node: Int, view: Int):
        self.node = node
        self.view = view
        self.pixels = List[UInt32]()
        self.wpx = 0
        self.hpx = 0
        self.drawn = -1
        self.pinch = 0
        self.moved = False
        self.last_x = 0
        self.last_y = 0
        self.surfaces = List[Int]()
        self.sw = 0
        self.sh = 0
        self.next = 0
        self.locked = -1
        self.layer = 0
        self.gpu_frames = 0
        self.cpu_only = False
        self.misses = 0
        self.retired = List[Int]()

    def drop_surfaces(mut self):
        """Releases its IOSurfaces and its layer (the canvas is going: the host rebuilt its views)."""
        for s in self.surfaces:
            cfunc[NoneType]("CFRelease", s)
        for s in self.retired:
            cfunc[NoneType]("CFRelease", s)
        self.surfaces.clear()
        self.retired.clear()
        if self.layer != 0:
            _ = msg(self.layer, "removeFromSuperlayer")
            _ = msg(self.layer, "release")
            self.layer = 0
