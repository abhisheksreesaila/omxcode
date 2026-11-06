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
from std.os.path import exists
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
