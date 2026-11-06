# mojoui.signin: a desktop app signs in through the system browser (goal 57 M4, RFC 8252, D-5703, D-5720). The app opens
# the server's /login with a loopback redirect and a PKCE challenge; the browser comes back to a one-shot listener on
# 127.0.0.1 with a one-time code; the app trades it, with its verifier, for a bearer token at the server's /api/token.
#
#   var s = DesktopSignIn.begin("https://saas.example")      # listens on 127.0.0.1:<random port>
#   self.browser.open(s.url)                                 # mojoui.browser: the system browser
#   …on a timer: var code = s.code()                         # "" until the browser came back (state checked)
#   if code != "": self.http.send(s.token_request(GOT_TOKEN, code))   # {token} comes back to update()
#
# The listener (Loopback) is plain libc sockets on a thread of its own (no Flare, so every desktop host has it): it takes
# GET <path>?code=…&state=… whose state matches (constant time), answers the browser a short page, and ends; anything
# else gets a 400 and it keeps waiting, up to `wait_ms`. Linux and macOS.
from std.atomic import Atomic
from std.sys import CompilationTarget
from std.memory.alloc import unsafe_alloc
from mojoui import libc
from mojoui.crypto import random_token, random_bytes, pkce_challenge, same
from mojoui.http import Request, uri_component
from mojoui.json import json_string
from mojoui.clock import now_ns

comptime _A = Atomic[Scalar[DType.int64]]
comptime _P = Pointer[Int64, MutUntrackedOrigin]
comptime L_STATE = 0  # 0 waiting, 1 got a code, 2 gave up (timed out, cancelled, no socket)
comptime L_REFS = 1  # the handle and the thread; the last frees
comptime L_FD = 2
comptime L_DEADLINE = 3  # now_ns
comptime L_EXPECT = 4  # a String*: the state the redirect must carry
comptime L_CODE = 5  # a String*: the code, once L_STATE is 1
comptime L_CANCEL = 6
comptime L_WORDS = 7
comptime PAGE = "<!doctype html><meta charset=utf-8><title>Signed in</title><body style=\"font:16px system-ui;margin:4em;text-align:center\"><h1>Signed in</h1><p>You can close this tab and go back to the app.</p>"


def _w(addr: Int, k: Int) -> _P:
    return _P(unsafe_from_address=addr + k * 8)


def _str(addr: Int) -> Pointer[String, MutUntrackedOrigin]:
    return Pointer[String, MutUntrackedOrigin](unsafe_from_address=addr)


def _sockaddr(port: Int) -> List[UInt8]:
    """sockaddr_in for 127.0.0.1:port (BSD's has a length byte first)."""
    var a = List[UInt8](length=16, fill=0)
    comptime if CompilationTarget.is_macos():
        a[0] = 16
        a[1] = 2
    else:
        a[0] = 2  # AF_INET, little-endian u16
    a[2] = UInt8(port >> 8)
    a[3] = UInt8(port & 0xFF)
    a[4] = 127
    a[7] = 1
    return a^


def _send_all(fd: Int, text: String):
    var b = text.as_bytes()
    var off = 0
    while off < len(b):
        var n = libc.send(fd, Int(b.unsafe_ptr()) + off, len(b) - off, 0)
        if n <= 0:
            return
        off += n


def _wait_readable(fd: Int, ms: Int) -> Bool:
    var pfd = List[Int32](length=2, fill=0)  # struct pollfd {int fd; short events; short revents}
    pfd[0] = Int32(fd)
    pfd[1] = 1  # POLLIN
    var r = libc.poll(Int(pfd.unsafe_ptr()), 1, ms)
    _ = len(pfd)
    return r > 0


def _hexv(c: UInt8) -> Int:
    var x = Int(c)
    if x >= 48 and x <= 57:
        return x - 48
    if x >= 97 and x <= 102:
        return x - 87
    if x >= 65 and x <= 70:
        return x - 55
    return -1


