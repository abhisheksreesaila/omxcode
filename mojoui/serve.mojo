# mojoui.serve: any Mojo app answers HTTP (goal 50 M2, D-4787). Flare's server (vendor/flare, MIT) does the wire:
# HTTP/1.1 keep-alive, chunked streaming, workers; this file is the app's side of it: a request in, a reply out, from the
# app's own state, which one lock guards (one request at a time touches it, whichever worker it came in on).
#
#   struct Api(Service):
#       var items: List[String]
#       def answer(mut self, mut req: Req) -> Reply:
#           if req.matches("GET", "/items/{id}"):
#               return Reply.json('{"id": ' + json_string(req.param("id")) + '}')
#           if req.matches("POST", "/items"):
#               self.items.append(req.body)
#               return Reply.json('{"ok": true}', 201)
#           return Reply.not_found()
#
#   Server.run(Api(), port=8080)                  # blocks; Server.start(...) runs it on a thread: see Served
#
# Streams: a reply can be a Pipe, a byte queue another thread fills while the client reads (SSE, a long log, a proxied
# upstream). `proxy(request, pipe)` relays an upstream reply into one byte for byte, on its own thread: what an API
# gateway does. Built with -D MOJOUI_FLARE (scripts/mojo_flare.sh); Linux and macOS.
# Limit: Reply.stream(pipe, wait_head_ms) holds a server worker while it waits for the upstream's head, so a proxy to the
# same server can wait on itself (its upstream request may land on that worker); proxy to another process (D-4777).
# SIGTERM / SIGINT: Service.stop() runs under the lock, then the process exits (a byte on a socket; see _on_stop_signal).
# One Server per process handles them (the first); a Service's ticker lives as long as the process.
# Server.start returns a Served: keep it while you serve; dropping it stops the server. Flare 0.13 runs its workers on
# Mojo's runtime pool, and a program can't end while a serving loop holds a pool worker (goal 52).
#
# Concurrent servers (goal 60, D-6007, D-6008): a `Handler` (answer(self, …): an immutable self, its state thread-safe)
# runs on every worker at once, no lock: `Server.serve(handler, port, log=Log.open(path))`. Requests its `blocking()`
# names (ones that call Google or Stripe) leave the reactor: Flare hands their socket over (the vendored offload patch)
# to a small fixed pool of offload threads, made when serving starts (`offload_threads`, 16; their SQLite connections
# stay open between requests), behind a bounded queue (`offload_queue`, 64): one answers with `Connection: close`, so a
# slow provider stalls nobody else; past the threads and the queue, 503 with Retry-After (D-6033). Every reply
# carries X-Request-Id; every request is one JSON line in the log (path without its query, status, ms, ip).
# mojoui.serve binds cleartext only (TLS ends in front of it), which the offload needs: Flare offloads a cleartext
# connection only (a TLS one would answer the bridge's 503 placeholder).

from std.os import getenv
from std.sys import CompilationTarget, exit
from std.memory.alloc import unsafe_alloc
from std.ffi import c_int, get_errno, ErrNo
from std.atomic import Atomic
from mojoui import libc
from mojoui.http import Request, utf8_lossy
from mojoui.json import json_string
from mojoui.clock import now_ns
from mojoui.log import Log, Fields
from mojoui.crypto import random_bytes
from mojoui.hash import hex
from mojoui.clientip import TrustedProxies, client_ip
from flare.http import HttpServer, HeaderMap, Cancel, ChunkSource, stream_response, HttpClient
from flare.http import Request as FlareRequest
from flare.http import Handler as FlareHandler
from flare.http import Response as FlareResponse
from flare.http._server.config import ServerConfig
from flare.net import SocketAddr, IpAddr
from flare.tls import TlsConfig
from flare.runtime._asyncrt import asyncrt_try_lease

comptime _A = Atomic[Scalar[DType.int64]]
comptime _P = Pointer[Int64, MutUntrackedOrigin]


# requests -----------------------------------------------------------------------------------------------------------

struct Req(Copyable, Movable):
    """One request as the app sees it: method, path (no query), the raw query, headers (lower-case names), the body as
    text, and the path's {parameters} once `matches` has read them."""

    var method: String
    var path: String
    var query: String
    var names: List[String]
    var values: List[String]
    var body: String
    var param_names: List[String]
    var param_values: List[String]
    var peer: String  # the socket's peer, as the kernel reported it ("" in a test)
    var client: String  # the client's IP: the peer, or X-Forwarded-For's rightmost untrusted hop from a trusted proxy (mojoui.clientip)
    var rid: String  # this request's id (X-Request-Id on the reply, `rid` in the log)

    def __init__(out self, method: String, target: String, body: String = ""):
        self.method = method
        var q = target.find("?")
        self.path = String(target) if q < 0 else String(target[byte = : q])
        self.query = String("") if q < 0 else String(target[byte = q + 1 :])
        self.names = List[String]()
        self.values = List[String]()
        self.body = body
        self.param_names = List[String]()
        self.param_values = List[String]()
        self.peer = String("")
        self.client = String("")
        self.rid = String("")

    def header(self, name: String) -> String:
        """A request header's value ("" when absent); any case."""
        var n = name.lower()
        for i in range(len(self.names)):
            if self.names[i] == n:
                return self.values[i]
        return ""

    def header_all(self, name: String, sep: String = ", ") -> String:
        """Every line of a header joined in order (RFC 9110 §5.3: repeated lines mean one comma-joined value; cookies
        join with "; "): a proxy may add its own X-Forwarded-For line after the client's."""
        var n = name.lower()
        var out = String("")
        var first = True
        for i in range(len(self.names)):
            if self.names[i] == n:
                out += ("" if first else sep) + self.values[i]
                first = False
        return out^

    def arg(self, name: String, default: String = "") -> String:
        """A query value, %-decoded (`?limit=40` → arg("limit") == "40")."""
        for part in self.query.split("&"):
            var eq = part.find("=")
            var k = String(part) if eq < 0 else String(part[byte = : eq])
            if decode(k) == name:
                return decode(String("") if eq < 0 else String(part[byte = eq + 1 :]))
        return default

    def param(self, name: String) -> String:
        """A path parameter `matches` read (`/models/{name}`), %-decoded."""
        for i in range(len(self.param_names)):
            if self.param_names[i] == name:
                return self.param_values[i]
        return ""

    def matches(mut self, method: String, pattern: String) -> Bool:
        """True when the method is `method` and the path fits `pattern`: literal parts match exactly, `{name}` takes one
        part, `{name*}` (last) takes the rest. The parameters are kept for `param`."""
        if self.method != method:
            return False
        var want = pattern.split("/")
        var got = self.path.split("/")
        var names = List[String]()
        var values = List[String]()
        for i in range(len(want)):
            var w = String(want[i])
            if w.startswith("{") and w.endswith("*}"):
                var rest = String("")
                for k in range(i, len(got)):
                    rest += ("/" if k > i else "") + String(got[k])
                names.append(String(w[byte = 1 : w.byte_length() - 2]))
                values.append(decode(rest))
                self.param_names = names^
                self.param_values = values^
                return True
            if i >= len(got):
                return False
            if w.startswith("{") and w.endswith("}"):
                if got[i].byte_length() == 0:
                    return False
                names.append(String(w[byte = 1 : w.byte_length() - 1]))
                values.append(decode(String(got[i])))
            elif w != got[i]:
                return False
        if len(got) != len(want):
            return False
        self.param_names = names^
        self.param_values = values^
        return True


