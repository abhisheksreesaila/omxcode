# mojoui.http_socket: the plain HTTP/1.1 transport (D-310, D-320): libc sockets, IPv4, http:// only, one request per
# connection (Connection: close), bodies by Content-Length, chunked, or to the end. Blocking calls with one deadline for
# the whole request (non-blocking socket + poll), made on a worker thread (mojoui.effects), never on the UI thread.
# Linux (glibc, Android's bionic) and Apple (macOS, iOS) differ in a few numbers and struct layouts, kept here.

from std.ffi import external_call, c_int, get_errno, ErrNo
from std.sys import CompilationTarget, is_defined
from std.os import getenv
from mojoui.http import Request, Response, Transport, Url, TLS_NEEDED, request_problem, has_control, Sink, SseReader, Piece, utf8_whole, utf8_lossy, MAX_STREAM_CHUNK
from mojoui.clock import now_ns

comptime APPLE = not CompilationTarget.is_linux()  # (BSD sockets: sin_len, other constants)
comptime AF_INET = 2
comptime SOCK_STREAM = 1
comptime F_GETFL = 3
comptime F_SETFL = 4
comptime O_NONBLOCK = 4 if APPLE else 2048
comptime SOL_SOCKET = 0xFFFF if APPLE else 1
comptime SO_ERROR = 0x1007 if APPLE else 4
comptime SO_NOSIGPIPE = 0x1022  # (Apple: a write to a closed socket returns EPIPE instead of killing the app)
comptime MSG_NOSIGNAL = 0 if APPLE else 0x4000  # (Linux: the same, per call)
comptime EINTR = 4
comptime EAGAIN = 35 if APPLE else 11
comptime EINPROGRESS = 36 if APPLE else 115
comptime ECONNREFUSED = 61 if APPLE else 111
comptime POLLIN = 1
comptime POLLOUT = 4
comptime MAX_BODY = 256 * 1024 * 1024
comptime CHUNK = 65536


def errno() -> Int:
    return Int(get_errno().value)  # (the standard library's: __errno_location, __error, … per platform)


def why(e: Int) -> String:
    """errno as words (strerror's)."""
    return String(ErrNo(e)).lower()


def ipv4(host: String) raises -> UInt32:
    """The host's IPv4 address, in network order as it sits in memory: a dotted address as is, `localhost` as
    127.0.0.1, any other name through getaddrinfo (on the worker: it may take a while)."""
    var name = String("127.0.0.1") if host == "localhost" else host
    var dst = List[UInt8](length=4, fill=0)
    var c = name.copy()
    if external_call["inet_pton", c_int](c_int(AF_INET), c.as_c_string_span(), Int(dst.unsafe_ptr())) == 1:
        return UInt32(dst[0]) | (UInt32(dst[1]) << 8) | (UInt32(dst[2]) << 16) | (UInt32(dst[3]) << 24)
    var hints = List[UInt8](length=64, fill=0)  # struct addrinfo, zeroed: ai_family at 4, ai_socktype at 8
    hints[4] = AF_INET
    hints[8] = SOCK_STREAM
    var out = List[Int](length=1, fill=0)  # (a buffer: getaddrinfo writes the list's address into it)
    var rc = external_call["getaddrinfo", c_int](c.as_c_string_span(), Int(0), Int(hints.unsafe_ptr()), Int(out.unsafe_ptr()))
    _ = len(hints)
    var res = out[0]
    if rc != 0 or res == 0:
        raise Error("can't find the host " + host)
    comptime ADDR_AT = 32 if APPLE else 24  # (ai_addr and ai_canonname swap places between Linux and Apple)
    var sa = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=res + ADDR_AT)[]
    var a = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=sa + 4)[]
    external_call["freeaddrinfo", NoneType](res)
    return a


