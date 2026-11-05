# mojoui.serve: any Mojo app answers HTTP (goal 50 M2, D-4765). Flare's server (vendor/flare, MIT) does the wire:
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

from std.os import getenv
from std.sys import CompilationTarget, exit
from std.memory.alloc import unsafe_alloc
from std.ffi import c_int, get_errno, ErrNo
from std.atomic import Atomic
from mojoui import libc
from mojoui.http import Request, utf8_lossy
from mojoui.json import json_string
from mojoui.clock import now_ns
from flare.http import HttpServer, Handler, HeaderMap, Cancel, ChunkSource, stream_response, HttpClient
from flare.http import Request as FlareRequest
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

    def header(self, name: String) -> String:
        """A request header's value ("" when absent); any case."""
        var n = name.lower()
        for i in range(len(self.names)):
            if self.names[i] == n:
                return self.values[i]
        return ""

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
struct _Bridge[S: Service](Copyable, Handler):
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
    finds none left)."""
    while asyncrt_try_lease():
        pass


struct Server:
    @staticmethod
    def bind(port: Int, host: String = "127.0.0.1") raises -> HttpServer:
        _keep_the_pool_for_compute()
        var cfg = ServerConfig(idle_timeout_ms=30_000, handler_timeout_ms=600_000, request_timeout_ms=600_000, write_timeout_ms=60_000)
        cfg.max_body_size = 64 * 1024 * 1024
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
            # which held a UI thread 515 ms with 500; loopback answers in about 1 ms)
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
    _ = libc.send(STOP_FD, Int(Pointer(to=b)), 1, 0x4040 if CompilationTarget.is_linux() else 0x80)  # (MSG_DONTWAIT | MSG_NOSIGNAL)


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
