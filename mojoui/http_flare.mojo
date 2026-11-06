# mojoui.http_flare: the Flare transport (goal 50 M1, D-4785): https:// (TLS 1.2/1.3 through OpenSSL), redirects,
# compressed replies, behind mojoui.http's Transport seam (D-320), so apps don't change. Flare (vendor/flare, MIT) does
# the wire; this file turns a mojoui Request into Flare's and Flare's reply back into a mojoui Response.
#
# Built in only with -D MOJOUI_FLARE (scripts/mojo_flare.sh, the desktop hosts that ask): Flare runs on Linux and macOS,
# not iOS or Android, and its shims are dlopened (scripts/flare_ffi.sh builds them; $FLARE_LIB_DIR or $CONDA_PREFIX/lib
# finds them). mojoui.effects' AutoTransport picks it for https://, and for http:// too when MOJOUI_HTTP_TRANSPORT=flare.
#
# Differences from SocketTransport: redirects are followed (up to 10, as Flare does by default; a download from Hugging
# Face is a redirect to its CDN); the timeout bounds the connect and each read (Flare has no whole-request deadline); a
# stream sees a cancel when its next bytes arrive (or after the timeout's silence), not every 50 ms.

from std.os import getenv
from std.os.path import exists, getsize
from std.atomic import Atomic
from std.memory.alloc import unsafe_alloc
from mojoui import libc
from mojoui.http import Request, Response, Transport, Url, request_problem, has_control, Sink, SseReader, Piece, utf8_whole, utf8_lossy, MAX_STREAM_CHUNK
from mojoui.clock import now_ns
from flare.http import HttpClient, HeaderMap
from flare.http import Request as FlareRequest
from flare.tls import TlsConfig


def ca_bundle() -> String:
    """The CA certificates TLS trusts: $MOJOUI_CA_BUNDLE, else the pixi env's, else the system's (Linux, then macOS)."""
    var own = getenv("MOJOUI_CA_BUNDLE")
    if own != "":
        return own
    var env = getenv("CONDA_PREFIX")
    if env != "" and exists(env + "/ssl/cacert.pem"):
        return env + "/ssl/cacert.pem"
    for p in ["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/cert.pem"]:
        if exists(p):
            return p
    return ""


def _where(url: Url) -> String:
    return url.host + ":" + String(url.port)


def _client(req: Request) -> HttpClient:
    var t = max(req.timeout_ms, 1)
    return HttpClient(TlsConfig(ca_bundle=ca_bundle()), timeout_ms=t, user_agent="mojoui").with_read_timeout(t)


def _outgoing(req: Request) raises -> FlareRequest:
    """Flare's request for `req`: method, URL, headers (an env header read now, on the worker), body."""
    var body = List[UInt8](capacity=req.body.byte_length())
    for b in req.body.as_bytes():
        body.append(b)
    var out = FlareRequest(method=req.method, url=req.url, body=body^)
    out.headers.set("Accept", "*/*")
    for i in range(len(req.names)):
        out.headers.set(req.names[i], req.values[i])
    for i in range(len(req.env_names)):
        var v = getenv(req.env_vars[i])
        if has_control(v):
            raise Error("$" + req.env_vars[i] + " holds a control character")
        if v.byte_length() > 0:
            out.headers.set(req.env_names[i], v)
    return out^


def _problem(req: Request) -> String:
    """What SocketTransport refuses before anything is sent, the same words ("" when it can go)."""
    try:
        _ = Url.parse(req.url)
    except e:
        return String(e)
    return request_problem(req)


def _failure(e: Error, req: Request) -> String:
    """Flare's error in SocketTransport's words where they have one (a timeout says so)."""
    var text = String(e)
    var where = req.url
    try:
        where = _where(Url.parse(req.url))
    except:
        pass
    if text.find("Timeout") >= 0 or text.find("timed out") >= 0:
        return "timed out after " + String(req.timeout_ms) + " ms waiting for " + where
    return text + " (" + where + ")"


def _headers(h: HeaderMap, mut r: Response):
    for i in range(len(h._keys)):
        r.names.append(h._keys[i].lower())
        r.values.append(h._values[i])


