# mojoui.mediastore (goal 82 M2): pictures kept once by their bytes, as Personal Note's web app keeps them (media_store.py and
# canvas-leafer/media.js), so a notes file and its media/ folder open the same in either app.
#
#   var store = MediaStore(folder)                         # the media/ folder beside the notes file
#   var made = prepare_picture(path)                        # raises (the web's words) when it isn't a picture or is too big
#   var name = store.put(made.bytes, made.ext)              # "media/<sha256>.<ext>": the same bytes, the same file, written once
#   var box = place_picture(made.width, made.height, x, y, index)   # where a new picture goes on a canvas (520 at most, 28 apart)
#
# The rules (the web's, kept in one place): a PNG, JPEG, WebP or GIF (by its own bytes, never by its name; SVG is never taken);
# over 100 megapixels or 20 MB refused; a picture already within 1400 px on its long side and 300 KB, not a GIF, is stored as it
# came (byte for byte: the web stores the same file under the same name); any other is shrunk to fit 1400 (box filter: every
# source pixel counted, as a browser's high-quality smoothing does) and written again: with see-through pixels as PNG, else as
# a JPEG at quality 85 on white (mojoui.jpeg; a GIF frozen at its first frame). Decoding goes through mojoui.picture (ffmpeg on
# Linux, ImageIO on the Mac); the PNG is deflated by the system's zlib.

from mojoui.zlibc import zlib_compress
from mojoui.hash import sha256, hex
from mojoui.jpeg import encode_jpeg
from mojoui.png import encode_png
from mojoui.picture import Picture
from mojoui.files import private_write_parts, file_exists
from mojoui.shared import make_dir

comptime IMAGE_MAX_SIDE = 1400
comptime IMAGE_MAX_BYTES_KEPT = 300 * 1024  # (the web's IMAGE_MAX_DATA_URL: bigger files are written again)
comptime MAX_MEGAPIXELS = 100
comptime MAX_MEDIA_BYTES = 20 * 1024 * 1024
comptime PLACE_SIDE_PX = 520  # (an Int beside it: Int() of a comptime float does not compile)
comptime PLACE_SIDE = 520.0  # a new picture is at most this big on its long side (page px)
comptime PLACE_OFFSET = 28.0  # each further picture of one drop is placed this far down and right
comptime JPEG_QUALITY = 85


def sniff_image(data: List[UInt8]) -> String:
    """The extension a picture's own bytes say it is (png, jpg, gif, webp), or "" (SVG never: it can carry script)."""
    var n = len(data)
    if n >= 8 and data[0] == 0x89 and data[1] == 0x50 and data[2] == 0x4E and data[3] == 0x47 and data[4] == 0x0D and data[5] == 0x0A and data[6] == 0x1A and data[7] == 0x0A:
        return "png"
    if n >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF:
        return "jpg"
    if n >= 6 and data[0] == 0x47 and data[1] == 0x49 and data[2] == 0x46 and data[3] == 0x38 and (data[4] == 0x37 or data[4] == 0x39) and data[5] == 0x61:
        return "gif"
    if n >= 12 and data[0] == 0x52 and data[1] == 0x49 and data[2] == 0x46 and data[3] == 0x46 and data[8] == 0x57 and data[9] == 0x45 and data[10] == 0x42 and data[11] == 0x50:
        return "webp"
    return ""


def _u16(b: List[UInt8], i: Int) -> Int:
    return (Int(b[i]) << 8) | Int(b[i + 1])


def _u32(b: List[UInt8], i: Int) -> Int:
    return (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])


