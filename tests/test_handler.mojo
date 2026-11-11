# Goal 60 (D-6007, D-6008): mojoui.serve's concurrent Handler: no lock, many requests at once, a blocking request
# answered on a thread of its own (Flare's offload patch) while the reactor keeps answering everyone else, every reply
# with an X-Request-Id. Proved over real sockets with Flare's client. Round 3: the offloaded reply's result is checked
# in main (R4), a header with CR/LF from an offloaded answer becomes a 500 (S-L5), req.client follows a trusted proxy's
# X-Forwarded-For only (R3), and a body over serve()'s 1 MB cap is refused before the app sees it.
# Hardening (2026-11-11, D-6033): blocking requests run on a small fixed pool of offload threads (made when serving
# starts, so their SQLite connections are kept), behind a bounded queue: past both, 503 with Retry-After.
from std.memory import Pointer
from std.os import listdir
from std.sys import CompilationTarget
from std.atomic import Atomic
from mojoui.serve import Handler, Req, Reply, serve, spawn, offload_queue_pipe, queue_job
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
        if req.path == "/slow-threads" or req.path == "/threads":  # (this process's threads now, Linux)
            return Reply.json('{"threads": ' + String(threads()) + "}")
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


def threads() -> Int:
    try:
        return len(listdir("/proc/self/task"))
    except:
        return -1


def raw_get(port: Int, path: String, xff: String = "") -> String:
    """GET over a plain libc socket, the whole reply as text ("" when it fails). (Flare's HttpClient would do; this
    keeps the burst's clients free of any client-side pooling.)"""
    var fd = libc.socket(2, 1, 0)  # AF_INET, SOCK_STREAM
    if fd < 0:
        return ""
    var sa = List[UInt8](length=16, fill=0)
    if CompilationTarget.is_macos():
        sa[0] = 16
        sa[1] = 2
    else:
        sa[0] = 2
    sa[2] = UInt8((port >> 8) & 255)
    sa[3] = UInt8(port & 255)
    sa[4] = 127
    sa[7] = 1
    var out = String("")
    if libc.connect(fd, Int(sa.unsafe_ptr()), 16) == 0:
        var rq = "GET " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n" + ("X-Forwarded-For: " + xff + "\r\n" if xff != "" else "") + "\r\n"
        _ = libc.send(fd, Int(rq.unsafe_ptr()), rq.byte_length(), 0)
        _ = rq.byte_length()
        var buf = List[UInt8](length=4096, fill=0)
        var got = List[UInt8]()
        while True:
            var n = libc.recv(fd, Int(buf.unsafe_ptr()), 4096, 0)
            if n <= 0:
                break
            for i in range(n):
                got.append(buf[i])
        out = String(from_utf8_lossy=Span(got))
    _ = len(sa)
    _ = libc.close(fd)
    return out


def burst_call(addr: Int):
    """Calls /slow on the port in word 0, then counts the answer: word 1 (201), 2 (503 with Retry-After), 3 (other),
    4 (429 with Retry-After). Word 5: an X-Forwarded-For client number (0: none)."""
    var w = Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=addr)
    var who = Int((w + 5)[])
    var r = raw_get(Int(w[]), "/slow", "203.0.113." + String(who) if who > 0 else String(""))
    var k = 3
    if r.startswith("HTTP/1.1 201"):
        k = 1
    elif r.startswith("HTTP/1.1 503") and "retry-after:" in r.lower():
        k = 2
    elif r.startswith("HTTP/1.1 429") and "retry-after:" in r.lower():
        k = 4
    _ = _A.fetch_add(w + k, 1)


def answered(addr: Int) -> Int:
    var w = Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=addr)
    return Int(_A.load(w + 1) + _A.load(w + 2) + _A.load(w + 3) + _A.load(w + 4))