def escape_html(s: String) -> String:
    """Text safe inside HTML elements and quoted attributes."""
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;").replace("'", "&#39;")


def decode(s: String) -> String:
    """%XX and '+' decoded (a query value or a path part); bad escapes stay as they are."""
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == 43:  # '+'
            out.append(32)
        elif c == 37 and i + 2 < len(b) and _hex(b[i + 1]) >= 0 and _hex(b[i + 2]) >= 0:
            out.append(UInt8(_hex(b[i + 1]) * 16 + _hex(b[i + 2])))
            i += 2
        else:
            out.append(c)
        i += 1
    return utf8_lossy(out)  # (escapes that aren't UTF-8, %FF or a lone %C3, become U+FFFD, never a broken String)


def _hex(c: UInt8) -> Int:
    var x = Int(c)
    if x >= 48 and x <= 57:
        return x - 48
    if x >= 97 and x <= 102:
        return x - 87
    if x >= 65 and x <= 70:
        return x - 55
    return -1


# pipes: a stream another thread fills --------------------------------------------------------------------------------

comptime _LOCK_BYTES = 64
comptime P_LOCK = 0  # the mutex's address
comptime P_DATA = 1  # a List[UInt8]'s address: bytes written, not yet read
comptime P_CLOSED = 2  # 1: the writer is done
comptime P_GONE = 3  # 1: the reader left (the client went away)
comptime P_REFS = 4  # owners; the last frees
comptime P_STATUS = 5  # a proxied upstream's status (0 until its head arrived; -1: it failed)
comptime P_TYPE = 6  # a String's address: the upstream's Content-Type
comptime P_TOTAL = 7  # bytes written in all
comptime P_KEEP = 8  # a List[UInt8]'s address: a copy of everything written, up to P_KEEP_MAX (0: keep none)
comptime P_KEEP_MAX = 9
comptime P_STARTED = 10  # now_ns when made
comptime P_ENDED = 11  # now_ns when closed
comptime P_FIRST = 12  # now_ns when the first bytes were written
comptime P_WORDS = 13


struct Pipe(ImplicitlyCopyable, Movable):
    """A handle on a byte queue: one side writes (any thread), a reply streams it out. Handles are copies of one address;
    `release` once per handle you were given (Pipe() gives one, `share` another); the queue is freed with the last."""

    var addr: Int

    def __init__(out self, keep_bytes: Int = 0):
        """`keep_bytes`: also keep a copy of the first this-many bytes written (read with `kept` after it's closed),
        e.g. a chat reply to log."""
        var w = unsafe_alloc[Int64](P_WORDS)
        for i in range(P_WORDS):
            (w + i)[] = 0
        var lock = Int(unsafe_alloc[UInt8](_LOCK_BYTES))
        _ = libc.pthread_mutex_init(lock)
        (w + P_LOCK)[] = Int64(lock)
        var data = unsafe_alloc[List[UInt8]](1)
        data.unsafe_write(List[UInt8]())
        (w + P_DATA)[] = Int64(Int(data))
        var ty = unsafe_alloc[String](1)
        ty.unsafe_write(String(""))
        (w + P_TYPE)[] = Int64(Int(ty))
        var keep = unsafe_alloc[List[UInt8]](1)
        keep.unsafe_write(List[UInt8]())
        (w + P_KEEP)[] = Int64(Int(keep))
        (w + P_KEEP_MAX)[] = Int64(keep_bytes)
        (w + P_REFS)[] = 1
        (w + P_STARTED)[] = Int64(now_ns())
        self.addr = Int(w)

    def __init__(out self, *, addr: Int):
        self.addr = addr

    @staticmethod
    def at(addr: Int) -> Pipe:
        return Pipe(addr=addr)

    def _w(self, k: Int) -> _P:
        return _P(unsafe_from_address=self.addr + k * 8)

    def _lock(self):
        _ = libc.pthread_mutex_lock(Int(self._w(P_LOCK)[]))

    def _unlock(self):
        _ = libc.pthread_mutex_unlock(Int(self._w(P_LOCK)[]))

    def share(self) -> Pipe:
        """One more owner (a thread you hand it to); it releases its own."""
        _ = _A.fetch_add(self._w(P_REFS), 1)
        return Pipe.at(self.addr)

    def release(self):
        if self.addr == 0:
            return
        if _A.fetch_add(self._w(P_REFS), -1) != 1:
            return
        var lock = Int(self._w(P_LOCK)[])
        _ = libc.pthread_mutex_destroy(lock)
        Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=lock).unsafe_free()
        for k in [P_DATA, P_KEEP]:
            var d = Pointer[List[UInt8], MutUntrackedOrigin](unsafe_from_address=Int(self._w(k)[]))
            d.unsafe_deinit_pointee()
            d.unsafe_free()
        var t = Pointer[String, MutUntrackedOrigin](unsafe_from_address=Int(self._w(P_TYPE)[]))
        t.unsafe_deinit_pointee()
        t.unsafe_free()
        _P(unsafe_from_address=self.addr).unsafe_free()

    def write(self, bytes: Span[UInt8, _]):
        """Queue bytes for the reader (nothing when the reader has gone)."""
        if len(bytes) == 0:
            return
        self._lock()
        if self._w(P_FIRST)[] == 0:
            self._w(P_FIRST)[] = Int64(now_ns())
        var d = Pointer[List[UInt8], MutUntrackedOrigin](unsafe_from_address=Int(self._w(P_DATA)[]))
        if self._w(P_GONE)[] == 0:
            for b in bytes:
                d[].append(b)
        var k = Pointer[List[UInt8], MutUntrackedOrigin](unsafe_from_address=Int(self._w(P_KEEP)[]))
        var room = Int(self._w(P_KEEP_MAX)[]) - len(k[])
        for i in range(min(room, len(bytes))):
            k[].append(bytes[i])
        self._w(P_TOTAL)[] += Int64(len(bytes))
        self._unlock()

    def write(self, text: String):
        self.write(text.as_bytes())

    def close(self):
        """The writer is done: the reply ends once the reader has what was queued."""
        self._lock()
        self._w(P_CLOSED)[] = 1
        self._w(P_ENDED)[] = Int64(now_ns())
        self._unlock()

    def closed(self) -> Bool:
        return _A.load(self._w(P_CLOSED)) == 1

    def gone(self) -> Bool:
        """The client went away (or the reply was never sent): a writer can stop."""
        return _A.load(self._w(P_GONE)) == 1

    def set_head(self, status: Int, content_type: String):
        """A proxied upstream's status and Content-Type (Reply.stream waits for them a moment)."""
        self._lock()
        Pointer[String, MutUntrackedOrigin](unsafe_from_address=Int(self._w(P_TYPE)[]))[] = content_type
        self._w(P_STATUS)[] = Int64(status)
        self._unlock()

    def status(self) -> Int:
        return Int(_A.load(self._w(P_STATUS)))

    def content_type(self) -> String:
        self._lock()
        var t = Pointer[String, MutUntrackedOrigin](unsafe_from_address=Int(self._w(P_TYPE)[]))[].copy()
        self._unlock()
        return t^

    def total(self) -> Int:
        return Int(_A.load(self._w(P_TOTAL)))

    def kept(self) -> String:
        """The copy of the first bytes written (Pipe(keep_bytes=…)), as text."""
        self._lock()
        var k = Pointer[List[UInt8], MutUntrackedOrigin](unsafe_from_address=Int(self._w(P_KEEP)[]))[].copy()
        self._unlock()
        return String(unsafe_from_utf8=k)

    def millis(self) -> Int:
        """From making it to closing it (or to now, while open)."""
        var end = Int(_A.load(self._w(P_ENDED)))
        return ((end if end > 0 else now_ns()) - Int(self._w(P_STARTED)[])) // 1_000_000

    def first_ms(self) -> Int:
        """From making it to the first bytes written (-1: none yet)."""
        var f = Int(_A.load(self._w(P_FIRST)))
        return -1 if f == 0 else (f - Int(self._w(P_STARTED)[])) // 1_000_000

    def _take(self) -> Optional[List[UInt8]]:
        """The reader's side: what's queued (empty: nothing now), or None when closed and drained."""
        self._lock()
        var d = Pointer[List[UInt8], MutUntrackedOrigin](unsafe_from_address=Int(self._w(P_DATA)[]))
        var out = d[].copy()
        d[].clear()
        var done = self._w(P_CLOSED)[] == 1
        self._unlock()
        if len(out) == 0 and done:
            return None
        return out^

    def _leave(self):
        _A.store(self._w(P_GONE), 1)


