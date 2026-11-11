# mojoui.crypto: the small pieces sign-in and payments stand on (goal 57 M1, D-5709), plain Mojo on mojoui.hash's SHA-256,
# so every host has them (the server, a desktop client, a phone):
#
#   hmac_sha256(key, msg)            RFC 2104 / 4231: a webhook's signature, a seal's tag
#   random_bytes(n), random_token(n) the OS CSPRNG (getentropy; raises, never falls back): session ids, OAuth state, PKCE
#   b64url(bytes), b64url_decode(s)  RFC 4648 §5, no padding; decoding refuses anything else (padding, + /, spare bits)
#   same(a, b)                       constant-time equality: tags, states, codes (time depends on the length only)
#   pkce_challenge(verifier)         RFC 7636 S256: b64url(sha256(verifier))
#   seal(key, value, ttl_s, now)     a signed, expiring value: "<b64url value>.<expires>.<b64url tag>"; unseal → the value, or
#                                    None when tampered, signed with another key, expired or malformed. Signed, not hidden:
#                                    seal ids and claims, never secrets.
from mojoui.hash import sha256
from mojoui import libc

comptime _BLOCK = 64
comptime _ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8](capacity=s.byte_length())
    for b in s.as_bytes():
        out.append(b)
    return out^


def hmac_sha256(key: List[UInt8], msg: List[UInt8]) -> List[UInt8]:
    """The 32-byte HMAC-SHA256 tag of `msg` under `key` (a key longer than a block is hashed first)."""
    var k = key.copy()
    if len(k) > _BLOCK:
        k = sha256(Span(key))
    while len(k) < _BLOCK:
        k.append(0)
    var inner = List[UInt8](capacity=_BLOCK + len(msg))
    var outer = List[UInt8](capacity=_BLOCK + 32)
    for i in range(_BLOCK):
        inner.append(k[i] ^ 0x36)
        outer.append(k[i] ^ 0x5C)
    for b in msg:
        inner.append(b)
    for b in sha256(Span(inner)):
        outer.append(b)
    return sha256(Span(outer))


def hmac_sha256(key: String, msg: String) -> List[UInt8]:
    return hmac_sha256(_bytes(key), _bytes(msg))


def random_bytes(n: Int) raises -> List[UInt8]:
    """`n` bytes from the OS's CSPRNG (getentropy, 256 at a time). Raises when the OS has none: there is no fallback."""
    var out = List[UInt8](length=max(n, 0), fill=0)
    var off = 0
    while off < n:
        var take = min(n - off, 256)
        if libc.getentropy(Int(out.unsafe_ptr()) + off, take) != 0:
            raise Error("no randomness from the OS (getentropy failed)")
        off += take
    _ = len(out)
    return out^


def random_token(n: Int = 32) raises -> String:
    """`n` random bytes as base64url (32 → 43 characters): a session id, an OAuth state, a PKCE verifier."""
    return b64url(random_bytes(n))


