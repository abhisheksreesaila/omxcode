# mojoui.static: a folder served by mojoui.serve (goal 66 M0). Content types by extension, an ETag from the file's size and
# modified time (If-None-Match → 304), content-hashed URLs (`app.<10 hex of sha256>.js`) cached a year as immutable,
# gzip when the client asks for it (text types only), one byte Range for media (206, 416), and nothing outside the folder:
# `..`, `.` segments, empty segments (`//etc`), dotfiles, NUL and backslashes are refused before the disk is touched, and
# the resolved path (realpath, so a symlink out of the folder) must still be inside it. Every refusal is a plain 404.
#
#   var files = Static("examples/finance_min/static", prefix="/static/")
#   var r = files.handle(req)                 # status 0: not under the prefix (or not GET/HEAD): the app answers it
#   if r.status != 0: return r^
#   files.url("app.js")                       # "/static/app.3f2a9c01de.js" (for a page's <script src>)
#
# Reads the file on each request (no cache; a Range reads only its bytes). Files over MAX_FILE are refused (413) unless
# asked for by a Range.

from std.sys import CompilationTarget
from std.ffi import c_int
from std.memory import Pointer
from mojoui.serve import Req, Reply, decode
from mojoui.hash import sha256, hex
from mojoui.watch import file_stamp
from mojoui.libc import _sym
from flare.http.encoding import compress_gzip

comptime MAX_FILE = 64 * 1024 * 1024  # a whole file read into a reply at most (larger: Range only)
comptime YEAR = "public, max-age=31536000, immutable"
comptime HASH_LEN = 10


def _c[T: RegisterPassable = Int, *A: AnyType](name: String, *args: *A) -> T:
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=_sym(name))
    var f = Pointer(to=raw).unsafe_bitcast[def(*a: *A) thin abi("C") -> T]()[]
    return f(*args)


def real_path(path: String) -> String:
    """The canonical absolute path (symlinks, `..` resolved) or "" when it doesn't exist."""
    var p = path
    var buf = List[UInt8](length=4097, fill=0)
    var r = _c[Int]("realpath", Int(p.as_c_string_span().unsafe_ptr()), Int(buf.unsafe_ptr()))
    _ = p.byte_length()
    if r == 0:
        return ""
    var n = 0
    while n < 4096 and buf[n] != 0:
        n += 1
    return String(from_utf8_lossy=Span(buf)[:n])


def _is_dir(path: String) -> Bool:
    var p = path + "/."
    return real_path(p) != "" and file_stamp(path + "/.")[1] >= 0


def content_type(name: String) -> String:
    var dot = name.rfind(".")
    var ext = String("") if dot < 0 else String(name[byte = dot + 1 :]).lower()
    if ext == "html" or ext == "htm":
        return "text/html; charset=utf-8"
    if ext == "js" or ext == "mjs":
        return "text/javascript; charset=utf-8"
    if ext == "css":
        return "text/css; charset=utf-8"
    if ext == "json" or ext == "map":
        return "application/json"
    if ext == "webmanifest":
        return "application/manifest+json"
    if ext == "txt" or ext == "md":
        return "text/plain; charset=utf-8"
    if ext == "csv":
        return "text/csv; charset=utf-8"
    if ext == "xml":
        return "application/xml"
    if ext == "svg":
        return "image/svg+xml"
    if ext == "png":
        return "image/png"
    if ext == "jpg" or ext == "jpeg":
        return "image/jpeg"
    if ext == "gif":
        return "image/gif"
    if ext == "webp":
        return "image/webp"
    if ext == "avif":
        return "image/avif"
    if ext == "ico":
        return "image/x-icon"
    if ext == "woff2":
        return "font/woff2"
    if ext == "woff":
        return "font/woff"
    if ext == "ttf":
        return "font/ttf"
    if ext == "otf":
        return "font/otf"
    if ext == "wasm":
        return "application/wasm"
    if ext == "mp4" or ext == "m4v":
        return "video/mp4"
    if ext == "webm":
        return "video/webm"
    if ext == "mp3":
        return "audio/mpeg"
    if ext == "m4a":
        return "audio/mp4"
    if ext == "ogg":
        return "audio/ogg"
    if ext == "wav":
        return "audio/wav"
    if ext == "pdf":
        return "application/pdf"
    return "application/octet-stream"


def _compressible(ctype: String) -> Bool:
    return ctype.startswith("text/") or ctype.startswith("application/json") or ctype.startswith("application/xml") or ctype.startswith(
        "application/manifest+json") or ctype.startswith("image/svg") or ctype.startswith("application/wasm")


