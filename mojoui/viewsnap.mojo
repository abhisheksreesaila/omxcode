# The last view of a tiled layer, kept on disk (goal 79, D-7956): when a big board has settled (every visible tile
# rastered at the zoom it is shown at, nothing being edited), the GPU 2D renderer reads its visible tiles back, one a
# frame, and keeps them here, compressed, with everything the pixels depend on. When the same layer opens again with
# the same key, the renderer shows these tiles (a texture upload) as the tiling's fallback while the real board loads
# underneath; the real tiles replace them as they are rastered. A snapshot is used only when every part of its key
# matches, so it is never stale:
#   tag       the app's: the document and its revision, the skin, anything else its picture depends on
#   renderer  the GPU and driver (a hash of GL_VENDOR/GL_RENDERER/GL_VERSION, set by the renderer: renderer_id())
#   build     this program's own file (a hash of its path, size and change time: build_id())
#   k, tx, ty the layer's zoom in device px and its translation (snapped to whole px), as exact doubles
#   w, h      the target's size in device px
# Backend-free (the file, the codec, the key); GL reads and uploads the tiles (mojoui.gpu2d_gl), the tile plan decides
# when (mojoui.gpu2d_tiles). Metal: the plan is shared; the Metal tile raster isn't written yet (debt), nor this.
#
# File: "MOJOSNP1", u32 head length, the head (key=value lines), then per tile: i32 i, j, x0, y0, w, h (the part of the
# tile's texture kept, texture px; w = h = 0: the tile was empty), i64 n, n bytes of RLE.
# RLE: a stream of u32 words: a word with the top bit set is a run (the low 31 bits: how many) of the next word's
# pixel; else that many literal pixels follow.

from std.ffi import external_call
from std.os import getenv, stat, makedirs
from std.memory import Pointer, bitcast
from std.sys import argv
from mojoui.shared import get_shared, put_shared
from mojoui.libc import rename, unlink

comptime SLOT_SNAP_RENDERER = 235  # mojoui.shared slot: the GPU 2D renderer's id (0: none yet: no snapshot is used)
comptime SNAP_MAGIC = "MOJOSNP1"


def renderer_id() -> Int:
    return get_shared(SLOT_SNAP_RENDERER)


def set_renderer_id(id: Int):
    put_shared(SLOT_SNAP_RENDERER, id if id != 0 else 1)


def fnv(s: String, seed: UInt64 = 1469598103934665603) -> Int:
    var h = seed
    for b in s.as_bytes():
        h = (h ^ UInt64(b)) * 1099511628211
    return Int(h & 0x7FFFFFFFFFFFFFFF)


def build_id() -> Int:
    """This program's file: its path, size and change time hashed (a rebuilt program draws with new code)."""
    var path = String("/proc/self/exe")
    try:
        var st = stat(path)
        return fnv(path + "|" + String(st.st_size) + "|" + String(st.st_mtimespec.tv_sec) + "." + String(st.st_mtimespec.tv_nsec))
    except:
        pass
    try:
        path = String(argv()[0])
        var st = stat(path)
        return fnv(path + "|" + String(st.st_size) + "|" + String(st.st_mtimespec.tv_sec) + "." + String(st.st_mtimespec.tv_nsec))
    except:
        return 0


def _bits(x: Float64) -> Int:
    return Int(bitcast[DType.int64](x))


def _from_bits(v: Int) -> Float64:
    return bitcast[DType.float64](Int64(v))


def _put32(mut out: List[UInt8], v: Int):
    for b in range(4):
        out.append(UInt8((v >> (8 * b)) & 0xFF))


def _put64(mut out: List[UInt8], v: Int):
    for b in range(8):
        out.append(UInt8((v >> (8 * b)) & 0xFF))


def _get32(b: List[UInt8], at: Int) -> Int:
    var v = Int(b[at]) | (Int(b[at + 1]) << 8) | (Int(b[at + 2]) << 16) | (Int(b[at + 3]) << 24)
    return v - (1 << 32) if v >= (1 << 31) else v


def _get64(b: List[UInt8], at: Int) -> Int:
    var v = 0
    for q in range(8):
        v |= Int(b[at + q]) << (8 * q)
    return v