struct _PipeSource(ChunkSource):
    """Flare's side of a Pipe: the reactor pulls chunks. With nothing queued it waits up to 2 ms before saying "nothing
    now" (an empty chunk), so an idle stream doesn't spin a worker (Flare re-polls a live source on every writable edge)."""

    var pipe: Pipe

    def __init__(out self, pipe: Pipe):
        self.pipe = pipe

    def next(mut self, cancel: Cancel) raises -> Optional[List[UInt8]]:
        if cancel.cancelled():
            self.pipe._leave()
            return None
        for _ in range(2):
            var got = self.pipe._take()
            if not got:
                return None
            if len(got.value()) > 0:
                return got^
            _ = libc.poll(0, 0, 1)  # (1 ms)
        return List[UInt8]()

    def __deinit__(deinit self):
        self.pipe._leave()
        self.pipe.release()


# replies ------------------------------------------------------------------------------------------------------------

struct Reply(Movable):
    var status: Int
    var names: List[String]
    var values: List[String]
    var body: List[UInt8]
    var pipe: Int  # a Pipe's address (0: the body is the reply)
    var wait_head_ms: Int

    def __init__(out self, status: Int, content_type: String, body: String):
        self.status = status
        self.names = List[String]()
        self.values = List[String]()
        self.body = List[UInt8](capacity=body.byte_length())
        for b in body.as_bytes():
            self.body.append(b)
        self.pipe = 0
        self.wait_head_ms = 0
        if content_type != "":
            self.names.append("Content-Type")
            self.values.append(content_type)

    @staticmethod
    def json(text: String, status: Int = 200) -> Reply:
        return Reply(status, "application/json", text)

    @staticmethod
    def text(text: String, status: Int = 200) -> Reply:
        return Reply(status, "text/plain; charset=utf-8", text)

    @staticmethod
    def empty(status: Int = 204) -> Reply:
        return Reply(status, "", "")

    @staticmethod
    def error(status: Int, message: String, code: String = "") -> Reply:
        """{"error": {"message", "code"}} (OpenAI's shape, which the console reads too)."""
        return Reply.json('{"error": {"message": ' + json_string(message) + ', "code": ' + json_string(code) + "}}", status)

    @staticmethod
    def html(text: String, status: Int = 200) -> Reply:
        """A page (build it with escape_html around every value): never framed, no scripts from elsewhere."""
        return Reply(status, "text/html; charset=utf-8", text).header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")

    @staticmethod
    def not_found() -> Reply:
        return Reply.error(404, "no such route", "not_found")

    @staticmethod
    def stream(pipe: Pipe, content_type: String = "text/event-stream", wait_head_ms: Int = 0) -> Reply:
        """Stream `pipe` to the client (takes a share of it). `wait_head_ms` > 0: first wait that long for the pipe's head
        (a proxy sets it): its status and Content-Type become the reply's."""
        var r = Reply(200, content_type, "")
        r.pipe = pipe.share().addr
        r.wait_head_ms = wait_head_ms
        if content_type == "text/event-stream":
            r.names.append("Cache-Control")
            r.values.append("no-cache")
        return r^

    def header(var self, name: String, value: String) -> Self:
        self.names.append(name)
        self.values.append(value)
        return self^

    def __deinit__(deinit self):
        if self.pipe != 0:  # (a stream reply never handed to Flare: its share of the pipe goes)
            var p = Pipe.at(self.pipe)
            p._leave()
            p.release()


# the app's side -----------------------------------------------------------------------------------------------------

trait Service(Movable, Deinitable):
    def answer(mut self, mut req: Req) -> Reply:
        ...

    def tick(mut self):
        """Called every `tick_ms` (Server.run/start), under the same lock as answer(): timers, sweeps, idle work."""
        ...

    def stop(mut self):
        """The process got SIGTERM or SIGINT: tidy up (children, files) under the lock; the process exits after."""
        ...


comptime S_LOCK = 0
comptime S_APP = 1
comptime S_MAX_BODY = 2


@fieldwise_init
struct _Bridge[S: Service](Copyable, FlareHandler):
    """Flare's Handler: every worker holds a copy (just the address of the app and its lock)."""

    var state: Int

    def serve(self, req: FlareRequest) raises -> FlareResponse:
        var r = Req(req.method, _target(req.url), _text(req.body))
        if r.path == READY_PATH:  # (Server.start's own probe, never the app's)
            return _flare_reply(Reply.empty())
        for i in range(len(req.headers._keys)):
            r.names.append(req.headers._keys[i].lower())
            r.values.append(req.headers._values[i])
        var w = _P(unsafe_from_address=self.state)
        var lock = Int((w + S_LOCK)[])
        var app = Pointer[Self.S, MutUntrackedOrigin](unsafe_from_address=Int((w + S_APP)[]))
        _ = libc.pthread_mutex_lock(lock)
        var reply = app[].answer(r)
        _ = libc.pthread_mutex_unlock(lock)
        return _flare_reply(reply^)


