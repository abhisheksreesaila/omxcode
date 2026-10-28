# mojoui.http: HTTP requests as effects, replies as Events (goal 33, D-320–D-322). The app says what it wants in update();
# the runtime sends it on a worker thread and hands the reply back to update() later, as an Event. Nothing waits.
#
#   struct Main(App):
#       comptime HTTP = True                    # this app sends requests (links the transport; D-321)
#       var http: Http                          # the outbox
#       def update(mut self, e: Event):
#           if e.message == LOAD:
#               self.http.send(Request.get(GOT, "http://127.0.0.1:8000/admin/models").header_from_env("X-Mst-Admin", "MX_ADMIN"))
#           elif e.message == GOT:              # e.number = the status (0: no reply), e.text = the body, e.error = why not
#               ...
#       def requests(mut self) -> List[Request]:
#           return self.http.take()
#
# Streams (goal 35, D-700): `Request.post_json(PIECE, url, body).stream(END)`: each SSE event (or, for any other body, each
# piece as it arrives) comes to update() as its own `PIECE` Event (name = the SSE event's type, "message" by default, or
# "chunk"; text = its data; number = 1, 2, …), then one `END` Event (number = the status, error = why it stopped early:
# dropped, timed out, cancelled). `Http.cancel(id)` stops a tagged request; a stream's timeout is its longest silence.
#
# The transport (how bytes reach the server) sits behind `Transport`: today mojoui.http_socket (HTTP/1.1 over libc sockets,
# http:// only); later flare (TLS, HTTP/2–3) as one more file and a build switch (mojoui/effects.mojo, docs/http.md).

from std.atomic import Atomic
from std.memory.alloc import unsafe_alloc

comptime GET = "GET"
comptime POST = "POST"
comptime TLS_NEEDED = "https needs a TLS backend (flare, Mojo ≥ 1.2); this build has plain HTTP only"


struct Request(Copyable, Movable):
    """One HTTP request. `msg` is the message its reply comes back as; `id` tells requests with the same message apart."""

    var msg: Int
    var id: Int
    var method: String
    var url: String
    var names: List[String]  # headers, in order
    var values: List[String]
    var env_names: List[String]  # headers whose value is read from an environment variable when the request is sent
    var env_vars: List[String]
    var body: String
    var timeout_ms: Int  # the whole request: connect, send, wait, read (a stream: the longest silence)
    var stream_end: Int  # -1: one reply; else a stream, and this is the message its end comes back as
    var cancels: Bool  # not a request: Http.cancel(id) asking the runtime to stop request `id`

    def __init__(out self, msg: Int, method: String, url: String, body: String = ""):
        self.msg = msg
        self.id = 0
        self.method = method
        self.url = url
        self.names = List[String]()
        self.values = List[String]()
        self.env_names = List[String]()
        self.env_vars = List[String]()
        self.body = body
        self.timeout_ms = 30_000
        self.stream_end = -1
        self.cancels = False

    @staticmethod
    def get(msg: Int, url: String) -> Request:
        return Request(msg, GET, url)

    @staticmethod
    def post_json(msg: Int, url: String, json: String) -> Request:
        """A POST of a JSON body (mojoui.json's json_string writes strings into one)."""
        return Request(msg, POST, url, json).header("Content-Type", "application/json")

    def header(var self, name: String, value: String) -> Self:
        self.names.append(name)
        self.values.append(value)
        return self^

    def header_from_env(var self, name: String, variable: String) -> Self:
        """A header whose value is the environment variable `variable`, read on the worker when the request goes out
        (a key never sits in the app's state or its views). Unset: the header isn't sent."""
        self.env_names.append(name)
        self.env_vars.append(variable)
        return self^

    def timeout(var self, ms: Int) -> Self:
        self.timeout_ms = ms
        return self^

    def tagged(var self, id: Int) -> Self:
        self.id = id
        return self^

    def stream(var self, end_msg: Int) -> Self:
        """Read the reply as it comes: each SSE event (a `text/event-stream` reply) or each piece of any other body comes
        back as its own `msg` Event, then one `end_msg` Event with the status (and the body, for a status that isn't
        2xx: no pieces then). The timeout becomes the longest wait for the next bytes (30 s unless set)."""
        self.stream_end = end_msg
        return self^


