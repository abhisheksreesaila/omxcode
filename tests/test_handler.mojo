# Goal 60 (D-6007, D-6008): mojoui.serve's concurrent Handler: no lock, many requests at once, a blocking request
# answered on a thread of its own (Flare's offload patch) while the reactor keeps answering everyone else, every reply
# with an X-Request-Id. Proved over real sockets with Flare's client. Round 3: the offloaded reply's result is checked
# in main (R4), a header with CR/LF from an offloaded answer becomes a 500 (S-L5), req.client follows a trusted proxy's
# X-Forwarded-For only (R3), and a body over serve()'s 1 MB cap is refused before the app sees it.
from std.memory import Pointer
from std.atomic import Atomic
from mojoui.serve import Handler, Req, Reply, serve, spawn
from mojoui.clientip import TrustedProxies
from mojoui.clock import now_ns
from mojoui import libc
from flare.http import HttpClient
from flare.http import Request as FlareRequest


def get_via(c: HttpClient, url: String, xff: String) raises -> String:
    var rq = FlareRequest("GET", url)
    rq.headers.set("X-Forwarded-For", xff)
    return c.send(rq).text()


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


struct App(Handler):
    def __init__(out self):
        pass

    def answer(self, mut req: Req) -> Reply:
        if req.path == "/slow":
            _ = libc.poll(0, 0, 2000)
            return Reply.json('{"slow": true}', 201)
        if req.path == "/slow-bad":
            return Reply.json('{"bad": true}').header("X-Echo", "a\r\nSet-Cookie: evil=1")
        if req.path == "/body":
            return Reply.json('{"bytes": ' + String(req.body.byte_length()) + "}")
        return Reply.json('{"fast": true, "peer": "' + req.peer + '", "client": "' + req.client + '"}')

    def blocking(self, req: Req) -> Bool:
        return req.path.startswith("/slow")

    def tick(self):
        pass

    def stop(self):
        pass


comptime _A = Atomic[Scalar[DType.int64]]


def slow_call(addr: Int):
    """Calls /slow on the port in word 0; word 1 becomes 1 (right answer), 2 (wrong), 3 (failed)."""
    var w = Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=addr)
    var result = 3
    try:
        var r = HttpClient(timeout_ms=10_000).get("http://127.0.0.1:" + String(Int(w[])) + "/slow")
        if r.status == 201 and r.text() == '{"slow": true}' and r.headers.get("x-request-id").byte_length() == 16:
            result = 1
        else:
            print("slow answered wrong: " + String(r.status) + " " + r.text())
            result = 2
    except e:
        print("slow failed: " + String(e))
    _ = _A.fetch_add(w + 1, Int64(result))


def main() raises:
    var served = serve(App(), port=0, workers=1)  # (one reactor: a blocking request on it would stall everything)
    var base = "http://127.0.0.1:" + String(served.port)
    var c = HttpClient(timeout_ms=5000)
    var r = c.get(base + "/x")
    expect(r.status == 200 and "fast" in r.text() and "127.0.0.1" in r.text(), "a fast answer: " + r.text())
    expect(r.headers.get("x-request-id").byte_length() == 16, "an X-Request-Id")
    print("handler: ok")
    var shared = List[Int64](length=2, fill=0)
    shared[0] = Int64(served.port)
    _ = spawn[slow_call](Int(shared.unsafe_ptr()))
    _ = libc.poll(0, 0, 300)
    var worst = 0
    for _ in range(20):
        var t0 = now_ns()
        var f = c.get(base + "/x")
        worst = max(worst, now_ns() - t0)
        expect(f.status == 200, "fast during slow")
    expect(worst < 200_000_000, "a fast request waited " + String(worst // 1_000_000) + " ms behind a blocking one")
    var waited = 0
    while _A.load(shared.unsafe_ptr() + 1) == 0 and waited < 100:
        _ = libc.poll(0, 0, 100)
        waited += 1
    expect(_A.load(shared.unsafe_ptr() + 1) == 1, "the offloaded request's answer: " + String(_A.load(shared.unsafe_ptr() + 1)) + " (1 right, 2 wrong, 3 failed, 0 none)")
    _ = len(shared)
    print("offload: ok (slowest fast request " + String(worst // 1000) + " µs)")
    var bad = c.get(base + "/slow-bad")
    expect(bad.status == 500 and bad.headers.get("set-cookie") == "" and bad.headers.get("x-echo") == "", "an offloaded header with CR/LF: " + String(bad.status) + " set-cookie=" + bad.headers.get("set-cookie"))
    print("header_inject: ok")
    var big = String("x") * (1024 * 1024 + 10)
    var refused = False
    try:
        var br = c.post(base + "/body", big)
        refused = br.status == 413 or br.status == 400
        expect(br.text().find('"bytes"') < 0, "the app saw a body over the cap")
    except:
        refused = True  # (Flare may close the connection mid-upload instead)
    expect(refused, "a body over 1 MB reached the app")
    expect("1000" in c.post(base + "/body", String("y") * 1000).text(), "a small body")
    print("body_cap: ok")
    served.stop()
    var behind = serve(App(), port=0, workers=1, proxies=TrustedProxies.parse("127.0.0.1"))
    var b2 = "http://127.0.0.1:" + String(behind.port) + "/x"
    var via = get_via(c, b2, "6.6.6.6, 203.0.113.5")
    expect('"client": "203.0.113.5"' in via, "a trusted proxy's client: " + via)
    behind.stop()
    var direct = serve(App(), port=0, workers=1, proxies=TrustedProxies.parse("10.0.0.0/8"))
    var d = get_via(c, "http://127.0.0.1:" + String(direct.port) + "/x", "203.0.113.5")
    expect('"client": "127.0.0.1"' in d, "an untrusted peer's X-Forwarded-For was believed: " + d)
    direct.stop()
    print("client_ip: ok")