def rle_encode(src: Int, n: Int, mut out: List[UInt8]):
    """n RGBA pixels at src appended to out as RLE words."""
    var p = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=src)
    var i = 0
    var start = len(out)
    var words = List[UInt32](capacity=n // 4 + 16)
    while i < n:
        var v = p[i]
        var j = i + 1
        while j < n and p[j] == v:
            j += 1
        if j - i >= 3:
            words.append(UInt32(0x80000000) | UInt32(j - i))
            words.append(v)
            i = j
            continue
        # literals: until a run of 3 begins
        var a = i
        j = i
        while j < n:
            if j + 2 < n and p[j] == p[j + 1] and p[j] == p[j + 2]:
                break
            j += 1
        words.append(UInt32(j - a))
        for q in range(a, j):
            words.append(p[q])
        i = j
    var nb = len(words) * 4
    out.resize(start + nb, 0)
    _ = external_call["memcpy", Int](Int(out.unsafe_ptr()) + start, Int(words.unsafe_ptr()), nb)
    _ = len(words)  # (kept alive past the copy: Mojo frees a value after its last use)


def rle_decode(src: Int, nbytes: Int, dst: Int, n: Int) -> Bool:
    """RLE words at src (nbytes) into n pixels at dst; False when they don't make exactly n."""
    var s = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=src)
    var d = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=dst)
    var nw = nbytes // 4
    var w = 0
    var o = 0
    while w < nw:
        var h = s[w]
        w += 1
        var c = Int(h & 0x7FFFFFFF)
        if o + c > n:
            return False
        if h & 0x80000000 != 0:
            if w >= nw:
                return False
            var v = s[w]
            w += 1
            if v == 0:
                _ = external_call["memset", Int](dst + 4 * o, 0, 4 * c)
            else:
                for q in range(o, o + c):
                    d[q] = v
        else:
            if w + c > nw:
                return False
            _ = external_call["memcpy", Int](dst + 4 * o, src + 4 * w, 4 * c)
            w += c
        o += c
    return o == n


@fieldwise_init
struct SnapTile(Copyable, Movable, ImplicitlyCopyable):
    var i: Int
    var j: Int
    var x0: Int  # the part of the tile's texture kept (texture px); w = h = 0: an empty tile
    var y0: Int
    var w: Int
    var h: Int
    var at: Int  # its RLE in the file's bytes
    var n: Int


struct SnapKey(Copyable, Movable):
    """Everything a snapshot's pixels depend on (see the top of the file)."""
    var tag: String
    var renderer: Int
    var build: Int
    var k: Float64
    var tx: Float64
    var ty: Float64
    var w: Int
    var h: Int

    def __init__(out self, tag: String, renderer: Int, build: Int, k: Float64, tx: Float64, ty: Float64, w: Int, h: Int):
        self.tag = tag
        self.renderer = renderer
        self.build = build
        self.k = k
        self.tx = tx
        self.ty = ty
        self.w = w
        self.h = h

    def same(self, o: SnapKey) -> Bool:
        return (self.tag == o.tag and self.renderer == o.renderer and self.build == o.build and _bits(self.k) == _bits(o.k)
                and _bits(self.tx) == _bits(o.tx) and _bits(self.ty) == _bits(o.ty) and self.w == o.w and self.h == o.h)

    def why_not(self, o: SnapKey) -> String:
        """The first part that differs ("" when none): for the log."""
        if self.tag != o.tag:
            return "tag"
        if self.renderer != o.renderer:
            return "renderer"
        if self.build != o.build:
            return "build"
        if _bits(self.k) != _bits(o.k):
            return "zoom"
        if _bits(self.tx) != _bits(o.tx) or _bits(self.ty) != _bits(o.ty):
            return "view"
        if self.w != o.w or self.h != o.h:
            return "size"
        return ""

    def text(self) -> String:
        return ("tag=" + self.tag + "\nrenderer=" + String(self.renderer) + "\nbuild=" + String(self.build) + "\nk=" + String(_bits(self.k))
                + "\ntx=" + String(_bits(self.tx)) + "\nty=" + String(_bits(self.ty)) + "\nw=" + String(self.w) + "\nh=" + String(self.h) + "\n")


struct ViewSnap(Movable):
    """A snapshot file read back: its key, the app's note, its tiles (decode each with decode())."""
    var ok: Bool
    var key: SnapKey
    var note: String
    var tiles: List[SnapTile]
    var bytes: List[UInt8]

    def __init__(out self):
        self.ok = False
        self.key = SnapKey("", 0, 0, 0, 0, 0, 0, 0)
        self.note = ""
        self.tiles = List[SnapTile]()
        self.bytes = List[UInt8]()

    def decode(self, t: SnapTile, dst: Int) -> Bool:
        """Tile t's kept part (t.w × t.h pixels, rows packed) into dst."""
        if t.w == 0 or t.h == 0:
            return True
        return rle_decode(Int(self.bytes.unsafe_ptr()) + t.at, t.n, dst, t.w * t.h)


