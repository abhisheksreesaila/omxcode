# The power goes at any moment (continuation 23: the desktop did, five times, and left git's objects as empty files): SaveOutbox's
# folder as a disk may be left, against what was promised. Each thing a window does to its folder is noted (HeldDisk.ops); a model
# disk keeps only what was synced, and of the rest any part: bytes not synced may be missing, short, zeros or whole; names made,
# renamed and removed since the folder was last synced may each be there or not. Then a start loads that folder.
# The property: what was settled before the cut is found, or a later version of it, unless it was dropped; whatever is found is whole.
#   pixi run mojo build -I . -I vendor tests/test_powercut.mojo -o build/test_powercut && build/test_powercut [seeds]
from std.os import listdir
from std.sys import argv
from std.testing import assert_true, assert_equal
from mojoui.files import private_dir, private_write, file_name
from mojoui.docstore import SaveOutbox, Unsaved, DiskOp, unsaved_text, unsaved_whole, settled_name
from mojoui.libc import unlink, open_append, write_fd, close

comptime DOCS = 3


struct Rng:
    var s: UInt64

    def __init__(out self, seed: Int):
        self.s = UInt64(seed) * 2654435761 + 88172645463325252

    def next(mut self, n: Int) -> Int:
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return Int((self.s >> 11) % UInt64(n))


def content(v: Int) -> String:
    var t = "v" + String(v) + ":"
    for k in range(v % 40 + 3):
        t += " words " + String(k * v)
    return t


def version_of(text: String) raises -> Int:
    return Int(String(text[byte = 1 : text.find(":")]))


struct Disk(Movable):
    """What is sure to be there, and what isn't yet."""
    var text: List[String]  # by inode
    var synced: List[Bool]
    var now: Dict[String, Int]  # the names as a program sees them
    var sure: Dict[String, Int]  # the names on the disk
    var waits: List[Tuple[Int, String, Int]]  # (0 made, 1 gone; name; inode) since the folder was synced

    def __init__(out self):
        self.text = List[String]()
        self.synced = List[Bool]()
        self.now = Dict[String, Int]()
        self.sure = Dict[String, Int]()
        self.waits = List[Tuple[Int, String, Int]]()

    def do(mut self, op: DiskOp) raises:
        var a = file_name(op.a)
        if op.kind == "write":
            self.text.append(op.b)
            self.synced.append(False)
            self.now[a] = len(self.text) - 1
            self.waits.append((0, a, len(self.text) - 1))
        elif op.kind == "file":
            self.synced[self.now[a]] = True
        elif op.kind == "rename":
            var b = file_name(op.b)
            var n = self.now.pop(a)
            self.now[b] = n
            self.waits.append((2, a + "|" + b, n))
        elif op.kind == "unlink":
            _ = self.now.pop(a)
            self.waits.append((1, a, 0))
        elif op.kind == "dir":
            for w in self.waits.copy():
                self.apply(self.sure, w)
            self.waits.clear()

    @staticmethod
    def apply(mut names: Dict[String, Int], w: Tuple[Int, String, Int]) raises:
        if w[0] == 0:
            names[w[1]] = w[2]
        elif w[0] == 1:
            if w[1] in names:
                _ = names.pop(w[1])
        else:
            var cut = w[1].find("|")
            var a = String(w[1][byte=0:cut])
            if a in names:
                _ = names.pop(a)
            names[String(w[1][byte = cut + 1 :])] = w[2]

    def cut(self, mut r: Rng, dir: String) raises:
        """The folder as the power going now may leave it."""
        for n in listdir(dir):
            _ = unlink(dir + "/" + String(n))
        var names = self.sure.copy()
        var how = r.next(3)  # in the order they were made up to some point | any of them | all
        var upto = r.next(len(self.waits) + 1)
        for k in range(len(self.waits)):
            if how == 2 or (how == 0 and k < upto) or (how == 1 and r.next(2) == 0):
                self.apply(names, self.waits[k])
        for e in names.items():
            var t = self.text[e.value]
            if not self.synced[e.value]:
                var n = t.byte_length()
                var k = r.next(5)
                if k == 0:
                    t = ""
                elif k == 1:
                    var short = String(t[byte = 0 : r.next(n)])
                    t = short
                elif k == 2:
                    var z = String("")
                    for _ in range(n):
                        z += "\0"
                    t = z
                elif k == 3:  # (a page in the middle that never got there)
                    var at = r.next(n)
                    var m = min(r.next(40) + 1, n - at)
                    var z = String(t[byte=0:at])
                    for _ in range(m):
                        z += "x"
                    t = z + String(t[byte = at + m :])
            var fd = open_append(dir + "/" + e.key)
            if t.byte_length() > 0:
                _ = write_fd(fd, Int(t.unsafe_ptr()), t.byte_length())
            _ = t.byte_length()
            _ = close(fd)