def image_size(b: List[UInt8]) -> Tuple[Int, Int]:
    """The pixel size from a picture's first bytes (PNG, JPEG, GIF, WebP: media.js readImageSize), (-1, -1) when it can't be told."""
    var n = len(b)
    if n > 24 and b[0] == 0x89 and b[1] == 0x50:
        return (_u32(b, 16), _u32(b, 20))
    if n > 10 and b[0] == 0x47 and b[1] == 0x49 and b[2] == 0x46:
        return (Int(b[6]) | (Int(b[7]) << 8), Int(b[8]) | (Int(b[9]) << 8))
    if n > 30 and b[0] == 0x52 and b[8] == 0x57 and b[9] == 0x45:
        if b[12] == 0x56 and b[13] == 0x50 and b[14] == 0x38 and b[15] == 0x58:  # VP8X
            return (1 + (Int(b[24]) | (Int(b[25]) << 8) | (Int(b[26]) << 16)), 1 + (Int(b[27]) | (Int(b[28]) << 8) | (Int(b[29]) << 16)))
        if b[12] == 0x56 and b[13] == 0x50 and b[14] == 0x38 and b[15] == 0x20:  # "VP8 "
            return ((Int(b[26]) | (Int(b[27]) << 8)) & 0x3FFF, (Int(b[28]) | (Int(b[29]) << 8)) & 0x3FFF)
        if b[12] == 0x56 and b[13] == 0x50 and b[14] == 0x38 and b[15] == 0x4C:  # VP8L
            var bits = Int(b[21]) | (Int(b[22]) << 8) | (Int(b[23]) << 16) | (Int(b[24]) << 24)
            return (1 + (bits & 0x3FFF), 1 + ((bits >> 14) & 0x3FFF))
        return (-1, -1)
    if n > 4 and b[0] == 0xFF and b[1] == 0xD8:
        var i = 2
        while i + 9 < n:
            if b[i] != 0xFF:
                i += 1
                continue
            var m = Int(b[i + 1])
            if m == 0xD8 or m == 0x01 or (m >= 0xD0 and m <= 0xD7) or m == 0xFF:
                i += 1 if m == 0xFF else 2
                continue
            if m >= 0xC0 and m <= 0xCF and m != 0xC4 and m != 0xC8 and m != 0xCC:
                return (_u16(b, i + 7), _u16(b, i + 5))
            i += 2 + _u16(b, i + 2)
    return (-1, -1)


def _js_round(v: Float64) -> Int:
    """JavaScript's Math.round (halves go up)."""
    var f = Int(v)
    if Float64(f) > v:
        f -= 1
    return f + 1 if v - Float64(f) >= 0.5 else f


def fit_image(w: Int, h: Int, max_side: Int = IMAGE_MAX_SIDE) -> Tuple[Int, Int]:
    """The size within max_side on its long side, the shape kept (objects.js fitImage: never enlarged)."""
    var longest = max(w, h)
    if longest <= max_side:
        return (w, h)
    var ratio = Float64(max_side) / Float64(longest)
    return (_js_round(Float64(w) * ratio), _js_round(Float64(h) * ratio))


@fieldwise_init
struct StoragePlan(Copyable, Movable):
    var keep: Bool  # stored as it came
    var too_big: Bool  # refused (over MAX_MEGAPIXELS)
    var width: Int  # the stored size
    var height: Int


def storage_plan(w: Int, h: Int, nbytes: Int, ext: String) -> StoragePlan:
    """How a picture is stored (media.js imageStorage)."""
    var t = fit_image(w, h)
    var resized = t[0] != w or t[1] != h
    if w * h > MAX_MEGAPIXELS * 1_000_000:
        return StoragePlan(False, True, t[0], t[1])
    return StoragePlan(not resized and nbytes <= IMAGE_MAX_BYTES_KEPT and ext != "gif", False, t[0], t[1])


struct Prepared(Movable):
    """What is stored for a picture: its bytes, their extension, and its pixel size."""
    var bytes: List[UInt8]
    var ext: String
    var width: Int
    var height: Int

    def __init__(out self, var bytes: List[UInt8], ext: String, width: Int, height: Int):
        self.bytes = bytes^
        self.ext = ext
        self.width = width
        self.height = height