def safe_relative(path: String) -> Optional[String]:
    """A decoded URL path below a folder, checked: no `..` or `.` segment, no empty segment, no segment starting with a
    dot (dotfiles and dot folders), no NUL, backslash or control byte. "" (the folder itself) is allowed."""
    for b in path.as_bytes():
        if b < 0x20 or b == 0x7F or b == UInt8(ord("\\")):
            return None
    if path == "":
        return String("")
    var out = String("")
    var parts = path.split("/")
    for i in range(len(parts)):
        var s = String(parts[i])
        if s == "":
            if i == len(parts) - 1 and i > 0:  # (a trailing slash: the folder's index)
                continue
            return None
        if s.startswith("."):
            return None
        out += ("/" if out != "" else "") + s
    return out^


def _hashed_name(rel: String) -> Tuple[String, String]:
    """`app.3f2a9c01de.js` → ("app.js", "3f2a9c01de"); ("", "") when the name carries no content hash."""
    var slash = rel.rfind("/")
    var dir = String("") if slash < 0 else String(rel[byte = : slash + 1])
    var name = String(rel) if slash < 0 else String(rel[byte = slash + 1 :])
    var parts = name.split(".")
    if len(parts) < 3:
        return ("", "")
    var h = String(parts[len(parts) - 2])
    if h.byte_length() != HASH_LEN:
        return ("", "")
    for b in h.as_bytes():
        if not ((b >= UInt8(ord("0")) and b <= UInt8(ord("9"))) or (b >= UInt8(ord("a")) and b <= UInt8(ord("f")))):
            return ("", "")
    var plain = String("")
    for i in range(len(parts)):
        if i == len(parts) - 2:
            continue
        plain += ("." if plain != "" else "") + String(parts[i])
    return (dir + plain, h)


def _read(path: String, start: Int, count: Int) raises -> List[UInt8]:
    with open(path, "r") as f:
        if start > 0:
            _ = f.seek(start)
        return f.read_bytes(count)


def _range(spec: String, size: Int) -> Tuple[Int, Int]:
    """One `bytes=a-b` / `bytes=a-` / `bytes=-n` range as (first, last) inclusive; (-1, 0) unsatisfiable or malformed,
    (-2, 0) a form we don't serve (several ranges: the whole file instead)."""
    if not spec.startswith("bytes="):
        return (-2, 0)
    var r = String(spec[byte = 6 :]).strip()
    if r.find(",") >= 0:
        return (-2, 0)
    var dash = r.find("-")
    if dash < 0:
        return (-1, 0)
    var a = String(r[byte = : dash]).strip()
    var b = String(r[byte = dash + 1 :]).strip()
    try:
        if a == "":
            var n = atol(b)
            if n <= 0 or size == 0:
                return (-1, 0)
            return (max(0, size - n), size - 1)
        var first = atol(a)
        var last = size - 1 if b == "" else min(atol(b), size - 1)
        if first < 0 or first >= size or last < first:
            return (-1, 0)
        return (first, last)
    except:
        return (-1, 0)


