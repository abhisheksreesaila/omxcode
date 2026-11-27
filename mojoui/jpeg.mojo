# mojoui.jpeg (goal 82 M2): a baseline JPEG encoder in plain Mojo. One encoder on every platform, so the same pixels give the same
# bytes on Linux and the Mac (a content-addressed picture store names a file by its bytes: two machines then agree on its name).
#
#   var bytes = encode_jpeg(pixels, w, h, 85)    RGBA (R in the low byte), opaque; quality 1..100 as libjpeg's scale
#
# How: the JFIF baseline the web's encoders write: YCbCr (JFIF's full-range matrix), 4:2:0 chroma, 8x8 DCT, the standard Annex K
# quantization tables scaled by quality (libjpeg's jpeg_quality_scaling), the standard Huffman tables. A picture with
# transparency is not this encoder's job (mojoui.mediastore keeps those as PNG); alpha is ignored.

from std.math import cos, sqrt

comptime PI = 3.14159265358979323846


def _natural() -> List[Int]:
    """The zigzag order: zigzag position k holds natural index natural[k]."""
    return [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42,
            49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]


def _lum_q() -> List[Int]:
    return [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
            18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]


def _chr_q() -> List[Int]:
    var q: List[Int] = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99]
    for _ in range(32):
        q.append(99)
    return q^


def _dc_lum_bits() -> List[Int]:
    return [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]


def _dc_chr_bits() -> List[Int]:
    return [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]


def _dc_vals() -> List[Int]:
    return [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]


def _ac_lum_bits() -> List[Int]:
    return [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D]


def _ac_chr_bits() -> List[Int]:
    return [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]


def _ac_lum_vals() -> List[Int]:
    return [0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
            0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
            0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
            0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
            0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
            0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
            0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
            0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
            0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
            0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
            0xF9, 0xFA]


def _ac_chr_vals() -> List[Int]:
    return [0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
            0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
            0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
            0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
            0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
            0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
            0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
            0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
            0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
            0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
            0xF9, 0xFA]


struct _Huff(Movable):
    """A canonical Huffman table: code and length per symbol (0..255)."""
    var code: List[Int]
    var size: List[Int]

    def __init__(out self, bits: List[Int], vals: List[Int]):
        self.code = List[Int](length=256, fill=0)
        self.size = List[Int](length=256, fill=0)
        var c = 0
        var k = 0
        for l in range(16):
            for _ in range(bits[l]):
                self.code[vals[k]] = c
                self.size[vals[k]] = l + 1
                c += 1
                k += 1
            c <<= 1


struct _Bits(Movable):
    var out: List[UInt8]
    var acc: UInt32
    var n: Int

    def __init__(out self, var out: List[UInt8]):
        self.out = out^
        self.acc = 0
        self.n = 0

    def put(mut self, code: Int, size: Int):
        self.acc = (self.acc << UInt32(size)) | UInt32(code & ((1 << size) - 1))
        self.n += size
        while self.n >= 8:
            var b = UInt8((self.acc >> UInt32(self.n - 8)) & 0xFF)
            self.out.append(b)
            if b == 0xFF:  # (byte stuffing)
                self.out.append(0)
            self.n -= 8
        self.acc &= (UInt32(1) << UInt32(self.n)) - 1 if self.n > 0 else UInt32(0)

    def flush(mut self):
        if self.n > 0:
            self.put(0x7F, 8 - self.n)  # (padded with 1 bits)