struct Response(Copyable, Movable):
    """What came back. `status` 0 means no reply, and `error` says why (refused, timed out, https…); any status the
    server sends, 500 too, is a reply, not an error."""

    var status: Int
    var names: List[String]  # reply headers, lower-case names
    var values: List[String]
    var body: List[UInt8]
    var error: String

    def __init__(out self):
        self.status = 0
        self.names = List[String]()
        self.values = List[String]()
        self.body = List[UInt8]()
        self.error = ""

    @staticmethod
    def failed(why: String) -> Response:
        var r = Response()
        r.error = why
        return r^

    def header(self, name: String) -> String:
        """A reply header's value ("" when absent); `name` in lower case."""
        for i in range(len(self.names)):
            if self.names[i] == name:
                return self.values[i]
        return ""

    def text(self) -> String:
        """The body as text (bytes that aren't UTF-8 become U+FFFD)."""
        try:
            return String(from_utf8=Span(self.body))
        except:
            return utf8_lossy(self.body)


def utf8_lossy(b: List[UInt8]) -> String:
    var out = List[UInt8]()
    var i = 0
    while i < len(b):
        var c = Int(b[i])
        var n = 1 if c < 0x80 else (2 if c >= 0xC2 and c < 0xE0 else (3 if c >= 0xE0 and c < 0xF0 else (4 if c >= 0xF0 and c < 0xF5 else 0)))
        var ok = n > 0 and i + n <= len(b)
        if ok:
            for k in range(1, n):
                if Int(b[i + k]) & 0xC0 != 0x80:
                    ok = False
        if ok:
            try:
                _ = String(from_utf8=Span(b)[i : i + n])
            except:
                ok = False
        if ok:
            for k in range(n):
                out.append(b[i + k])
            i += n
        else:
            out.append(0xEF)
            out.append(0xBF)
            out.append(0xBD)
            i += 1
    return String(unsafe_from_utf8=out)


trait Transport:
    """How a request reaches its server: one blocking call, made on a worker thread (never on the UI thread)."""

    @staticmethod
    def send(req: Request) -> Response:
        ...

    @staticmethod
    def stream(req: Request, mut sink: Sink) -> Response:
        """`req` as a stream: each SSE event (or body piece) handed to `sink.push` as it arrives (only for a 2xx status;
        another status's body goes in the Response), returning when the stream ends; stops early when
        `sink.cancelled()`. The Response carries the status and headers, or `error`."""
        ...


@fieldwise_init
struct Piece(Copyable, Movable):
    """One SSE event (or one piece of a streamed body)."""

    var name: String  # the SSE event's type ("message" when it names none), or "chunk"
    var data: String  # its data lines joined by "\n" (a chunk's text)


struct SseReader(Movable):
    """Server-sent events from bytes as they arrive (the WHATWG event-stream format): `feed` returns the events finished
    so far. Lines end in LF or CRLF; `data:` lines join with LF; `event:` names the type; comments (":") and `id:` /
    `retry:` are read and ignored. A UTF-8 character split across feeds is kept until it's whole."""

    var line: List[UInt8]
    var data: String
    var has_data: Bool
    var name: String

    def __init__(out self):
        self.line = List[UInt8]()
        self.data = ""
        self.has_data = False
        self.name = ""

    def feed(mut self, bytes: Span[UInt8, _]) -> List[Piece]:
        var out = List[Piece]()
        for b in bytes:
            if b != 10:
                self.line.append(b)
                continue
            if len(self.line) > 0 and self.line[len(self.line) - 1] == 13:
                _ = self.line.pop()
            var text = utf8_lossy(self.line)
            self.line.clear()
            if text.byte_length() == 0:
                if self.has_data:
                    out.append(Piece(self.name if self.name.byte_length() > 0 else String("message"), self.data))
                self.data = ""
                self.has_data = False
                self.name = ""
                continue
            if text.startswith(":"):
                continue
            var colon = text.find(":")
            var field = text if colon < 0 else String(text[byte = : colon])
            var value = String("") if colon < 0 else String(text[byte = colon + 1 :])
            if value.startswith(" "):
                var trimmed = String(value[byte = 1 :])
                value = trimmed
            if field == "data":
                self.data = (self.data + "\n" + value) if self.has_data else value
                self.has_data = True
            elif field == "event":
                self.name = value
        return out^


