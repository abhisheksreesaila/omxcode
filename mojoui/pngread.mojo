# mojoui.pngread: a PNG picture decoded in Mojo, in the process (goal 77 M3). Map tiles arrive as PNG bytes many times a second
# while a map flies; starting a decoder process for each (mojoui.picture's ffmpeg path) costs tens of milliseconds and a
# fork, and the system's zlib isn't something every host links. So this file inflates (RFC 1950/1951, after zlib's puff)
# and unfilters (PNG's five row filters) itself. Run it off the UI thread (mojoui.tiles does: on each tile's worker).
#
#   var img = decode_png(bytes)          # raises (a clear message) on anything it can't read
#   img.width, img.height, img.pixels    # RGBA, row by row, R in the low byte (as mojoui.picture's)
#   inflate_zlib(bytes) -> List[UInt8]   # the zlib stream's bytes, for anything else that needs them
#
# Reads: every colour type (grey, RGB, palette, grey + alpha, RGBA), bit depths 1, 2, 4, 8 and 16 (16 keeps the high byte),
# a palette's tRNS alpha. Not read: interlaced (Adam7) pictures (raises), colour profiles and gamma (ignored).


struct _Huffman(Movable):
    var count: List[Int]  # codes of each length 0…15
    var symbol: List[Int]  # the symbols, ordered by code

    def __init__(out self, lengths: List[Int]) raises:
        self.count = List[Int](length=16, fill=0)
        self.symbol = List[Int](length=len(lengths), fill=0)
        for l in lengths:
            self.count[l] += 1
        var left = 1
        for l in range(1, 16):
            left = left * 2 - self.count[l]
            if left < 0:
                raise Error("inflate: a Huffman table is over-subscribed")
        var offs = List[Int](length=16, fill=0)
        for l in range(1, 15):
            offs[l + 1] = offs[l] + self.count[l]
        for s in range(len(lengths)):
            if lengths[s] != 0:
                self.symbol[offs[lengths[s]]] = s
                offs[lengths[s]] += 1