struct FlareTransport(Transport):
    @staticmethod
    def send(req: Request) -> Response:
        var problem = _problem(req)
        if problem != "":
            return Response.failed(problem)
        try:
            var client = _client(req)
            var reply = client.send(_outgoing(req))
            var r = Response()
            r.status = reply.status
            _headers(reply.headers, r)
            r.body = reply.body.copy()
            return r^
        except e:
            return Response.failed(_failure(e, req))

    @staticmethod
    def stream(req: Request, mut sink: Sink) -> Response:
        var problem = _problem(req)
        if problem != "":
            return Response.failed(problem)
        try:
            var client = _client(req)
            var s = client.send_streaming(_outgoing(req))
            var r = Response()
            r.status = s.status
            _headers(s.headers, r)
            if r.status < 200 or r.status >= 300:
                while not s.done():
                    var more = s.read_chunk(65536)
                    if len(more) == 0:
                        break
                    r.body += more^
                return r^
            var sse = r.header("content-type").lower().startswith("text/event-stream")
            var reader = SseReader()
            var pending = List[UInt8]()  # (a UTF-8 character cut across chunks waits for its rest)
            var total = 0
            var began = now_ns()
            while not s.done():
                if sink.cancelled():
                    s.close()
                    return Response.failed("cancelled")
                var chunk = s.read_chunk(MAX_STREAM_CHUNK)
                if len(chunk) == 0:
                    break
                total += len(chunk)
                if total > req.stream_max_bytes:
                    return Response.failed("the stream from " + req.url + " is larger than " + String(req.stream_max_bytes) + " bytes")
                if (now_ns() - began) // 1_000_000 >= req.stream_max_ms:
                    return Response.failed("the stream from " + req.url + " lasted longer than " + String(req.stream_max_ms) + " ms")
                if sse:
                    for piece in reader.feed(Span(chunk)):
                        sink.push(piece.copy())
                    if reader.error != "":
                        return Response.failed("the stream from " + req.url + ": " + reader.error)
                else:
                    pending += chunk^
                    var whole = utf8_whole(pending)
                    if whole > 0:
                        var head = List[UInt8](capacity=whole)
                        for k in range(whole):
                            head.append(pending[k])
                        sink.push(Piece("chunk", utf8_lossy(head)))
                        var rest = List[UInt8]()
                        for k in range(whole, len(pending)):
                            rest.append(pending[k])
                        pending = rest^
            if len(pending) > 0:
                sink.push(Piece("chunk", utf8_lossy(pending)))
            return r^
        except e:
            return Response.failed(_failure(e, req))


# ---- downloads to a file (goal 55: a model's weights; any app's large files) -----------------------------------------

comptime _A = Atomic[Scalar[DType.int64]]
comptime _P = Pointer[Int64, MutUntrackedOrigin]
comptime DOWNLOAD_CHUNK = 4 * 1024 * 1024


struct Transfer(Copyable, Movable):
    """A download's progress and its cancel flag, shared between the thread that downloads and the ones that watch:
    three words on the heap (bytes done, bytes in all (0: not known yet), cancel). Copies share them; whoever made it
    frees it once nobody downloads or watches."""

    var words: Int

    def __init__(out self):
        var w = unsafe_alloc[Int64](3)
        for i in range(3):
            w[i] = 0
        self.words = Int(w)

    def _w(self, k: Int) -> _P:
        return _P(unsafe_from_address=self.words + 8 * k)

    def done(self) -> Int:
        return Int(_A.load(self._w(0)))

    def total(self) -> Int:
        return Int(_A.load(self._w(1)))

    def cancel(self):
        _A.store(self._w(2), 1)

    def cancelled(self) -> Bool:
        return _A.load(self._w(2)) != 0

    def _set(self, k: Int, v: Int):
        _A.store(self._w(k), Int64(v))

    def free(mut self):
        if self.words != 0:
            _P(unsafe_from_address=self.words).unsafe_free()
            self.words = 0


def redirected(req: Request, location: String) raises -> Request:
    """`req` sent on to a redirect's Location (absolute, scheme-relative, host-relative or path-relative); an
    Authorization header stays only while the host does and HTTPS stays HTTPS (a token never follows a redirect to a
    CDN, nor in the clear)."""
    var base = Url.parse(req.url)
    var origin = base.scheme + "://" + base.host + ("" if (base.port == 443 and base.scheme == "https") or (base.port == 80 and base.scheme == "http") else ":" + String(base.port))
    var to: String
    if location.startswith("http://") or location.startswith("https://"):
        to = location
    elif location.startswith("//"):
        to = base.scheme + ":" + location
    elif location.startswith("/"):
        to = origin + location
    else:
        var dir = base.target.split("?")[0]
        to = origin + String(dir[byte=:dir.rfind("/") + 1]) + location
    var out = req.copy()
    out.url = to
    var next = Url.parse(to)
    if next.host != base.host or (base.scheme == "https" and next.scheme != "https"):  # (another host, or https down to http)
        var names = List[String]()
        var values = List[String]()
        for i in range(len(out.names)):
            if out.names[i].lower() != "authorization":
                names.append(out.names[i])
                values.append(out.values[i])
        out.names = names^
        out.values = values^
    return out^


