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
# The transport (how bytes reach the server) sits behind `Transport`: today mojoui.http_socket (HTTP/1.1 over libc sockets,
# http:// only); later flare (TLS, HTTP/2–3) as one more file and a build switch (mojoui/effects.mojo, docs/http.md).

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
    var timeout_ms: Int  # the whole request: connect, send, wait, read

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


struct Http(Movable):
    """An app's outbox: requests asked for since the runtime last looked (App.requests returns take())."""

    var queued: List[Request]

    def __init__(out self):
        self.queued = List[Request]()

    def send(mut self, var req: Request):
        self.queued.append(req^)

    def get(mut self, msg: Int, url: String):
        self.send(Request.get(msg, url))

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
            raise Error("not an http:// or https:// URL: " + url)
        var slash = rest.find("/")
        var authority = rest if slash < 0 else String(rest[byte = : slash])
        var target = String("/") if slash < 0 else String(rest[byte = slash :])
        var port = 80 if scheme == "http" else 443
        var host = authority
        if authority.startswith("["):
            raise Error("IPv6 addresses aren't supported yet: " + url)
        var colon = authority.rfind(":")
        if colon >= 0:
            host = String(authority[byte = : colon])
            var digits = String(authority[byte = colon + 1 :])
            if digits.byte_length() == 0 or digits.byte_length() > 5:
                raise Error("a bad port in " + url)
            port = 0
            for b in digits.as_bytes():
                if b < 48 or b > 57:
                    raise Error("a bad port in " + url)
                port = port * 10 + Int(b) - 48
            if port == 0 or port > 65535:
                raise Error("a bad port in " + url)
        if host.byte_length() == 0:
            raise Error("no host in " + url)
        return Url(scheme, host, port, target)


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
