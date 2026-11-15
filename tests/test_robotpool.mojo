# Goal 71 M1: mojoui.robotpool over omxcore's moments index (the pool: 1,851 episodes from 4 LeRobot datasets).
#   G71_INDEX  the index (omxcore's build/robotics/index.parquet)
#   G71_PICKS  picks.json: {"one": [10 keys], "three": [[3 keys] x 3], "export": [3 keys]} (keys "dataset:episode")
#   G71_OUT    writes pool.json there: the pool's facts, the top 24 for every pick, the warm search time, the export
# docs/goals/71-check.py M1 compares the rankings with omxcore's Python and loads the export with lerobot.
from std.os import getenv
from mojoui.robotpool import RobotPool, Hits
from mojoui.clock import now_ns

comptime K = 24


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def section(text: String, name: String) raises -> List[String]:
    """The quoted strings in picks.json's `name` entry, in order (the file is ours: keys hold no quotes)."""
    var at = text.find('"' + name + '"')
    check(at >= 0, "picks.json has no " + name)
    var i = at + name.byte_length() + 2
    var depth = 0
    var out = List[String]()
    var b = text.as_bytes()
    while i < len(b):
        var c = Int(b[i])
        if c == ord("["):
            depth += 1
        elif c == ord("]"):
            depth -= 1
            if depth == 0:
                break
        elif c == ord('"') and depth > 0:
            var j = text.find('"', i + 1)
            out.append(String(text[byte=i + 1:j]))
            i = j
        i += 1
    return out^


def ranking(h: Hits) -> String:
    var s = String("[")
    for i in range(len(h.hits)):
        s += (", " if i > 0 else "") + '["' + h.hits[i].key + '", ' + String(h.hits[i].score) + "]"
    return s + "]"


def main() raises:
    var out = getenv("G71_OUT", "build/g71/pool")
    var text = String()
    with open(getenv("G71_PICKS", "build/g71/picks.json"), "r") as f:
        text = f.read()
    var one = section(text, "one")
    var three = section(text, "three")
    var exp = section(text, "export")
    check(len(one) == 10 and len(three) == 9 and len(exp) == 3, "picks: " + String(len(one)) + "/" + String(len(three)) + "/" + String(len(exp)))
    var t0 = now_ns()
    var pool = RobotPool.open(getenv("G71_INDEX", getenv("HOME") + "/Projects/mxframe/build/robotics/index.parquet"))
    var open_ms = Float64(now_ns() - t0) / 1e6
    check(len(pool.episodes) > 0, "no episodes")
    var j = String("{")
    j += '"episodes": ' + String(len(pool.episodes)) + ', "hours": ' + String(pool.hours()) + ', "datasets": ' + String(len(pool.datasets))
    j += ', "open_ms": ' + String(open_ms) + ', "robots": ' + String(len(pool.robots))
    j += ', "one": ['
    for i in range(len(one)):
        var h = pool.like([one[i]], K)
        check(len(h.hits) == K, one[i] + ": " + String(len(h.hits)) + " hits")
        for x in h.hits:
            check(x.at >= 0 and x.key != one[i], one[i] + ": hit " + x.key)
        j += (", " if i > 0 else "") + ranking(h)
    j += '], "three": ['
    for t in range(3):
        var picks = List[String]()
        for k in range(3):
            picks.append(three[t * 3 + k])
        var h = pool.like(picks, K)
        j += (", " if t > 0 else "") + ranking(h)
    j += "]"
    # warm: the median of 21 one-clip searches (the index is on the device after the first)
    var times = List[Float64]()
    var dev = String()
    for i in range(21):
        var h = pool.like([one[i % 10]], K)
        times.append(h.ms)
        dev = h.device
    sort(times)
    j += ', "warm_ms": ' + String(times[10]) + ', "device": "' + dev + '"'
    # a robot filter answers with that robot's episodes only
    var rb = pool.robots[0]
    var hf = pool.like([one[0]], K, robot=rb)
    for x in hf.hits:
        check(pool.episodes[x.at].robot == rb, "filter " + rb + ": " + x.key)
    j += ', "filter_robot": "' + rb + '", "filtered": ' + ranking(hf)  # (M1 compares it with omxcore's Python, where = robot)
    # export the three seeded episodes (one dataset: one folder)
    var made = pool.export(exp, out + "/export-" + String(now_ns()))
    check(len(made) == 1 and made[0].episodes == 3, "export made " + String(len(made)) + " folders")
    j += ', "export": "' + made[0].folder + '", "export_frames": ' + String(made[0].frames) + "}"
    with open(out + "/pool.json", "w") as f:
        f.write(j)
    print("robotpool: " + String(len(pool.episodes)) + " episodes, " + String(pool.hours()) + " h, " + String(len(pool.datasets)) +
          " datasets; warm search " + String(times[10]) + " ms on " + dev + "; export " + made[0].folder)