def _decode(s: String) -> String:
    """%XX and '+' decoded (the server's codes and states are base64url, so this only has to be right, not lenient)."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(b):
        if b[i] == 43:
            out.append(32)
        elif b[i] == 37 and i + 2 < len(b) and _hexv(b[i + 1]) >= 0 and _hexv(b[i + 2]) >= 0:
            out.append(UInt8(_hexv(b[i + 1]) * 16 + _hexv(b[i + 2])))
            i += 2
        else:
            out.append(b[i])
        i += 1
    try:
        return String(from_utf8=Span(out))
    except:
        return ""


def _query_arg(target: String, name: String) -> String:
    var q = target.find("?")
    if q < 0:
        return ""
    for part in String(target[byte = q + 1 :]).split("&"):
        var eq = part.find("=")
        if eq > 0 and _decode(String(part[byte = : eq])) == name:
            return _decode(String(part[byte = eq + 1 :]))
    return ""


def _serve(p: libc.ThreadArg) -> libc.ThreadArg:
    var addr = Int(p)
    var fd = Int(_w(addr, L_FD)[])
    while _A.load(_w(addr, L_STATE)) == 0:
        if _A.load(_w(addr, L_CANCEL)) == 1 or now_ns() > Int(_w(addr, L_DEADLINE)[]):
            _A.store(_w(addr, L_STATE), 2)
            break
        if not _wait_readable(fd, 100):
            continue
        var peer = List[UInt8](length=128, fill=0)
        var plen = List[UInt32](length=1, fill=128)
        var c: Int
        comptime if CompilationTarget.is_linux():
            c = libc.accept4(fd, Int(peer.unsafe_ptr()), Int(plen.unsafe_ptr()), 0o2000000)  # SOCK_CLOEXEC
        else:
            c = libc.accept(fd, Int(peer.unsafe_ptr()), Int(plen.unsafe_ptr()))
        _ = len(peer)
        _ = len(plen)
        if c < 0:
            continue
        var got = List[UInt8]()
        var buf = List[UInt8](length=4096, fill=0)
        var until = now_ns() + 2_000_000_000
        while len(got) < 16384 and now_ns() < until:  # (the request's head; a slow or silent peer is dropped)
            if not _wait_readable(c, 100):
                continue
            var n = libc.recv(c, Int(buf.unsafe_ptr()), len(buf), 0)
            if n <= 0:
                break
            for i in range(n):
                got.append(buf[i])
            if String(unsafe_from_utf8=Span(got)).find("\r\n\r\n") >= 0:
                break
        _ = len(buf)
        var head = String(unsafe_from_utf8=Span(got))
        var line = String(head.split("\r\n")[0]) if head.byte_length() > 0 else String("")
        var parts = line.split(" ")
        var code = String("")
        if len(parts) == 3 and parts[0] == "GET":
            var target = String(parts[1])
            var st = _query_arg(target, "state")
            if same(st, _str(Int(_w(addr, L_EXPECT)[]))[]):
                code = _query_arg(target, "code")
        if code != "":
            _send_all(c, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: " + String(PAGE.byte_length()) + "\r\n\r\n" + PAGE)
            _str(Int(_w(addr, L_CODE)[]))[] = code
            _A.store(_w(addr, L_STATE), 1)
        else:
            var no = "This isn't the sign-in you started here."
            _send_all(c, "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nContent-Length: " + String(no.byte_length()) + "\r\n\r\n" + no)
        _ = libc.close(c)
    _ = libc.close(fd)
    _release(addr)
    return libc.null_arg()


def _release(addr: Int):
    if _A.fetch_add(_w(addr, L_REFS), -1) != 1:
        return
    for k in [L_EXPECT, L_CODE]:
        var s = _str(Int(_w(addr, k)[]))
        s.unsafe_deinit_pointee()
        s.unsafe_free()
    _P(unsafe_from_address=addr).unsafe_free()


struct Loopback(Movable):
    """A one-shot listener on 127.0.0.1 for one redirect carrying `state`. `.port`; `code()`; `failed()`."""

    var addr: Int
    var port: Int

    def __init__(out self, state: String, wait_ms: Int = 300_000) raises:
        var fd = libc.socket(2, 1, 0)  # AF_INET, SOCK_STREAM
        if fd < 0:
            raise Error("no socket for the sign-in's loopback")
        var port = 0
        for _ in range(40):  # a random port in the dynamic range (49152–65535); the system picks none we can read back
            var r = random_bytes(2)
            var p = 49152 + ((Int(r[0]) << 8) | Int(r[1])) % 16384
            var sa = _sockaddr(p)
            if libc.bind(fd, Int(sa.unsafe_ptr()), 16) == 0:
                port = p
                _ = len(sa)
                break
            _ = len(sa)
        if port == 0 or libc.listen(fd, 8) != 0:
            _ = libc.close(fd)
            raise Error("no loopback port for the sign-in")
        var w = unsafe_alloc[Int64](L_WORDS)
        for i in range(L_WORDS):
            (w + i)[] = 0
        var expect = unsafe_alloc[String](1)
        expect.unsafe_write(state)
        var code = unsafe_alloc[String](1)
        code.unsafe_write(String(""))
        (w + L_REFS)[] = 2
        (w + L_FD)[] = Int64(fd)
        (w + L_DEADLINE)[] = Int64(now_ns() + wait_ms * 1_000_000)
        (w + L_EXPECT)[] = Int64(Int(expect))
        (w + L_CODE)[] = Int64(Int(code))
        self.addr = Int(w)
        self.port = port
        var tid = List[Int](length=1, fill=0)
        if libc.pthread_create[_serve](self.addr, Int(tid.unsafe_ptr())) != 0:
            _ = libc.close(fd)
            (w + L_REFS)[] = 1
            raise Error("no thread for the sign-in's loopback")
        _ = libc.pthread_detach(tid[0])
        _ = len(tid)

    def code(self) -> String:
        """The redirect's code once it came ("" until then)."""
        if _A.load(_w(self.addr, L_STATE)) != 1:
            return ""
        return _str(Int(_w(self.addr, L_CODE)[]))[]

    def failed(self) -> Bool:
        return _A.load(_w(self.addr, L_STATE)) == 2

    def __deinit__(deinit self):
        _A.store(_w(self.addr, L_CANCEL), 1)
        _release(self.addr)


struct DesktopSignIn(Movable):
    """One sign-in in progress: the loopback, the PKCE verifier, the URL to open."""

    var loop: Loopback
    var verifier: String
    var server: String
    var url: String

    def __init__(out self, server: String) raises:
        var state = random_token(24)
        self.loop = Loopback(state)
        self.verifier = random_token(32)
        self.server = server
        var redirect = "http://127.0.0.1:" + String(self.loop.port) + "/done"
        self.url = server + "/login?client=desktop&redirect=" + uri_component(redirect) + "&challenge=" + pkce_challenge(self.verifier) + "&app_state=" + state

    def code(self) -> String:
        return self.loop.code()

    def failed(self) -> Bool:
        return self.loop.failed()

    def token_request(self, msg: Int, code: String) -> Request:
        """POST <server>/api/token {code, verifier}: its reply is {"token": …}."""
        return Request.post_json(msg, self.server + "/api/token", '{"code": ' + json_string(code) + ', "verifier": ' + json_string(self.verifier) + "}")