def _read_all(path: String, limit: Int = -1) -> List[UInt8]:
    try:
        var f = open(path, "r")
        var b = f.read_bytes(limit) if limit > 0 else f.read_bytes()
        f.close()
        return b^
    except:
        return List[UInt8]()


def snap_read(path: String, head_only: Bool = False) -> ViewSnap:
    """The snapshot at path (ok False when there is none, or it isn't one). head_only: its key and note, not its tiles
    (a small read: the app checks a snapshot would match before it waits on one)."""
    var out = ViewSnap()
    var b = _read_all(path, 4096 if head_only else -1)
    if len(b) < 12:
        return out^
    for q in range(8):
        if b[q] != SNAP_MAGIC.as_bytes()[q]:
            return out^
    var hl = _get32(b, 8)
    if hl < 0 or 12 + hl > len(b):
        return out^
    var head = String(from_utf8_lossy=Span(b)[12:12 + hl])
    var tiles_n = -1
    try:
        for line in head.split("\n"):
            var l = String(line)
            var eq = l.find("=")
            if eq < 0:
                continue
            var name = String(l[byte=:eq])
            var val = String(l[byte=eq + 1:])
            if name == "tag":
                out.key.tag = val
            elif name == "note":
                out.note = val
            elif name == "renderer":
                out.key.renderer = Int(val)
            elif name == "build":
                out.key.build = Int(val)
            elif name == "k":
                out.key.k = _from_bits(Int(val))
            elif name == "tx":
                out.key.tx = _from_bits(Int(val))
            elif name == "ty":
                out.key.ty = _from_bits(Int(val))
            elif name == "w":
                out.key.w = Int(val)
            elif name == "h":
                out.key.h = Int(val)
            elif name == "tiles":
                tiles_n = Int(val)
    except:
        return out^
    if head_only:
        out.ok = tiles_n >= 0
        return out^
    var at = 12 + hl
    for _ in range(tiles_n):
        if at + 32 > len(b):
            return out^
        var t = SnapTile(_get32(b, at), _get32(b, at + 4), _get32(b, at + 8), _get32(b, at + 12), _get32(b, at + 16), _get32(b, at + 20), at + 32, _get64(b, at + 24))
        if t.n < 0 or t.at + t.n > len(b) or t.w < 0 or t.h < 0:
            return out^
        out.tiles.append(t)
        at = t.at + t.n
    out.bytes = b^
    out.ok = True
    return out^


struct SnapWriter(Movable):
    """A snapshot being written, a tile at a time (the renderer reads one back a frame): finish() puts it in place in
    one step (a temporary file renamed over the old one), so a reader never sees half of one."""
    var path: String
    var key: SnapKey
    var note: String
    var body: List[UInt8]
    var count: Int

    def __init__(out self, path: String, key: SnapKey, note: String):
        self.path = path
        self.key = key.copy()
        self.note = note
        self.body = List[UInt8]()
        self.count = 0

    def add(mut self, i: Int, j: Int, x0: Int, y0: Int, w: Int, h: Int, src: Int):
        """Tile (i, j)'s part (w × h pixels from texture px (x0, y0), rows packed at src); w = h = 0: an empty tile."""
        _put32(self.body, i)
        _put32(self.body, j)
        _put32(self.body, x0)
        _put32(self.body, y0)
        _put32(self.body, w)
        _put32(self.body, h)
        var at = len(self.body)
        _put64(self.body, 0)
        if w > 0 and h > 0:
            rle_encode(src, w * h, self.body)
        var n = len(self.body) - at - 8
        for b in range(8):
            self.body[at + b] = UInt8((n >> (8 * b)) & 0xFF)
        self.count += 1

    def finish(mut self) -> Bool:
        var head = self.key.text() + "note=" + self.note.replace("\n", " ") + "\ntiles=" + String(self.count) + "\n"
        var out = List[UInt8]()
        for c in SNAP_MAGIC.as_bytes():
            out.append(c)
        _put32(out, head.byte_length())
        for c in head.as_bytes():
            out.append(c)
        var tmp = self.path + ".tmp"
        try:
            var f = open(tmp, "w")
            f.write_bytes(Span(out))
            f.write_bytes(Span(self.body))
            f.close()
        except:
            return False
        return rename(tmp, self.path) == 0


def snap_dir_ready(dir: String) -> Bool:
    """The folder snapshots go in, made if missing."""
    try:
        makedirs(dir, exist_ok=True)
    except:
        return False
    try:
        var f = open(dir + "/.probe", "w")
        f.close()
        _ = unlink(dir + "/.probe")
        return True
    except:
        return False