def utf8_whole(b: List[UInt8]) -> Int:
    """How many leading bytes of `b` end on a whole UTF-8 character (a sequence cut at the end is held back)."""
    var n = len(b)
    var back = 0
    while back < 3 and back < n and (Int(b[n - 1 - back]) & 0xC0) == 0x80:
        back += 1
    if back < n:
        var lead = Int(b[n - 1 - back])
        var need = 1 if lead < 0x80 else (2 if lead >= 0xC0 and lead < 0xE0 else (3 if lead >= 0xE0 and lead < 0xF0 else (4 if lead >= 0xF0 else 1)))
        if need > back + 1:
            return n - back - 1
    return n


comptime _A = Atomic[Scalar[DType.int64]]
comptime _P = Pointer[Int64, MutUntrackedOrigin]
comptime S_CANCEL = 3  # the request's shared words (mojoui.effects): 1 once the app cancelled
comptime S_HEAD = 4  # the reader's last node


def _word(words: Int, k: Int) -> _P:
    return _P(unsafe_from_address=words + 8 * k)


def new_node(piece_addr: Int) -> Int:
    """A list node: [next node's address (0: none yet), its piece's address]."""
    var n = unsafe_alloc[Int64](2)
    _A.store(_word(Int(n), 0), 0)
    _A.store(_word(Int(n), 1), Int64(piece_addr))
    return Int(n)


struct Sink(Movable):
    """Where a transport's worker puts a stream's pieces: a list one thread writes and the runtime reads (each node is
    linked only once it's whole), and the app's cancel flag."""

    var words: Int
    var tail: Int
    var count: Int

    def __init__(out self, words: Int, tail: Int):
        self.words = words
        self.tail = tail
        self.count = 0

    def push(mut self, var piece: Piece):
        var p = unsafe_alloc[Piece](1)
        p.unsafe_write(piece^)
        var node = new_node(Int(p))
        _A.store(_word(self.tail, 0), Int64(node))  # (after the node is written: the reader sees all of it)
        self.tail = node
        self.count += 1

    def cancelled(self) -> Bool:
        return _A.load(_word(self.words, S_CANCEL)) != 0


struct Http(Movable):
    """An app's outbox: requests asked for since the runtime last looked (App.requests returns take())."""

    var queued: List[Request]

    def __init__(out self):
        self.queued = List[Request]()

    def send(mut self, var req: Request):
        self.queued.append(req^)

    def get(mut self, msg: Int, url: String):
        self.send(Request.get(msg, url))

    def cancel(mut self, id: Int):
        """Stop the request (or stream) tagged `id`: its end comes back at once with the error "cancelled" (a stream's
        end message; a plain request's own message); nothing of it after that. An id not out changes nothing."""
        var r = Request(0, "", "")
        r.id = id
        r.cancels = True
        self.queued.append(r^)

    def take(mut self) -> List[Request]:
        var out = self.queued^
        self.queued = List[Request]()
        return out^


