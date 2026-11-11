# Goal 66 M0: mojoui.static on its own (no server): content types, ETag + 304, a content-hashed URL cached a year,
# gzip when asked, Range, and every way out of the folder refused with 404.
from std.os import makedirs, getenv
from std.os.path import exists
from mojoui.serve import Req, Reply
from mojoui.static import Static, content_type, safe_relative
from mojoui.hash import sha256, hex
from mojoui import libc
from flare.http.encoding import decompress_gzip


def get(s: Static, target: String, h1: String = "", v1: String = "") -> Reply:
    var r = Req("GET", target)
    if h1 != "":
        r.names.append(h1.lower())
        r.values.append(v1)
    return s.handle(r)


def head(r: Reply, name: String) -> String:
    for i in range(len(r.names)):
        if r.names[i].lower() == name.lower():
            return r.values[i]
    return ""


def text(r: Reply) -> String:
    return String(from_utf8_lossy=Span(r.body))


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error("FAILED: " + what)


def write(path: String, body: String) raises:
    with open(path, "w") as f:
        f.write(body)


def main() raises:
    var dir = getenv("TMPDIR", "/tmp") + "/mojoui-static-" + String(libc.getpid())
    makedirs(dir + "/site/sub", exist_ok=True)
    write(dir + "/outside.txt", "outside the folder")
    var js = String("console.log('hi');\n")
    for _ in range(100):
        js += "// padding so gzip pays off\n"
    write(dir + "/site/app.js", js)
    write(dir + "/site/index.html", "<!doctype html><p>home</p>")
    write(dir + "/site/sub/index.html", "<p>sub</p>")
    write(dir + "/site/.env", "SECRET=1")
    write(dir + "/site/style.css", "body{}")
    var media = String("")
    for i in range(1000):
        media += String(i % 10)
    write(dir + "/site/clip.mp4", media)
    _ = libc.unlink(dir + "/site/leak.txt")
    var p = String(dir + "/outside.txt")
    var l = String(dir + "/site/leak.txt")
    _ = libc._sym("symlink")
    from mojoui.static import _c
    _ = _c[Int]("symlink", Int(p.as_c_string_span().unsafe_ptr()), Int(l.as_c_string_span().unsafe_ptr()))
    _ = p.byte_length() + l.byte_length()

    var s = Static(dir + "/site")
    var app = get(s, "/app.js")
    check(app.status == 200 and text(app) == js, "/app.js")
    check(head(app, "content-type").startswith("text/javascript"), "js type")
    check(content_type("a.woff2") == "font/woff2" and content_type("x.CSS").startswith("text/css") and content_type("v.mp4") == "video/mp4", "types table")
    check(get(s, "/").status == 200 and text(get(s, "/")).find("home") >= 0, "/ is index.html")
    check(text(get(s, "/sub/")).find("sub") >= 0, "a folder's index")
    check(get(s, "/nope.js").status == 404, "missing")
    check(Req("POST", "/app.js").method == "POST" and s.handle(Req("POST", "/app.js")).status == 0, "POST is the app's")
    print("types: ok")

    var etag = head(app, "etag")
    check(etag != "" and get(s, "/app.js", "If-None-Match", etag).status == 304, "304")
    check(get(s, "/app.js", "If-None-Match", '"zzz"').status == 200, "stale etag")
    check(head(app, "cache-control") == "no-cache", "plain URL revalidates")
    print("etag: ok")

    var h = String(hex(sha256(js.as_bytes()))[byte = :10])
    check(s.url("app.js") == "/app." + h + ".js", "url(): " + s.url("app.js"))
    var hashed = get(s, "/app." + h + ".js")
    check(hashed.status == 200 and head(hashed, "cache-control").find("immutable") >= 0 and head(hashed, "cache-control").find("max-age=31536000") >= 0, "hashed")
    check(get(s, "/app.0000000000.js").status == 404, "wrong hash")
    var under = Static(dir + "/site", prefix="/static/")
    check(under.url("app.js") == "/static/app." + h + ".js" and get(under, "/static/app.js").status == 200, "prefix")
    check(get(under, "/app.js").status == 0, "outside the prefix is the app's")
    print("hashed: ok")

    var gz = get(s, "/app.js", "Accept-Encoding", "br, gzip")
    check(head(gz, "content-encoding") == "gzip" and len(gz.body) < js.byte_length(), "gzip")
    var back = decompress_gzip(Span(gz.body))
    check(String(from_utf8_lossy=Span(back)) == js, "gzip round trip")
    check(head(get(s, "/app.js", "Accept-Encoding", "gzip;q=0"), "content-encoding") == "", "q=0")
    check(head(get(s, "/clip.mp4", "Accept-Encoding", "gzip"), "content-encoding") == "", "media isn't gzipped")
    print("gzip: ok")

    var part = get(s, "/clip.mp4", "Range", "bytes=10-19")
    check(part.status == 206 and text(part) == String(media[byte = 10:20]) and head(part, "content-range") == "bytes 10-19/1000", "range")
    check(text(get(s, "/clip.mp4", "Range", "bytes=-5")) == String(media[byte = 995:]), "suffix")
    check(text(get(s, "/clip.mp4", "Range", "bytes=990-")) == String(media[byte = 990:]), "open end")
    check(get(s, "/clip.mp4", "Range", "bytes=2000-").status == 416, "416")
    check(get(s, "/clip.mp4", "Range", "bytes=1-2,5-6").status == 200, "multi: whole")
    print("range: ok")

    var bad = List[String]()
    bad.append("/../outside.txt")
    bad.append("/%2e%2e/outside.txt")
    bad.append("/sub/../../outside.txt")
    bad.append("/.env")
    bad.append("/%2eenv")
    bad.append("/leak.txt")
    bad.append("//etc/passwd")
    bad.append("/%2fetc%2fpasswd")
    bad.append("/app.js%00.txt")
    bad.append("/..%2f..%2foutside.txt")
    bad.append("/sub/./index.html")
    bad.append("/sub\\..\\..\\outside.txt")
    for t in bad:
        var r = get(s, t)
        check(r.status == 404 and text(r).find("outside") < 0 and text(r).find("SECRET") < 0, "refused: " + t + " → " + String(r.status))
    check(not safe_relative("a/../b") and not safe_relative(".git/config") and safe_relative("a/b.js").value() == "a/b.js", "safe_relative")
    print("refuse: ok")
