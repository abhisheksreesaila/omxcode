# Goal 57 M1: mojoui.crypto: HMAC-SHA256 against RFC 4231's vectors, OS random tokens that never repeat, base64url against
# RFC 4648's vectors (no padding, URL alphabet) with round trips and refusals, a constant-time compare, and a seal (a signed,
# expiring value): tampered, signed with another key or expired → refused.
from mojoui.crypto import hmac_sha256, random_bytes, random_token, b64url, b64url_decode, same, seal, unseal, pkce_challenge
from mojoui.hash import hex


def bytes_of(b: Int, n: Int) -> List[UInt8]:
    return List[UInt8](length=n, fill=UInt8(b))


def text_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def want(got: String, expect: String, what: String) raises:
    if got != expect:
        raise Error(what + ": " + got + ", want " + expect)


def test_hmac() raises:
    var k4 = List[UInt8]()
    for i in range(1, 26):
        k4.append(UInt8(i))
    want(hex(hmac_sha256(bytes_of(0x0B, 20), text_bytes("Hi There"))), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", "RFC 4231 #1")
    want(hex(hmac_sha256(text_bytes("Jefe"), text_bytes("what do ya want for nothing?"))), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "#2")
    want(hex(hmac_sha256(bytes_of(0xAA, 20), bytes_of(0xDD, 50))), "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe", "#3")
    want(hex(hmac_sha256(k4, bytes_of(0xCD, 50))), "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b", "#4")
    want(hex(hmac_sha256(bytes_of(0xAA, 131), text_bytes("Test Using Larger Than Block-Size Key - Hash Key First"))), "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", "#6")
    var m7 = "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."
    want(hex(hmac_sha256(bytes_of(0xAA, 131), text_bytes(m7))), "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2", "#7")
    print("hmac: ok")


def test_random() raises:
    var a = random_bytes(32)
    var b = random_bytes(32)
    if len(a) != 32 or len(b) != 32 or same(hex(a), hex(b)):
        raise Error("two 32-byte draws match or have the wrong length")
    var big = random_bytes(1000)  # (getentropy gives at most 256 a call)
    var zeros = 0
    for x in big:
        if x == 0:
            zeros += 1
    if len(big) != 1000 or zeros > 30:
        raise Error("1000 random bytes: " + String(zeros) + " zeros")
    var seen = List[String]()
    for _ in range(200):
        var t = random_token(32)
        if t.byte_length() != 43:  # 32 bytes → 43 base64url characters
            raise Error("a token is " + String(t.byte_length()) + " long")
        for s in seen:
            if s == t:
                raise Error("a token repeated")
        seen.append(t)
    print("random: ok")


def test_base64url() raises:
    var vectors: List[String] = ["", "f", "fo", "foo", "foob", "fooba", "foobar"]
    var coded: List[String] = ["", "Zg", "Zm8", "Zm9v", "Zm9vYg", "Zm9vYmE", "Zm9vYmFy"]
    for i in range(len(vectors)):
        want(b64url(vectors[i]), coded[i], "RFC 4648 " + vectors[i])
        want(String(from_utf8=Span(b64url_decode(coded[i]).value())), vectors[i], "decode " + coded[i])
    # the URL alphabet: 0xfb 0xff → "-_8" (standard base64 would be "+/8=")
    var odd: List[UInt8] = [0xFB, 0xFF]
    want(b64url(odd), "-_8", "URL alphabet")
    for n in range(0, 70):
        var r = random_bytes(n)
        var back = b64url_decode(b64url(r))
        if not back or hex(back.value()) != hex(r):
            raise Error("round trip of " + String(n) + " bytes")
    for bad in ["Zm9v=", "Zm+v", "Zm/v", "Z", "Zm9v Y", "Zh"]:  # padding, the standard alphabet, a lone char, a space, non-zero spare bits
        if b64url_decode(bad):
            raise Error("decoded the bad " + bad)
    print("base64url: ok")


def test_compare() raises:
    if not same("abc", "abc") or same("abc", "abd") or same("abc", "abcd") or same("", "a") or not same("", ""):
        raise Error("same() is wrong")
    # PKCE S256 (RFC 7636 appendix B)
    want(pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 B")
    print("compare: ok")


def test_seal() raises:
    var key = random_bytes(32)
    var other = random_bytes(32)
    var now = 1_800_000_000
    var t = seal(key, "session:abc", 3600, now)
    var back = unseal(key, t, now + 10)
    if not back or back.value() != "session:abc":
        raise Error("a fresh seal didn't open")
    if unseal(other, t, now + 10):
        raise Error("opened with the wrong key")
    if unseal(key, t, now + 3601):
        raise Error("opened after it expired")
    var b = t.as_bytes()
    for i in range(len(b)):  # every one-character change is refused
        var flipped = String("")
        for k in range(len(b)):
            var c = b[k]
            if k == i:
                c = UInt8(65) if c != 65 else UInt8(66)
            flipped += chr(Int(c))
        if unseal(key, flipped, now + 10):
            raise Error("a tampered seal opened (byte " + String(i) + ")")
    if unseal(key, "", now) or unseal(key, "a.b", now) or unseal(key, t + ".x", now):
        raise Error("a malformed seal opened")
    print("seal: ok")


def main() raises:
    test_hmac()
    test_random()
    test_base64url()
    test_compare()
    test_seal()
