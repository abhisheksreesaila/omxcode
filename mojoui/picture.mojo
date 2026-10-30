# mojoui.picture: a still picture from a file (PNG, JPEG, WebP, GIF's first frame, any format ffmpeg reads), and the
# aspect-fit, rounded drawing the Player shares (goal 39 M6). A generic component: omxplorer's image card is built on it.
#
#   var p = Picture("photo.jpg")                   # raises (a clear message) when the file is missing or isn't a picture (waits: tests, jobs)
#   var p = Picture.opening("photo.jpg")           # returns at once (the UI thread): decoded on a thread; p.poll() takes it, p.ready()
#   p.width, p.height, p.pixels                    # RGBA, row by row, R in the low byte (as VideoSource's frames)
#   p.draw(surface, backdrop)                      # aspect-fit in the surface, rounded corners, `backdrop` around it
#   draw_fitted(surface, pixels, w, h, backdrop)   # the same for any RGBA buffer (the Player's frames)
#
# How: decoding goes through VideoSource reading one frame (ffmpeg reads stills as one-frame videos), so there is one decoder
# for pictures and video and nothing new to link; a decoder in the process can replace VideoSource without changing a caller.

from mojoui.canvas import Surface
from mojoui.video import VideoSource
from mojoui.framefeed import FrameFeed


def _channels(p: UInt32) -> SIMD[DType.float32, 4]:
    return SIMD[DType.float32, 4](Float32(p & 255), Float32((p >> 8) & 255), Float32((p >> 16) & 255), Float32((p >> 24) & 255))


def _pack(c: SIMD[DType.float32, 4]) -> UInt32:
    return (UInt32(min(max(c[0], 0.0), 255.0) + 0.5) | (UInt32(min(max(c[1], 0.0), 255.0) + 0.5) << 8)
            | (UInt32(min(max(c[2], 0.0), 255.0) + 0.5) << 16) | (UInt32(255) << 24))


