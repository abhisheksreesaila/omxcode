# Goal 52 M7 (owner: "ensure it does not interfere with our UI thread and blocks"): Flare never stalls the thread an
# app draws on. The main thread here plays a UI's frame loop (a tick every 4 ms, as a 240 Hz display asks) while the
# same program serves through mojoui.serve (Flare), streams SSE, proxies, fetches over HTTPS through mojoui.http
# (FlareTransport, on effects' own threads) and answers engine jobs. Measured: the longest gap between ticks while
# all that runs, and how long Server.start and Served.stop hold the caller (an app might call them from its UI thread).
from mojoui.serve import Server, Service, Req, Reply, Pipe, spawn, proxy
from mojoui.http import Request, Response
from mojoui.effects import start, Backend, InFlight
from mojoui.clock import now_ns
from mojoui import libc
from omxcore import SharedTable, Table, Query, col, sum, count, INT, CPU, compute_job

comptime TICK_MS = 4
comptime MAX_GAP_MS = 25      # a frame at 60 Hz is 16.7 ms: a gap past 25 ms would be a dropped frame anyone sees
comptime MAX_START_MS = 250
comptime MAX_STOP_MS = 5        # stop() only asks: the loop ends on its own thread


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def ticks(addr: Int):
    """Writes six SSE events 30 ms apart, then closes."""
    var pipe = Pipe.at(addr)
    for i in range(6):
        if pipe.gone():
            break
        pipe.write("data: " + String(i) + "\n\n")
        _ = libc.poll(0, 0, 30)
    pipe.close()
    pipe.release()


struct Api(Service):
    var table: SharedTable
    var port: Int

    def __init__(out self, var table: SharedTable):
        self.table = table^
        self.port = 0

    def tick(mut self):
        pass

    def stop(mut self):
        pass

    def answer(mut self, mut req: Req) -> Reply:
        if req.matches("PUT", "/port"):
            try:
                self.port = atol(req.body)
            except:
                return Reply.error(400, "not a port", "bad_port")
            return Reply.empty()
        if req.matches("GET", "/sse"):
            var pipe = Pipe()
            var r = Reply.stream(pipe)
            _ = spawn[ticks](pipe.share().addr)
            pipe.release()
            return r^
        if req.matches("GET", "/proxy"):
            var pipe = Pipe(keep_bytes=4096)
            _ = proxy(Request.get(0, "http://127.0.0.1:" + String(self.port) + "/sse").timeout(5000), pipe)
            var r = Reply.stream(pipe, wait_head_ms=3000)
            pipe.release()
            return r^
        if req.matches("GET", "/sums"):
            try:
                var job = compute_job(Query(self.table).group_by(col("k"), groups=5).agg(sum(col("v")), count()), CPU)
                var r = job.result()
                return Reply.json('{"first": ' + String(r.sums[0]) + "}")
            except e:
                return Reply.error(500, String(e), "engine")
        return Reply.text("ok")


def table() raises -> SharedTable:
    var t = Table.empty()
    var k = t.add_column("k", INT)
    var v = t.add_column("v", INT)
    for i in range(2_000_000):
        t.append(k, Int64(i % 5))
        t.append(v, Int64(i % 1000))
    return t^.share()


def main() raises:
    var t = table()
    var gaps = List[Int]()  # ms between consecutive ticks
    # Server.start as an app's UI thread would call it
    var t0 = now_ns()
    var server = Server.start(Api(t), workers=4)
    var start_ms = (now_ns() - t0) // 1_000_000
    var up = Server.start(Api(t), workers=2)  # (the proxy's upstream: another server)
    var base = "http://127.0.0.1:" + String(server.port)
    var set = start[Backend](Request(0, "PUT", base + "/port", String(up.port)))
    while not set.ready():  # (the proxies need the upstream's port first)
        _ = libc.poll(0, 0, 1)
    # the load: SSE streams, proxied streams, engine jobs, plain requests and HTTPS fetches, all in flight at once
    var jobs = List[InFlight]()
    for i in range(6):
        jobs.append(start[Backend](Request.get(1, base + "/sse").stream(2).timeout(10_000)))
        jobs.append(start[Backend](Request.get(1, base + "/proxy").stream(2).timeout(10_000)))
        jobs.append(start[Backend](Request.get(0, base + "/sums").timeout(30_000)))
        jobs.append(start[Backend](Request.get(0, base + "/x").timeout(10_000)))
    var local = len(jobs)  # (the rest go over the network: their failures are reported as the network's, below)
    for _ in range(3):
        jobs.append(start[Backend](Request.get(0, "https://huggingface.co/api/models/Qwen/Qwen2.5-0.5B-Instruct").timeout(30_000)))
    # the frame loop: tick until everything has answered
    var last = now_ns()
    var began = last
    while True:
        _ = libc.poll(0, 0, TICK_MS)
        var now = now_ns()
        gaps.append((now - last) // 1_000_000)
        last = now
        var done = True
        for i in range(len(jobs)):
            if not jobs[i].ready():
                done = False
        if done:
            break
        check(now - began < 60_000_000_000, "the load didn't finish in 60 s")
    var worst = 0
    for g in gaps:
        worst = max(worst, g)
    # the timing first: a network failure must never read as Flare stalling the UI (or hide that it did)
    check(worst <= MAX_GAP_MS, "the frame loop stalled " + String(worst) + " ms")
    check(start_ms <= MAX_START_MS, "Server.start held the caller " + String(start_ms) + " ms")
    var bad = 0
    var net = 0
    for i in range(len(jobs)):
        var r = jobs[i].response()
        if r.status != 200:
            if i >= local:
                net += 1
                print("network (huggingface.co): " + String(r.status) + " " + r.error)
            else:
                bad += 1
                print("not 200: " + String(r.status) + " " + r.error)
    check(bad == 0, String(bad) + " of " + String(local) + " local requests failed")
    check(net == 0, "network: " + String(net) + " of 3 HTTPS fetches to huggingface.co failed (not a stall: the frame loop held)")
    # stopping, as an app's UI thread would at quit
    var t1 = now_ns()
    up.stop()
    server.stop()
    var stop_ms = (now_ns() - t1) // 1_000_000
    var gone = now_ns()
    while not (server.stopped() and up.stopped()):
        check(now_ns() - gone < 3_000_000_000, "the servers' loops didn't end within 3 s of stop()")
        _ = libc.poll(0, 0, 5)
    var ended_ms = (now_ns() - t1) // 1_000_000
    print("ticks " + String(len(gaps)) + ", longest gap " + String(worst) + " ms; Server.start " + String(start_ms)
          + " ms; stop (both) " + String(stop_ms) + " ms, loops ended after " + String(ended_ms) + " ms; " + String(len(jobs)) + " requests")
    check(stop_ms <= MAX_STOP_MS, "stop held the caller " + String(stop_ms) + " ms")
    print("ui thread: ok")