comptime _LBASE: List[Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
comptime _LEXT: List[Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
comptime _DBASE: List[Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
comptime _DEXT: List[Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
comptime _ORDER: List[Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]


struct _Inflater(Movable):
    var src: List[UInt8]
    var pos: Int
    var bitbuf: Int
    var bitcnt: Int
    var out: List[UInt8]

    def __init__(out self, var src: List[UInt8], start: Int, expect: Int):
        self.src = src^
        self.pos = start
        self.bitbuf = 0
        self.bitcnt = 0
        self.out = List[UInt8](capacity=max(expect, 1024))

    def bits(mut self, need: Int) raises -> Int:
        var val = self.bitbuf
        while self.bitcnt < need:
            if self.pos >= len(self.src):
                raise Error("inflate: the stream ends early")
            val |= Int(self.src[self.pos]) << self.bitcnt
            self.pos += 1
            self.bitcnt += 8
        self.bitbuf = val >> need
        self.bitcnt -= need
        return val & ((1 << need) - 1)

    def decode(mut self, h: _Huffman) raises -> Int:
        var code = 0
        var first = 0
        var index = 0
        for l in range(1, 16):
            code |= self.bits(1)
            var count = h.count[l]
            if code - count < first:
                return h.symbol[index + (code - first)]
            index += count
            first += count
            first <<= 1
            code <<= 1
        raise Error("inflate: a code that isn't in its table")

    def stored(mut self) raises:
        self.bitbuf = 0
        self.bitcnt = 0
        if self.pos + 4 > len(self.src):
            raise Error("inflate: a stored block ends early")
        var n = Int(self.src[self.pos]) | (Int(self.src[self.pos + 1]) << 8)
        var check = Int(self.src[self.pos + 2]) | (Int(self.src[self.pos + 3]) << 8)
        if n != (~check & 0xFFFF):
            raise Error("inflate: a stored block's length doesn't match its complement")
        self.pos += 4
        if self.pos + n > len(self.src):
            raise Error("inflate: a stored block ends early")
        for i in range(n):
            self.out.append(self.src[self.pos + i])
        self.pos += n

    def codes(mut self, lencode: _Huffman, distcode: _Huffman) raises:
        while True:
            var sym = self.decode(lencode)
            if sym < 256:
                self.out.append(UInt8(sym))
            elif sym == 256:
                return
            else:
                sym -= 257
                if sym >= 29:
                    raise Error("inflate: a length code past the table")
                var n = materialize[_LBASE]()[sym] + self.bits(materialize[_LEXT]()[sym])
                var ds = self.decode(distcode)
                if ds >= 30:
                    raise Error("inflate: a distance code past the table")
                var dist = materialize[_DBASE]()[ds] + self.bits(materialize[_DEXT]()[ds])
                var at = len(self.out) - dist
                if at < 0:
                    raise Error("inflate: a distance before the start")
                for i in range(n):
                    self.out.append(self.out[at + i])

    def fixed(mut self) raises:
        var lengths = List[Int](length=288, fill=8)
        for s in range(144, 256):
            lengths[s] = 9
        for s in range(256, 280):
            lengths[s] = 7
        var lencode = _Huffman(lengths)
        var dists = List[Int](length=30, fill=5)
        var distcode = _Huffman(dists)
        self.codes(lencode, distcode)

    def dynamic(mut self) raises:
        var nlen = self.bits(5) + 257
        var ndist = self.bits(5) + 1
        var ncode = self.bits(4) + 4
        if nlen > 286 or ndist > 30:
            raise Error("inflate: too many codes")
        var lengths = List[Int](length=19, fill=0)
        for i in range(ncode):
            lengths[materialize[_ORDER]()[i]] = self.bits(3)
        var lencode = _Huffman(lengths)
        var all = List[Int](length=nlen + ndist, fill=0)
        var i = 0
        while i < nlen + ndist:
            var sym = self.decode(lencode)
            if sym < 16:
                all[i] = sym
                i += 1
                continue
            var value = 0
            var rep = 0
            if sym == 16:
                if i == 0:
                    raise Error("inflate: a repeat with nothing before it")
                value = all[i - 1]
                rep = 3 + self.bits(2)
            elif sym == 17:
                rep = 3 + self.bits(3)
            else:
                rep = 11 + self.bits(7)
            if i + rep > nlen + ndist:
                raise Error("inflate: too many lengths")
            for _ in range(rep):
                all[i] = value
                i += 1
        if all[256] == 0:
            raise Error("inflate: no end-of-block code")
        var ll = List[Int](capacity=nlen)
        for k in range(nlen):
            ll.append(all[k])
        var dl = List[Int](capacity=ndist)
        for k in range(nlen, nlen + ndist):
            dl.append(all[k])
        self.codes(_Huffman(ll), _Huffman(dl))

    def run(mut self) raises:
        while True:
            var last = self.bits(1)
            var kind = self.bits(2)
            if kind == 0:
                self.stored()
            elif kind == 1:
                self.fixed()
            elif kind == 2:
                self.dynamic()
            else:
                raise Error("inflate: block type 3")
            if last == 1:
                return


def inflate_zlib(var data: List[UInt8], expect: Int = 0) raises -> List[UInt8]:
    """The bytes of a zlib stream (a 2-byte header, deflate blocks; the Adler-32 at the end isn't checked). `expect`: the
    size it will have, if known (one allocation)."""
    if len(data) < 2:
        raise Error("zlib: too short")
    if (Int(data[0]) & 0x0F) != 8 or ((Int(data[0]) << 8) | Int(data[1])) % 31 != 0:
        raise Error("zlib: not a deflate stream")
    if (Int(data[1]) & 0x20) != 0:
        raise Error("zlib: a preset dictionary")
    var inf = _Inflater(data^, 2, expect)
    inf.run()
    var out = List[UInt8]()
    swap(out, inf.out)
    return out^


struct PngImage(Movable):
    var width: Int
    var height: Int
    var pixels: List[UInt32]  # RGBA, R in the low byte

    def __init__(out self, width: Int, height: Int, var pixels: List[UInt32]):
        self.width = width
        self.height = height
        self.pixels = pixels^


def _u32(b: List[UInt8], at: Int) -> Int:
    return (Int(b[at]) << 24) | (Int(b[at + 1]) << 16) | (Int(b[at + 2]) << 8) | Int(b[at + 3])


def _paeth(a: Int, b: Int, c: Int) -> Int:
    var p = a + b - c
    var pa = abs(p - a)
    var pb = abs(p - b)
    var pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _rgba(r: Int, g: Int, b: Int, a: Int) -> UInt32:
    return UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(a) << 24)


def decode_png(bytes: List[UInt8]) raises -> PngImage:
    """A PNG file's picture as RGBA (raises with what is wrong: not a PNG, interlaced, damaged)."""
    var sig: List[UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    if len(bytes) < 8 + 25:
        raise Error("png: too short")
    for i in range(8):
        if bytes[i] != sig[i]:
            raise Error("png: not a PNG file")
    var at = 8
    var width = 0
    var height = 0
    var depth = 0
    var ctype = 0
    var palette = List[UInt32]()
    var alpha = List[Int]()
    var idat = List[UInt8]()
    var seen_header = False
    while at + 8 <= len(bytes):
        var n = _u32(bytes, at)
        var kind = String(unsafe_from_utf8=Span(bytes)[at + 4 : at + 8])
        var body = at + 8
        if body + n > len(bytes):
            raise Error("png: a chunk runs past the end")
        if kind == "IHDR":
            width = _u32(bytes, body)
            height = _u32(bytes, body + 4)
            depth = Int(bytes[body + 8])
            ctype = Int(bytes[body + 9])
            if Int(bytes[body + 12]) != 0:
                raise Error("png: interlaced pictures aren't read")
            seen_header = True
        elif kind == "PLTE":
            for k in range(n // 3):
                palette.append(_rgba(Int(bytes[body + 3 * k]), Int(bytes[body + 3 * k + 1]), Int(bytes[body + 3 * k + 2]), 255))
        elif kind == "tRNS":
            for k in range(n):
                alpha.append(Int(bytes[body + k]))
        elif kind == "IDAT":
            for k in range(n):
                idat.append(bytes[body + k])
        elif kind == "IEND":
            break
        at = body + n + 4  # (the CRC isn't checked: a damaged picture fails in inflate or shows wrong pixels, it can't crash)
    if not seen_header or width <= 0 or height <= 0 or width > 16384 or height > 16384:
        raise Error("png: no usable header")
    var channels = 1
    if ctype == 2:
        channels = 3
    elif ctype == 4:
        channels = 2
    elif ctype == 6:
        channels = 4
    elif ctype != 0 and ctype != 3:
        raise Error("png: colour type " + String(ctype))
    if depth != 1 and depth != 2 and depth != 4 and depth != 8 and depth != 16:
        raise Error("png: bit depth " + String(depth))
    if ctype == 3 and len(palette) == 0:
        raise Error("png: a palette picture with no palette")
    var bits_pp = channels * depth
    var stride = (width * bits_pp + 7) // 8
    var bpp = max(1, bits_pp // 8)
    var raw = inflate_zlib(idat^, (stride + 1) * height)
    if len(raw) < (stride + 1) * height:
        raise Error("png: the picture's data is short")
    # unfilter in place, row by row
    var prev = List[UInt8](length=stride, fill=0)
    var line = List[UInt8](length=stride, fill=0)
    var px = List[UInt32](length=width * height, fill=0)
    for y in range(height):
        var row = y * (stride + 1)
        var f = Int(raw[row])
        for i in range(stride):
            var x = Int(raw[row + 1 + i])
            var a = Int(line[i - bpp]) if i >= bpp else 0
            var b = Int(prev[i])
            var c = Int(prev[i - bpp]) if i >= bpp else 0
            var v = x
            if f == 1:
                v = x + a
            elif f == 2:
                v = x + b
            elif f == 3:
                v = x + (a + b) // 2
            elif f == 4:
                v = x + _paeth(a, b, c)
            elif f != 0:
                raise Error("png: filter " + String(f))
            line[i] = UInt8(v & 0xFF)
        # this row's pixels
        var o = y * width
        if depth == 8:
            if ctype == 3:
                for x in range(width):
                    var k = Int(line[x])
                    var c = palette[k] if k < len(palette) else UInt32(0xFF000000)
                    if k < len(alpha):
                        c = (c & 0x00FFFFFF) | (UInt32(alpha[k]) << 24)
                    px[o + x] = c
            elif ctype == 2:
                for x in range(width):
                    px[o + x] = _rgba(Int(line[3 * x]), Int(line[3 * x + 1]), Int(line[3 * x + 2]), 255)
            elif ctype == 6:
                for x in range(width):
                    px[o + x] = _rgba(Int(line[4 * x]), Int(line[4 * x + 1]), Int(line[4 * x + 2]), Int(line[4 * x + 3]))
            elif ctype == 0:
                for x in range(width):
                    var g = Int(line[x])
                    px[o + x] = _rgba(g, g, g, 255)
            else:
                for x in range(width):
                    var g = Int(line[2 * x])
                    px[o + x] = _rgba(g, g, g, Int(line[2 * x + 1]))
        elif depth == 16:
            for x in range(width):
                var s = x * channels * 2
                if ctype == 2:
                    px[o + x] = _rgba(Int(line[s]), Int(line[s + 2]), Int(line[s + 4]), 255)
                elif ctype == 6:
                    px[o + x] = _rgba(Int(line[s]), Int(line[s + 2]), Int(line[s + 4]), Int(line[s + 6]))
                elif ctype == 0:
                    px[o + x] = _rgba(Int(line[s]), Int(line[s]), Int(line[s]), 255)
                else:
                    px[o + x] = _rgba(Int(line[s]), Int(line[s]), Int(line[s]), Int(line[s + 2]))
        else:  # 1, 2 or 4 bits: grey or a palette
            var per = 8 // depth
            var mask = (1 << depth) - 1
            for x in range(width):
                var byte = Int(line[x // per])
                var shift = 8 - depth * (x % per + 1)
                var v = (byte >> shift) & mask
                if ctype == 3:
                    var c = palette[v] if v < len(palette) else UInt32(0xFF000000)
                    if v < len(alpha):
                        c = (c & 0x00FFFFFF) | (UInt32(alpha[v]) << 24)
                    px[o + x] = c
                else:
                    var g = v * 255 // mask
                    px[o + x] = _rgba(g, g, g, 255)
        var t = prev^
        prev = line^
        line = t^
    return PngImage(width, height, px^)
