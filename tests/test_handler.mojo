# Goal 60 (D-6007, D-6008): mojoui.serve's concurrent Handler: no lock, many requests at once, a blocking request
# answered on a thread of its own (Flare's offload patch) while the reactor keeps answering everyone else, every reply
# with an X-Request-Id. Proved over real sockets with Flare's client.
from std.memory import Pointer
from mojoui.serve import Handler, Req, Reply, serve, spawn
from mojoui.clock import now_ns
from mojoui import libc
from flare.http import HttpClient


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
        return Reply.json('{"fast": true, "peer": "' + req.peer + '"}')

    def blocking(self, req: Req) -> Bool:
        return req.path == "/slow"

    def tick(self):
        pass

    def stop(self):
        pass


def slow_call(port: Int):
    try:
        var r = HttpClient(timeout_ms=10_000).get("http://127.0.0.1:" + String(port) + "/slow")
        print("slow answered " + String(r.status) + " " + r.text())
    except e:
        print("slow failed: " + String(e))


def main() raises:
    var served = serve(App(), port=0, workers=1)  # (one reactor: a blocking request on it would stall everything)
    var base = "http://127.0.0.1:" + String(served.port)
    var c = HttpClient(timeout_ms=5000)
    var r = c.get(base + "/x")
    expect(r.status == 200 and "fast" in r.text() and "127.0.0.1" in r.text(), "a fast answer: " + r.text())
    expect(r.headers.get("x-request-id").byte_length() == 16, "an X-Request-Id")
    print("handler: ok")
    _ = spawn[slow_call](served.port)
    _ = libc.poll(0, 0, 300)
    var worst = 0
    for _ in range(20):
        var t0 = now_ns()
        var f = c.get(base + "/x")
        worst = max(worst, now_ns() - t0)
        expect(f.status == 200, "fast during slow")
    expect(worst < 200_000_000, "a fast request waited " + String(worst // 1_000_000) + " ms behind a blocking one")
    _ = libc.poll(0, 0, 2500)
    print("offload: ok (slowest fast request " + String(worst // 1000) + " µs)")
    served.stop()
