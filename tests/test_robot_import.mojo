# Goal 71 M0: omxcore 5194d77's robot surface (`from omxcore.robot import open_dataset, MomentIndex, export`) in one program
# with Flare and its json, as omxplorer links them. A mojoui.serve service answers GET /like/<episode> with a search by
# example over the pool's index (the engine's moments index, on the GPU when there is one); the client parses the reply with
# Flare's json and checks it against the same search made directly. Then a dataset opens where the HF cache keeps it.
#   G71_INDEX: the pool's index.parquet (omxcore's build/robotics/index.parquet)
from omxcore.robot import open_dataset, MomentIndex, SearchQuery, export
from omxcore.robot.index import QUERY_LIKE
from omxcore import SharedTable
from mojoui.serve import Server, Service, Req, Reply
from mojoui.http import Request, Response
from mojoui.effects import start, Backend, InFlight
from mojoui.clock import now_ns
from mojoui import libc
from std.os import getenv
from json import loads

comptime SET = "lerobot/svla_so100_sorting"


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def like(mut idx: MomentIndex, episode: Int) raises -> SharedTable:
    var q = SearchQuery()
    q.kind = QUERY_LIKE
    q.like_datasets.append(SET)
    q.like_episodes.append(episode)
    q.k = 5
    return idx.search(q)


def hf_snapshot(repo: String) raises -> String:
    """Where huggingface_hub keeps a dataset repo's refs/main snapshot."""
    var hub = getenv("HOME") + "/.cache/huggingface/hub/datasets--" + repo.replace("/", "--")
    with open(hub + "/refs/main", "r") as f:
        return hub + "/snapshots/" + f.read().strip()


struct Api(Service):
    var idx: MomentIndex

    def __init__(out self, var idx: MomentIndex):
        self.idx = idx^

    def tick(mut self):
        pass

    def stop(mut self):
        pass

    def answer(mut self, mut req: Req) -> Reply:
        if req.matches("GET", "/like/1"):
            try:
                var t = like(self.idx, 1)
                var ep = t.column("episode")
                var sc = t.column("score")
                var out = String('{"hits": [')
                for r in range(t.rows()):
                    out += (", " if r > 0 else "") + '{"episode": ' + String(Int(t.get(ep, r))) + ', "score": ' + String(t.get_float(sc, r)) + "}"
                return Reply.json(out + "]}")
            except e:
                return Reply.error(500, String(e), "engine")
        return Reply.not_found()


def main() raises:
    var path = getenv("G71_INDEX", getenv("HOME") + "/Projects/mxframe/build/robotics/index.parquet")
    var idx = MomentIndex.open(path)
    check(idx.episodes() == 1851, "episodes in the pool: " + String(idx.episodes()))
    var direct = like(idx, 1)
    check(direct.rows() == 5, "direct search rows: " + String(direct.rows()))
    var server = Server.start(Api(idx^), workers=2)
    var job = start[Backend](Request.get(0, "http://127.0.0.1:" + String(server.port) + "/like/1"))
    var t0 = now_ns()
    while not job.ready():
        check(now_ns() - t0 < 30_000_000_000, "no answer in 30 s")
        _ = libc.poll(0, 0, 1)
    var r = job.response()
    check(r.status == 200, "GET /like/1: " + String(r.status) + " " + r.text() + " " + r.error)
    var j = loads(r.text())
    var ep = direct.column("episode")
    for i in range(5):
        check(Int(j["hits"][i]["episode"].int_value()) == Int(direct.get(ep, i)), "served hit " + String(i) + ": " + r.text())
    server.stop()
    var ds = open_dataset(hf_snapshot(SET))
    check(ds.episodes.rows() > 0, "no episodes in " + SET)
    print("robot + flare: ok (" + String(direct.rows()) + " hits served; " + SET + ": " + String(ds.episodes.rows()) + " episodes)")