def b64url(data: List[UInt8]) -> String:
    var a = _ALPHABET.as_bytes()
    var out = List[UInt8](capacity=(len(data) * 4 + 2) // 3)
    var i = 0
    while i + 3 <= len(data):
        var v = (Int(data[i]) << 16) | (Int(data[i + 1]) << 8) | Int(data[i + 2])
        out.append(a[(v >> 18) & 63])
        out.append(a[(v >> 12) & 63])
        out.append(a[(v >> 6) & 63])
        out.append(a[v & 63])
        i += 3
    var rest = len(data) - i
    if rest == 1:
        var v = Int(data[i]) << 16
        out.append(a[(v >> 18) & 63])
        out.append(a[(v >> 12) & 63])
    elif rest == 2:
        var v = (Int(data[i]) << 16) | (Int(data[i + 1]) << 8)
        out.append(a[(v >> 18) & 63])
        out.append(a[(v >> 12) & 63])
        out.append(a[(v >> 6) & 63])
    return String(unsafe_from_utf8=Span(out))


def b64url(text: String) -> String:
    return b64url(_bytes(text))


def _sextet(c: UInt8) -> Int:
    var x = Int(c)
    if x >= 65 and x <= 90:
        return x - 65
    if x >= 97 and x <= 122:
        return x - 71
    if x >= 48 and x <= 57:
        return x + 4
    if x == 45:  # '-'
        return 62
    if x == 95:  # '_'
        return 63
    return -1


def b64url_decode(s: String) -> Optional[List[UInt8]]:
    """The bytes, or None for anything but canonical unpadded base64url (a stray character, '=', a length of 4k+1, or
    spare bits that aren't zero: one value has one spelling)."""
    var b = s.as_bytes()
    if len(b) % 4 == 1:
        return None
    var out = List[UInt8](capacity=len(b) * 3 // 4)
    var acc = 0
    var bits = 0
    for c in b:
        var v = _sextet(c)
        if v < 0:
            return None
        acc = ((acc << 6) | v) & 0xFFFFFF
        bits += 6
        if bits >= 8:
            bits -= 8
            out.append(UInt8((acc >> bits) & 0xFF))
    if bits > 0 and (acc & ((1 << bits) - 1)) != 0:
        return None
    return out^


def same(a: String, b: String) -> Bool:
    """Equal, in time that depends on the lengths only (never stops at the first different byte)."""
    var x = a.as_bytes()
    var y = b.as_bytes()
    var diff = len(x) ^ len(y)
    var n = max(len(x), len(y))
    for i in range(n):
        var p = Int(x[i]) if i < len(x) else 0
        var q = Int(y[i]) if i < len(y) else 0
        diff |= p ^ q
    return diff == 0


def pkce_challenge(verifier: String) -> String:
    """RFC 7636's S256 code challenge of a verifier."""
    return b64url(sha256(verifier.as_bytes()))


def _tag(key: List[UInt8], body: String) -> String:
    return b64url(hmac_sha256(key, _bytes("mojoui.seal.v1." + body)))


def seal(key: List[UInt8], value: String, ttl_s: Int, now: Int) -> String:
    """`value` signed under `key`, good for `ttl_s` seconds from `now` (epoch seconds)."""
    var body = b64url(value) + "." + String(now + ttl_s)
    return body + "." + _tag(key, body)


def unseal(key: List[UInt8], token: String, now: Int) -> Optional[String]:
    """The sealed value, if `token` is one `seal` made under `key` and it hasn't expired at `now`; else None."""
    var parts = token.split(".")
    if len(parts) != 3:
        return None
    var body = String(parts[0]) + "." + String(parts[1])
    if not same(_tag(key, body), String(parts[2])):
        return None
    var expires: Int
    try:
        expires = atol(String(parts[1]))
    except:
        return None
    if now >= expires:
        return None
    var raw = b64url_decode(String(parts[0]))
    if not raw:
        return None
    try:
        return String(from_utf8=Span(raw.value()))
    except:
        return None


def b64(data: List[UInt8]) -> String:
    """Standard base64 (RFC 4648 §4: + and /, padded with =), for MIME and SMTP AUTH."""
    var s = b64url(data).replace("-", "+").replace("_", "/")
    var pad = (4 - s.byte_length() % 4) % 4
    return s + "=" * pad


def b64(text: String) -> String:
    var d = List[UInt8]()
    for c in text.as_bytes():
        d.append(c)
    return b64(d)


def hmac_hex_ok(signature_hex: String, body: String, secret: String) -> Bool:
    """A generic webhook signature (GitHub's `X-Hub-Signature-256: sha256=<hex>`, most `X-Webhook-Signature`s): the
    hex HMAC-SHA256 of the raw body under the shared secret, compared in constant time (any "sha256=" prefix dropped)."""
    if secret == "" or signature_hex == "":
        return False
    var sig = String(signature_hex[byte = 7 :]) if signature_hex.startswith("sha256=") else signature_hex
    var d = hmac_sha256(secret, body)
    var digits = "0123456789abcdef"
    var want = String("")
    for b in d:
        want += String(digits[byte = Int(b >> 4) : Int(b >> 4) + 1]) + String(digits[byte = Int(b & 15) : Int(b & 15) + 1])
    return same(want, sig.lower())
