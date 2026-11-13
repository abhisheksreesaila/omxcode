# mojoui.avi: JPEG pictures into a video file without re-encoding (goal 68 M3): an AVI holding them as Motion JPEG,
# which ffmpeg (mojoui.video on Linux) and every player open. A robot camera's CompressedImage topic becomes a video
# this way: its JPEGs are copied into the file as they are.
#
#   var w = MjpegAvi()
#   w.add(jpeg, start, end)            # one frame's JPEG bytes (jpeg[start:end]); its size is read from the first one
#   w.write("front_left.avi", fps)     # the file: header, frames, index
#   jpeg_size(jpeg, start, end)        # (width, height) from the JPEG's SOF marker; (0, 0) when it has none


def jpeg_size(b: List[UInt8], start: Int, end: Int) -> Tuple[Int, Int]:
    """A JPEG's width and height, read from its first SOF0–SOF15 marker (not DHT, JPG or DAC)."""
    var p = start + 2
    while p + 9 < end:
        if b[p] != 0xFF:
            return (0, 0)
        var m = Int(b[p + 1])
        var n = (Int(b[p + 2]) << 8) | Int(b[p + 3])
        if m >= 0xC0 and m <= 0xCF and m != 0xC4 and m != 0xC8 and m != 0xCC:
            return ((Int(b[p + 7]) << 8) | Int(b[p + 8]), (Int(b[p + 5]) << 8) | Int(b[p + 6]))
        p += 2 + n
    return (0, 0)


def _u32(mut out: List[UInt8], v: Int):
    for i in range(4):
        out.append(UInt8((v >> (8 * i)) & 0xFF))


def _u16(mut out: List[UInt8], v: Int):
    out.append(UInt8(v & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))


def _cc(mut out: List[UInt8], s: String):
    for b in s.as_bytes():
        out.append(b)


struct MjpegAvi(Movable):
    var frames: List[UInt8]  # the 'movi' list's chunks, as they will be written
    var offsets: List[Int]  # each frame chunk's offset in frames
    var sizes: List[Int]
    var width: Int
    var height: Int
    var biggest: Int

    def __init__(out self):
        self.frames = List[UInt8]()
        self.offsets = List[Int]()
        self.sizes = List[Int]()
        self.width = 0
        self.height = 0
        self.biggest = 0

    def count(self) -> Int:
        return len(self.sizes)

    def add(mut self, b: List[UInt8], start: Int, end: Int) raises:
        if self.width == 0:
            var wh = jpeg_size(b, start, end)
            if wh[0] == 0:
                raise Error("avi: a frame that isn't a JPEG (no size marker)")
            self.width = wh[0]
            self.height = wh[1]
        var n = end - start
        self.offsets.append(len(self.frames))
        self.sizes.append(n)
        self.biggest = max(self.biggest, n)
        _cc(self.frames, "00dc")
        _u32(self.frames, n)
        for i in range(start, end):
            self.frames.append(b[i])
        if n % 2 == 1:
            self.frames.append(0)

    def write(self, path: String, fps: Float64) raises:
        if self.count() == 0:
            raise Error("avi: no frames to write")
        var us = Int(1e6 / fps + 0.5)
        var rate = Int(fps * 1000.0 + 0.5)
        var hdrl = List[UInt8]()
        _cc(hdrl, "hdrl")
        _cc(hdrl, "avih")
        _u32(hdrl, 56)
        _u32(hdrl, us)
        _u32(hdrl, Int(Float64(self.biggest) * fps))
        _u32(hdrl, 0)
        _u32(hdrl, 0x10)  # AVIF_HASINDEX
        _u32(hdrl, self.count())
        _u32(hdrl, 0)
        _u32(hdrl, 1)
        _u32(hdrl, self.biggest)
        _u32(hdrl, self.width)
        _u32(hdrl, self.height)
        for _ in range(4):
            _u32(hdrl, 0)
        var strl = List[UInt8]()
        _cc(strl, "strl")
        _cc(strl, "strh")
        _u32(strl, 56)
        _cc(strl, "vids")
        _cc(strl, "MJPG")
        _u32(strl, 0)
        _u16(strl, 0)
        _u16(strl, 0)
        _u32(strl, 0)
        _u32(strl, 1000)  # dwScale / dwRate = seconds per frame
        _u32(strl, rate)
        _u32(strl, 0)
        _u32(strl, self.count())
        _u32(strl, self.biggest)
        _u32(strl, 0xFFFFFFFF)
        _u32(strl, 0)
        _u16(strl, 0)
        _u16(strl, 0)
        _u16(strl, self.width)
        _u16(strl, self.height)
        _cc(strl, "strf")
        _u32(strl, 40)
        _u32(strl, 40)
        _u32(strl, self.width)
        _u32(strl, self.height)
        _u16(strl, 1)
        _u16(strl, 24)
        _cc(strl, "MJPG")
        _u32(strl, self.width * self.height * 3)
        for _ in range(4):
            _u32(strl, 0)
        _cc(hdrl, "LIST")
        _u32(hdrl, len(strl))
        hdrl.extend(strl^)
        var idx = List[UInt8]()
        for i in range(self.count()):
            _cc(idx, "00dc")
            _u32(idx, 0x10)  # AVIIF_KEYFRAME
            _u32(idx, 4 + self.offsets[i])  # (from the 'movi' fourcc)
            _u32(idx, self.sizes[i])
        var out = List[UInt8]()
        _cc(out, "RIFF")
        _u32(out, 4 + 8 + len(hdrl) + 8 + 4 + len(self.frames) + 8 + len(idx))
        _cc(out, "AVI ")
        _cc(out, "LIST")
        _u32(out, len(hdrl))
        out.extend(hdrl^)
        _cc(out, "LIST")
        _u32(out, 4 + len(self.frames))
        _cc(out, "movi")
        out.extend(self.frames.copy())
        _cc(out, "idx1")
        _u32(out, len(idx))
        out.extend(idx^)
        with open(path, "w") as f:
            f.write_bytes(Span(out))
