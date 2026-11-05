# mojoui.hash: SHA-256 in plain Mojo (goal 50 M4, D-4770): FIPS 180-4, no library, every host (iOS and Android too).
#   sha256_hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
# For checksums and stored key hashes (not for passwords: use a slow KDF for those).

comptime _K = SIMD[DType.uint32, 64](
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
)


@always_inline
def _rotr(x: UInt32, n: UInt32) -> UInt32:
    return (x >> n) | (x << (32 - n))


def sha256(data: Span[UInt8, _]) -> List[UInt8]:
    """The 32-byte digest."""
    var h: List[UInt32] = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]
    var msg = List[UInt8](capacity=len(data) + 72)
    for b in data:
        msg.append(b)
    var bits = UInt64(len(data)) * 8
    msg.append(0x80)
    while len(msg) % 64 != 56:
        msg.append(0)
    for i in range(8):
        msg.append(UInt8((bits >> UInt64((7 - i) * 8)) & 0xFF))
    var w = List[UInt32](length=64, fill=0)
    var k = materialize[_K]()
    for chunk in range(0, len(msg), 64):
        for t in range(16):
            var at = chunk + t * 4
            w[t] = (UInt32(msg[at]) << 24) | (UInt32(msg[at + 1]) << 16) | (UInt32(msg[at + 2]) << 8) | UInt32(msg[at + 3])
        for t in range(16, 64):
            var s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            var s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] + s0 + w[t - 7] + s1
        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]
        for t in range(64):
            var S1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)
            var ch = (e & f) ^ ((~e) & g)
            var t1 = hh + S1 + ch + k[t] + w[t]
            var S0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)
            var mj = (a & b) ^ (a & c) ^ (b & c)
            var t2 = S0 + mj
            hh = g
            g = f
            f = e
            e = d + t1
            d = c
            c = b
            b = a
            a = t1 + t2
        h[0] += a
        h[1] += b
        h[2] += c
        h[3] += d
        h[4] += e
        h[5] += f
        h[6] += g
        h[7] += hh
    var out = List[UInt8](capacity=32)
    for i in range(8):
        for s in range(4):
            out.append(UInt8((h[i] >> UInt32((3 - s) * 8)) & 0xFF))
    return out^


def hex(bytes: List[UInt8]) -> String:
    var digits = "0123456789abcdef"
    var out = String("")
    for b in bytes:
        out += String(digits[byte = Int(b) >> 4]) + String(digits[byte = Int(b) & 15])
    return out


def sha256_hex(text: String) -> String:
    """SHA-256 of the text's UTF-8 bytes, as 64 lower-case hex digits (Python's hashlib.sha256(s.encode()).hexdigest())."""
    return hex(sha256(text.as_bytes()))
