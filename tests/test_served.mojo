# Goal 52 (review): the lifecycle of a server Server.start runs (mojoui.serve's Served and the record it shares with
# the serve thread): dropped without stop(), stop() then dropped, stop() twice, one worker and four, and 30 cycles
# that leave no threads or memory behind. (A serve loop that ends on its own error frees the same way, through the
# thread's release; nothing here can make Flare's loop fail on purpose.)
from mojoui.serve import Server, Service, Req, Reply
from mojoui.http import Request, Response
from mojoui.effects import start, Backend, InFlight
from mojoui.clock import now_ns
from mojoui import libc
from std.os import listdir


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


struct Api(Service):
    def __init__(out self):
        pass

    def tick(mut self):
        pass

    def stop(mut self):
        pass

    def answer(mut self, mut req: Req) -> Reply:
        return Reply.text("hi")


def answers(port: Int) raises -> Bool:
    var job = start[Backend](Request.get(0, "http://127.0.0.1:" + String(port) + "/x").timeout(500))
    while not job.ready():
        _ = libc.poll(0, 0, 1)
    return job.response().status == 200


def gone_within(port: Int, ms: Int) raises -> Bool:
    var until = now_ns() + ms * 1_000_000
    while now_ns() < until:
        if not answers(port):
            return True
        _ = libc.poll(0, 0, 20)
    return False


def threads() raises -> Int:
    return len(listdir("/proc/self/task"))


def rss_kb() raises -> Int:
    var f = open("/proc/self/statm", "r")
    var parts = f.read().split(" ")
    f.close()
    return Int(String(parts[1])) * 4


def start_and_drop(workers: Int) raises -> Int:
    """Starts a server, checks it answers, and lets the Served drop at the end of this function."""
    var s = Server.start(Api(), workers=workers)
    check(answers(s.port), "a started server answers")
    return s.port


def stop_then_drop(workers: Int) raises:
    var s = Server.start(Api(), workers=workers)
    var port = s.port
    check(answers(port), "answers before stop")
    check(not s.stopped(), "stopped() is false while serving")
    s.stop()
    s.stop()  # (twice: a no-op)
    var until = now_ns() + 3_000_000_000
    while not s.stopped():
        check(now_ns() < until, "stopped() within 3 s of stop()")
        _ = libc.poll(0, 0, 5)
    check(gone_within(port, 2000), "nothing answers on the port after stop()")


def main() raises:
    var base_threads = threads()
    for w in [1, 4]:
        var port = start_and_drop(w)
        check(gone_within(port, 3000), "dropped without stop() (" + String(w) + " workers): the port still answers")
        stop_then_drop(w)
    print("DROP, STOP: ok (1 and 4 workers)")
    var rss0 = rss_kb()
    for i in range(30):
        if i % 2 == 0:
            stop_then_drop(4)
        else:
            _ = start_and_drop(2)
    var until = now_ns() + 3_000_000_000
    while threads() > base_threads + 2 and now_ns() < until:
        _ = libc.poll(0, 0, 20)
    var grew = rss_kb() - rss0
    print("CYCLES: 30, threads " + String(threads()) + " (at the start " + String(base_threads) + "), memory +" + String(grew) + " KB")
    check(threads() <= base_threads + 2, "threads left behind: " + String(threads()) + " (start " + String(base_threads) + ")")
    check(grew < 32 * 1024, "memory grew " + String(grew) + " KB over 30 servers")
    print("served: ok")