def shrink(pixels: List[UInt32], sw: Int, sh: Int, dw: Int, dh: Int) -> List[UInt32]:
    """sw × sh RGBA to dw × dh (smaller or equal) by area: each target pixel the coverage-weighted mean of the source pixels under it,
    colours weighted by their alpha (premultiplied), as a browser's high-quality downscale counts them."""
    if dw == sw and dh == sh:
        return pixels.copy()
    var out = List[UInt32](capacity=dw * dh)
    var fx = Float64(sw) / Float64(dw)
    var fy = Float64(sh) / Float64(dh)
    for y in range(dh):
        var y0 = Float64(y) * fy
        var y1 = y0 + fy
        for x in range(dw):
            var x0 = Float64(x) * fx
            var x1 = x0 + fx
            var r = 0.0
            var g = 0.0
            var b = 0.0
            var a = 0.0
            var wsum = 0.0
            var sy = Int(y0)
            while Float64(sy) < y1 and sy < sh:
                var wy = min(Float64(sy + 1), y1) - max(Float64(sy), y0)
                var sx = Int(x0)
                while Float64(sx) < x1 and sx < sw:
                    var wgt = wy * (min(Float64(sx + 1), x1) - max(Float64(sx), x0))
                    var p = pixels[sy * sw + sx]
                    var pa = Float64(Int((p >> 24) & 0xFF)) / 255.0
                    r += wgt * pa * Float64(Int(p & 0xFF))
                    g += wgt * pa * Float64(Int((p >> 8) & 0xFF))
                    b += wgt * pa * Float64(Int((p >> 16) & 0xFF))
                    a += wgt * pa
                    wsum += wgt
                    sx += 1
                sy += 1
            var oa = a / wsum if wsum > 0 else 0.0
            var cr = r / a if a > 0 else 0.0
            var cg = g / a if a > 0 else 0.0
            var cb = b / a if a > 0 else 0.0
            out.append(UInt32(Int(cr + 0.5)) | (UInt32(Int(cg + 0.5)) << 8) | (UInt32(Int(cb + 0.5)) << 16) | (UInt32(Int(oa * 255.0 + 0.5)) << 24))
    return out^


def has_transparency(pixels: List[UInt32]) -> Bool:
    for p in pixels:
        if (p >> 24) != 0xFF:
            return True
    return False


def on_white(pixels: List[UInt32]) -> List[UInt32]:
    """The picture over white (the web's destination-over white fill before a JPEG)."""
    var out = List[UInt32](capacity=len(pixels))
    for p in pixels:
        var a = Int((p >> 24) & 0xFF)
        var r = (Int(p & 0xFF) * a + 255 * (255 - a) + 127) // 255
        var g = (Int((p >> 8) & 0xFF) * a + 255 * (255 - a) + 127) // 255
        var b = (Int((p >> 16) & 0xFF) * a + 255 * (255 - a) + 127) // 255
        out.append(UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(255) << 24))
    return out^


def encode_png_small(pixels: List[UInt32], w: Int, h: Int) -> List[UInt8]:
    """A PNG of RGBA pixels deflated by the system's zlib (level 6, each row's filter Sub): mojoui.png's stored blocks are 4× bigger.
    mojoui.png's when there is no zlib."""
    var raw = List[UInt8](capacity=h * (1 + 4 * w))
    for y in range(h):
        raw.append(1)  # (Sub: each byte less the one 4 before it)
        var prev = UInt32(0)
        for x in range(w):
            var p = pixels[y * w + x]
            for c in range(4):
                var sh = UInt32(8 * c)
                raw.append(UInt8(((p >> sh) - (prev >> sh)) & 0xFF))
            prev = p
    var z = zlib_compress(raw, 6)
    if len(z) == 0:
        return encode_png(pixels, w, h)
    var n = len(z)
    var out = List[UInt8]()
    for b in [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]:
        out.append(UInt8(b))
    var ihdr = List[UInt8]()
    _be32(ihdr, w)
    _be32(ihdr, h)
    for b in [8, 6, 0, 0, 0]:
        ihdr.append(UInt8(b))
    _chunk(out, "IHDR", ihdr)
    var idat = List[UInt8](capacity=n)
    for i in range(n):
        idat.append(z[i])
    _chunk(out, "IDAT", idat)
    _chunk(out, "IEND", List[UInt8]())
    return out^


def _be32(mut out: List[UInt8], v: Int):
    out.append(UInt8((v >> 24) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))


def _crc(data: List[UInt8], start: Int) -> Int:
    var c = UInt32(0xFFFFFFFF)
    for i in range(start, len(data)):
        c ^= UInt32(data[i])
        for _ in range(8):
            c = (UInt32(0xEDB88320) ^ (c >> 1)) if (c & 1) != 0 else (c >> 1)
    return Int(c ^ UInt32(0xFFFFFFFF))


def _chunk(mut out: List[UInt8], kind: String, data: List[UInt8]):
    _be32(out, len(data))
    var start = len(out)
    for b in kind.as_bytes():
        out.append(b)
    for b in data:
        out.append(b)
    _be32(out, _crc(out, start))