def left_ms(deadline: Int) -> Int:
    return max((deadline - now_ns()) // 1_000_000, 0)


def wait_for(fd: c_int, events: Int, deadline: Int) -> Bool:
    """Until the socket is ready for `events` (POLLIN / POLLOUT), or the deadline passes (False)."""
    var pfd = List[UInt8](length=8, fill=0)  # struct pollfd { int fd; short events; short revents; }
    var p = Pointer[c_int, MutUntrackedOrigin](unsafe_from_address=Int(pfd.unsafe_ptr()))
    p[] = fd
    pfd[4] = UInt8(events)
    while True:
        var ms = left_ms(deadline)
        pfd[6] = 0
        pfd[7] = 0
        var n = external_call["poll", c_int](Int(pfd.unsafe_ptr()), Int(1), c_int(min(ms, 1_000_000)))
        if n > 0:
            _ = len(pfd)
            return True
        if n == 0 and ms <= 0:
            return False
        if n < 0 and errno() != EINTR:
            return True  # (the next call reports the error)


def find(buf: List[UInt8], what: String, start: Int = 0) -> Int:
    var w = what.as_bytes()
    var n = len(w)
    for i in range(start, len(buf) - n + 1):
        var ok = True
        for k in range(n):
            if buf[i + k] != w[k]:
                ok = False
                break
        if ok:
            return i
    return -1


def text_of(buf: List[UInt8], a: Int, b: Int) -> String:
    var out = List[UInt8](capacity=max(b - a, 0))
    for i in range(a, b):
        out.append(buf[i])
    try:
        return String(from_utf8=Span(out))
    except:
        return String("")


def dechunk(buf: List[UInt8], start: Int, mut body: List[UInt8]) -> Bool:
    """A chunked body from `start` into `body`; False while it isn't all there."""
    var i = start
    body.clear()
    while True:
        var eol = find(buf, "\r\n", i)
        if eol < 0:
            return False
        var size = 0
        var digits = 0
        for k in range(i, eol):
            var c = Int(buf[k])
            var d = c - 48 if c >= 48 and c <= 57 else (c - 87 if c >= 97 and c <= 102 else (c - 55 if c >= 65 and c <= 70 else -1))
            if d < 0:
                break  # (a chunk extension: ";name=value")
            size = size * 16 + d
            digits += 1
            if size > MAX_BODY:
                return False
        if digits == 0:
            return False
        i = eol + 2
        if size == 0:
            return True  # (trailers, if any, are not read)
        if i + size + 2 > len(buf):
            return False
        for k in range(i, i + size):
            body.append(buf[k])
        i += size + 2


struct SocketTransport(Transport):
    @staticmethod
    def send(req: Request) -> Response:
        var url: Url
        try:
            url = Url.parse(req.url)
        except e:
            return Response.failed(String(e))
        if url.scheme == "https":
            return Response.failed(TLS_NEEDED)
        var problem = request_problem(req)
        if problem != "":
            return Response.failed(problem)
        var deadline = now_ns() + max(req.timeout_ms, 1) * 1_000_000
        var where = url.host + ":" + String(url.port)
        var addr: UInt32
        try:
            addr = ipv4(url.host)
        except e:
            return Response.failed(String(e))
        var fd = external_call["socket", c_int](c_int(AF_INET), c_int(SOCK_STREAM), c_int(0))
        if fd < 0:
            return Response.failed("no socket: " + why(errno()))
        var r = SocketTransport.exchange(fd, addr, url, where, req, deadline)
        _ = external_call["close", c_int](fd)
        return r^

    @staticmethod
    def exchange(fd: c_int, addr: UInt32, url: Url, where: String, req: Request, deadline: Int) -> Response:
        var problem = SocketTransport.open_send(fd, addr, url, where, req, deadline)
        if problem != "":
            return Response.failed(problem)
        return SocketTransport.receive(fd, where, req, deadline)

    @staticmethod
    def open_send(fd: c_int, addr: UInt32, url: Url, where: String, req: Request, deadline: Int) -> String:
        """Connects and sends the request: "" or why not."""
        var flags = external_call["fcntl", c_int, num_fixed_args=2](fd, c_int(F_GETFL))
        _ = external_call["fcntl", c_int, num_fixed_args=2](fd, c_int(F_SETFL), flags | c_int(O_NONBLOCK))
        comptime if APPLE:
            var one = List[c_int](length=1, fill=1)
            _ = external_call["setsockopt", c_int](fd, c_int(SOL_SOCKET), c_int(SO_NOSIGPIPE), Int(one.unsafe_ptr()), c_int(4))
            _ = len(one)
        # connect
        var sa = List[UInt8](length=16, fill=0)  # struct sockaddr_in
        comptime if APPLE:
            sa[0] = 16
            sa[1] = AF_INET
        else:
            sa[0] = AF_INET
        sa[2] = UInt8(url.port >> 8)
        sa[3] = UInt8(url.port & 255)
        Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=Int(sa.unsafe_ptr()) + 4)[] = addr
        var rc = external_call["connect", c_int](fd, Int(sa.unsafe_ptr()), c_int(16))
        _ = len(sa)
        if rc != 0:
            var e = errno()
            if e != EINPROGRESS and e != EINTR:
                return SocketTransport.connect_error(e, where)
            if not wait_for(fd, POLLOUT, deadline):
                return "timed out after " + String(req.timeout_ms) + " ms connecting to " + where
            var out = List[c_int](length=2, fill=0)  # SO_ERROR's value, and its size (a buffer: C writes into it)
            out[1] = 4
            _ = external_call["getsockopt", c_int](fd, c_int(SOL_SOCKET), c_int(SO_ERROR), Int(out.unsafe_ptr()), Int(out.unsafe_ptr()) + 4)
            var err = Int(out[0])
            if err != 0:
                return SocketTransport.connect_error(err, where)
        # send
        var head = req.method + " " + url.target + " HTTP/1.1\r\nHost: " + url.host + ("" if url.port == 80 else ":" + String(url.port))
        head += "\r\nUser-Agent: mojoui\r\nAccept: */*\r\nConnection: close\r\n"
        for i in range(len(req.names)):
            head += req.names[i] + ": " + req.values[i] + "\r\n"
        for i in range(len(req.env_names)):
            var v = getenv(req.env_vars[i])
            if has_control(v):
                return "$" + req.env_vars[i] + " holds a control character"
            if v.byte_length() > 0:
                head += req.env_names[i] + ": " + v + "\r\n"
        if req.body.byte_length() > 0 or req.method == "POST" or req.method == "PUT" or req.method == "PATCH":
            head += "Content-Length: " + String(req.body.byte_length()) + "\r\n"
        head += "\r\n"
        var out = List[UInt8](capacity=head.byte_length() + req.body.byte_length())
        for b in head.as_bytes():
            out.append(b)
        for b in req.body.as_bytes():
            out.append(b)
        var sent = 0
        while sent < len(out):
            var n = external_call["send", Int](fd, Int(out.unsafe_ptr()) + sent, len(out) - sent, c_int(MSG_NOSIGNAL))
            if n > 0:
                sent += n
                continue
            var e = errno()
            if n < 0 and (e == EAGAIN or e == EINTR):
                if not wait_for(fd, POLLOUT, deadline):
                    return "timed out after " + String(req.timeout_ms) + " ms sending to " + where
                continue
            return "the connection to " + where + " broke while sending: " + why(e)
        _ = len(out)
        return ""

    @staticmethod
    def receive(fd: c_int, where: String, req: Request, deadline: Int) -> Response:
        # receive
        var buf = List[UInt8]()
        var chunk = List[UInt8](length=CHUNK, fill=0)
        var body_at = -1
        var length = -1
        var chunked = False
        var bodyless = req.method == "HEAD"
        while True:
            if body_at >= 0:
                if bodyless or (length >= 0 and len(buf) - body_at >= length):
                    break
                if chunked and len(buf) >= 5 and find(buf, "0\r\n\r\n", len(buf) - 5) >= 0:
                    var probe = List[UInt8]()
                    if dechunk(buf, body_at, probe):
                        break
            if not wait_for(fd, POLLIN, deadline):
                return Response.failed("timed out after " + String(req.timeout_ms) + " ms waiting for " + where)
            var n = external_call["recv", Int](fd, Int(chunk.unsafe_ptr()), CHUNK, c_int(0))
            if n < 0:
                var e = errno()
                if e == EAGAIN or e == EINTR:
                    continue
                return Response.failed("the connection to " + where + " broke: " + why(e))
            if n == 0:
                break  # the server closed: the end
            for k in range(n):
                buf.append(chunk[k])
            if len(buf) > MAX_BODY:
                return Response.failed("the reply from " + where + " is larger than 256 MB")
            if body_at < 0:
                var end = find(buf, "\r\n\r\n", max(len(buf) - n - 3, 0))
                if end >= 0:
                    body_at = end + 4
                    var r = Response()
                    try:
                        SocketTransport.read_head(buf, end, r)
                    except e:
                        return Response.failed(String(e) + " (from " + where + ")")
                    var status = r.status
                    var cl = r.header("content-length")
                    chunked = r.header("transfer-encoding").lower().find("chunked") >= 0
                    if cl.byte_length() > 0 and not chunked:
                        try:
                            length = atol(cl.strip())
                        except:
                            return Response.failed("a bad Content-Length from " + where)
                    if status == 204 or status == 304 or (status >= 100 and status < 200):
                        bodyless = True
        _ = len(chunk)
        if body_at < 0:
            return Response.failed(where + " closed the connection without a reply" if len(buf) == 0 else "a reply without its headers from " + where)
        var r = Response()
        try:
            SocketTransport.read_head(buf, body_at - 4, r)
        except e:
            return Response.failed(String(e))
        if bodyless:
            return r^
        if chunked:
            if not dechunk(buf, body_at, r.body):
                return Response.failed("the chunked reply from " + where + " ended early")
            return r^
        var end = len(buf) if length < 0 else body_at + length
        if end > len(buf):
            return Response.failed("the reply from " + where + " ended early (" + String(len(buf) - body_at) + " of " + String(length) + " bytes)")
        r.body = List[UInt8](capacity=end - body_at)
        for k in range(body_at, end):
            r.body.append(buf[k])
        return r^

    @staticmethod
    def stream(req: Request, mut sink: Sink) -> Response:
        var url: Url
        try:
            url = Url.parse(req.url)
        except e:
            return Response.failed(String(e))
        if url.scheme == "https":
            return Response.failed(TLS_NEEDED)
        var problem = request_problem(req)
        if problem != "":
            return Response.failed(problem)
        var idle = max(req.timeout_ms, 1) * 1_000_000
        var where = url.host + ":" + String(url.port)
        var addr: UInt32
        try:
            addr = ipv4(url.host)
        except e:
            return Response.failed(String(e))
        var fd = external_call["socket", c_int](c_int(AF_INET), c_int(SOCK_STREAM), c_int(0))
        if fd < 0:
            return Response.failed("no socket: " + why(errno()))
        var sent = SocketTransport.open_send(fd, addr, url, where, req, now_ns() + idle)
        var r: Response
        if sent != "":
            r = Response.failed(sent)
        else:
            r = SocketTransport.read_stream(fd, where, req, idle, sink)
        _ = external_call["close", c_int](fd)
        return r^

    @staticmethod
    def read_stream(fd: c_int, where: String, req: Request, idle: Int, mut sink: Sink) -> Response:
        """Reads the reply as it comes, handing each SSE event (or body piece) to the sink. Waits in 50 ms slices so a
        cancel is seen soon; `idle` is the longest silence allowed."""
        var head = List[UInt8]()
        var raw = List[UInt8]()  # body bytes not yet de-chunked
        var data = List[UInt8]()  # body bytes not yet handed on
        var chunk = List[UInt8](length=CHUNK, fill=0)
        var r = Response()
        var head_done = False
        var chunked = False
        var length = -1
        var got = 0
        var sse = False
        var good = False
        var done = False
        var reader = SseReader()
        var last = now_ns()
        var began = last
        var total = 0  # body bytes so far
        while not done:
            if sink.cancelled():
                return Response.failed("cancelled")
            var now = now_ns()
            if (now - began) // 1_000_000 >= req.stream_max_ms:
                return Response.failed("the stream from " + where + " lasted longer than " + String(req.stream_max_ms) + " ms")
            if now - last >= idle:
                return Response.failed("timed out after " + String(req.timeout_ms) + " ms waiting for the stream from " + where)
            if not wait_for(fd, POLLIN, min(last + idle, now + 50_000_000)):
                continue
            var n = external_call["recv", Int](fd, Int(chunk.unsafe_ptr()), CHUNK, c_int(0))
            if n < 0:
                var e = errno()
                if e == EAGAIN or e == EINTR:
                    continue
                return Response.failed("the stream from " + where + " broke: " + why(e))
            if n == 0:
                break  # the server closed
            last = now_ns()
            if head_done:
                total += n
                if total > req.stream_max_bytes:
                    return Response.failed("the stream from " + where + " is larger than " + String(req.stream_max_bytes) + " bytes")
            if not head_done:
                for k in range(n):
                    head.append(chunk[k])
                var end = find(head, "\r\n\r\n", 0)
                if end < 0:
                    if len(head) > 1 << 20:
                        return Response.failed("a reply head larger than 1 MB from " + where)
                    continue
                try:
                    SocketTransport.read_head(head, end, r)
                except e:
                    return Response.failed(String(e) + " (from " + where + ")")
                head_done = True
                good = r.status >= 200 and r.status < 300
                chunked = r.header("transfer-encoding").lower().find("chunked") >= 0
                sse = r.header("content-type").lower().startswith("text/event-stream")
                var cl = r.header("content-length")
                if cl.byte_length() > 0 and not chunked:
                    try:
                        length = atol(cl.strip())
                    except:
                        return Response.failed("a bad Content-Length from " + where)
                if r.status == 204 or r.status == 304 or (r.status >= 100 and r.status < 200) or req.method == "HEAD":
                    return r^
                for k in range(end + 4, len(head)):
                    raw.append(head[k])
            else:
                for k in range(n):
                    raw.append(chunk[k])
            # de-chunk what's whole
            if chunked:
                var i = 0
                while True:
                    var eol = find(raw, "\r\n", i)
                    if eol < 0:
                        break
                    var size = 0
                    var digits = 0
                    for k in range(i, eol):
                        var c = Int(raw[k])
                        var d = c - 48 if c >= 48 and c <= 57 else (c - 87 if c >= 97 and c <= 102 else (c - 55 if c >= 65 and c <= 70 else -1))
                        if d < 0:
                            break
                        digits += 1
                        if digits > 8:  # (no Int overflow, no size that moves backwards)
                            return Response.failed("a bad chunk size (more than 8 hex digits) in the stream from " + where)
                        size = size * 16 + d
                    if digits == 0:
                        return Response.failed("a bad chunk in the stream from " + where)
                    if size > MAX_STREAM_CHUNK:
                        return Response.failed("a chunk larger than " + String(MAX_STREAM_CHUNK) + " bytes in the stream from " + where)
                    if size == 0:
                        done = True
                        i = len(raw)
                        break
                    if eol + 2 + size + 2 > len(raw):
                        break
                    for k in range(eol + 2, eol + 2 + size):
                        data.append(raw[k])
                    i = eol + 2 + size + 2
                var rest = List[UInt8](capacity=len(raw) - i)
                for k in range(i, len(raw)):
                    rest.append(raw[k])
                raw = rest^
            else:
                for b in raw:
                    data.append(b)
                got += len(raw)
                raw.clear()
                if length >= 0 and got >= length:
                    done = True
            # hand on what's whole
            if not good:
                for b in data:
                    r.body.append(b)
                data.clear()
                if len(r.body) > MAX_BODY:
                    return Response.failed("the reply from " + where + " is larger than 256 MB")
            elif sse:
                var events = reader.feed(Span(data))
                data.clear()
                for ref ev in events:
                    sink.push(ev.copy())
                if reader.error != "":
                    return Response.failed("the stream from " + where + " sent " + reader.error)
            else:
                var whole = utf8_whole(data)
                if whole > 0:
                    var part = List[UInt8](capacity=whole)
                    for k in range(whole):
                        part.append(data[k])
                    sink.push(Piece("chunk", utf8_lossy(part)))
                    var rest = List[UInt8]()
                    for k in range(whole, len(data)):
                        rest.append(data[k])
                    data = rest^
        _ = len(chunk)
        if not head_done:
            return Response.failed(where + " closed the connection without a reply" if len(head) == 0 else "a reply without its headers from " + where)
        if not done and (chunked or length >= 0):
            return Response.failed("the stream from " + where + " ended early (the connection dropped)")
        if good and not sse and len(data) > 0:
            sink.push(Piece("chunk", utf8_lossy(data)))
        return r^

    @staticmethod
    def connect_error(e: Int, where: String) -> String:
        if e == ECONNREFUSED:
            return "connection refused (" + where + ")"
        return "can't connect to " + where + ": " + why(e)

    @staticmethod
    def read_head(buf: List[UInt8], end: Int, mut r: Response) raises:
        """The status line and the headers (up to `end`, the blank line) into `r`."""
        var head = text_of(buf, 0, end)
        var lines = head.split("\r\n")
        var first = String(lines[0])
        if not first.startswith("HTTP/1."):
            raise Error("not an HTTP reply")
        var parts = first.split(" ")
        if len(parts) < 2:
            raise Error("a bad status line")
        r.status = atol(parts[1])
        for i in range(1, len(lines)):
            var line = String(lines[i])
            var colon = line.find(":")
            if colon <= 0:
                continue
            r.names.append(String(line[byte = : colon]).strip().lower())
            r.values.append(String(String(line[byte = colon + 1 :]).strip()))
