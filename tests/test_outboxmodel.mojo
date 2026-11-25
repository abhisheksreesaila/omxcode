# SaveOutbox against a reference model (review 5, MUST 2; its invariants are in the struct's docstring): random windows that hold,
# spill, land and take over, each killed at any step of the disk's (fault) or ended; sometimes without file locks. The property:
# every version a person was told is kept is, at the end, in a window's hands, in a file, or was offered as a copy, unless it
# landed, was dropped, or a later version by the same window (or one that took it over) stands for it.
#   pixi run mojo build -I . -I vendor tests/test_outboxmodel.mojo -o build/test_outboxmodel && build/test_outboxmodel [seeds]
from std.os import listdir, setenv
from std.sys import argv
from std.testing import assert_true, assert_equal
from mojoui.files import private_dir
from mojoui.docstore import SaveOutbox, Unsaved
from mojoui.libc import unlink
from mojoui.json import Json

comptime DOCS = 4


struct Rng:
    var s: UInt64

    def __init__(out self, seed: Int):
        self.s = UInt64(seed) * 2654435761 + 88172645463325252

    def next(mut self, n: Int) -> Int:
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return Int((self.s >> 11) % UInt64(n))


struct Window(Movable):
    """A window and what it knows: for each document the version it holds or has spilled (0: none)."""
    var box: SaveOutbox
    var held: List[Int]
    var alive: Bool

    def __init__(out self, dir: String):
        self.box = SaveOutbox(dir, "m")
        self.box.disk.inline = True
        self.held = List[Int](length=DOCS, fill=0)
        self.alive = True


struct Model(Movable):
    """What became of each version ever kept: 0 nothing yet, 1 landed or dropped, 2 a later one stands for it, 3 offered as a copy."""
    var fate: List[Int]

    def __init__(out self):
        self.fate = List[Int](length=1, fill=1)

    def new(mut self) -> Int:
        self.fate.append(0)
        return len(self.fate) - 1


def version_of(content: String) raises -> Int:
    return Int(String(content[byte=1:]))


def on_disk(dir: String) raises -> List[Int]:
    var out = List[Int]()
    for n in listdir(dir):
        if String(n).endswith(".json"):
            var t: String
            with open(dir + "/" + String(n), "r") as f:
                t = f.read()
            out.append(version_of(Json.parse(t).text(Json.parse(t).get(0, "content"))))
    return out^


def learn(mut w: Window, mut m: Model, others: List[Window], seed: Int) raises:
    """What a start found: what the window holds now, and the copies it offers (made into documents: done). Nothing another
    living window has, nothing a later version stands for, nothing offered before."""
    var got = List[Int]()
    for u in w.box.items.copy():
        got.append(version_of(u.content))
    for u in w.box.extras.copy():
        got.append(version_of(u.content))
    for v in got:
        assert_true(m.fate[v] != 2, "seed " + String(seed) + ": version " + String(v) + " came back though a later one stands for it")
        assert_true(m.fate[v] != 3, "seed " + String(seed) + ": version " + String(v) + " offered twice")
        for i in range(len(others)):
            for k in range(DOCS):
                assert_true(others[i].held[k] != v, "seed " + String(seed) + ": version " + String(v) + " taken from a window that lives")
    for k in range(DOCS):
        w.held[k] = 0
    for u in w.box.items.copy():
        w.held[u.id] = version_of(u.content)
    while len(w.box.extras) > 0:
        var v = version_of(w.box.extras[0].content)
        w.box.extra_done(0)
        m.fate[v] = 3 if w.box.disk.fault != 0 else 4  # (4: killed while its file went: it is a document, and may be offered again)


