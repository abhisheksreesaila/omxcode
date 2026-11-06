# Goal 52 M5: the omxcore engine and Flare in one program. Until goal 52 they couldn't link together: the engine declared
# pthread_create, strtod, mmap… with other types than Flare and its json (one signature per C symbol per binary,
# D-4761); the engine's patch (vendor/patches/omxcore-834ef9a-mojo12.patch) looks them up at run time instead.
# A mojoui.serve service (on Flare) answers each request with an engine background job (its thread pool) over a table
# read from a CSV (the engine's mmap and its float parsing), and the client parses the reply with Flare's json.
# mojoui.serve keeps Mojo's runtime pool for compute: the engine's parallel kernels run while Flare serves.
from omxcore import Table, SharedTable, Query, col, sum, count, INT, FLOAT, CPU, compute_job, read_csv, CsvOptions
from mojoui.serve import Server, Service, Req, Reply
from mojoui.http import Request, Response
from mojoui.effects import start, Backend, InFlight
from mojoui.clock import now_ns
from mojoui import libc
from json import loads

comptime CSV = "build/g52/engine_flare.csv"
comptime ROWS = 200_000


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def make_csv() raises:
    var text = String("k,v,x\n")
    for i in range(ROWS):
        text += String(i % 5) + "," + String(i % 1000) + "," + String(Float64(i % 100) / 4.0) + "e0\n"  # (an exponent: a FLOAT column, parsed by strtod)
    with open(CSV, "w") as f:
        f.write(text)


struct Api(Service):
    var table: SharedTable

    def __init__(out self, var table: SharedTable):
        self.table = table^

    def tick(mut self):
        pass

    def stop(mut self):
        pass

    def answer(mut self, mut req: Req) -> Reply:
        if req.matches("GET", "/sums"):
            try:
                var job = compute_job(Query(self.table).group_by(col("k"), groups=5).agg(sum(col("v")), count()), CPU)
                var r = job.result()
                var out = String('{"sums": [')
                for g in range(len(r.sums)):
                    out += (", " if g > 0 else "") + String(r.sums[g])
                out += '], "counts": ['
                for g in range(len(r.counts)):
                    out += (", " if g > 0 else "") + String(r.counts[g])
                return Reply.json(out + "]}")
            except e:
                return Reply.error(500, String(e), "engine")
        return Reply.not_found()


def wait(mut job: InFlight) raises -> Response:
    var t0 = now_ns()
    while not job.ready():
        if now_ns() - t0 > 30_000_000_000:
            raise Error("no answer in 30 s")
        _ = libc.poll(0, 0, 1)
    return job.response()


def main() raises:
    make_csv()
    var csv = read_csv(CSV, CsvOptions())
    check(csv.rows == ROWS, "CSV rows: " + String(csv.rows))
    var t = csv.take_table().share()
    var x = t.column("x")
    check(t.get_float(x, 7) == 1.75, "float parsing: " + String(t.get_float(x, 7)))
    # the plain answer, to compare with the served one
    var plain = Query(t).group_by(col("k"), groups=5).agg(sum(col("v")), count()).compute(CPU)
    # (Flare's loops on OS threads, not Mojo's pool: an engine job's parallel kernels waited forever behind them before
    # mojoui.serve held the pool's leases, goal 52)
    var server = Server.start(Api(t), workers=4)
    var port = server.port
    var jobs = List[InFlight]()
    for _ in range(8):  # eight requests at once: eight engine jobs on eight Flare workers' requests
        jobs.append(start[Backend](Request.get(0, "http://127.0.0.1:" + String(port) + "/sums")))
    for i in range(len(jobs)):
        var r = wait(jobs[i])
        check(r.status == 200, "GET /sums: " + String(r.status) + " " + r.text() + " " + r.error)
        var j = loads(r.text())
        for g in range(5):
            check(Int(j["sums"][g].int_value()) == plain.sums[g] and Int(j["counts"][g].int_value()) == plain.counts[g],
                  "group " + String(g) + ": " + r.text())
    server.stop()
    print("engine + flare: ok (" + String(len(jobs)) + " engine jobs served, sums " + String(plain.sums[0]) + "…)")
