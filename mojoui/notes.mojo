# mojoui.notes: find things in a folder of notes by meaning, in the app's own process (goal 72 M6, D-7284).
# Sentence embeddings by MAX (mojoui.textembed: the e5-small-v2 pack, 384 numbers a passage), a cached index, and the rules
# that keep a search inside the one folder the person chose.
#
#   var notes = NotesIndex("~/Documents/notes", "build/packs/e5small", cache="~/.cache/omxcode/notes")   # raises: no such folder
#   while not notes.step(8): ...                    # from update(): a few passages a call, never more than ~8 ms of work (D-7308)
#   notes.refresh()                                 # before a question: new, changed or removed files are noticed (a listing, at most
#                                                   # every 3 s; nothing is re-read when nothing changed)
#   for hit in notes.search("when is my next dental cleaning?", k=4):  hit.file, hit.text, hit.score
#   resolve_inside(root, "../../.ssh")              # raises (outside()'s words): a path that leaves the folder is refused, never read
#
# What is read: only `.md`, `.txt` and `.org` files under the folder, up to 1 MB each, nothing whose path has a part that
# starts with a dot, and no symbolic links (a link out of the folder is never followed: mojoui.watch.list_dir leaves links
# out, and a folder argument is resolved with realpath before it is compared). A file is cut into passages of about 500
# characters at paragraph breaks; each is embedded as "passage: <file>: <text>", a question as "query: <question>" (what the
# model's card asks for). The index is saved beside nothing the person owns, in `cache` (one pair of files a folder), and
# only files whose size or modified time changed are embedded again. Search: the best passages by cosine, at most two a
# file, and only those close to the best (the floor), so an unrelated question finds nothing rather than the least bad note.

from std.os.path import realpath, isdir
from mojoui.utf8 import head, boundary
from mojoui.watch import walk_files, file_stamp
from mojoui.textembed import Embedder
from mojoui.json import Json, json_string
from mojoui.clock import now_ns
from mojoui.video import file_exists

comptime MAX_BYTES = 1_000_000
comptime CHUNK = 500
comptime PER_FILE = 2
comptime MIN_SCORE = 0.806  # e5-small cosines run high (0.7-0.9 for anything): the lowest right answer seen scored 0.812, the highest unrelated question 0.802
comptime BAND = 0.05  # and a passage must be within this of the best one
comptime BATCH = 8  # passages embedded in one call (about 5 ms on the GPU, whatever the batch up to 8: the cost of one tick of the index)
comptime RESCAN_NS = 3_000_000_000  # refresh() looks at the folder at most this often
comptime TOP = 200  # candidates kept while scoring (the best few, not a sort of every passage)


def outside(folder: String, asked: String) -> String:
    """What the person hears when a path leaves the notes folder."""
    return "I only read your notes folder (" + folder + "), not " + asked


def _name_of(path: String) -> String:
    var p = String(path.rstrip("/"))
    return String(p[byte = p.rfind("/") + 1 :])


def resolve_inside(root: String, sub: String) raises -> String:
    """`sub` (a folder inside `root`, "" for the root itself) as a real path, or an Error saying notes are only read from
    `root`. A `..` part, a symbolic link out, or an absolute path elsewhere all end here."""
    var base = realpath(root)
    if sub == "" or sub == "." or sub == "/":
        return base
    for part in sub.split("/"):
        if String(part) == "..":
            raise Error(outside(_name_of(base), sub))
    var target = String("")
    try:
        target = realpath(base + "/" + sub)
    except:
        raise Error("there is no folder " + sub + " in " + _name_of(base))
    if target != base and not target.startswith(base + "/"):
        raise Error(outside(_name_of(base), sub))
    if not isdir(target):
        raise Error("there is no folder " + sub + " in " + _name_of(base))
    return target^


def _hidden(rel: String) -> Bool:
    for part in rel.split("/"):
        if String(part).startswith("."):
            return True
    return False


def _readable_type(name: String) -> Bool:
    var low = name.lower()
    return low.endswith(".md") or low.endswith(".txt") or low.endswith(".org")