struct Static(Copyable, Movable):
    var root: String  # the folder, canonical
    var prefix: String  # the URL prefix it answers ("/" or "/static/")

    def __init__(out self, folder: String, prefix: String = "/") raises:
        self.root = real_path(folder)
        if self.root == "":
            raise Error("no such folder: " + folder)
        self.prefix = prefix if prefix.endswith("/") else prefix + "/"

    def _file(self, rel: String) -> String:
        """The canonical path of a regular file inside the folder, or ""."""
        var full = self.root + ("/" + rel if rel != "" else "")
        var real = real_path(full)
        if real == "" or not (real.startswith(self.root + "/") or real == self.root):
            return ""
        if _is_dir(real):
            var idx = real_path(real + "/index.html")
            if idx == "" or not idx.startswith(self.root + "/"):
                return ""
            return idx
        var last = real.rfind("/")
        if String(real[byte = last + 1 :]).startswith("."):  # (a symlink inside the folder to a dotfile)
            return ""
        return real

    def hash_of(self, rel: String) raises -> String:
        var f = self._file(rel)
        if f == "":
            raise Error("no such file: " + rel)
        var stamp = file_stamp(f)
        return String(hex(sha256(_read(f, 0, stamp[1])))[byte = : HASH_LEN])

    def url(self, rel: String) -> String:
        """The content-hashed URL of a file in the folder (the plain URL if it can't be read)."""
        try:
            var h = self.hash_of(rel)
            var dot = rel.rfind(".")
            var slash = rel.rfind("/")
            if dot > slash and dot > 0:
                return self.prefix + String(rel[byte = : dot]) + "." + h + String(rel[byte = dot :])
        except:
            pass
        return self.prefix + rel

    def handle(self, req: Req) -> Reply:
        if req.method != "GET" and req.method != "HEAD":
            return Reply.empty(0)
        var rest: String
        if req.path.startswith(self.prefix):
            rest = String(req.path[byte = self.prefix.byte_length() :])
        elif req.path + "/" == self.prefix:
            rest = ""
        else:
            return Reply.empty(0)
        if rest.find("%2f") >= 0 or rest.find("%2F") >= 0 or rest.find("%5c") >= 0 or rest.find("%5C") >= 0 or rest.find("%00") >= 0:
            return Reply.not_found()  # (an encoded slash or NUL is never part of a file name here)
        var checked = safe_relative(decode(rest))
        if not checked:
            return Reply.not_found()
        var rel = checked.value()
        var immutable = False
        var path = self._file(rel)
        if path == "" or not path.startswith(self.root):
            var hashed = _hashed_name(rel)
            if hashed[0] == "":
                return Reply.not_found()
            path = self._file(hashed[0])
            if path == "":
                return Reply.not_found()
            try:
                var st = file_stamp(path)
                if st[1] > MAX_FILE or String(hex(sha256(_read(path, 0, st[1])))[byte = : HASH_LEN]) != hashed[1]:
                    return Reply.not_found()  # (an old hash: the content changed)
            except:
                return Reply.not_found()
            immutable = True
        return self._send(req, path, immutable)

    def _send(self, req: Req, path: String, immutable: Bool) -> Reply:
        var stamp = file_stamp(path)
        var size = stamp[1]
        if size < 0:
            return Reply.not_found()
        var ctype = content_type(path)
        var etag = '"' + hex_int(size) + "-" + hex_int(stamp[0]) + '"'
        var cache = YEAR if immutable else "no-cache"  # (no-cache: kept, but revalidated with the ETag)
        var inm = req.header("if-none-match")
        if inm != "" and (inm == etag or inm.find(etag) >= 0 or inm == "*"):
            return Reply(304, "", "").header("ETag", etag).header("Cache-Control", cache)
        var rng = req.header("range")
        try:
            if rng != "":
                var r = _range(rng, size)
                if r[0] == -1:
                    return Reply(416, "text/plain; charset=utf-8", "").header("Content-Range", "bytes */" + String(size)).header("Accept-Ranges", "bytes")
                if r[0] >= 0:
                    var out = Reply(206, ctype, "")
                    out.body = _read(path, r[0], r[1] - r[0] + 1)
                    return out^.header("Content-Range", "bytes " + String(r[0]) + "-" + String(r[1]) + "/" + String(size)).header(
                        "Accept-Ranges", "bytes").header("ETag", etag).header("Cache-Control", cache)
            if size > MAX_FILE:
                return Reply.error(413, "too large to send whole: ask for a Range", "too_large")
            var out = Reply(200, ctype, "")
            out.body = _read(path, 0, size)
            var compress = _compressible(ctype)
            var gz = compress and size >= 256 and _accepts_gzip(req.header("accept-encoding"))
            if gz:
                out.body = compress_gzip(Span(out.body))
            out = out^.header("ETag", etag).header("Cache-Control", cache).header("Accept-Ranges", "bytes").header(
                "X-Content-Type-Options", "nosniff")
            if compress:
                out = out^.header("Vary", "Accept-Encoding")
            if gz:
                out = out^.header("Content-Encoding", "gzip")
            return out^
        except e:
            return Reply.error(500, "can't read the file", "read_failed")


def _accepts_gzip(header: String) -> Bool:
    for part in header.lower().split(","):
        var p = String(part).strip()
        var semi = p.find(";")
        var name = String(p) if semi < 0 else String(String(p[byte = : semi]).strip())
        if name == "gzip" or name == "*":
            var q = String("") if semi < 0 else String(p[byte = semi + 1 :]).replace(" ", "")
            if q == "q=0" or q.startswith("q=0.0") and q.replace("0", "").replace(".", "") == "q=":
                return False
            return True
    return False


def hex_int(n: Int) -> String:
    if n == 0:
        return "0"
    var digits = "0123456789abcdef"
    var out = String("")
    var v = n if n > 0 else -n
    while v > 0:
        out = String(digits[byte = v % 16 : v % 16 + 1]) + out
        v //= 16
    return out^