def run(seed: Int, dir: String, after: String) raises -> Int:
    for n in listdir(dir):
        _ = unlink(dir + "/" + String(n))
    var r = Rng(seed)
    var ops = List[DiskOp]()
    var dropped = List[Tuple[Int, Int]]()  # (document, at which op)
    var docs = List[Int](length=1, fill=0)  # of each version
    var boxes = List[SaveOutbox]()
    for _ in range(40 + r.next(60)):
        if len(boxes) == 0 or r.next(14) == 0:
            if len(boxes) > 0:
                if r.next(2) == 0:
                    boxes[0].disk.fault = 0  # (killed)
                else:
                    boxes[0].sync(True)
                    ops.extend(boxes[0].disk.ops.copy())
                    boxes[0].disk.ops.clear()
                _ = boxes.pop()
            var b = SaveOutbox(dir, "m")
            b.disk.inline = True
            b.disk.tracing = True
            b.load()
            boxes.append(b^)
        var k = r.next(10)
        var id = r.next(DOCS)
        if k < 5:
            docs.append(id)
            var v = len(docs) - 1
            var u = Unsaved(id, "page", r.next(4), content(v), "", "why", False)
            if r.next(3) > 0:
                _ = boxes[0].put(u^)
            else:
                _ = boxes[0].spill(u)
        elif k < 6:
            dropped.append((id, len(ops)))
            boxes[0].drop(id)
            while len(boxes[0].extras) > 0 and boxes[0].extras[0].id == id:
                boxes[0].extra_done(0)
        else:
            boxes[0].settle_next()
        ops.extend(boxes[0].disk.ops.copy())
        boxes[0].disk.ops.clear()
    boxes[0].disk.fault = 0
    boxes.clear()
    # every place the power may go
    var checked = 0
    for c in range(len(ops) + 1):
        var d = Disk()
        var need = List[Int](length=DOCS, fill=0)  # the last settled version of each document
        var of = Dict[String, Int]()
        var renamed = Dict[String, Bool]()
        for q in range(c):
            for e in dropped:
                if e[1] == q:
                    need[e[0]] = 0
            ref op = ops[q]
            d.do(op)
            var name = file_name(settled_name(op.a))
            if op.kind == "write":
                var at = op.b.find('"content":"') + 11
                of[name] = version_of(String(op.b[byte = at :]))
            elif op.kind == "rename":
                renamed[name] = True
            elif op.kind == "dir" and name in renamed:
                var v = of[name]
                need[docs[v]] = max(need[docs[v]], v)
        for e in dropped:
            if e[1] == c:
                need[e[0]] = 0
        d.cut(r, after)
        var start = SaveOutbox(after, "m")
        start.disk.inline = True
        start.load()
        var found = List[Int](length=DOCS, fill=0)
        var all = start.items.copy()
        all.extend(start.extras.copy())
        for u in all:
            var v = version_of(u.content)
            assert_true(u.content == content(v) and docs[v] == u.id, "seed " + String(seed) + " cut " + String(c) + ": a torn version was taken for whole")
            found[u.id] = max(found[u.id], v)
        for k in range(DOCS):
            # (a drop that was under way at the cut had nothing to keep any more)
            assert_true(found[k] >= need[k], "seed " + String(seed) + " cut " + String(c) + " of " + String(len(ops)) + ": document " + String(k) + " had version " + String(need[k]) + " settled, and "
                        + (String(found[k]) if found[k] > 0 else "nothing") + " came back")
        checked += 1
        start.disk.fault = 0
    return checked


def test_sums() raises:
    var u = Unsaved(3, "page", 7, 'words "and" ,"sum":12} more', "b", "", True)
    var t = unsaved_text(u)
    assert_true(unsaved_whole(t))
    for n in range(t.byte_length()):
        assert_true(not unsaved_whole(String(t[byte=0:n])), "cut at " + String(n))
    assert_true(not unsaved_whole("") and not unsaved_whole(t.replace("words", "wordx")))


def test_durable_write() raises:
    assert_true(private_write("build/powercut_dir/one.txt", "abc", durable=True))
    var t: String
    with open("build/powercut_dir/one.txt", "r") as f:
        t = f.read()
    assert_equal(t, "abc")
    assert_true(not private_write("build/powercut_dir/none/one.txt", "abc", durable=True))


def main() raises:
    var args = argv()
    var seeds = Int(String(args[1])) if len(args) > 1 else 40
    var dir = String("build/powercut_dir")
    var after = String("build/powercut_after")
    assert_true(private_dir(dir) and private_dir(after))
    test_sums()
    test_durable_write()
    var cuts = 0
    for seed in range(1, seeds + 1):
        cuts += run(seed, dir, after)
    print("   ", seeds, "seeds, the power cut at", cuts, "places")
    print("powercut: ok")