def _target(url: String) -> String:
    """The path and query of a request line's target (a full URL too)."""
    var s = url.find("://")
    if s < 0:
        return url
    var slash = url.find("/", s + 3)
    return String("/") if slash < 0 else String(url[byte = slash :])


def _text(b: List[UInt8]) -> String:
    try:
        return String(from_utf8=Span(b))
    except:
        return utf8_lossy(b)


def _flare_reply(var reply: Reply) raises -> FlareResponse:
    if reply.pipe != 0:
        var pipe = Pipe.at(reply.pipe)
        var status = reply.status
        var ctype = String("")
        if reply.wait_head_ms > 0:
            var until = now_ns() + reply.wait_head_ms * 1_000_000
            while pipe.status() == 0 and now_ns() < until:
                _ = libc.poll(0, 0, 2)
            if pipe.status() > 0:
                status = pipe.status()
                ctype = pipe.content_type()
        reply.pipe = 0  # (the source owns the share from here)
        var out = stream_response[_PipeSource](_PipeSource(pipe), status)
        for i in range(len(reply.names)):
            if ctype != "" and reply.names[i].lower() == "content-type":
                out.headers.set("Content-Type", ctype)
            else:
                out.headers.set(reply.names[i], reply.values[i])
        return out^
    var out = FlareResponse(status=reply.status, body=reply.body.copy())
    for i in range(len(reply.names)):
        out.headers.set(reply.names[i], reply.values[i])
    return out^


def _keep_the_pool_for_compute():
    """Flare 0.13 runs serving loops as tasks on Mojo's runtime pool while it may lease pool workers, on OS threads once
    they're all held. A loop never returns its worker, and work an app puts on the pool (`parallelize`: the omxcore
    engine's kernels, MAX) then waits on tasks queued behind it: an engine job inside a request hung (goal 52). Holding
    every lease first sends Flare's loops to OS threads, in every server of the process (each call after the first
    finds none left). Upstream: https://github.com/ehsanmok/flare/issues/47."""
    while asyncrt_try_lease():
        pass


struct Server:
    @staticmethod
    def bind(port: Int, host: String = "127.0.0.1", max_body: Int = 64 * 1024 * 1024, request_timeout_ms: Int = 600_000) raises -> HttpServer:
        """A listening Flare server. `max_body`: Flare refuses a bigger request body (413) as it reads it;
        `request_timeout_ms`: a request's head and body must arrive within it (a slow sender can't hold a connection
        longer). A Service keeps the wide defaults (uploads, long streams); `serve()`'s Handlers default to 1 MB, 30 s."""
        _keep_the_pool_for_compute()
        var cfg = ServerConfig(idle_timeout_ms=30_000, handler_timeout_ms=600_000, request_timeout_ms=request_timeout_ms, write_timeout_ms=60_000)
        cfg.max_body_size = max_body
        return HttpServer.bind(SocketAddr(IpAddr(host, False), UInt16(port)), cfg^)

    @staticmethod
    def _state[S: Service](var service: S) -> Int:
        var w = unsafe_alloc[Int64](4)
        var lock = Int(unsafe_alloc[UInt8](_LOCK_BYTES))
        _ = libc.pthread_mutex_init(lock)
        var app = unsafe_alloc[S](1)
        app.unsafe_write(service^)
        (w + S_LOCK)[] = Int64(lock)
        (w + S_APP)[] = Int64(Int(app))
        return Int(w)

    @staticmethod
    def run[S: Service](var service: S, port: Int, host: String = "127.0.0.1", workers: Int = 8, tick_ms: Int = 0) raises:
        """Serves until the process ends. `workers` reactors (threads) share the port; the app's answer() runs under one
        lock either way. `tick_ms` > 0: tick() that often, on a thread of its own."""
        var handles_signals = Server._install_stop_handler()
        var srv = Server.bind(port, host)
        var state = Server._state(service^)
        if tick_ms > 0:
            Server._ticker[S](state, tick_ms)
        if handles_signals:
            Server._watch_stop[S](state)
        if workers <= 1:
            srv.serve(_Bridge[S](state))
        else:
            srv.serve(_Bridge[S](state), num_workers=workers, pin_cores=False)

    @staticmethod
    def _install_stop_handler() -> Bool:
        """SIGTERM and SIGINT turned into a byte on a socket (the self-pipe trick): Mojo has no globals for a handler to
        set, and the runtime's own threads exist before main, so blocking the signals can't cover them. The handler only
        calls send() on the fixed descriptor STOP_FD (async-signal-safe, no memory); the stop watcher reads the byte.
        One per process: False (no handler, no watcher) when STOP_FD or STOP_FD + 1 is already open (another Server in
        this process has them, or the program uses those numbers) or the socket can't be made."""
        if libc.fcntl(STOP_FD, 1) >= 0 or libc.fcntl(STOP_FD + 1, 1) >= 0:  # (F_GETFD: open already)
            return False
        var fds = List[Int32](length=2, fill=-1)
        if libc.socketpair(1, 1, 0, Int(fds.unsafe_ptr())) != 0:  # (AF_UNIX, SOCK_STREAM)
            return False
        var ok = libc.dup2(Int(fds[1]), STOP_FD) == STOP_FD and libc.dup2(Int(fds[0]), STOP_FD + 1) == STOP_FD + 1
        _ = libc.close(Int(fds[1]))
        _ = libc.close(Int(fds[0]))
        if not ok:
            _ = libc.close(STOP_FD)
            _ = libc.close(STOP_FD + 1)
            return False
        _ = libc.fcntl(STOP_FD, 2, 1)  # (F_SETFD FD_CLOEXEC: children, max serve too, don't inherit them)
        _ = libc.fcntl(STOP_FD + 1, 2, 1)
        _ = libc.signal(15, _on_stop_signal)
        _ = libc.signal(2, _on_stop_signal)
        return True

    @staticmethod
    def _watch_stop[S: Service](state: Int) raises:
        if not spawn[_stop_loop[S]](state):
            raise Error("no thread for the server's stop watcher")

    @staticmethod
    def _ticker[S: Service](state: Int, every_ms: Int) raises:
        var w = unsafe_alloc[Int64](2)
        w[0] = Int64(state)
        w[1] = Int64(every_ms)
        if not spawn[_tick_loop[S]](Int(w)):
            raise Error("no thread for the server's tick")

    @staticmethod
    def start[S: Service](var service: S, port: Int = 0, host: String = "127.0.0.1", workers: Int = 4, tick_ms: Int = 0) raises -> Served:
        """Serves on a thread of its own until the returned Served is dropped (or stopped); `.port` is the port (port 0:
        one the system picks). Returns once the workers answer (Flare's workers bind their own listeners after the first
        one closes: connecting at once could be refused)."""
        var handles_signals = Server._install_stop_handler()
        var srv = Server.bind(port, host)
        var bound = Int(srv.local_addr().port)
        var st = Server._state(service^)
        if tick_ms > 0:
            Server._ticker[S](st, tick_ms)
        if handles_signals:
            Server._watch_stop[S](st)
        var job = unsafe_alloc[_Run[S]](1)
        job.unsafe_write(_Run[S](srv^, st, workers))
        var tid = List[Int](length=1, fill=0)
        if libc.pthread_create[_run_entry[S]](Int(job), Int(tid.unsafe_ptr())) != 0:
            job.unsafe_deinit_pointee()  # (no thread: nothing else holds the record)
            job.unsafe_free()
            raise Error("no thread for the server")
        _ = libc.pthread_detach(tid[0])
        var served = Served(bound, Int(job), _close_run[S], _ended_run[S], _release_run[S])
        if not _answers(host, bound, 5000):
            raise Error("the server on port " + String(bound) + " didn't start answering")
        return served^