def read_file(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def prepare_bytes(var data: List[UInt8], path: String) raises -> Prepared:
    """A picture's bytes made ready to store by the web's rules (prepareImage). `path`: where they are on disk (the decoder reads it;
    "" when only a re-encode can't be needed). Raises with the web's words."""
    if len(data) > MAX_MEDIA_BYTES:
        raise Error("That picture is larger than 20 MB")
    var ext = sniff_image(data)
    if ext == "":
        raise Error("That is not a PNG, JPEG, WebP or GIF picture")
    var hs = image_size(data)
    if hs[0] > 0 and storage_plan(hs[0], hs[1], len(data), ext).too_big:
        raise Error("That picture is too large (over " + String(MAX_MEGAPIXELS) + " megapixels)")
    if hs[0] > 0:
        var plan0 = storage_plan(hs[0], hs[1], len(data), ext)
        if plan0.keep:
            return Prepared(data^, ext, hs[0], hs[1])
    var pic = _decode(path)
    var plan = storage_plan(pic.width, pic.height, len(data), ext)
    if plan.too_big:
        raise Error("That picture is too large (over " + String(MAX_MEGAPIXELS) + " megapixels)")
    if plan.keep:
        return Prepared(data^, ext, pic.width, pic.height)
    var px = shrink(pic.pixels, pic.width, pic.height, plan.width, plan.height)
    var alpha = ext != "jpg" and has_transparency(px)
    if alpha:
        return Prepared(encode_png_small(px, plan.width, plan.height), "png", plan.width, plan.height)
    return Prepared(encode_jpeg(on_white(px), plan.width, plan.height, JPEG_QUALITY), "jpg", plan.width, plan.height)


def _decode(path: String) raises -> Picture:
    try:
        return Picture(path)
    except:
        raise Error("Could not read that picture")


def _read(path: String) raises -> List[UInt8]:
    try:
        return read_file(path)
    except:
        raise Error("Could not read that picture")


def prepare_picture(path: String) raises -> Prepared:
    """prepare_bytes of a file."""
    return prepare_bytes(_read(path), path)


def media_name_ok(name: String) -> Bool:
    """`<64 hex>.<png|jpg|webp|gif|svg>` (media_store.py MEDIA_NAME): only such names reach the file system."""
    var b = name.as_bytes()
    if len(b) < 68 or b[64] != 0x2E:
        return False
    for i in range(64):
        var c = b[i]
        if not ((c >= 0x30 and c <= 0x39) or (c >= 0x61 and c <= 0x66)):
            return False
    var ext = String(name[byte=65:])
    return ext == "png" or ext == "jpg" or ext == "webp" or ext == "gif" or ext == "svg"


struct MediaStore(Movable):
    """The media/ folder: files named by their bytes' SHA-256, written once (atomically: a temporary name, then renamed)."""
    var root: String

    def __init__(out self, root: String):
        self.root = root

    def file(self, name: String) -> String:
        """The path of a stored name ("media/<sha>.<ext>" or "<sha>.<ext>"), "" for a name that isn't one."""
        var n = String(name[byte=6:]) if name.startswith("media/") else name
        return self.root + "/" + n if media_name_ok(n) else String("")

    def put(self, data: List[UInt8], ext: String) raises -> String:
        """The bytes stored (unless the same are already there): "media/<sha256>.<ext>"."""
        var name = hex(sha256(Span(data))) + "." + ext
        var path = self.root + "/" + name
        if not file_exists(path):
            make_dir(self.root)
            if not private_write_parts(path, [(Int(data.unsafe_ptr()), len(data))], True):
                raise Error("Could not store that picture")
            _ = len(data)
        return "media/" + name


@fieldwise_init
struct Placed(Copyable, Movable):
    """A new picture on a canvas (newImage): its unscaled box's corner and size, and the scale it is shown at."""
    var x: Float64
    var y: Float64
    var width: Float64
    var height: Float64
    var scale: Float64


def place_picture(w: Int, h: Int, x: Float64, y: Float64, index: Int = 0) -> Placed:
    """Centred on (x, y) (page px), at most PLACE_SIDE on its long side, never enlarged; the index-th of one drop PLACE_OFFSET
    further down and right. The corner is the unscaled box's (scaled about its centre), as the web writes it."""
    var shown = fit_image(w, h, PLACE_SIDE_PX)
    var scale = Float64(shown[0]) / Float64(w) if w > 0 else 1.0
    var off = Float64(index) * PLACE_OFFSET
    return Placed(x + off - Float64(w) / 2, y + off - Float64(h) / 2, Float64(w), Float64(h), scale)