def run(seed: Int, dir: String) raises -> Int:
    for n in listdir(dir):
        _ = unlink(dir + "/" + String(n))
    var r = Rng(seed)
    var m = Model()
    var ws = List[Window]()
    var kept = 0
    for step in range(260):
        var k = r.next(100)
        if k < 22 or len(ws) == 0:
            if len(ws) < 5:
                var w = Window(dir)
                if r.next(4) == 0:
                    w.box.disk.fault = r.next(14)
                w.box.load()
                if w.box.disk.fault == 0:  # (killed in the middle of its start: what it had made of it is nobody's)
                    _ = w^
                else:
                    learn(w, m, ws, seed)
                    if w.box.disk.fault == 0:
                        _ = w^
                    else:
                        w.box.disk.fault = -1
                        ws.append(w^)
            continue
        var i = r.next(len(ws))
        var id = r.next(DOCS)
        var kill = r.next(6) == 0
        if kill:
            ws[i].box.disk.fault = r.next(9)
        for _ in range(r.next(3)):  # (its thread got round to some)
            ws[i].box.settle_next()
        if k < 55 or (k < 70 and ws[i].held[id] == 0):
            var v = m.new()
            var u = Unsaved(id, "page", r.next(5), "v" + String(v), "", "why", r.next(2) == 0)
            var told = ws[i].box.put(u^) if r.next(3) > 0 else ws[i].box.spill(u) > 0
            if told and ws[i].box.disk.fault != 0:
                kept += 1
                if ws[i].held[id] > 0:
                    m.fate[ws[i].held[id]] = 2
                ws[i].held[id] = v
            elif told:  # (killed after the file was there: kept, and the one before it maybe still)
                if ws[i].held[id] > 0:
                    m.fate[ws[i].held[id]] = 2
                ws[i].held[id] = v
            else:
                m.fate[v] = 1  # (it wasn't told kept: nothing is promised of it)
        elif k < 70:
            var f = ws[i].box.job_file(id)  # (a save's thread: it lands, a newer one spilled meanwhile or not)
            if r.next(2) == 0:
                var v = m.new()
                var u = Unsaved(id, "page", r.next(5), "v" + String(v), "", "why", False)
                if ws[i].box.spill(u) > 0:
                    m.fate[ws[i].held[id]] = 1
                    ws[i].held[id] = v
                    ws[i].box.landed(id, f.seq)
                else:
                    m.fate[v] = 1
            else:
                m.fate[ws[i].held[id]] = 1
                ws[i].held[id] = 0
                ws[i].box.drop(id)
        elif k < 80:
            if ws[i].held[id] > 0:
                m.fate[ws[i].held[id]] = 1
                ws[i].held[id] = 0
                ws[i].box.drop(id)
        else:
            ws[i].box.disk.fault = 0 if r.next(2) == 0 else -1
            kill = True
        if kill:
            var gone = ws.pop(i)
            _ = gone^
    ws.clear()
    var last = Window(dir)
    last.box.load()
    learn(last, m, ws, seed)
    last.box.sync(True)
    var there = on_disk(dir)
    for v in range(1, len(m.fate)):
        if m.fate[v] == 0:
            var held = False
            for k in range(DOCS):
                held = held or last.held[k] == v
            assert_true(held and v in there, "seed " + String(seed) + ": version " + String(v) + " is " + ("only in a window's memory" if held else "nowhere"))
    # and nothing more than what is held is left behind
    for v in there:
        var held = False
        for k in range(DOCS):
            held = held or last.held[k] == v
        assert_true(held, "seed " + String(seed) + ": a file of version " + String(v) + " nobody holds (fate " + String(m.fate[v]) + ")")
    for k in range(DOCS):
        last.box.drop(k)
    last.box.sync(True)
    _ = last^
    var after = Window(dir)
    after.box.load()
    assert_true(len(after.box.items) + len(after.box.extras) == 0, "all dropped: none comes back")
    _ = after^
    var locks = 0
    for n in listdir(dir):
        locks += 1
    assert_equal(locks, 0, "seed " + String(seed) + ": nothing left in the folder")
    return kept


def main() raises:
    var args = argv()
    var seeds = Int(String(args[1])) if len(args) > 1 else 400
    var dir = String("build/outboxmodel_dir")
    assert_true(private_dir(dir))
    var kept = 0
    for seed in range(1, seeds + 1):
        kept += run(seed, dir)
    print("   ", seeds, "seeds,", kept, "versions kept")
    print("outboxmodel: ok")