comptime READY_PATH = "/.mojoui/ready"


def _answers(host: String, port: Int, ms: Int) -> Bool:
    """Does something answer an HTTP request on host:port within `ms`? (A 404 counts: a worker read it.)"""
    var until = now_ns() + ms * 1_000_000
    while now_ns() < until:
        try:
            # (50 ms each: a probe that reached the listener Flare is about to close waits out its whole timeout,
            # which held a UI thread 515 ms with 500; loopback answers in about 1 ms; flare#48)
            _ = HttpClient(timeout_ms=50).get("http://" + host + ":" + String(port) + READY_PATH)
            return True
        except:
            _ = libc.poll(0, 0, 5)
    return False


struct Served(Movable):
    """A server Server.start runs on threads of its own. Keep it while you serve: dropping it (or stop()) closes the
    server. Mojo drops a value after its last use, so call `stop()` where serving should end (`var port =
    Server.start(api).port` would stop it at once). stop() returns at once, so a UI thread can call it: the loop ends
    on its own thread (Flare looks every 50 ms, then lets its workers finish); `stopped()` says when it has."""
    var port: Int
    var _job: Int
    var _closed: Bool
    var _close: def(Int) thin -> None
    var _ended: def(Int) thin -> Bool
    var _release: def(Int) thin -> None

    def __init__(out self, port: Int, job: Int, close: def(Int) thin -> None, ended: def(Int) thin -> Bool,
                 release: def(Int) thin -> None):
        self.port = port
        self._job = job
        self._closed = False
        self._close = close
        self._ended = ended
        self._release = release

    def stop(mut self):
        if not self._closed:
            self._close(self._job)
            self._closed = True

    def stopped(self) -> Bool:
        """Has the server's loop ended? (False while serving.)"""
        return self._ended(self._job)

    def __deinit__(deinit self):
        if not self._closed:
            self._close(self._job)
        self._release(self._job)


struct _Run[S: Service](Movable):
    """A started server, shared by its Served and its thread: the last of the two to let go frees it, so neither
    ever reads it freed."""
    var srv: HttpServer
    var state: Int
    var workers: Int
    var refs: Scalar[DType.int64]   # (atomic: 2 at the start, the Served and the thread)
    var ended: Scalar[DType.int64]  # (atomic: 1 once serve() returned)

    def __init__(out self, var srv: HttpServer, state: Int, workers: Int):
        self.srv = srv^
        self.state = state
        self.workers = workers
        self.refs = 2
        self.ended = 0


def _close_run[S: Service](addr: Int):
    Pointer[_Run[S], MutUntrackedOrigin](unsafe_from_address=addr)[].srv.close()


def _ended_run[S: Service](addr: Int) -> Bool:
    var job = Pointer[_Run[S], MutUntrackedOrigin](unsafe_from_address=addr)
    return _A.load(_P(unsafe_from_address=Int(Pointer(to=job[].ended)))) >= 1


def _release_run[S: Service](addr: Int):
    var job = Pointer[_Run[S], MutUntrackedOrigin](unsafe_from_address=addr)
    if _A.fetch_add(_P(unsafe_from_address=Int(Pointer(to=job[].refs))), -1) == 1:
        job.unsafe_deinit_pointee()
        job.unsafe_free()


def _run_entry[S: Service](p: libc.ThreadArg) -> libc.ThreadArg:
    var job = Pointer[_Run[S], MutUntrackedOrigin](unsafe_from_address=Int(p))
    try:
        if job[].workers <= 1:
            job[].srv.serve(_Bridge[S](job[].state))
        else:
            job[].srv.serve(_Bridge[S](job[].state), num_workers=job[].workers, pin_cores=False)
    except e:
        print("mojoui.serve: the server stopped: " + String(e))
    _ = _A.fetch_add(_P(unsafe_from_address=Int(Pointer(to=job[].ended))), 1)
    _release_run[S](Int(p))
    return libc.null_arg()


def _tick_loop[S: Service](addr: Int):
    var w = _P(unsafe_from_address=addr)
    var state = Int(w[0])
    var every = Int((w + 1)[])
    var sw = _P(unsafe_from_address=state)
    var lock = Int((sw + S_LOCK)[])
    var app = Pointer[S, MutUntrackedOrigin](unsafe_from_address=Int((sw + S_APP)[]))
    while True:
        _ = libc.poll(0, 0, every)
        _ = libc.pthread_mutex_lock(lock)
        app[].tick()
        _ = libc.pthread_mutex_unlock(lock)


comptime STOP_FD = 1001  # (the stop socket's write end; its read end is STOP_FD + 1)


def _on_stop_signal(sig: c_int) abi("C"):
    var b = Int(sig)
    _ = libc.send(STOP_FD, Int(Pointer(to=b)), 1, 0x4040 if CompilationTarget.is_linux() else 0x80)  # (MSG_DONTWAIT | MSG_NOSIGNAL) (read only)


def _stop_loop[S: Service](state: Int):
    """Waits for SIGTERM or SIGINT (a byte on the stop socket), then app.stop() under the lock and exit: a daemon's
    children go with it."""
    var sw = _P(unsafe_from_address=state)
    var lock = Int((sw + S_LOCK)[])
    var app = Pointer[S, MutUntrackedOrigin](unsafe_from_address=Int((sw + S_APP)[]))
    var buf = List[UInt8](length=8, fill=0)
    while True:
        var n = libc.recv(STOP_FD + 1, Int(buf.unsafe_ptr()), 8, 0)
        if n > 0:
            break
        if n == 0 or get_errno() != ErrNo.EINTR:
            return  # (the socket closed or failed: no stop through it, never a spin)
    _ = libc.pthread_mutex_lock(lock)
    app[].stop()
    _ = libc.pthread_mutex_unlock(lock)
    exit(0)


# threads and the proxy ----------------------------------------------------------------------------------------------

def spawn[f: def(Int) thin -> None](arg: Int) -> Bool:
    """Runs f(arg) on a detached thread of its own (False: no thread to be had)."""
    var tid = List[Int](length=1, fill=0)
    if libc.pthread_create[_spawn_entry[f]](arg, Int(tid.unsafe_ptr())) != 0:
        return False
    _ = libc.pthread_detach(tid[0])
    return True