def fetch_to_file(req: Request, path: String, t: Transfer, hops: Int = 10) -> Response:
    """Downloads `req`'s body into `path`, on the calling thread: into `path`.part first (a part already there is
    resumed with a Range request; a server that ignores it starts over), renamed to `path` once whole. `t` counts the
    bytes (a resumed part's included) and is polled for a cancel, which keeps the part for a later resume. The reply's
    status and headers come back; its body is empty, or the error page's when the status isn't 2xx."""
    var problem = _problem(req)
    if problem != "":
        return Response.failed(problem)
    var part = path + ".part"
    try:
        var have = getsize(part) if exists(part) else 0
        var client = _client(req)
        var out = _outgoing(req)
        if have > 0:
            out.headers.set("Range", "bytes=" + String(have) + "-")
        var s = client.send_streaming(out^)
        var r = Response()
        r.status = s.status
        _headers(s.headers, r)
        if r.status == 416 and have > 0:  # (the part is whole, or the file changed: start over)
            s.close()
            _ = libc.unlink(part)
            return fetch_to_file(req, path, t, hops)
        if (r.status == 301 or r.status == 302 or r.status == 303 or r.status == 307 or r.status == 308) and r.header("location") != "":
            s.close()
            if hops <= 0:
                return Response.failed("too many redirects from " + req.url)
            return fetch_to_file(redirected(req, r.header("location")), path, t, hops - 1)
        if r.status < 200 or r.status >= 300:
            while not s.done():
                var more = s.read_chunk(65536)
                if len(more) == 0:
                    break
                r.body += more^
            return r^
        if r.status != 206:
            have = 0  # (a whole body: the server didn't resume)
        t._set(1, 0)  # (this file's total, not the last one's: unknown until a Content-Length says)
        var length = r.header("content-length")
        if length != "":
            try:
                t._set(1, have + atol(length))
            except:
                pass
        t._set(0, have)
        var done = have
        with open(part, "a" if have > 0 else "w") as f:
            while not s.done():
                if t.cancelled():
                    s.close()
                    return Response.failed("cancelled")
                var chunk = s.read_chunk(DOWNLOAD_CHUNK)
                if len(chunk) == 0:
                    break
                f.write_bytes(Span(chunk))
                done += len(chunk)
                t._set(0, done)
        if t.total() > 0 and done != t.total():
            return Response.failed("the download of " + req.url + " ended at " + String(done) + " of " + String(t.total()) + " bytes")
        if libc.rename(part, path) != 0:
            return Response.failed("couldn't rename " + part + " to " + path)
        if r.status == 206:
            r.status = 200
        return r^
    except e:
        return Response.failed(_failure(e, req))


# ---- a stream's chunks with their arrival times (goal 55: benchmarks; time to first token, tokens/s) ----------------

struct TimedStream(Movable):
    """A streamed reply read whole on the calling thread: each chunk's text and when it arrived (ns, mojoui.clock's
    now_ns), and when the request was sent."""

    var status: Int
    var error: String  # "" unless it failed
    var sent_ns: Int
    var chunks: List[String]
    var at_ns: List[Int]

    def __init__(out self):
        self.status = 0
        self.error = ""
        self.sent_ns = 0
        self.chunks = List[String]()
        self.at_ns = List[Int]()


def stream_timed(req: Request, max_bytes: Int = 16 * 1024 * 1024) -> TimedStream:
    """Sends `req` and reads its streamed body chunk by chunk, timing each (an SSE reply: feed the chunks to SseReader
    in order, each piece arriving at its chunk's time). Stops with an error past `max_bytes`."""
    var out = TimedStream()
    var problem = _problem(req)
    if problem != "":
        out.error = problem
        return out^
    try:
        var client = _client(req)
        out.sent_ns = now_ns()
        var s = client.send_streaming(_outgoing(req))
        out.status = s.status
        var total = 0
        var pending = List[UInt8]()
        while not s.done():
            var chunk = s.read_chunk(65536)
            if len(chunk) == 0:
                break
            var at = now_ns()
            total += len(chunk)
            if total > max_bytes:
                s.close()
                out.error = "the stream from " + req.url + " is larger than " + String(max_bytes) + " bytes"
                return out^
            pending += chunk^
            var whole = utf8_whole(pending)  # (a UTF-8 character cut across chunks waits for its rest)
            if whole > 0:
                var head = List[UInt8](capacity=whole)
                for k in range(whole):
                    head.append(pending[k])
                out.chunks.append(utf8_lossy(head))
                out.at_ns.append(at)
                var rest = List[UInt8]()
                for k in range(whole, len(pending)):
                    rest.append(pending[k])
                pending = rest^
        return out^
    except e:
        out.error = _failure(e, req)
        return out^
