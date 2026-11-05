# Goal 50 M2: mojoui.serve from inside one program: a Service on its own thread (Server.start), asked through mojoui's
# own client (mojoui.effects, as an app sends requests). Routes and parameters, query values, JSON bodies, status codes,
# headers both ways, the state's lock under 50 requests at once, an SSE stream written by a thread (a Pipe), a stream
# proxied from an upstream (proxy), a dead upstream's 502, and a quick answer while a slow stream is still open.
from mojoui.serve import Server, Service, Req, Reply, Pipe, spawn, proxy
from mojoui.http import Request, Response, Piece
from mojoui.effects import start, Backend, InFlight
from mojoui.json import Json, json_string
from mojoui.clock import now_ns
from mojoui import libc

comptime EVENTS = 6


def tick_events(addr: Int):
    """Writes EVENTS SSE events 60 ms apart, then closes."""
    var pipe = Pipe.at(addr)
    for i in range(EVENTS):
        if pipe.gone():
            break
        pipe.write("event: tick\ndata: " + String(i) + "\n\n")
        _ = libc.poll(0, 0, 60)
    pipe.close()
    pipe.release()


struct Api(Service):
    var count: Int
    var port: Int

    def __init__(out self):
        self.count = 0
        self.port = 0

    def tick(mut self):
        pass

    def answer(mut self, mut req: Req) -> Reply:
        if req.matches("PUT", "/port"):
            try:
                self.port = atol(req.body)
            except:
                return Reply.error(400, "not a port", "bad_port")
            return Reply.empty()
        if req.matches("GET", "/items/{id}"):
            return Reply.json('{"id": ' + json_string(req.param("id")) + ', "x": ' + json_string(req.arg("x")) + "}").header("X-Served", "mojoui")
        if req.matches("GET", "/files/{path*}"):
            return Reply.text(req.param("path"))
        if req.matches("POST", "/count"):
            var before = self.count
            _ = libc.poll(0, 0, 1)  # (a race would lose increments here)
            self.count = before + 1
            return Reply.json('{"count": ' + String(self.count) + "}", 201)
        if req.matches("GET", "/count"):
            return Reply.json('{"count": ' + String(self.count) + "}")
        if req.matches("GET", "/hdr"):
            return Reply.text(req.header("X-Test"))
        if req.matches("POST", "/echo"):
            try:
                var j = Json.parse(req.body)
                return Reply.json('{"name": ' + json_string(j.text(j.get(0, "name"))) + "}")
            except:
                return Reply.error(400, "not JSON", "bad_json")
        if req.matches("GET", "/sse"):
            var pipe = Pipe()
            var r = Reply.stream(pipe)
            _ = spawn[tick_events](pipe.share().addr)
            pipe.release()
            return r^
        if req.matches("GET", "/proxy"):
            var pipe = Pipe(keep_bytes=4096)
            _ = proxy(Request.get(0, "http://127.0.0.1:" + String(self.port) + "/sse").timeout(5000), pipe)
            var r = Reply.stream(pipe, wait_head_ms=3000)
            pipe.release()
            return r^
        if req.matches("GET", "/dead"):
            var pipe = Pipe()
            _ = proxy(Request.get(0, "http://127.0.0.1:9/").timeout(2000), pipe)
            var r = Reply.stream(pipe, wait_head_ms=3000)
            pipe.release()
            return r^
        return Reply.not_found()


def wait(mut job: InFlight, seconds: Int = 20) raises -> Response:
    var t0 = now_ns()
    while not job.ready():
        if now_ns() - t0 > seconds * 1_000_000_000:
            raise Error("no answer in " + String(seconds) + " s")
        _ = libc.poll(0, 0, 1)
    return job.response()


def call(var req: Request) raises -> Response:
    var job = start[Backend](req^)
    return wait(job)