def _spawn_entry[f: def(Int) thin -> None](p: libc.ThreadArg) -> libc.ThreadArg:
    f(Int(p))
    return libc.null_arg()


struct _Proxy(Movable):
    var req: Request
    var pipe: Pipe
    var ready_url: String
    var ready_ms: Int

    def __init__(out self, var req: Request, pipe: Pipe, ready_url: String, ready_ms: Int):
        self.req = req^
        self.pipe = pipe
        self.ready_url = ready_url
        self.ready_ms = ready_ms


def proxy(var req: Request, pipe: Pipe, ready_url: String = "", ready_ms: Int = 0) -> Bool:
    """Relays `req`'s reply into `pipe` byte for byte on a thread of its own: the status and Content-Type with
    set_head, the body as it arrives, then close. `ready_url`: first wait (up to `ready_ms`) until a GET of it answers
    2xx (an upstream that's still starting). A failure writes {"error": …} with status 502. Takes a share of the pipe."""
    var job = unsafe_alloc[_Proxy](1)
    job.unsafe_write(_Proxy(req^, pipe.share(), ready_url, ready_ms))
    if not spawn[_proxy_run](Int(job)):
        var j = Pointer[_Proxy, MutUntrackedOrigin](unsafe_from_address=Int(job))
        j[].pipe.set_head(502, "application/json")
        j[].pipe.write('{"error": {"message": "no thread for the proxy", "code": "proxy"}}')
        j[].pipe.close()
        j[].pipe.release()
        j.unsafe_deinit_pointee()
        j.unsafe_free()
        return False
    return True


def _proxy_fail(pipe: Pipe, why: String):
    if pipe.status() == 0:
        pipe.set_head(502, "application/json")
        pipe.write('{"error": {"message": ' + json_string(why) + ', "code": "upstream"}}')
    pipe.close()


def _proxy_run(addr: Int):
    var j = Pointer[_Proxy, MutUntrackedOrigin](unsafe_from_address=addr)
    var pipe = j[].pipe
    try:
        if j[].ready_url != "":
            var until = now_ns() + j[].ready_ms * 1_000_000
            var up = False
            while not up and now_ns() < until and not pipe.gone():
                try:
                    var probe = HttpClient(timeout_ms=1000).get(j[].ready_url)
                    up = probe.status >= 200 and probe.status < 300
                except:
                    pass
                if not up:
                    _ = libc.poll(0, 0, 250)
            if not up:
                raise Error("the upstream wasn't ready after " + String(j[].ready_ms) + " ms")
        var r = FlareRequest(method=j[].req.method, url=j[].req.url, body=_bytes(j[].req.body))
        for i in range(len(j[].req.names)):
            r.headers.set(j[].req.names[i], j[].req.values[i])
        var client = HttpClient(TlsConfig(), timeout_ms=max(j[].req.timeout_ms, 1), user_agent="mojoui").with_read_timeout(max(j[].req.timeout_ms, 1))
        var s = client.send_streaming(r^)
        pipe.set_head(s.status, s.header("content-type"))
        while not s.done() and not pipe.gone():
            var chunk = s.read_chunk(65536)
            if len(chunk) == 0:
                break
            pipe.write(Span(chunk))
        s.close()
        pipe.close()
    except e:
        _proxy_fail(pipe, String(e))
    pipe.release()
    j.unsafe_deinit_pointee()
    j.unsafe_free()


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8](capacity=s.byte_length())
    for b in s.as_bytes():
        out.append(b)
    return out^


# concurrent handlers (goal 60, D-6007, D-6008) -----------------------------------------------------------------------

trait Handler(Movable, Deinitable):
    """A server's app whose answer() may run on many threads at once: its state is read-only or thread-safe itself
    (mojoui.sqlite's per-thread connections, a locked table)."""

    def answer(self, mut req: Req) -> Reply:
        ...

    def blocking(self, req: Req) -> Bool:
        """True for a request whose answer waits on the network (an OAuth token, a Stripe call): it is answered on one
        of the offload pool's threads instead of the reactor worker its connection came in on."""
        ...

    def tick(self):
        """Every `tick_ms`, on a thread of its own (no lock): sweeps, timers."""
        ...

    def stop(self):
        """SIGTERM / SIGINT: tidy up; the process exits after."""
        ...


comptime H_APP = 0
comptime H_LOG = 1
comptime H_OFFLOADED = 2  # blocking requests queued for or running on the offload pool now (atomic)
comptime H_MAX_OFFLOADED = 3  # the pool's threads + its queue
comptime H_PROXIES = 4  # a TrustedProxies (read-only once serving)
comptime H_QUEUE_W = 5  # the offload queue: a pipe of job addresses (8 bytes each: one write, one read, never split)
comptime H_QUEUE_R = 6
comptime H_WORDS = 7
comptime MAX_OFFLOAD_QUEUE = 4096  # (threads + queue stay far inside a pipe's 64 KB: a hand-off never blocks)


def request_id() -> String:
    try:
        return hex(random_bytes(8))
    except:
        return String(now_ns())


def _peer(req: FlareRequest) -> String:
    return String(req.peer.ip)


@fieldwise_init
struct _HBridge[H: Handler](Copyable, FlareHandler):
    var state: Int

    def serve(self, req: FlareRequest) raises -> FlareResponse:
        var t0 = now_ns()
        var r = Req(req.method, _target(req.url), _text(req.body))
        if r.path == READY_PATH:
            return _flare_reply(Reply.empty())
        for i in range(len(req.headers._keys)):
            r.names.append(req.headers._keys[i].lower())
            r.values.append(req.headers._values[i])
        r.peer = _peer(req)
        var w = _P(unsafe_from_address=self.state)
        r.client = client_ip(r.peer, r.header_all("x-forwarded-for"), Pointer[TrustedProxies, MutUntrackedOrigin](unsafe_from_address=Int((w + H_PROXIES)[]))[])
        r.rid = request_id()
        var app = Pointer[Self.H, MutUntrackedOrigin](unsafe_from_address=Int((w + H_APP)[]))
        if app[].blocking(r) and req.version.startswith("HTTP/1"):  # (HTTP/2 streams share a connection: answered inline)
            if _A.fetch_add(w + H_OFFLOADED, 1) < (w + H_MAX_OFFLOADED)[]:
                var job = unsafe_alloc[_Offload](1)
                job.unsafe_write(_Offload(self.state, r^, t0))
                var out = FlareResponse(status=503, body=_bytes("the server can't hand this request off"))
                var hook = _offload_hook[Self.H]
                out.offload_fn = Pointer(to=hook).unsafe_bitcast[Int]()[]
                out.offload_arg = Int(job)
                return out^
            _ = _A.fetch_add(w + H_OFFLOADED, -1)
            var busy = Reply.error(503, "too many slow requests at once: try again", "busy").header("Retry-After", "1")
            return _flare_reply(_finish(self.state, r, busy^, t0))
        var reply = app[].answer(r)
        return _flare_reply(_finish(self.state, r, reply^, t0))


