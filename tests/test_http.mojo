# mojoui.http through the runtime, as an app uses it: update() asks for requests, the replies come back as Events
# from Runtime.poll. Needs scripts/http_server.py running (scripts/check.py M1 starts it):
#   HTTP_TEST_URL=http://127.0.0.1:PORT/ HTTP_TEST_DEAD=http://127.0.0.1:PORT2/ HTTP_TEST_SECRET=… build/test_http
# Prints one line per case (scripts/check.py compares them with what the server sent and saw).
from std.testing import assert_equal, assert_true
from std.os import getenv
from mojoui.app import App, Event, Runtime
from mojoui import View, Text
from mojoui.http import Http, Request, Response, Url, TLS_NEEDED
from mojoui.http_socket import SocketTransport
from mojoui.clock import now_ns

comptime GO = 1
comptime GET_JSON = 10
comptime POST_JSON = 11
comptime HEADER = 12
comptime CHUNKED = 13
comptime BIG = 14
comptime TIMEOUT = 15
comptime REFUSED = 16
comptime FAIL = 17
comptime HTTPS = 18


def name_of(msg: Int) -> String:
    var names: List[String] = ["GET", "POST", "HEADER", "CHUNKED", "BIG", "TIMEOUT", "REFUSED", "FAIL", "HTTPS"]
    return names[msg - GET_JSON]


struct Offline(App):
    """An app that didn't say HTTP = True: its requests come back as errors, nothing is sent."""
    var http: Http
    var got: List[Event]

    def __init__(out self):
        self.http = Http()
        self.got = List[Event]()

    def title(self) -> String:
        return "offline"

    def update(mut self, e: Event):
        if e.message == GO:
            self.http.get(GET_JSON, getenv("HTTP_TEST_URL") + "json")
        else:
            self.got.append(e.copy())

    def view(self) -> View:
        return Text("offline")

    def requests(mut self) -> List[Request]:
        return self.http.take()


struct Probe(App):
    comptime HTTP = True
    var http: Http
    var got: List[Event]
    var base: String

    def __init__(out self):
        self.http = Http()
        self.got = List[Event]()
        self.base = getenv("HTTP_TEST_URL")

    def title(self) -> String:
        return "http probe"

    def update(mut self, e: Event):
        if e.message == GO:
            var b = self.base
            self.http.send(Request.get(GET_JSON, b + "json"))
            self.http.send(Request.post_json(POST_JSON, b + "echo", '{"name": "Ada", "n": 3, "ok": true}'))
            self.http.send(Request.get(HEADER, b + "header?name=X-Test-Key").header_from_env("X-Test-Key", "HTTP_TEST_SECRET"))
            self.http.send(Request.get(CHUNKED, b + "chunked"))
            self.http.send(Request.get(BIG, b + "big").tagged(7))
            self.http.send(Request.get(TIMEOUT, b + "slow?ms=3000").timeout(500))
            self.http.send(Request.get(REFUSED, getenv("HTTP_TEST_DEAD") + "json"))
            self.http.send(Request.get(FAIL, b + "fail"))
            self.http.send(Request.get(HTTPS, "https://127.0.0.1:1/json"))
        else:
            self.got.append(e.copy())

    def view(self) -> View:
        return Text(String(len(self.got)) + " replies")

    def requests(mut self) -> List[Request]:
        return self.http.take()


def fnv1a(s: String) -> String:
    var h = UInt64(0xcbf29ce484222325)
    for b in s.as_bytes():
        h = (h ^ UInt64(b)) * 0x100000001b3
    var hex = String("")
    var digits = "0123456789abcdef"
    for k in range(16):
        var d = Int((h >> UInt64((15 - k) * 4)) & 15)
        hex += String(digits[byte = d : d + 1])
    return hex


def main() raises:
    assert_true(getenv("HTTP_TEST_URL") != "", "set HTTP_TEST_URL (scripts/http_server.py)")
    # URLs
    var u = Url.parse("http://localhost:8123/a/b?c=1")
    assert_equal(u.host, "localhost")
    assert_equal(u.port, 8123)
    assert_equal(u.target, "/a/b?c=1")
    assert_equal(Url.parse("http://example.com").target, "/")
    assert_equal(Url.parse("https://example.com/x").port, 443)
    for bad in ["ftp://x/", "http://", "http://h:0/", "http://h:99999/", "http://h:8x/", "http://[::1]/"]:
        var failed = False
        try:
            _ = Url.parse(bad)
        except:
            failed = True
        assert_true(failed, "refuses " + bad)
    # the transport on its own, and a header that would split the request
    assert_equal(SocketTransport.send(Request.get(0, "https://example.com/")).error, TLS_NEEDED)
    assert_true(SocketTransport.send(Request.get(0, getenv("HTTP_TEST_URL") + "json").header("X-Bad", "a\r\nX-Evil: 1")).error.find("line break") >= 0)
    # through the runtime: one update asks for every case; it returns at once, the replies come later
    var rt = Runtime(Probe())
    assert_equal(rt.wake_in(0), -1)
    var t0 = now_ns()
    _ = rt.dispatch(GO)
    var dispatch_ms = Float64(now_ns() - t0) / 1e6
    assert_equal(len(rt.inflight), 9)
    var sent_at = now_ns()
    var arrived = List[Int](length=20, fill=-1)
    var deadline = now_ns() + 15_000_000_000
    while len(rt.app.got) < 9 and now_ns() < deadline:
        var w = rt.wake_in(now_ns() // 1000)
        assert_true(w >= 0 and w <= 4000, "polls often while requests are out")
        _ = rt.poll(now_ns() // 1000)
        for ref e in rt.app.got:
            if arrived[e.message] < 0:
                arrived[e.message] = (now_ns() - sent_at) // 1_000_000
    assert_equal(len(rt.app.got), 9, "every request answered")
    assert_equal(len(rt.inflight), 0)
    assert_equal(rt.wake_in(0), -1, "nothing left to wait for")
    print("DISPATCH: " + String(dispatch_ms) + " ms")
    for ref e in rt.app.got:
        var name = name_of(e.message)
        if e.message == BIG:
            assert_equal(e.id, 7)
            print("BIG: " + String(e.number) + " " + String(e.text.byte_length()) + " " + fnv1a(e.text))
        elif e.message == TIMEOUT:
            assert_equal(e.number, 0)
            print("TIMEOUT: " + String(arrived[TIMEOUT]) + " " + e.error)
        elif e.message == REFUSED or e.message == HTTPS:
            assert_equal(e.number, 0)
            assert_true(e.error != "")
            print(name + ": " + e.error)
        else:
            assert_equal(e.error, "", name)
            print(name + ": " + String(e.number) + " " + e.text)
    # an app that didn't say HTTP = True gets an error event, not a request
    var off = Runtime(Offline())
    _ = off.dispatch(GO)
    assert_equal(len(off.inflight), 0)
    assert_equal(off.wake_in(0), 0)
    _ = off.poll(0)
    assert_equal(len(off.app.got), 1)
    assert_true(off.app.got[0].error.find("HTTP = True") >= 0)
    print("test_http: all passed")