def fitted_box(s: Surface, vw: Int, vh: Int) -> Tuple[Float64, Float64, Float64]:
    """Where draw_fitted puts a vw × vh picture in `s`: its left and top in pixels and its scale (surface pixels a
    picture pixel), so marks drawn over it line up."""
    if vw <= 0 or vh <= 0:
        return (0.0, 0.0, 1.0)
    var scale = min(Float64(s.width) / Float64(vw), Float64(s.height) / Float64(vh))
    var dw = max(Int(Float64(vw) * scale), 1)
    var dh = max(Int(Float64(vh) * scale), 1)
    return (Float64((s.width - dw) // 2), Float64((s.height - dh) // 2), scale)


def draw_fitted(mut s: Surface, pixels: List[UInt32], vw: Int, vh: Int, backdrop: UInt32, corner: Float64 = 14.0):
    """Paints the vw × vh RGBA `pixels` as large as fits in `s`, centred, bilinear, with rounded corners (`corner` points)
    blended into `backdrop`, which also fills the rest. Nothing but the backdrop when the buffer isn't vw × vh."""
    s.fill(backdrop)
    if vw <= 0 or vh <= 0 or len(pixels) != vw * vh:
        return
    var scale = min(Float64(s.width) / Float64(vw), Float64(s.height) / Float64(vh))
    var dw = max(Int(Float64(vw) * scale), 1)
    var dh = max(Int(Float64(vh) * scale), 1)
    var x0 = (s.width - dw) // 2
    var y0 = (s.height - dh) // 2
    var radius = min(corner * s.scale, Float64(min(dw, dh)) / 2)
    var back = _channels(backdrop)
    var out = s.pixels()
    var src = pixels.unsafe_ptr()
    var sx_step = Float64(vw) / Float64(dw)
    var sy_step = Float64(vh) / Float64(dh)
    for y in range(dh):
        var fy = min(max((Float64(y) + 0.5) * sy_step - 0.5, 0.0), Float64(vh - 1))
        var iy = Int(fy)
        var iy2 = min(iy + 1, vh - 1)
        var wy = Float32(fy - Float64(iy))
        var dy = min(Float64(y) + 0.5, Float64(dh) - Float64(y) - 0.5)  # distance to the nearest top or bottom edge
        for x in range(dw):
            var fx = min(max((Float64(x) + 0.5) * sx_step - 0.5, 0.0), Float64(vw - 1))
            var ix = Int(fx)
            var ix2 = min(ix + 1, vw - 1)
            var wx = Float32(fx - Float64(ix))
            var top = _channels(src.unsafe_offset(iy * vw + ix)[]) * (1 - wx) + _channels(src.unsafe_offset(iy * vw + ix2)[]) * wx
            var bottom = _channels(src.unsafe_offset(iy2 * vw + ix)[]) * (1 - wx) + _channels(src.unsafe_offset(iy2 * vw + ix2)[]) * wx
            var c = top * (1 - wy) + bottom * wy
            var dx = min(Float64(x) + 0.5, Float64(dw) - Float64(x) - 0.5)
            if dx < radius and dy < radius:  # inside a corner's square: how much of the pixel the rounded corner covers
                var ex = radius - dx
                var ey = radius - dy
                var cover = min(max(radius - (ex * ex + ey * ey) ** 0.5 + 0.5, 0.0), 1.0)
                c = back + (c - back) * Float32(cover)
            out.unsafe_offset((y0 + y) * s.width + x0 + x)[] = _pack(c)


struct Picture(Movable):
    """A still picture decoded once into RGBA: at once (Picture(path)), or on a thread of its own (Picture.opening)."""
    var path: String
    var width: Int
    var height: Int
    var pixels: List[UInt32]
    var feed: Optional[FrameFeed]  # decoding still (opening): poll() takes it
    var problem: String  # why it can't be shown ("" when it can, or while it opens)

    def __init__(out self, path: String) raises:
        var src = VideoSource(path)
        self.path = path
        self.width = src.width
        self.height = src.height
        self.pixels = List[UInt32]()
        self.feed = None
        self.problem = ""
        if not src.next_into(self.pixels):
            raise Error("Picture: cannot decode " + path)
        src.close()

    def __init__(out self, path: String, var feed: FrameFeed):
        self.path = path
        self.width = 0
        self.height = 0
        self.pixels = List[UInt32]()
        self.feed = feed^
        self.problem = ""
        self.feed.value().want(0)

    @staticmethod
    def opening(path: String) raises -> Picture:
        """The picture at `path`, probed and decoded on a thread (mojoui.framefeed): returns at once, empty; poll() takes
        it when it lands. Raises only when the file is missing."""
        return Picture(path, FrameFeed(path, once=True))

    def ready(self) -> Bool:
        return self.width > 0 and len(self.pixels) == self.width * self.height

    def pending(self) -> Bool:
        return not self.ready() and self.problem == "" and Bool(self.feed)

    def poll(mut self) -> Bool:
        """Takes the decoded picture when it has landed (True then, or when it failed: problem says why)."""
        if not self.feed:
            return False
        ref f = self.feed.value()
        if self.problem == "" and f.problem() != "":
            self.problem = f.problem()
            self.feed = None
            return True
        if not f.ready():
            return False
        var info = f.info()
        if f.take(self.pixels):
            self.width = info.width
            self.height = info.height
            self.feed = None  # (its thread has ended: once)
            return True
        return False

    def draw(self, mut s: Surface, backdrop: UInt32, corner: Float64 = 14.0):
        draw_fitted(s, self.pixels, self.width, self.height, backdrop, corner)

    def pixel(self, x: Int, y: Int) -> UInt32:
        """The pixel at (x, y), RGBA with R in the low byte (0 outside the picture)."""
        if x < 0 or y < 0 or x >= self.width or y >= self.height:
            return 0
        return self.pixels[y * self.width + x]