def _finish(state: Int, req: Req, var reply: Reply, t0: Int) -> Reply:
    """The request id on the reply, the request's line in the log."""
    var w = _P(unsafe_from_address=state)
    var log = Log(addr=Int((w + H_LOG)[]))
    if log.addr != 0:
        log.request(req.rid, req.method, req.path, reply.status, Float64(now_ns() - t0) / 1e6, req.client if req.client != "" else req.peer)
    return reply^.header("X-Request-Id", req.rid)


struct _Offload(Movable):
    var state: Int
    var req: Req
    var t0: Int
    var fd: Int

    def __init__(out self, state: Int, var req: Req, t0: Int):
        self.state = state
        self.req = req^
        self.t0 = t0
        self.fd = -1


def _offload_hook[H: Handler](fd: Int, arg: Int):
    """Flare's reactor gives up the connection (on its worker): the socket goes blocking and a thread answers it."""
    var job = Pointer[_Offload, MutUntrackedOrigin](unsafe_from_address=arg)
    if fd < 0:  # (Flare couldn't hand the connection over (TLS, HTTP/2): the slot and the record go back; it got the 503)
        _ = _A.fetch_add(_P(unsafe_from_address=job[].state) + H_OFFLOADED, -1)
        job.unsafe_deinit_pointee()
        job.unsafe_free()
        return
    job[].fd = fd
    var fl = libc.fcntl(fd, 3)  # F_GETFL
    if fl >= 0:
        _ = libc.fcntl(fd, 4, fl & ~(0x4 if CompilationTarget.is_macos() else 0x800))  # F_SETFL without O_NONBLOCK
    var tv = List[Int64](length=2, fill=0)  # (SO_SNDTIMEO / SO_RCVTIMEO 30 s: Flare's timeouts end with the hand-off)
    tv[0] = 30
    var lvl = 0xFFFF if CompilationTarget.is_macos() else 1  # SOL_SOCKET
    _ = libc.setsockopt(fd, lvl, 0x1005 if CompilationTarget.is_macos() else 21, Int(tv.unsafe_ptr()), 16)
    _ = libc.setsockopt(fd, lvl, 0x1006 if CompilationTarget.is_macos() else 20, Int(tv.unsafe_ptr()), 16)
    _ = len(tv)
    var job_addr = List[Int64](length=1, fill=Int64(arg))
    var wfd = Int((_P(unsafe_from_address=job[].state) + H_QUEUE_W)[])
    var n = libc.write_fd(wfd, Int(job_addr.unsafe_ptr()), 8)
    while n < 0 and get_errno() == ErrNo.EINTR:
        n = libc.write_fd(wfd, Int(job_addr.unsafe_ptr()), 8)
    _ = len(job_addr)
    if n != 8:  # (no queue: answered here, as a last resort; the slot counts held it to the pool's size)
        _offload_run[H](arg)


def _offload_worker[H: Handler](state: Int):
    """One of the offload pool's threads: forever takes the next queued job (a blocking read of 8 bytes) and answers it.
    Its SQLite connections (mojoui.sqlite's Pool, per thread) stay open between jobs."""
    var rfd = Int((_P(unsafe_from_address=state) + H_QUEUE_R)[])
    var buf = List[Int64](length=1, fill=0)
    while True:
        var got = 0
        while got < 8:
            var n = libc.read_fd(rfd, Int(buf.unsafe_ptr()) + got, 8 - got)
            if n > 0:
                got += n
            elif n < 0 and get_errno() == ErrNo.EINTR:
                continue
            else:
                return  # (the queue closed: nothing more comes)
        _offload_run[H](Int(buf[0]))


def _offload_run[H: Handler](arg: Int):
    var job = Pointer[_Offload, MutUntrackedOrigin](unsafe_from_address=arg)
    var w = _P(unsafe_from_address=job[].state)
    var app = Pointer[H, MutUntrackedOrigin](unsafe_from_address=Int((w + H_APP)[]))
    var reply = app[].answer(job[].req)
    if reply.pipe != 0:
        reply = Reply.error(500, "a streamed reply can't come from a blocking request", "internal")
    reply = _finish(job[].state, job[].req, reply^, job[].t0)
    var bad = False
    for i in range(len(reply.names)):
        bad = bad or not header_safe(reply.names[i], reply.values[i])
    if bad:  # (a CR, LF or NUL would split the reply: Flare's own path refuses them too)
        var log = Log(addr=Int((w + H_LOG)[]))
        if log.addr != 0:
            log.error("a reply header with CR, LF or NUL refused", Fields().str("rid", job[].req.rid).str("path", job[].req.path))
        reply = _finish(job[].state, job[].req, Reply.error(500, "the server built a bad reply header", "internal"), job[].t0)
    var head = "HTTP/1.1 " + String(reply.status) + " " + _reason(reply.status) + "\r\n"
    var has_type = False
    for i in range(len(reply.names)):
        var n = reply.names[i].lower()
        if n == "content-length" or n == "connection" or n == "transfer-encoding":
            continue
        has_type = has_type or n == "content-type"
        head += reply.names[i] + ": " + reply.values[i] + "\r\n"
    if not has_type and len(reply.body) > 0:
        head += "Content-Type: text/plain; charset=utf-8\r\n"
    var body_len = 0 if job[].req.method == "HEAD" else len(reply.body)
    head += "Content-Length: " + String(len(reply.body)) + "\r\nConnection: close\r\n\r\n"
    var fd = job[].fd
    _send_all(fd, Int(head.unsafe_ptr()), head.byte_length())
    _ = head.byte_length()
    if body_len > 0:
        _send_all(fd, Int(reply.body.unsafe_ptr()), body_len)
        _ = len(reply.body)
    _ = libc.close(fd)
    _ = _A.fetch_add(w + H_OFFLOADED, -1)
    job.unsafe_deinit_pointee()
    job.unsafe_free()


def header_safe(name: String, value: String) -> Bool:
    """A header a reply may carry: a token name (no separators, spaces or controls), a value without CR, LF or NUL."""
    if name.byte_length() == 0:
        return False
    for b in name.as_bytes():
        if b <= 32 or b >= 127 or b == 58:
            return False
    for b in value.as_bytes():
        if b == 13 or b == 10 or b == 0:
            return False
    return True


def _send_all(fd: Int, p: Int, n: Int):
    var off = 0
    while off < n:
        var s = libc.send(fd, p + off, n - off, 0x4000 if CompilationTarget.is_linux() else 0)  # (MSG_NOSIGNAL)
        if s <= 0:
            if s < 0 and get_errno() == ErrNo.EINTR:
                continue
            break
        off += s