def quality_table(base: List[Int], quality: Int) -> List[Int]:
    """libjpeg's jpeg_quality_scaling of an Annex K table (natural order), clamped to 1..255."""
    var q = min(max(quality, 1), 100)
    var s = 5000 // q if q < 50 else 200 - 2 * q
    var out = List[Int](capacity=64)
    for v in base:
        out.append(min(max((v * s + 50) // 100, 1), 255))
    return out^


def _u16(mut out: List[UInt8], v: Int):
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))


def _dht(mut out: List[UInt8], cls_id: Int, bits: List[Int], vals: List[Int]):
    out.append(UInt8(cls_id))
    for b in bits:
        out.append(UInt8(b))
    for v in vals:
        out.append(UInt8(v))


def _bitcount(v: Int) -> Int:
    var a = v if v >= 0 else -v
    var n = 0
    while a > 0:
        n += 1
        a >>= 1
    return n


def _block(mut bw: _Bits, blk: List[Float64], q: List[Int], cosines: List[Float64], prev_dc: Int, dc: _Huff, ac: _Huff) -> Int:
    """One 8x8 block (natural order, level-shifted samples): DCT, quantized, coded. Its DC (for the next block's difference)."""
    var tmp = List[Float64](length=64, fill=0.0)
    for y in range(8):  # rows
        for u in range(8):
            var s = 0.0
            for x in range(8):
                s += blk[y * 8 + x] * cosines[x * 8 + u]
            tmp[y * 8 + u] = s
    var coef = List[Int](length=64, fill=0)
    for u in range(8):
        for v in range(8):
            var s = 0.0
            for y in range(8):
                s += tmp[y * 8 + u] * cosines[y * 8 + v]
            var cu = 0.7071067811865476 if u == 0 else 1.0
            var cv = 0.7071067811865476 if v == 0 else 1.0
            var f = 0.25 * cu * cv * s / Float64(q[v * 8 + u])
            coef[v * 8 + u] = Int(f + 0.5) if f >= 0 else -Int(-f + 0.5)
    var nat = _natural()
    var d = coef[0] - prev_dc
    var nb = _bitcount(d)
    bw.put(dc.code[nb], dc.size[nb])
    if nb > 0:
        bw.put(d if d >= 0 else d + (1 << nb) - 1, nb)
    var run = 0
    var last = 63
    while last > 0 and coef[nat[last]] == 0:
        last -= 1
    for k in range(1, last + 1):
        var c = coef[nat[k]]
        if c == 0:
            run += 1
            continue
        while run > 15:
            bw.put(ac.code[0xF0], ac.size[0xF0])
            run -= 16
        var n = _bitcount(c)
        var sym = (run << 4) | n
        bw.put(ac.code[sym], ac.size[sym])
        bw.put(c if c >= 0 else c + (1 << n) - 1, n)
        run = 0
    if last < 63:
        bw.put(ac.code[0x00], ac.size[0x00])
    return coef[0]


def encode_jpeg(pixels: List[UInt32], width: Int, height: Int, quality: Int = 85) -> List[UInt8]:
    """Baseline JFIF bytes for RGBA pixels (row by row, R in the low byte), 4:2:0, at libjpeg's `quality`."""
    var lq = quality_table(_lum_q(), quality)
    var cq = quality_table(_chr_q(), quality)
    var nat = _natural()
    var out = List[UInt8](capacity=width * height // 4 + 1024)
    for b in [0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]:
        out.append(UInt8(b))
    out.append(0xFF)
    out.append(0xDB)
    _u16(out, 2 + 2 * 65)
    out.append(0)
    for k in range(64):
        out.append(UInt8(lq[nat[k]]))
    out.append(1)
    for k in range(64):
        out.append(UInt8(cq[nat[k]]))
    out.append(0xFF)
    out.append(0xC0)
    _u16(out, 17)
    out.append(8)
    _u16(out, height)
    _u16(out, width)
    out.append(3)
    for b in [1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]:
        out.append(UInt8(b))
    out.append(0xFF)
    out.append(0xC4)
    _u16(out, 2 + 4 * 17 + 12 + 162 + 12 + 162)
    _dht(out, 0x00, _dc_lum_bits(), _dc_vals())
    _dht(out, 0x10, _ac_lum_bits(), _ac_lum_vals())
    _dht(out, 0x01, _dc_chr_bits(), _dc_vals())
    _dht(out, 0x11, _ac_chr_bits(), _ac_chr_vals())
    out.append(0xFF)
    out.append(0xDA)
    _u16(out, 12)
    for b in [3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0]:
        out.append(UInt8(b))
    var dcl = _Huff(_dc_lum_bits(), _dc_vals())
    var acl = _Huff(_ac_lum_bits(), _ac_lum_vals())
    var dcc = _Huff(_dc_chr_bits(), _dc_vals())
    var acc = _Huff(_ac_chr_bits(), _ac_chr_vals())
    var cosines = List[Float64](capacity=64)  # cos((2x+1)uπ/16), x * 8 + u
    for x in range(8):
        for u in range(8):
            cosines.append(cos(Float64((2 * x + 1) * u) * PI / 16.0))
    var bw = _Bits(out^)
    var pdy = 0
    var pdb = 0
    var pdr = 0
    var blk = List[Float64](length=64, fill=0.0)
    var cb = List[Float64](length=64, fill=0.0)
    var cr = List[Float64](length=64, fill=0.0)
    var my = 0
    while my < height:
        var mx = 0
        while mx < width:
            for k in range(64):
                cb[k] = 0.0
                cr[k] = 0.0
            for by in range(2):
                for bx in range(2):
                    for y in range(8):
                        var py = min(my + by * 8 + y, height - 1)
                        for x in range(8):
                            var px = min(mx + bx * 8 + x, width - 1)
                            var p = pixels[py * width + px]
                            var r = Float64(Int(p & 0xFF))
                            var g = Float64(Int((p >> 8) & 0xFF))
                            var b = Float64(Int((p >> 16) & 0xFF))
                            blk[y * 8 + x] = 0.299 * r + 0.587 * g + 0.114 * b - 128.0
                            var ci = ((by * 8 + y) // 2) * 8 + (bx * 8 + x) // 2
                            cb[ci] += 0.25 * (-0.168736 * r - 0.331264 * g + 0.5 * b)
                            cr[ci] += 0.25 * (0.5 * r - 0.418688 * g - 0.081312 * b)
                    pdy = _block(bw, blk, lq, cosines, pdy, dcl, acl)
            pdb = _block(bw, cb, cq, cosines, pdb, dcc, acc)
            pdr = _block(bw, cr, cq, cosines, pdr, dcc, acc)
            mx += 16
        my += 16
    bw.flush()
    bw.out.append(0xFF)
    bw.out.append(0xD9)
    var res = List[UInt8]()
    swap(res, bw.out)
    return res^