struct Url(Copyable, Movable):
    """A URL split into what a transport needs."""

    var scheme: String
    var host: String
    var port: Int
    var target: String  # path and query, at least "/"

    def __init__(out self, scheme: String, host: String, port: Int, target: String):
        self.scheme = scheme
        self.host = host
        self.port = port
        self.target = target

    @staticmethod
    def parse(url: String) raises -> Url:
        var rest: String
        var scheme: String
        if url.startswith("http://"):
            scheme = "http"
            rest = String(url[byte = 7 :])
        elif url.startswith("https://"):
            scheme = "https"
            rest = String(url[byte = 8 :])
        else:
            raise Error("not an http:// or https:// URL: " + shown(url))
        var slash = rest.find("/")
        var authority = rest if slash < 0 else String(rest[byte = : slash])
        var target = String("/") if slash < 0 else String(rest[byte = slash :])
        var port = 80 if scheme == "http" else 443
        var host = authority
        if authority.startswith("["):
            raise Error("IPv6 addresses aren't supported yet: " + shown(url))
        var colon = authority.rfind(":")
        if colon >= 0:
            host = String(authority[byte = : colon])
            var digits = String(authority[byte = colon + 1 :])
            if digits.byte_length() == 0 or digits.byte_length() > 5:
                raise Error("a bad port in " + shown(url))
            port = 0
            for b in digits.as_bytes():
                if b < 48 or b > 57:
                    raise Error("a bad port in " + shown(url))
                port = port * 10 + Int(b) - 48
            if port == 0 or port > 65535:
                raise Error("a bad port in " + shown(url))
        if host.byte_length() == 0:
            raise Error("no host in " + shown(url))
        for b in host.as_bytes():  # (a host name or an IPv4 address: it goes into the Host header)
            var c = Int(b)
            if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 45 or c == 46 or c == 95):
                raise Error("a host that isn't a host name in the URL (" + shown(host) + ")")
        for b in target.as_bytes():  # (the request line: printable ASCII, no spaces; escape the rest with uri_component)
            if Int(b) <= 32 or Int(b) >= 127:
                raise Error("a space or a control character in the URL's path (" + shown(target) + "): escape it (uri_component)")
        return Url(scheme, host, port, target)


def shown(s: String) -> String:
    """`s` for an error message: control characters and non-ASCII bytes as \\xNN (a message never splits a line)."""
    var hexd = String("0123456789abcdef")
    var out = String("")
    for b in s.as_bytes():
        var c = Int(b)
        if c >= 32 and c < 127:
            out += chr(c)
        else:
            out += "\\x" + String(hexd[byte = c // 16]) + String(hexd[byte = c % 16])
    return out


def is_token(s: String) -> Bool:
    """An HTTP token (RFC 9110 §5.6.2): a method or a header name. One or more of A–Z a–z 0–9 ! # $ % & ' * + - . ^ _ ` | ~."""
    if s.byte_length() == 0:
        return False
    var marks = String("!#$%&'*+-.^_`|~")
    for b in s.as_bytes():
        var c = Int(b)
        if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or (c < 128 and chr(c) in marks)):
            return False
    return True


def has_control(s: String) -> Bool:
    """A control character a header value may not hold (any below 32 but the tab, and DEL): it would split the request."""
    for b in s.as_bytes():
        var c = Int(b)
        if (c < 32 and c != 9) or c == 127:
            return True
    return False


def request_problem(req: Request) -> String:
    """Why `req` can't go out as written ("": it can), for every transport: a method or header name that isn't a token,
    a header value with a control character. (The URL's own rules are Url.parse's; an env header's value is checked
    where it's read, on the worker.) Never sent, so no request is ever split into another (reviewer, D-570)."""
    if not is_token(req.method):
        return "a method that isn't an HTTP token (" + shown(req.method) + ")"
    for n in req.names:
        if not is_token(n):
            return "a header name that isn't an HTTP token (" + shown(n) + ")"
    for n in req.env_names:
        if not is_token(n):
            return "a header name that isn't an HTTP token (" + shown(n) + ")"
    for i in range(len(req.values)):
        if has_control(req.values[i]):
            return "the header " + req.names[i] + "'s value holds a control character"
    return ""


def uri_component(s: String) -> String:
    """JavaScript's encodeURIComponent: every byte but A–Z a–z 0–9 - _ . ! ~ * ' ( ) as %XX (UTF-8), for a query value
    or a path part ("owner/name" → "owner%2Fname")."""
    var hexd = String("0123456789ABCDEF")
    var keep = String("-_.!~*'()")
    var out = String("")
    for b in s.as_bytes():
        var c = Int(b)
        if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or (c < 128 and chr(c) in keep):
            out += chr(c)
        else:
            out += "%" + String(hexd[byte = c // 16]) + String(hexd[byte = c % 16])
    return out