def burst(port: Int, n: Int, who: Int = 0) -> List[Int64]:
    """n concurrent /slow calls as client `who`; waits for them: [port, 201s, 503s, others, 429s, who]."""
    var counts = List[Int64](length=6, fill=0)
    counts[0] = Int64(port)
    counts[5] = Int64(who)
    for _ in range(n):
        _ = spawn[burst_call](Int(counts.unsafe_ptr()))
    var spent = 0
    while _A.load(counts.unsafe_ptr() + 1) + _A.load(counts.unsafe_ptr() + 2) + _A.load(counts.unsafe_ptr() + 3) + _A.load(counts.unsafe_ptr() + 4) < Int64(n) and spent < 300:
        _ = libc.poll(0, 0, 100)
        spent += 1
    return counts^


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
    var two = FlareRequest("GET", b2)  # (a proxy that adds its own line after the client's, as HAProxy's forwardfor)
    two.headers.append("X-Forwarded-For", "198.51.100.66")
    two.headers.append("X-Forwarded-For", "203.0.113.5")
    var tt = c.send(two).text()
    expect('"client": "203.0.113.5"' in tt, "two X-Forwarded-For lines: the client's own line was believed: " + tt)
    behind.stop()
    var direct = serve(App(), port=0, workers=1, proxies=TrustedProxies.parse("10.0.0.0/8"))
    var d = get_via(c, "http://127.0.0.1:" + String(direct.port) + "/x", "203.0.113.5")
    expect('"client": "127.0.0.1"' in d, "an untrusted peer's X-Forwarded-For was believed: " + d)
    direct.stop()
    print("client_ip: ok")
    # the fixed pool: 2 threads and a queue of 2 take 4 of 6 slow requests at once; the other 2 get 503 + Retry-After
    var gone = 0
    while not direct.stopped() and gone < 100:  # (a stopped server's loop ends on its own thread: let it, D-6033)
        _ = libc.poll(0, 0, 50)
        gone += 1
    var pooled = serve(App(), port=0, workers=1, offload_threads=2, offload_queue=2, offload_per_client=0)
    var counts = List[Int64](length=4, fill=0)
    counts[0] = Int64(pooled.port)
    for _ in range(6):
        _ = spawn[burst_call](Int(counts.unsafe_ptr()))
    var spent = 0
    while _A.load(counts.unsafe_ptr() + 1) + _A.load(counts.unsafe_ptr() + 2) + _A.load(counts.unsafe_ptr() + 3) < 6 and spent < 200:
        _ = libc.poll(0, 0, 100)
        spent += 1
    var took = Int(_A.load(counts.unsafe_ptr() + 1))
    var busy = Int(_A.load(counts.unsafe_ptr() + 2))
    expect(took == 4 and busy == 2, "6 slow requests on 2 threads + a queue of 2: " + String(took) + " answered, " + String(busy) + " 503 with Retry-After, " + String(Int(_A.load(counts.unsafe_ptr() + 3))) + " other")
    expect(spent >= 30, "the 4 taken ran 2 at a time (2 waves of 2 s): done in " + String(spent * 100) + " ms")
    _ = len(counts)
    if CompilationTarget.is_linux():  # (no thread made per request: the offloaded answer sees the threads the reactor sees)
        var pb = "http://127.0.0.1:" + String(pooled.port)
        _ = libc.poll(0, 0, 300)  # (the burst's client threads have ended)
        for _ in range(5):
            var on_reactor = c.get(pb + "/threads").text()
            var offloaded = c.get(pb + "/slow-threads").text()
            expect(on_reactor.startswith('{"threads": '), "the thread count: " + on_reactor)
            expect(on_reactor == offloaded, "an offloaded request ran on a new thread: reactor " + on_reactor + ", offloaded " + offloaded)
    pooled.stop()
    print("pool: ok")
    # one client holds at most offload_per_client slots (429 past it); another client still gets its own (D-6036)
    while not pooled.stopped():
        _ = libc.poll(0, 0, 50)
    var fair = serve(App(), port=0, workers=1, offload_threads=4, offload_queue=4, offload_per_client=2, proxies=TrustedProxies.parse("127.0.0.1"))
    var a = List[Int64](length=6, fill=0)
    var b = List[Int64](length=6, fill=0)
    a[0] = Int64(fair.port)
    a[5] = 7
    b[0] = Int64(fair.port)
    b[5] = 8
    for _ in range(4):
        _ = spawn[burst_call](Int(a.unsafe_ptr()))
    for _ in range(2):
        _ = spawn[burst_call](Int(b.unsafe_ptr()))
    var waited2 = 0
    while (answered(Int(a.unsafe_ptr())) < 4 or answered(Int(b.unsafe_ptr())) < 2) and waited2 < 300:
        _ = libc.poll(0, 0, 100)
        waited2 += 1
    expect(Int(a[1]) == 2 and Int(a[4]) == 2 and Int(b[1]) == 2, "per client: A's 4 → " + String(Int(a[1])) + " answered, " + String(Int(a[4])) + " 429; B's 2 → " + String(Int(b[1])) + " answered")
    _ = len(a)
    _ = len(b)
    fair.stop()
    while not fair.stopped():
        _ = libc.poll(0, 0, 50)
    print("per_client: ok")
    # a job that waited in the queue past the request timeout is dropped with 503 + Retry-After, never answered late
    var late = serve(App(), port=0, workers=1, offload_threads=1, offload_queue=4, offload_per_client=0, request_timeout_ms=1000)
    var l = burst(late.port, 3)
    expect(Int(l[1]) == 1 and Int(l[2]) == 2, "1 thread, 3 slow requests of 2 s, a 1 s deadline: " + String(Int(l[1])) + " answered, " + String(Int(l[2])) + " 503")
    late.stop()
    while not late.stopped():
        _ = libc.poll(0, 0, 50)
    print("deadline: ok")
    # the queue's hand-off never blocks the reactor: a full pipe says so (EAGAIN) and the request gets 503
    var q = offload_queue_pipe()
    var taken = 0
    while queue_job(q[1], 12345) and taken < 100_000:
        taken += 1
    expect(taken > 0 and taken < 100_000, "a full queue pipe refused at once after " + String(taken) + " jobs (never blocked)")
    _ = libc.close(q[0])
    _ = libc.close(q[1])
    print("queue_full: ok")
