# mojoui.mediafiles: pictures kept as content-addressed files and moved in and out of documents as data URLs (goal 82 M3).
# The rules are Personal Note's media store's (media_store.py), so files one app writes the other reads:
#
#   var name = put_media(dir, bytes, "png")     # "media/<sha256>.png": written once (atomically), the same bytes the same name
#   var b = read_media(dir, "media/<sha>.png")  # Optional bytes (a name that isn't <64 hex>.<png|jpg|webp|gif|svg>: None)
#   var url = data_url(bytes, "png")            # "data:image/png;base64,…"
#   var d = decode_data_url(url)                # Optional (bytes, ext): base64 or percent-encoded png/jpeg/webp/gif/svg+xml,
#                                               # at most MAX_MEDIA_BYTES; anything else None
#   sniff_image(bytes)                          # "png" | "jpg" | "gif" | "webp" | "" (never "svg": a file's own bytes only)
#
# `dir` is the media folder itself (Personal Note's: the notes file's folder + "/media").

from std.collections import Optional
from std.os import makedirs
from mojoui.hash import sha256, hex
from mojoui.crypto import b64
from mojoui.files import file_exists, private_write_parts

comptime MAX_MEDIA_BYTES = 20 * 1024 * 1024


def mime_of(ext: String) -> String:
    if ext == "png":
        return "image/png"
    if ext == "jpg":
        return "image/jpeg"
    if ext == "webp":
        return "image/webp"
    if ext == "gif":
        return "image/gif"
    if ext == "svg":
        return "image/svg+xml"
    return ""


def ext_of_suffix(suffix: String) -> String:
    """A file name's suffix as a media extension ("jpeg" → "jpg"; "": not a picture)."""
    var s = suffix.lower()
    if s == "png" or s == "webp" or s == "gif" or s == "svg":
        return s
    if s == "jpg" or s == "jpeg":
        return "jpg"
    return ""


def sniff_image(data: List[UInt8]) -> String:
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


def media_name_ok(name: String) -> Bool:
    """`<64 lowercase hex>.<png|jpg|webp|gif|svg>` (a bare name, no folder): the only names read or written."""
    var b = name.as_bytes()
    if len(b) < 68 or b[64] != UInt8(ord(".")):
        return False
    for k in range(64):
        var c = Int(b[k])
        if not (48 <= c <= 57 or 97 <= c <= 102):
            return False
    var ext = String(name[byte=65:])
    return ext == "png" or ext == "jpg" or ext == "webp" or ext == "gif" or ext == "svg"


def put_media(dir: String, data: List[UInt8], ext: String) raises -> String:
    """The bytes as `dir/<sha256>.<ext>` (written whole under a name of its own, then renamed; left as it is when there);
    "media/<sha256>.<ext>", as notes name it."""
    if mime_of(ext) == "":
        raise Error("not a picture type: " + ext)
    var name = hex(sha256(Span(data))) + "." + ext
    var path = dir + "/" + name
    if not file_exists(path):
        makedirs(dir, exist_ok=True)
        if not private_write_parts(path, [(Int(data.unsafe_ptr()), len(data))]):
            raise Error("couldn't write " + path)
        _ = len(data)
    return "media/" + name


def read_media(dir: String, ref_name: String) -> Optional[List[UInt8]]:
    """The bytes of "media/<name>" (or a bare "<name>") in `dir`; None when the name isn't a media name or there's no file."""
    var name = String(ref_name[byte=6:]) if ref_name.startswith("media/") else ref_name
    if not media_name_ok(name) or not file_exists(dir + "/" + name):
        return None
    try:
        with open(dir + "/" + name, "r") as f:
            return f.read_bytes()
    except:
        return None


def data_url(data: List[UInt8], ext: String) -> String:
    return "data:" + mime_of(ext) + ";base64," + b64(data)


def _sextet(c: UInt8) -> Int:
    var x = Int(c)
    if 65 <= x <= 90:
        return x - 65
    if 97 <= x <= 122:
        return x - 71
    if 48 <= x <= 57:
        return x + 4
    if x == 43:  # +
        return 62
    if x == 47:  # /
        return 63
    return -1


def b64_decode(text: String) -> Optional[List[UInt8]]:
    """Standard base64 (+ and /, '=' padding at the end only); None for anything else (Python's validate=True)."""
    var b = text.as_bytes()
    var n = len(b)
    while n > 0 and b[n - 1] == UInt8(ord("=")):
        n -= 1
    if len(b) % 4 != 0 or len(b) - n > 2:
        return None
    var out = List[UInt8](capacity=n * 3 // 4)
    var acc = 0
    var bits = 0
    for k in range(n):
        var v = _sextet(b[k])
        if v < 0:
            return None
        acc = ((acc << 6) | v) & 0xFFFFFF
        bits += 6
        if bits >= 8:
            bits -= 8
            out.append(UInt8((acc >> bits) & 0xFF))
    return out^


def _hexval(c: UInt8) -> Int:
    var x = Int(c)
    if 48 <= x <= 57:
        return x - 48
    if 97 <= x <= 102:
        return x - 87
    if 65 <= x <= 70:
        return x - 55
    return -1


def decode_data_url(url: String) -> Optional[Tuple[List[UInt8], String]]:
    """(bytes, extension) of a base64 or percent-encoded picture data URL (png, jpeg/jpg, webp, gif, svg+xml; a charset
    allowed), at most MAX_MEDIA_BYTES; None for anything else."""
    var t = String(url.strip())
    if not t.lower().startswith("data:image/"):
        return None
    var comma = t.find(",")
    if comma < 0:
        return None
    var head = String(t[byte=11:comma]).lower()  # "png;base64", "svg+xml;charset=utf-8"
    var parts = head.split(";")
    var kind = String(parts[0])
    var ext = String("svg") if kind == "svg+xml" else ext_of_suffix(kind)
    if ext == "":
        return None
    var base64 = False
    for k in range(1, len(parts)):
        var p = String(parts[k])
        if p == "base64" and k == len(parts) - 1:
            base64 = True
        elif not p.startswith("charset="):
            return None
    var payload = String(t[byte = comma + 1 :])
    var data: List[UInt8]
    if base64:
        var d = b64_decode(payload)
        if not d:
            return None
        data = d.take()
    else:
        var b = payload.as_bytes()
        data = List[UInt8](capacity=len(b))
        var k = 0
        while k < len(b):
            if b[k] == UInt8(ord("%")) and k + 2 < len(b) and _hexval(b[k + 1]) >= 0 and _hexval(b[k + 2]) >= 0:
                data.append(UInt8(_hexval(b[k + 1]) * 16 + _hexval(b[k + 2])))
                k += 3
            else:
                data.append(b[k])
                k += 1
    if len(data) == 0 or len(data) > MAX_MEDIA_BYTES:
        return None
    return (data^, ext)