def _reason(status: Int) -> String:
    if status == 200:
        return "OK"
    if status == 201:
        return "Created"
    if status == 204:
        return "No Content"
    if status == 302:
        return "Found"
    if status == 303:
        return "See Other"
    if status == 400:
        return "Bad Request"
    if status == 401:
        return "Unauthorized"
    if status == 402:
        return "Payment Required"
    if status == 403:
        return "Forbidden"
    if status == 404:
        return "Not Found"
    if status == 410:
        return "Gone"
    if status == 413:
        return "Content Too Large"
    if status == 429:
        return "Too Many Requests"
    if status == 500:
        return "Internal Server Error"
    if status == 502:
        return "Bad Gateway"
    if status == 503:
        return "Service Unavailable"
    return "Status"


struct _HRun[H: Handler](Movable):
    var srv: HttpServer
    var state: Int
    var workers: Int
    var refs: Scalar[DType.int64]
    var ended: Scalar[DType.int64]

    def __init__(out self, var srv: HttpServer, state: Int, workers: Int):
        self.srv = srv^
        self.state = state
        self.workers = workers
        self.refs = 2
        self.ended = 0


def _hclose_run[H: Handler](addr: Int):
    Pointer[_HRun[H], MutUntrackedOrigin](unsafe_from_address=addr)[].srv.close()


def _hended_run[H: Handler](addr: Int) -> Bool:
    var job = Pointer[_HRun[H], MutUntrackedOrigin](unsafe_from_address=addr)
    return _A.load(_P(unsafe_from_address=Int(Pointer(to=job[].ended)))) >= 1


def _hrelease_run[H: Handler](addr: Int):
    var job = Pointer[_HRun[H], MutUntrackedOrigin](unsafe_from_address=addr)
    if _A.fetch_add(_P(unsafe_from_address=Int(Pointer(to=job[].refs))), -1) == 1:
        job.unsafe_deinit_pointee()
        job.unsafe_free()


def _hrun_entry[H: Handler](p: libc.ThreadArg) -> libc.ThreadArg:
    var job = Pointer[_HRun[H], MutUntrackedOrigin](unsafe_from_address=Int(p))
    try:
        if job[].workers <= 1:
            job[].srv.serve(_HBridge[H](job[].state))
        else:
            job[].srv.serve(_HBridge[H](job[].state), num_workers=job[].workers, pin_cores=False)
    except e:
        print("mojoui.serve: the server stopped: " + String(e))
    _ = _A.fetch_add(_P(unsafe_from_address=Int(Pointer(to=job[].ended))), 1)
    _hrelease_run[H](Int(p))
    return libc.null_arg()


def _htick_loop[H: Handler](addr: Int):
    var w = _P(unsafe_from_address=addr)
    var app = Pointer[H, MutUntrackedOrigin](unsafe_from_address=Int((_P(unsafe_from_address=Int(w[0])) + H_APP)[]))
    var every = Int((w + 1)[])
    while True:
        _ = libc.poll(0, 0, every)
        app[].tick()


def _hstop_loop[H: Handler](state: Int):
    var w = _P(unsafe_from_address=state)
    var app = Pointer[H, MutUntrackedOrigin](unsafe_from_address=Int((w + H_APP)[]))
    var buf = List[UInt8](length=8, fill=0)
    while True:
        var n = libc.recv(STOP_FD + 1, Int(buf.unsafe_ptr()), 8, 0)
        if n > 0:
            break
        if n == 0 or get_errno() != ErrNo.EINTR:
            return
    app[].stop()
    exit(0)


def serve[H: Handler](var handler: H, port: Int = 0, host: String = "127.0.0.1", workers: Int = 0, tick_ms: Int = 0,
                      log: Log = Log(addr=0), var proxies: TrustedProxies = TrustedProxies(), max_body: Int = 1024 * 1024,
                      request_timeout_ms: Int = 30_000, offload_threads: Int = 16, offload_queue: Int = 64) raises -> Served:
    """Serves `handler` concurrently on threads of its own until the returned Served is dropped or stopped (`.port`:
    the port). `workers` 0: one reactor per CPU core (up to 16). `log`: a request line each (Log(addr=0): none).
    `proxies`: the reverse proxies whose X-Forwarded-For names the client (`req.client`; none: the socket's peer).
    `max_body` (1 MB) and `request_timeout_ms` (30 s): Flare's limits on reading a request (Server.bind).
    `offload_threads` (16) answer the requests `blocking()` names, made now and kept; at most `offload_queue` (64) more
    wait for one; past that a blocking request gets 503 with Retry-After. (The threads live as long as the process.)"""
    if offload_threads < 1 or offload_queue < 0 or offload_threads + offload_queue > MAX_OFFLOAD_QUEUE:
        raise Error("serve: offload_threads ≥ 1, offload_queue ≥ 0, together at most " + String(MAX_OFFLOAD_QUEUE))
    var handles_signals = Server._install_stop_handler()
    var srv = Server.bind(port, host, max_body, request_timeout_ms)
    var bound = Int(srv.local_addr().port)
    var n = workers
    if n <= 0:
        n = min(max(libc.cpu_count(), 2), 16)
    var w = unsafe_alloc[Int64](H_WORDS)
    var app = unsafe_alloc[H](1)
    app.unsafe_write(handler^)
    (w + H_APP)[] = Int64(Int(app))
    (w + H_LOG)[] = Int64(log.addr)
    (w + H_OFFLOADED)[] = 0
    (w + H_MAX_OFFLOADED)[] = Int64(offload_threads + offload_queue)
    var fds = List[Int32](length=2, fill=-1)
    if libc.pipe(Int(fds.unsafe_ptr())) != 0:
        raise Error("serve: no pipe for the offload queue")
    (w + H_QUEUE_R)[] = Int64(fds[0])
    (w + H_QUEUE_W)[] = Int64(fds[1])
    _ = len(fds)
    var px = unsafe_alloc[TrustedProxies](1)
    px.unsafe_write(proxies^)
    (w + H_PROXIES)[] = Int64(Int(px))
    var st = Int(w)
    for _ in range(offload_threads):
        if not spawn[_offload_worker[H]](st):
            raise Error("serve: no thread for the offload pool")
    if tick_ms > 0:
        var tw = unsafe_alloc[Int64](2)
        tw[0] = Int64(st)
        tw[1] = Int64(tick_ms)
        if not spawn[_htick_loop[H]](Int(tw)):
            raise Error("no thread for the server's tick")
    if handles_signals and not spawn[_hstop_loop[H]](st):
        raise Error("no thread for the server's stop watcher")
    var job = unsafe_alloc[_HRun[H]](1)
    job.unsafe_write(_HRun[H](srv^, st, n))
    var tid = List[Int](length=1, fill=0)
    if libc.pthread_create[_hrun_entry[H]](Int(job), Int(tid.unsafe_ptr())) != 0:
        job.unsafe_deinit_pointee()
        job.unsafe_free()
        raise Error("no thread for the server")
    _ = libc.pthread_detach(tid[0])
    var served = Served(bound, Int(job), _hclose_run[H], _hended_run[H], _hrelease_run[H])
    if not _answers(host, bound, 5000):
        raise Error("the server on port " + String(bound) + " didn't start answering")
    return served^