def stream(url: String, mut times: List[Int]) raises -> List[Piece]:
    """The SSE events of a GET, and when each arrived (ms after the request)."""
    var job = start[Backend](Request.get(1, url).stream(2).timeout(10_000))
    var t0 = now_ns()
    var out = List[Piece]()
    while not job.ready():
        for p in job.take_pieces():
            out.append(p.copy())
            times.append((now_ns() - t0) // 1_000_000)
        if now_ns() - t0 > 20_000_000_000:
            raise Error("the stream didn't end")
        _ = libc.poll(0, 0, 2)
    for p in job.take_pieces():
        out.append(p.copy())
        times.append((now_ns() - t0) // 1_000_000)
    var r = job.response()
    if r.error != "":
        raise Error(url + ": " + r.error)
    return out^


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def main() raises:
    var port = Server.start(Api(), workers=4)
    var base = "http://127.0.0.1:" + String(port)
    _ = call(Request(0, "PUT", base + "/port", String(port)))
    # routes, parameters, query, headers both ways
    var r = call(Request.get(0, base + "/items/a%2Fb?x=hello%20world"))
    var j = Json.parse(r.text())
    check(r.status == 200 and j.text(j.get(0, "id")) == "a/b" and j.text(j.get(0, "x")) == "hello world", "items: " + String(r.status) + " " + r.text())
    check(r.header("x-served") == "mojoui" and r.header("content-type") == "application/json", "reply headers: " + r.header("content-type"))
    check(call(Request.get(0, base + "/files/a/b/c.txt")).text() == "a/b/c.txt", "the {path*} rest")
    check(call(Request.get(0, base + "/hdr").header("X-Test", "from the client")).text() == "from the client", "request header")
    var nf = call(Request.get(0, base + "/nope"))
    check(nf.status == 404 and nf.text().find("not_found") >= 0, "404: " + String(nf.status))
    var e = call(Request.post_json(0, base + "/echo", '{"name": "Ada"}'))
    check(e.status == 200 and e.text() == '{"name": "Ada"}', "echo: " + e.text())
    check(call(Request.post_json(0, base + "/echo", "{nope")).status == 400, "bad JSON is a 400")
    print("ROUTES: ok")
    # the lock: 50 at once, each a read-modify-write
    var jobs = List[InFlight]()
    for _ in range(50):
        jobs.append(start[Backend](Request(0, "POST", base + "/count", "")))
    for i in range(len(jobs)):
        var a = wait(jobs[i])
        check(a.status == 201, "count POST: " + String(a.status) + " " + a.error)
    var c = Json.parse(call(Request.get(0, base + "/count")).text())
    check(c.number(c.get(0, "count")) == 50, "50 increments counted " + String(c.number(c.get(0, "count"))))
    print("LOCK: 50 of 50")
    # SSE from a thread, and a quick answer while it streams
    var times = List[Int]()
    var slow = start[Backend](Request.get(1, base + "/sse").stream(2).timeout(10_000))
    _ = libc.poll(0, 0, 50)
    var t0 = now_ns()
    _ = call(Request.get(0, base + "/items/1"))
    var quick_ms = (now_ns() - t0) // 1_000_000
    check(quick_ms < 300, "a request during a stream took " + String(quick_ms) + " ms")
    _ = wait(slow)
    var ev = stream(base + "/sse", times)
    check(len(ev) == EVENTS, "SSE events: " + String(len(ev)))
    for i in range(len(ev)):
        check(ev[i].name == "tick" and ev[i].data == String(i), "event " + String(i) + ": " + ev[i].name + " " + ev[i].data)
    check(times[len(times) - 1] - times[0] >= 200, "the events came all at once (" + String(times[0]) + " … " + String(times[len(times) - 1]) + " ms)")
    print("SSE: " + String(len(ev)) + " events over " + String(times[len(times) - 1] - times[0]) + " ms; a request meanwhile " + String(quick_ms) + " ms")
    # the proxy: the same stream through a second hop; a dead upstream
    var ptimes = List[Int]()
    var pv = stream(base + "/proxy", ptimes)
    check(len(pv) == EVENTS and pv[EVENTS - 1].data == String(EVENTS - 1), "proxied events: " + String(len(pv)))
    check(ptimes[len(ptimes) - 1] - ptimes[0] >= 200, "the proxy buffered the stream instead of relaying it")
    var dead = call(Request.get(0, base + "/dead"))
    check(dead.status == 502 and dead.text().find("upstream") >= 0, "a dead upstream: " + String(dead.status) + " " + dead.text())
    print("PROXY: " + String(len(pv)) + " events relayed; dead upstream 502")
    print("serve: ok")
