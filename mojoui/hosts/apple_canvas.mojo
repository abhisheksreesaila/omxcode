# What the Mac and iPhone hosts share for Canvas views: points and rects returned by
# value, C calls looked up at run time, and turning pixels into a CGImage.
#
# On arm64, a struct of two (or four) doubles comes back from objc_msgSend in d0–d1
# (d0–d3), the same as Apple's CGPoint/CGRect: checked in the disassembly (docs/journal.md).

from std.ffi import external_call
from std.memory import Pointer

from mojoui.hosts.objc import cls, msg, ns_data

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