def split_passages(text: String) -> List[String]:
    """The text cut at blank lines into passages of about CHUNK characters (a long paragraph stays whole up to 2000)."""
    var out = List[String]()
    var cur = String("")
    for raw in text.split("\n\n"):
        var para = String(String(raw).strip())
        if para == "":
            continue
        if cur != "" and cur.byte_length() + para.byte_length() > CHUNK:
            out.append(cur)
            cur = String("")
        cur = (cur + "\n\n" + para) if cur != "" else para
    if cur != "":
        out.append(cur)
    for i in range(len(out)):
        if out[i].byte_length() > 2000:
            var cut = head(out[i], 2000)
            out[i] = cut^
    return out^


@fieldwise_init
struct NoteHit(Copyable, Movable):
    var file: String  # relative to the notes folder
    var text: String
    var score: Float64


def _fnv(text: String) -> String:
    var h: UInt64 = 1469598103934665603
    for b in text.as_bytes():
        h = (h ^ UInt64(b)) * 1099511628211
    var digits = "0123456789abcdef"
    var out = String("")
    for i in range(16):
        out += String(digits[byte = Int((h >> UInt64(60 - 4 * i)) & 15)])
    return out^


struct NotesIndex(Movable):
    var root: String  # the folder, resolved
    var embedder: Embedder
    var cache: String  # the folder the index is kept in ("": not kept)
    var files: List[String]  # relative paths, sorted
    var stamps: List[String]  # "size:modified" of each file when it was read
    var passages: List[List[String]]  # per file; empty while the file waits to be embedded
    var vectors: List[List[Float32]]  # per file: its passages' vectors, one after another
    var waiting: List[Int]  # files still to embed
    var embedded: Int  # passages embedded since the index was made (a cached index starts at 0)
    var scanned: Bool
    var cur: Int  # the file being embedded a few passages a tick (-1: none)
    var cur_parts: List[String]
    var cur_vecs: List[Float32]
    var cur_at: Int  # its next passage
    var call_ms: Float64  # what one embedding call has cost lately (a tick runs another only when it fits the budget)
    var scan_ns: Int  # when the folder was last listed
    var scans: Int  # times the index was rebuilt from a listing that differed from what it held

    def __init__(out self, folder: String, pack: String, cache: String = "") raises:
        self.root = resolve_inside(folder, "")
        if not isdir(self.root):
            raise Error("there is no notes folder at " + folder)
        self.embedder = Embedder(pack, 384, 160)
        self.cache = cache
        self.files = List[String]()
        self.stamps = List[String]()
        self.passages = List[List[String]]()
        self.vectors = List[List[Float32]]()
        self.waiting = List[Int]()
        self.embedded = 0
        self.scanned = False
        self.cur = -1
        self.cur_parts = List[String]()
        self.cur_vecs = List[Float32]()
        self.cur_at = 0
        self.call_ms = 6.0
        self.scan_ns = 0
        self.scans = 0
        self.scan()

    def key(self) -> String:
        return self.cache + "/" + _fnv(self.root)

    def listing(self) -> List[String]:
        """The notes the folder holds now: relative paths of the readable types under the size limit, sorted (so two scans, and
        two machines, agree)."""
        var found = List[String]()
        var suffixes = List[String]()
        for s in [".md", ".txt", ".org", ".MD", ".TXT", ".ORG"]:
            suffixes.append(String(s))
        for full in walk_files(self.root, suffixes):
            var rel = String(full[byte = self.root.byte_length() + 1 :])
            if _hidden(rel) or not _readable_type(rel):
                continue
            var st = file_stamp(full)
            if st[1] < 0 or st[1] > MAX_BYTES:
                continue
            found.append(rel)
        sort(found)
        return found^

    def stamp_of(self, rel: String) -> String:
        var st = file_stamp(self.root + "/" + rel)
        return String(st[1]) + ":" + String(st[0])

    def scan(mut self):
        """Lists the folder's notes, takes what the cache holds for files that haven't changed, queues the rest."""
        var found = self.listing()
        var old = self.load_cache()
        self.rebuild(found, old)
        self.scanned = True
        self.scan_ns = now_ns()

    def refresh(mut self):
        """Notices files that were added, changed or removed since the last look: only the listing and the stamps are read, and
        when they are what the index holds nothing else is touched (a question never re-reads the cache or the notes). At most
        every few seconds."""
        if self.scanned and now_ns() - self.scan_ns < RESCAN_NS:
            return
        self.scan_ns = now_ns()
        var found = self.listing()
        var same = len(found) == len(self.files)
        if same:
            for i in range(len(found)):
                if found[i] != self.files[i] or self.stamp_of(found[i]) != self.stamps[i]:
                    same = False
                    break
        if same:
            return
        var kept = _Old()  # (what the index already holds is kept as it is; only new or changed files wait to be embedded)
        for i in range(len(self.files)):
            if len(self.passages[i]) > 0 or i not in self.waiting:
                kept.files.append(self.files[i])
                kept.stamps.append(self.stamps[i])
                kept.passages.append(self.passages[i].copy())
                kept.vectors.append(self.vectors[i].copy())
        self.rebuild(found, kept)

    def rebuild(mut self, found: List[String], old: _Old):
        self.scans += 1
        self.files = List[String]()
        self.stamps = List[String]()
        self.passages = List[List[String]]()
        self.vectors = List[List[Float32]]()
        self.waiting = List[Int]()
        self.cur = -1  # (a file half embedded starts again: its index may have moved)
        self.cur_parts = List[String]()
        self.cur_vecs = List[Float32]()
        for rel in found:
            var stamp = self.stamp_of(rel)
            self.files.append(rel)
            self.stamps.append(stamp)
            var kept = old.find(rel, stamp)
            if kept >= 0:
                self.passages.append(old.passages[kept].copy())
                self.vectors.append(old.vectors[kept].copy())
            else:
                self.passages.append(List[String]())
                self.vectors.append(List[Float32]())
                self.waiting.append(len(self.files) - 1)

    def ready(self) -> Bool:
        return self.scanned and len(self.waiting) == 0

    def step(mut self, budget_ms: Int) raises -> Bool:
        """Embeds waiting notes a few passages at a time (BATCH a call) for about `budget_ms`: a call is only made when the last one's
        cost still fits, so one tick is one call at the usual budget, however big the file is (at least one call is always
        made). True when the index is complete (and saved)."""
        var until = now_ns() + budget_ms * 1_000_000
        var first = True
        while len(self.waiting) > 0 and (first or Float64(until - now_ns()) / 1e6 >= self.call_ms):
            first = False
            if self.cur < 0:  # the next file: read and cut into passages (a megabyte cuts in under a millisecond)
                self.cur = self.waiting[0]
                var text = String("")
                try:
                    text = open(self.root + "/" + self.files[self.cur], "r").read()
                except:
                    pass  # (unreadable or not text: it holds nothing)
                self.cur_parts = split_passages(text)
                self.cur_vecs = List[Float32]()
                self.cur_at = 0
            var n = min(BATCH, len(self.cur_parts) - self.cur_at)
            if n > 0:
                var t0 = now_ns()
                var labelled = List[String]()
                for k in range(self.cur_at, self.cur_at + n):
                    labelled.append(self.files[self.cur] + ": " + self.cur_parts[k])
                self.embedder.prefix = "passage: "
                var vecs = self.embedder.embed(labelled)
                for v in vecs:
                    self.cur_vecs.append(v)
                self.cur_at += n
                self.embedded += n
                self.call_ms = Float64(now_ns() - t0) / 1e6
            if self.cur_at >= len(self.cur_parts):  # the file is whole: its passages become searchable at once
                self.vectors[self.cur] = self.cur_vecs.copy()
                self.passages[self.cur] = self.cur_parts.copy()
                self.cur = -1
                _ = self.waiting.pop(0)
        if len(self.waiting) == 0 and self.scanned:
            self.save_cache()
            return True
        return False

    def count(self) -> Int:
        var n = 0
        for p in self.passages:
            n += len(p)
        return n

    def search(mut self, question: String, folder: String = "", k: Int = 4) raises -> List[NoteHit]:
        """The passages that best answer `question`, best first, from `folder` (inside the notes folder; "" = all of it)."""
        var start = resolve_inside(self.root, folder)
        var prefix = String("") if start == self.root else String(start[byte = self.root.byte_length() + 1 :]) + "/"
        self.embedder.prefix = "query: "
        var q = self.embedder.embed([question])
        var dim = self.embedder.dim
        # (the TOP best candidates by score, kept as (score, file, passage) while scoring: no sort of every passage)
        var top_score = List[Float64]()
        var top_file = List[Int]()
        var top_pass = List[Int]()
        for f in range(len(self.files)):
            if prefix != "" and not self.files[f].startswith(prefix):
                continue
            for p in range(len(self.passages[f])):
                var sc = 0.0
                for d in range(dim):
                    sc += Float64(q[d]) * Float64(self.vectors[f][p * dim + d])
                if len(top_score) >= TOP and sc <= top_score[len(top_score) - 1]:
                    continue
                var at = len(top_score)
                while at > 0 and top_score[at - 1] < sc:
                    at -= 1
                top_score.insert(at, sc)
                top_file.insert(at, f)
                top_pass.insert(at, p)
                if len(top_score) > TOP:
                    _ = top_score.pop()
                    _ = top_file.pop()
                    _ = top_pass.pop()
        var scored = List[NoteHit]()
        for i in range(len(top_score)):
            scored.append(NoteHit(self.files[top_file[i]], self.passages[top_file[i]][top_pass[i]], top_score[i]))
        var out = List[NoteHit]()
        if len(scored) == 0 or scored[0].score < MIN_SCORE:
            return out^
        var floor = scored[0].score - BAND
        for h in scored:
            if h.score < floor or len(out) >= k:
                break
            var same = 0
            for o in out:
                if o.file == h.file:
                    same += 1
            if same < PER_FILE:
                out.append(h.copy())
        return out^

    # --- the cache ------------------------------------------------------------------------------------------------

    def save_cache(self):
        if self.cache == "":
            return
        try:
            _make_dir(self.cache)
            var meta = String('{"dim":384,"files":[')
            var floats = List[Float32]()
            for f in range(len(self.files)):
                meta += ("," if f > 0 else "") + '{"f":' + json_string(self.files[f]) + ',"s":' + json_string(self.stamps[f]) + ',"c":['
                for p in range(len(self.passages[f])):
                    meta += ("," if p > 0 else "") + json_string(self.passages[f][p])
                meta += "]}"
                for v in self.vectors[f]:
                    floats.append(v)
            meta += "]}"
            var out = open(self.key() + ".json", "w")
            out.write(meta)
            out.close()
            var raw = open(self.key() + ".f32", "w")
            var bytes = List[UInt8](length=len(floats) * 4, fill=0)
            var src = floats.unsafe_ptr().bitcast[UInt8]()
            for k in range(len(bytes)):
                bytes[k] = src[k]
            raw.write_bytes(Span(bytes))
            raw.close()
        except:
            pass  # (an index that can't be kept is made again next time)

    def load_cache(self) -> _Old:
        var old = _Old()
        if self.cache == "" or not file_exists(self.key() + ".json") or not file_exists(self.key() + ".f32"):
            return old^
        try:
            var j = Json.parse(open(self.key() + ".json", "r").read())
            var raw = open(self.key() + ".f32", "r").read_bytes()
            var files = j.get(0, "files")
            var total = 0
            for i in range(j.size(files)):
                total += j.size(j.get(j.at(files, i), "c"))
            if total * 384 * 4 != len(raw):
                return _Old()  # (half written, or another dimension: made again)
            var at = 0
            for i in range(j.size(files)):
                var rec = j.at(files, i)
                old.files.append(j.text(j.get(rec, "f")))
                old.stamps.append(j.text(j.get(rec, "s")))
                var ps = List[String]()
                var cs = j.get(rec, "c")
                for p in range(j.size(cs)):
                    ps.append(j.text(j.at(cs, p)))
                var vs = List[Float32](length=len(ps) * 384, fill=0)
                var dst = vs.unsafe_ptr().bitcast[UInt8]()
                for k in range(len(vs) * 4):
                    dst[k] = raw[at * 4 + k]
                at += len(vs)
                old.passages.append(ps^)
                old.vectors.append(vs^)
        except:
            return _Old()
        return old^


struct _Old(Movable):
    """What the cache held: per file its name, its stamp, its passages and their vectors."""
    var files: List[String]
    var stamps: List[String]
    var passages: List[List[String]]
    var vectors: List[List[Float32]]

    def __init__(out self):
        self.files = List[String]()
        self.stamps = List[String]()
        self.passages = List[List[String]]()
        self.vectors = List[List[Float32]]()

    def find(self, file: String, stamp: String) -> Int:
        for i in range(len(self.files)):
            if self.files[i] == file and self.stamps[i] == stamp:
                return i
        return -1


def _make_dir(path: String) raises:
    from std.os import makedirs
    makedirs(path, exist_ok=True)
