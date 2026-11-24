# mojoui.canvasload: a JSON Canvas document opened a part at a time into an ObjectLayer (goal 79, D-7944).
#
#   var ld = CanvasLoad(text)                         # skimmed: every node's bytes and box, nothing parsed yet
#   var pn = ld.member("pn")                          # a top-level member parsed on its own (Json; -1 root when absent)
#   ld.take(layer, x0, y0, x1, y1)                    # the nodes meeting a rect (page units): parsed on every core, adopted
#   ld.step(layer, x0, y0, x1, y1, budget_us)         # the next slice: nodes meeting the rect first, then file order
#   ld.finish(layer)                                  # everything now: a reader that needs the whole document calls it
#   ld.done()                                         # nothing left
#   ld.covers(x0, y0, x1, y1)                         # every node meeting the rect is in (and both ends of its edges)
#
#   var b = OpenBoard()                               # a board and its open as one value (D-7952)
#   b.open(text, x0, y0, x1, y1)                      # skimmed and the rect's nodes taken now, on this thread
#   b.open_later(SqlText(db, sql, id), x0, y0, x1, y1)  # (D-7956) read + skim + the rect's nodes on a job thread: the
#                                                     # frame that asks costs nothing; b.holding(rect) until they're in
#
# Why: parsing Personal Note's 12 MB stress canvas whole takes ~100 ms, and the window shows a part of it. The skim
# finds where every node is without parsing: the bytes go by in 64-byte blocks, each turned into bit masks (quotes,
# backslashes, brackets), strings found by a prefix XOR of the unescaped quotes (simdjson's stage 1), and only blocks
# where the depth can come back to a node's level are walked bit by bit. Then the first frame parses only the nodes it
# shows. Edges join once both their ends are there. Stacking is the file's order throughout (a node's z and id are its
# index), so what's drawn early is drawn in its final order, and after finish() the layer is what import_json_canvas_doc
# makes of the same text (the same objects, ids, z and order; tests/test_canvasload).
# Adopting objects isn't an edit: a layer saved before a slice is still saved after it (ObjectLayer.unsaved()).

from std.bit import pop_count, count_trailing_zeros
from std.memory import pack_bits
from std.sys.info import num_logical_cores
from max.algorithm import parallelize
from mojoui.json import Json, c_locale, c_float, pow5_table
from mojoui.objectlayer import ObjectLayer, Obj, canvas_node_obj, canvas_edge_obj, CONNECTOR
from mojoui.docstore import clock_us
from mojoui.canvassource import CanvasSource
from mojoui.jsonpatch import member_text
from mojoui.shared import serial
from mojoui.objectlayer import import_json_canvas_doc
from mojoui.sqlite import Database
from mojoui.uijobs import start_ui_job
from mojoui import libc
from omxcore import Job, JobBody, JobCtl, JOB_RUNNING
from std.os import getenv

comptime _EVEN = UInt64(0x5555555555555555)


def _prefix_xor(x: UInt64) -> UInt64:
    """Bit i of the result is the XOR of bits 0..i (a string's inside, from its quotes)."""
    var y = x ^ (x << 1)
    y = y ^ (y << 2)
    y = y ^ (y << 4)
    y = y ^ (y << 8)
    y = y ^ (y << 16)
    y = y ^ (y << 32)
    return y


@fieldwise_init
struct Member(Copyable, Movable):
    var key: String
    var start: Int  # its value's first byte ('{' or '[')
    var end: Int  # one past its last


struct Skim(Movable):
    """Where a JSON document's top-level members are, and every container element of its top-level arrays."""

    var members: List[Member]
    var el_member: List[Int]  # per element: the member (index in members) it belongs to
    var el_start: List[Int]
    var el_end: List[Int]
    var ok: Bool  # the brackets and strings balanced to the end

    def __init__(out self):
        self.members = List[Member]()
        self.el_member = List[Int]()
        self.el_start = List[Int]()
        self.el_end = List[Int]()
        self.ok = False


def _key_before(p: Pointer[UInt8, MutUntrackedOrigin], at: Int) -> String:
    """The key of the member whose value starts at `at` (back over spaces and the colon to the key's quotes)."""
    var i = at - 1
    while i >= 0 and (p.unsafe_offset(i)[] == 32 or p.unsafe_offset(i)[] == 9 or p.unsafe_offset(i)[] == 10 or p.unsafe_offset(i)[] == 13 or p.unsafe_offset(i)[] == 58):
        i -= 1
    if i < 0 or p.unsafe_offset(i)[] != 34:
        return ""
    var end = i
    i -= 1
    while i >= 0:
        if p.unsafe_offset(i)[] == 34:
            var bs = 0
            var k = i - 1
            while k >= 0 and p.unsafe_offset(k)[] == 92:
                bs += 1
                k -= 1
            if bs % 2 == 0:
                break
        i -= 1
    if i < 0:
        return ""
    var out = List[UInt8](capacity=end - i - 1)
    for k in range(i + 1, end):
        out.append(p.unsafe_offset(k)[])
    return String(from_utf8_lossy=Span(out))


def skim(addr: Int, n: Int) -> Skim:
    """The structure of the JSON object in bytes [addr, addr + n): its top-level members and the containers in its
    top-level arrays (their byte ranges). Nothing is parsed; nothing past the end is read."""
    var s = Skim()
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
    var depth = 0
    var prev_escaped = UInt64(0)
    var prev_in = UInt64(0)  # all ones when the previous block ended inside a string
    var member = -1
    var member_array = False
    var el_open = -1
    var b = 0
    while b < n:
        var v = SIMD[DType.uint8, 64](32)
        if b + 64 <= n:
            v = p.unsafe_offset(b).unsafe_load[width=64]()
        else:  # (the last block: read byte by byte, nothing past the end; the rest count as spaces)
            for k in range(n - b):
                v[k] = p.unsafe_offset(b + k)[]
        var quote = pack_bits(v.eq(34))
        var bslash = pack_bits(v.eq(92))
        var opens = pack_bits(v.eq(123) | v.eq(91))
        var closes = pack_bits(v.eq(125) | v.eq(93))
        var escaped = UInt64(0)
        if bslash != 0 or prev_escaped != 0:  # (simdjson's find_escaped: bytes after an odd run of backslashes)
            var bsl = bslash & ~prev_escaped
            var follows = (bsl << 1) | prev_escaped
            var odd_starts = bsl & ~_EVEN & ~follows
            var seq = odd_starts + bsl
            prev_escaped = UInt64(1) if seq < bsl else UInt64(0)
            escaped = (_EVEN ^ (seq << 1)) & follows
        quote = quote & ~escaped
        var inside = _prefix_xor(quote) ^ prev_in
        prev_in = UInt64(0) - (inside >> 63)
        opens = opens & ~inside
        closes = closes & ~inside
        if depth - pop_count(closes).cast[DType.int64]().__int__() >= 3:  # (the depth can't reach an element's level here)
            depth += pop_count(opens).cast[DType.int64]().__int__() - pop_count(closes).cast[DType.int64]().__int__()
            b += 64
            continue
        var m = opens | closes
        while m != 0:
            var bit = count_trailing_zeros(m).cast[DType.int64]().__int__()
            m = m & (m - 1)
            var at = b + bit
            if (opens >> UInt64(bit)) & 1 == 1:
                if depth == 1:
                    member = len(s.members)
                    member_array = p.unsafe_offset(at)[] == 91
                    s.members.append(Member(_key_before(p, at), at, -1))
                elif depth == 2 and member_array:
                    el_open = at
                depth += 1
            else:
                depth -= 1
                if depth < 0:
                    return s^
                if depth == 2 and member_array and el_open >= 0:
                    s.el_member.append(member)
                    s.el_start.append(el_open)
                    s.el_end.append(at + 1)
                    el_open = -1
                elif depth == 1 and member >= 0:
                    s.members[member].end = at + 1
                    member = -1
                    member_array = False
        b += 64
    s.ok = depth == 0 and prev_in == 0
    return s^


def _skip_ws(p: Pointer[UInt8, MutUntrackedOrigin], var i: Int, end: Int) -> Int:
    while i < end and (p.unsafe_offset(i)[] == 32 or p.unsafe_offset(i)[] == 9 or p.unsafe_offset(i)[] == 10 or p.unsafe_offset(i)[] == 13):
        i += 1
    return i


def _skip_string(p: Pointer[UInt8, MutUntrackedOrigin], var i: Int, end: Int) -> Int:
    """i at an opening quote: one past the closing one."""
    i += 1
    while i < end:
        var c = p.unsafe_offset(i)[]
        if c == 92:
            i += 2
            continue
        if c == 34:
            return i + 1
        i += 1
    return end


def _skip_value(p: Pointer[UInt8, MutUntrackedOrigin], var i: Int, end: Int) -> Int:
    """One past the JSON value starting at i (a container walked bracket by bracket, strings skipped)."""
    var c = p.unsafe_offset(i)[]
    if c == 34:
        return _skip_string(p, i, end)
    if c == 123 or c == 91:
        var d = 0
        while i < end:
            c = p.unsafe_offset(i)[]
            if c == 34:
                i = _skip_string(p, i, end)
                continue
            if c == 123 or c == 91:
                d += 1
            elif c == 125 or c == 93:
                d -= 1
                if d == 0:
                    return i + 1
            i += 1
        return end
    while i < end and p.unsafe_offset(i)[] != 44 and p.unsafe_offset(i)[] != 125 and p.unsafe_offset(i)[] != 93:
        i += 1
    return i


def read_keys(addr: Int, start: Int, end: Int, names: List[String]) -> List[Int]:
    """The values of an object's own keys `names` (the object's bytes [start, end)): for each name its value's byte range
    as two entries (start, end), (-1, -1) when absent. Keys are read in order until every name is found; a nested value
    is skipped whole, nothing is parsed."""
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
    var out = List[Int](length=2 * len(names), fill=-1)
    var found = 0
    var i = _skip_ws(p, start + 1, end)
    while i < end and found < len(names):
        if p.unsafe_offset(i)[] != 34:
            break
        var k0 = i + 1
        i = _skip_string(p, i, end)
        var klen = i - 1 - k0
        i = _skip_ws(p, i, end)
        if i >= end or p.unsafe_offset(i)[] != 58:
            break
        i = _skip_ws(p, i + 1, end)
        var v0 = i
        i = _skip_value(p, i, end)
        for n in range(len(names)):
            if out[2 * n] >= 0 or names[n].byte_length() != klen:
                continue
            var same = True
            var nb = names[n].as_bytes()
            for c in range(klen):
                if p.unsafe_offset(k0 + c)[] != nb[c]:
                    same = False
                    break
            if same:
                out[2 * n] = v0
                out[2 * n + 1] = i
                found += 1
                break
        i = _skip_ws(p, i, end)
        if i < end and p.unsafe_offset(i)[] == 44:
            i = _skip_ws(p, i + 1, end)
    return out^


def _number_at(addr: Int, a: Int, b: Int, default: Float64) -> Float64:
    """The JSON number in bytes [a, b) (`default` when it isn't one)."""
    if a < 0:
        return default
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
    var c = p.unsafe_offset(a)[]
    if not (c == 45 or (c >= 48 and c <= 57)):
        return default
    var t = List[UInt8](capacity=b - a)
    for k in range(a, b):
        var ch = p.unsafe_offset(k)[]
        if ch == 32 or ch == 9 or ch == 10 or ch == 13:
            break
        t.append(ch)
    return c_float(String(from_utf8_lossy=Span(t)))


def _string_at(addr: Int, a: Int, b: Int) -> String:
    """The JSON string in bytes [a, b) as text ("" when it isn't one); escapes decoded as the reader decodes them."""
    if a < 0:
        return ""
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
    if p.unsafe_offset(a)[] != 34:
        return ""
    var plain = True
    for k in range(a + 1, b - 1):
        if p.unsafe_offset(k)[] == 92:
            plain = False
            break
    if plain:
        var t = List[UInt8](capacity=b - a)
        for k in range(a + 1, b - 1):
            t.append(p.unsafe_offset(k)[])
        return String(from_utf8_lossy=Span(t))
    try:
        var j = Json.parse_bytes(addr + a, b - a)
        return j.text(0)
    except:
        return ""


def node_box(addr: Int, start: Int, end: Int) -> Tuple[Float64, Float64, Float64, Float64]:
    """A JSON Canvas node's x, y, width, height from its own keys (width 200 and height 100 when absent, as the
    importer), nothing else parsed."""
    var v = read_keys(addr, start, end, ["x", "y", "width", "height"])
    return (_number_at(addr, v[0], v[1], 0), _number_at(addr, v[2], v[3], 0), _number_at(addr, v[4], v[5], 200), _number_at(addr, v[6], v[7], 100))


comptime _PENDING = 0
comptime _ADOPTED = 1
comptime _NOTHING = 2  # parsed: the importer makes no object of it (or it isn't JSON)


struct CanvasLoad(Movable):
    """A JSON Canvas document being opened into an ObjectLayer a part at a time (see the top of the file)."""

    var text: String
    var ok: Bool  # skimmed: an object with a "nodes" array (else open it whole: import_json_canvas_doc raises the why)
    var members: List[Member]
    var ns: List[Int]  # per node: its bytes [ns, ne)
    var ne: List[Int]
    var bx0: List[Float64]  # per node: its box, from its own keys
    var by0: List[Float64]
    var bx1: List[Float64]
    var by1: List[Float64]
    var state: List[UInt8]
    var left: Int  # nodes not parsed yet
    var cursor: Int  # the next node in file order a slice looks at
    var es: List[Int]  # per edge: its bytes
    var ee: List[Int]
    var e_from: List[Int]  # per edge: the node (index) it starts and ends at, -1 when no node has that id
    var e_to: List[Int]
    var e_left: List[Int]  # edges not adopted yet (indices)
    var at_key: Dict[String, Int]  # a node's id in the document → its last node's index
    var dup_prev: List[Int]  # per node: the previous node with the same id (-1): an edge binds to the last that made an object
    var rate: Float64  # bytes parsed per µs, all cores together (measured by every slice)
    var skim_us: Int
    var bad: Int  # nodes that weren't JSON (made nothing)
    var trace: Bool  # MOJOUI_LOAD_TRACE=1: each slice's parse and adopt times (diagnosis)
    var serial: Bool  # parse on this thread only (a job thread's load, D-7956)
    var nodes_m: Int  # the members "nodes" and "edges" (-1: none)
    var edges_m: Int
    var src_id: Int  # (review 3) the document's source (CanvasSource): objects name it as they come in, its text is handed over at the end
    var cores: Int  # workers for a slice (the machine's logical cores: 12 → 24 measured 6.5 → 4.8 ms; MOJOUI_LOAD_CORES=n for an A/B)

    def __init__(out self, var text: String):
        self.text = text^
        self.ok = False
        self.members = List[Member]()
        self.ns = List[Int]()
        self.ne = List[Int]()
        self.bx0 = List[Float64]()
        self.by0 = List[Float64]()
        self.bx1 = List[Float64]()
        self.by1 = List[Float64]()
        self.state = List[UInt8]()
        self.left = 0
        self.cursor = 0
        self.es = List[Int]()
        self.ee = List[Int]()
        self.e_from = List[Int]()
        self.e_to = List[Int]()
        self.e_left = List[Int]()
        self.at_key = Dict[String, Int]()
        self.dup_prev = List[Int]()
        self.rate = 0
        self.skim_us = 0
        self.bad = 0
        self.trace = getenv("MOJOUI_LOAD_TRACE") == "1"
        self.cores = num_logical_cores()
        self.serial = False
        self.src_id = serial()
        self.nodes_m = -1
        self.edges_m = -1
        try:
            if getenv("MOJOUI_LOAD_CORES") != "":
                self.cores = max(1, Int(getenv("MOJOUI_LOAD_CORES")))
        except:
            pass
        var t0 = clock_us()
        var addr = Int(self.text.unsafe_ptr())
        var sk = skim(addr, self.text.byte_length())
        if not sk.ok:
            return
        var nodes_m = -1
        var edges_m = -1
        for i in range(len(sk.members)):
            if sk.members[i].key == "nodes" and sk.members[i].end > 0 and self.text.as_bytes()[sk.members[i].start] == 91:
                nodes_m = i
            elif sk.members[i].key == "edges" and sk.members[i].end > 0 and self.text.as_bytes()[sk.members[i].start] == 91:
                edges_m = i
        if nodes_m < 0:
            return
        self.nodes_m = nodes_m
        self.edges_m = edges_m
        for k in range(len(sk.el_start)):
            if sk.el_member[k] == nodes_m:
                var a = sk.el_start[k]
                var b = sk.el_end[k]
                var v = read_keys(addr, a, b, ["x", "y", "width", "height", "id"])
                var x = _number_at(addr, v[0], v[1], 0)
                var y = _number_at(addr, v[2], v[3], 0)
                var key = _string_at(addr, v[8], v[9])
                self.dup_prev.append(self.at_key.get(key, -1))
                self.at_key[key] = len(self.ns)
                self.ns.append(a)
                self.ne.append(b)
                self.bx0.append(x)
                self.by0.append(y)
                self.bx1.append(x + max(_number_at(addr, v[4], v[5], 200), 0.0))
                self.by1.append(y + max(_number_at(addr, v[6], v[7], 100), 0.0))
            elif sk.el_member[k] == edges_m:
                self.es.append(sk.el_start[k])
                self.ee.append(sk.el_end[k])
        for e in range(len(self.es)):  # (an edge's ends, read without parsing it: a slice that shows it loads both)
            var v = read_keys(addr, self.es[e], self.ee[e], ["fromNode", "toNode"])
            self.e_from.append(self.at_key.get(_string_at(addr, v[0], v[1]), -1))
            self.e_to.append(self.at_key.get(_string_at(addr, v[2], v[3]), -1))
            self.e_left.append(e)
        # (review 3) an element that isn't an object or array (a stray number, null) isn't in the skim: such a document is
        # imported whole, so every element keeps its place
        if not self._bare(sk.members[nodes_m], self.ns, self.ne) or (edges_m >= 0 and not self._bare(sk.members[edges_m], self.es, self.ee)):
            return
        self.state = List[UInt8](length=len(self.ns), fill=_PENDING)
        self.left = len(self.ns)
        self.members = sk.members.copy()
        self.ok = True
        self.skim_us = clock_us() - t0

    def _bare(self, m: Member, a: List[Int], b: List[Int]) -> Bool:
        """Between the elements found, the array m holds commas and spaces only."""
        ref t = self.text
        var at = m.start + 1
        for i in range(len(a) + 1):
            var end = a[i] if i < len(a) else m.end - 1
            var commas = 0
            for q in range(at, end):
                var c = t.as_bytes()[q]
                if c == 44:
                    commas += 1
                elif c != 32 and c != 9 and c != 10 and c != 13:
                    return False
            if commas != (1 if 0 < i < len(a) else 0):
                return False
            if i < len(b):
                at = b[i]
        return True

    def nodes(self) -> Int:
        return len(self.ns)

    def done(self) -> Bool:
        return self.left == 0 and len(self.e_left) == 0

    def member(self, key: String) -> Json:
        """A top-level member (an object or an array) parsed on its own; an empty object's Json when it isn't there."""
        for ref m in self.members:
            if m.key == key and m.end > m.start:
                try:
                    return Json.parse_bytes(Int(self.text.unsafe_ptr()) + m.start, m.end - m.start)
                except:
                    pass
        try:
            return Json.parse("{}")
        except:
            return Json()

    def covers(self, x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> Bool:
        """Nothing the rect needs is pending (page units: the nodes meeting it and both ends of every edge crossing it,
        what take() of it would parse): everything drawn there is in."""
        for m in self._marks(x0, y0, x1, y1):
            if m:
                return False
        return True

    def _meets(self, i: Int, x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> Bool:
        return self.bx1[i] >= x0 and self.bx0[i] <= x1 and self.by1[i] >= y0 and self.by0[i] <= y1

    def _parse(mut self, mut layer: ObjectLayer, idx: List[Int], stepping: Bool = False):
        """Nodes idx (pending, in file order) parsed on every core and adopted with their file ids, then the edges whose
        ends are both there."""
        layer.src.id = self.src_id
        layer.reserve_ids(len(self.ns) + len(self.es))  # (D-7959: an edit meanwhile makes ids above the document's)
        var count = len(idx)
        if count > 0:
            var t0 = clock_us()
            _ = c_locale()  # (made once, here, before any worker reads it)
            _ = pow5_table()
            var made = List[Bool](length=count, fill=False)
            var objs = List[Obj](capacity=count)
            for _ in range(count):
                objs.append(Obj(0, 0, 0, 0, 0, 0, 0))
            var total = 0
            for i in idx:
                total += self.ne[i] - self.ns[i]
            var workers = self.cores
            var tasks = max(1, min(4 * workers, count, total // 16384 + 1))  # (more pieces than cores: they even out)
            var cut = List[Int](length=tasks + 1, fill=count)  # (tasks split by bytes, not by count)
            cut[0] = 0
            var acc = 0
            var t = 1
            for k in range(count):
                if t < tasks and acc * tasks >= total * t:
                    cut[t] = k
                    t += 1
                acc += self.ne[idx[k]] - self.ns[idx[k]]
            var base = Int(self.text.unsafe_ptr())
            var ip = Int(idx.unsafe_ptr())
            var sp = Int(self.ns.unsafe_ptr())
            var ep = Int(self.ne.unsafe_ptr())
            var mp = Int(made.unsafe_ptr())
            var op = Int(objs.unsafe_ptr())
            var cp = Int(cut.unsafe_ptr())

            def work(w: Int) {imm}:
                var ids_ = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=ip)
                var st = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=sp)
                var en = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=ep)
                var mk = Pointer[Bool, MutUntrackedOrigin](unsafe_from_address=mp)
                var ob = Pointer[Obj, MutUntrackedOrigin](unsafe_from_address=op)
                var ct = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=cp)
                var j = Json()  # (one reader per piece, made over for each node: no allocation per node)
                for k in range(ct.unsafe_offset(w)[], ct.unsafe_offset(w + 1)[]):
                    var i = ids_.unsafe_offset(k)[]
                    var a = st.unsafe_offset(i)[]
                    try:
                        j.reparse(base + a, en.unsafe_offset(i)[] - a)
                        if canvas_node_obj(j, 0, ob.unsafe_offset(k)[]):
                            mk.unsafe_offset(k)[] = True
                    except:
                        pass

            if tasks == 1:
                work(0)
            elif self.serial:  # (on a job thread: max's parallelize there aborts, AsyncRT's CPU device made with other options)
                for w in range(tasks):
                    work(w)
            else:
                parallelize(work, tasks, min(tasks, workers))
            _ = len(cut)
            _ = len(idx)
            var t_par = clock_us()
            var was_saved = not layer.unsaved()
            for k in range(count):
                var i = idx[k]
                self.left -= 1
                if not made[k]:
                    self.state[i] = _NOTHING
                    continue
                self.state[i] = _ADOPTED
                var o = Obj(0, 0, 0, 0, 0, 0, 0)
                swap(o, objs[k])
                _ = layer.adopt_as(o^, i + 1, i + 1)
            if was_saved:
                layer.mark_saved()
            var r = Float64(total) / Float64(max(clock_us() - t0, 1))  # (the slice's own rate, adopting included)
            if stepping:  # (a slice's rate sets the next slice's size; the first, big and on every core, runs faster)
                self.rate = r if self.rate == 0 else min(r, 0.5 * self.rate + 0.5 * r)
            if self.trace:
                print("CANVASLOAD: " + String(count) + " nodes, " + String(total) + " bytes on " + String(tasks) + " cores: parse " + String(t_par - t0) + " us, adopt " + String(clock_us() - t_par) + " us", flush=True)
        var te = clock_us()
        self._edges(layer)
        if self.trace:
            print("CANVASLOAD: edges " + String(clock_us() - te) + " us, " + String(len(self.e_left)) + " waiting", flush=True)

    def _edges(mut self, mut layer: ObjectLayer):
        """The edges whose ends are both adopted, parsed and adopted (an end that made nothing, or no node with its id:
        dropped, as the importer drops it)."""
        var was_saved = not layer.unsaved()
        var count = len(self.ns)
        var still = List[Int]()
        var j = Json()
        for e in self.e_left:
            var a = self._end(self.e_from[e])
            var b = self._end(self.e_to[e])
            if a == -1 or b == -1:  # (no node with that id made an object: the importer drops the edge too)
                continue
            if a == -2 or b == -2:  # (a node it may bind to isn't parsed yet)
                still.append(e)
                continue
            if not layer.has(a + 1) or not layer.has(b + 1):
                # (D-7959) an end deleted by an edit made during the open: that delete would have taken the edge too, so
                # it joins that step as deleted there (an undo brings it back with its end)
                try:
                    j.reparse(Int(self.text.unsafe_ptr()) + self.es[e], self.ee[e] - self.es[e])
                    var rd = canvas_edge_obj(j, 0)
                    var cd = rd[2].copy()
                    cd.from_id = a + 1
                    cd.to_id = b + 1
                    _ = layer.adopt_deleted(cd^, count + e + 1, count + e + 1, [a + 1, b + 1])
                except:
                    pass
                continue
            if a == b:
                continue
            try:
                j.reparse(Int(self.text.unsafe_ptr()) + self.es[e], self.ee[e] - self.es[e])
                var r = canvas_edge_obj(j, 0)
                var c = r[2].copy()
                c.from_id = a + 1
                c.to_id = b + 1
                _ = layer.adopt_as(c^, count + e + 1, count + e + 1)
            except:
                pass
        self.e_left = still^
        if was_saved:
            layer.mark_saved()

    def _end(self, last: Int) -> Int:
        """The node an edge end binds to, as import_json_canvas_doc binds it: the last node with that id that made an
        object (-1: none did; -2: one that may is still pending)."""
        var i = last
        while i >= 0:
            if self.state[i] == _PENDING:
                return -2
            if self.state[i] == _ADOPTED:
                return i
            i = self.dup_prev[i]
        return -1

    def _marks(self, x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> List[Bool]:
        """Per node: pending and needed to draw the rect: its box meets it, or it is an end (the whole chain of nodes
        with that id) of an edge crossing it."""
        var mark = List[Bool](length=len(self.ns), fill=False)
        for i in range(len(self.ns)):
            if self.state[i] == _PENDING and self._meets(i, x0, y0, x1, y1):
                mark[i] = True
        for e in self.e_left:  # (a connector crossing the rect needs both its ends, wherever they are)
            var a = self.e_from[e]
            var b = self.e_to[e]
            if a < 0 or b < 0:
                continue
            # (its line lies within its two ends' boxes, whichever rule routes it)
            if max(self.bx1[a], self.bx1[b]) >= x0 and min(self.bx0[a], self.bx0[b]) <= x1 and max(self.by1[a], self.by1[b]) >= y0 and min(self.by0[a], self.by0[b]) <= y1:
                for end in [a, b]:  # (the whole chain of nodes with that id: the edge binds to the last that makes one)
                    var q = end
                    while q >= 0:
                        if self.state[q] == _PENDING:
                            mark[q] = True
                        q = self.dup_prev[q]
        return mark^

    def take(mut self, mut layer: ObjectLayer, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        """Every pending node the rect needs (its box meets it, or it ends an edge crossing it), parsed and adopted now."""
        var mark = self._marks(x0, y0, x1, y1)
        var idx = List[Int]()
        for i in range(len(self.ns)):
            if mark[i]:
                idx.append(i)
        self._parse(layer, idx)
        self._settle(layer)

    def step(mut self, mut layer: ObjectLayer, x0: Float64, y0: Float64, x1: Float64, y1: Float64, budget_us: Int):
        """One slice: pending nodes meeting the rect first (the view moved), then file order, as many bytes as the
        measured rate parses in budget_us (at least one node)."""
        if self.done():
            return
        var budget = Int((self.rate if self.rate > 0 else 400.0) * Float64(budget_us))
        var idx = List[Int]()
        var taken = 0
        var need = self._marks(x0, y0, x1, y1)  # (what the rect needs first: as take() would load it)
        for i in range(len(self.ns)):
            if need[i]:
                idx.append(i)
                taken += self.ne[i] - self.ns[i]
                if taken >= budget:
                    break
        var mark = List[Bool]()
        if len(idx) > 0:
            mark = List[Bool](length=len(self.ns), fill=False)
            for i in idx:
                mark[i] = True
        while self.cursor < len(self.ns) and taken < budget:
            var i = self.cursor
            self.cursor += 1
            if self.state[i] == _PENDING and (len(mark) == 0 or not mark[i]):
                idx.append(i)
                taken += self.ne[i] - self.ns[i]
        sort(idx)
        self._parse(layer, idx, True)
        self._settle(layer)

    def finish(mut self, mut layer: ObjectLayer):
        """Everything left, now (a save, an export, an edit, anything that reads the whole document calls this first)."""
        if self.done():
            return
        var idx = List[Int]()
        for i in range(len(self.ns)):
            if self.state[i] == _PENDING:
                idx.append(i)
        self._parse(layer, idx)
        self._settle(layer)

    def _settle(mut self, mut layer: ObjectLayer):
        if self.done():
            var was_saved = not layer.unsaved()
            if not layer.src.ok and self.ok:  # (its own text goes with it: what isn't edited is saved as it was)
                var src = CanvasSource()
                src.id = self.src_id
                src.ns = self.ns.copy()
                src.ne = self.ne.copy()
                src.es = self.es.copy()
                src.ee = self.ee.copy()
                src.nodes_at = self.members[self.nodes_m].start
                src.nodes_end = self.members[self.nodes_m].end
                if self.edges_m >= 0:
                    src.edges_at = self.members[self.edges_m].start
                    src.edges_end = self.members[self.edges_m].end
                src.text = self.text
                src.ok = True
                if self.edges_m < 0 and self.text.find('"edges"') >= 0:  # (an "edges" the skim has no place for: null, a number)
                    var whole = CanvasSource.of(self.text)
                    whole.id = self.src_id
                    src = whole^
                layer.src = src^
            layer.order_by_z()
            if was_saved:  # (D-7959: an edit made during the open stays undoable)
                layer.history.clear()
                layer.mark_saved()


def text_hash(text: String) -> Int:
    """A fingerprint of a document's text (eight bytes at a step; 12 MB in ~3 ms): whether a picture kept of it is of this
    very text. 0 is no text's."""
    var n = text.byte_length()
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(text.unsafe_ptr()))
    var h = UInt64(0xCBF29CE484222325) ^ UInt64(n)
    var i = 0
    while i + 8 <= n:
        var v = UInt64(0)
        for k in range(8):
            v |= UInt64(p.unsafe_offset(i + k)[]) << UInt64(8 * k)
        h = (h ^ v) * 0x9E3779B97F4A7C15
        h ^= h >> 32
        i += 8
    while i < n:
        h = (h ^ UInt64(p.unsafe_offset(i)[])) * 0x100000001B3
        i += 1
    _ = text.byte_length()
    return Int(h >> 2) | 1


trait TextSource(Movable, Deinitable):
    """(D-7956) Where a document's text comes from, read on a job thread (so it opens its own handles there)."""

    def read(mut self) raises -> String:
        ...


struct SqlText(TextSource):
    """One TEXT column of one row: `sql` with one integer parameter, on a connection of its own (memory-mapped reads),
    opened on the thread that reads it."""

    var path: String
    var sql: String
    var arg: Int

    def __init__(out self, path: String, sql: String, arg: Int):
        self.path = path
        self.sql = sql
        self.arg = arg

    def read(mut self) raises -> String:
        var db = Database(self.path)
        db.map_reads()
        var q = db.prepare(self.sql)
        q.bind(1, self.arg)
        if not q.step():
            raise Error("no such row")
        return q.text(0)


struct OpenedCanvas(Movable):
    """What an open on a job thread hands back: the load with the rect's nodes taken into `layer`, or `back` (the text,
    when the skim can't open it: imported whole on the UI thread), or `problem` (the read failed)."""

    var load: List[CanvasLoad]
    var layer: ObjectLayer
    var back: String
    var problem: String
    var hash: Int  # text_hash of what was read
    var read_us: Int
    var skim_us: Int
    var take_us: Int

    def __init__(out self):
        self.load = List[CanvasLoad]()
        self.layer = ObjectLayer()
        self.back = ""
        self.problem = ""
        self.hash = 0
        self.read_us = 0
        self.skim_us = 0
        self.take_us = 0


struct CanvasOpenJob[S: TextSource](JobBody):
    comptime Out = OpenedCanvas
    var src: Self.S
    var x0: Float64
    var y0: Float64
    var x1: Float64
    var y1: Float64
    var gap: Float64
    var take: Bool  # the rect's nodes parsed on the job too (serially: max's parallelize can't run on a job thread)

    def __init__(out self, var src: Self.S, x0: Float64, y0: Float64, x1: Float64, y1: Float64, gap: Float64, take: Bool):
        self.src = src^
        self.take = take
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
        self.gap = gap

    def run(mut self, ctl: JobCtl) raises -> OpenedCanvas:
        var out = OpenedCanvas()
        var t0 = clock_us()
        var text: String
        try:
            text = self.src.read()
        except e:
            out.problem = String(e)
            return out^
        if text == "":  # (not a canvas, whatever else: never an empty board)
            out.problem = "the document is empty"
            return out^
        out.hash = text_hash(text)
        var t1 = clock_us()
        out.read_us = t1 - t0
        var ld = CanvasLoad(text^)
        var t2 = clock_us()
        out.skim_us = t2 - t1
        if not ld.ok:
            swap(out.back, ld.text)
            return out^
        if self.gap >= 0:
            out.layer.set_connector_gap(self.gap)
        out.layer.mark_saved()
        if self.take:
            ld.serial = True
            ld.take(out.layer, self.x0, self.y0, self.x1, self.y1)
        out.take_us = clock_us() - t2
        if not ld.done():
            out.load.append(ld^)
        return out^


struct OpenBoard(Movable):
    """(D-7952) A board and the progressive open still filling it, as one value, so an app can't act on part of a
    document: painting and panning read `layer` as it is (the visible part is there from the first frame); edit() and
    take() finish the load first, then hand the whole board over (an edit during an open waits for the rest, measured by
    the GTK framebench's `openpress`). step() runs one slice per frame, skipping the open's own frame."""

    var layer: ObjectLayer
    var load: List[CanvasLoad]
    var fresh: Bool  # the open's own frame: it shows what open() took, no slice in it
    var job: Optional[Job[OpenedCanvas]]  # (D-7956) an open_later() still reading on its job thread
    var gap: Float64
    var broken: Bool  # (review 3) the last open failed: the board is empty and read-only until another document is opened
    var text_hash: Int  # a fingerprint of the text an open_later() read (0: none yet)
    var problem: String  # why the last open_later() found nothing ("" when it didn't fail)
    var times: String  # the last open_later()'s read / skim / take on its thread, µs (MOJOUI_LOAD_TRACE prints it)

    def __init__(out self):
        self.layer = ObjectLayer()
        self.load = List[CanvasLoad]()
        self.fresh = False
        self.job = None
        self.gap = -1
        self.broken = False
        self.text_hash = 0
        self.problem = ""
        self.times = ""

    def _fail(mut self, why: String):
        """The document couldn't be read: an empty board that nothing may edit, and why."""
        self.problem = why if why != "" else String("It couldn't be read.")
        self.broken = True
        self.load.clear()
        self.layer = ObjectLayer()
        self.layer.read_only = True
        self.layer.mark_saved()

    def fail(mut self, why: String):
        """The app couldn't read the document: the same (nothing to edit, nothing to keep, nothing to save)."""
        self.job = None
        self._fail(why)

    def keepable(self) -> Bool:
        """The board is a document read whole: worth keeping parsed, safe to save (never a failed open's empty one)."""
        return not self.broken and not self.loading()

    def set(mut self, var layer: ObjectLayer):
        """A board made whole elsewhere (a kept parse, a whole import, an empty one): any open in progress is dropped
        (a job still reading ends on its own thread; what it read is thrown away)."""
        self.load.clear()
        self.fresh = False
        self.job = None
        self.broken = False
        self.problem = ""
        self.layer = layer^

    def open_later[S: TextSource](mut self, var src: S, x0: Float64, y0: Float64, x1: Float64, y1: Float64, connector_gap: Float64 = -1,
                                  take_on_job: Bool = False):
        """(D-7956) The open with nothing on this thread: the text read and skimmed on a job thread (start_ui_job: the UI
        is woken when it ends). Until then the board is empty and pending(); step() adopts it the frame after it lands
        (no slice in that frame), then slices as open() does, the rect's nodes first, on every core (holding() until
        they're in). take_on_job: the rect's nodes parsed on the job as well (one core there: measured 44 ms for PN's
        stress view, against ~5 ms of slices here; an edit made meanwhile waits for it).
        edit(), take(), member() and finish() wait for it. An app shows something in the meantime (the view kept on
        disk, mojoui.viewsnap, while holding() says the rect isn't in yet)."""
        self.load.clear()
        self.fresh = False
        self.problem = ""
        self.broken = False
        self.text_hash = 0
        self.gap = connector_gap
        self.layer = ObjectLayer()
        if connector_gap >= 0:
            self.layer.set_connector_gap(connector_gap)
        self.layer.mark_saved()
        self.job = start_ui_job(CanvasOpenJob[S](src^, x0, y0, x1, y1, connector_gap, take_on_job))

    def pending(self) -> Bool:
        """An open_later() whose job hasn't been adopted yet."""
        return Bool(self.job)

    def holding(self, x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> Bool:
        """The rect's nodes aren't all in yet (an open_later() still on its thread, or a load whose rect part is pending)."""
        if self.job:
            return True
        return len(self.load) > 0 and not self.load[0].covers(x0, y0, x1, y1)

    def _adopt(mut self, wait: Bool) -> Bool:
        """An open_later()'s result into the board when its job has ended (wait: block until it has). True when adopted."""
        if not self.job:
            return False
        if not wait and self.job.value().poll() == JOB_RUNNING:
            return False
        while self.job.value().poll() == JOB_RUNNING:
            _ = libc.usleep(100)
        var job = self.job.take()
        var got = OpenedCanvas()
        try:
            got = job.result()
        except e:
            got.problem = String(e)
        self.text_hash = got.hash
        self.times = "read " + String(got.read_us) + " skim " + String(got.skim_us) + " take " + String(got.take_us)
        if got.problem != "":
            self._fail(got.problem)
            return True
        if got.back != "":  # (not something the skim opens: the whole import, which raises the why)
            try:
                var j = Json.parse(got.back)
                self.layer = import_json_canvas_doc(j, got.back)
                if self.gap >= 0:
                    self.layer.set_connector_gap(self.gap)
                self.layer.mark_saved()
            except e:
                self._fail(String(e))
            return True
        if len(got.load) > 0:
            self.load.append(got.load.pop())
            self.load[0].serial = False  # (its slices run here, on every core)
        swap(self.layer, got.layer)
        self.fresh = True
        return True

    def open(mut self, var text: String, x0: Float64, y0: Float64, x1: Float64, y1: Float64, connector_gap: Float64 = -1) -> String:
        """A JSON Canvas opened progressively: the nodes meeting the rect (page units) now, the rest by step(). Returns
        "" when it opened, else the text back (not a document the skim can open: the caller imports it whole and gets
        the reader's error)."""
        var ld = CanvasLoad(text^)
        self.job = None  # (an earlier open_later() still reading: what it reads is thrown away)
        self.broken = False
        self.problem = ""
        if not ld.ok:
            var back = String("")
            swap(back, ld.text)
            return back^
        self.layer = ObjectLayer()
        if connector_gap >= 0:
            self.layer.set_connector_gap(connector_gap)
        self.layer.mark_saved()  # (what the file holds: unchanged until edited; slices keep it so)
        ld.take(self.layer, x0, y0, x1, y1)
        self.load.clear()
        self.fresh = True
        if not ld.done():
            self.load.append(ld^)
        return ""

    def member(mut self, key: String) -> Json:
        """A top-level member of the document being opened (its page grid); an empty object when none is opening."""
        _ = self._adopt(True)
        if len(self.load) > 0:
            return self.load[0].member(key)
        if self.layer.src.ok:  # (all in: its own text)
            try:
                var t = member_text(self.layer.src.text, key)
                if t != "":
                    return Json.parse(t)
            except:
                pass
        try:
            return Json.parse("{}")
        except:
            return Json()

    def loading(self) -> Bool:
        return len(self.load) > 0 or Bool(self.job)

    def left(self) -> Int:
        """Nodes not parsed yet (0 when whole)."""
        return self.load[0].left if len(self.load) > 0 else 0

    def step(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64, budget_us: Int) -> Bool:
        """One slice (the rect's nodes first); True while more is left (the app asks for another frame)."""
        if self.job:
            _ = self._adopt(False)
            if self.job:
                return True  # (still reading: another frame)
        if len(self.load) == 0:
            self.fresh = False
            return False
        if self.fresh:
            self.fresh = False
            return True
        self.load[0].step(self.layer, x0, y0, x1, y1, budget_us)
        if self.load[0].done():
            self.load.clear()
            return False
        return True

    def finish(mut self):
        """Everything left, now."""
        _ = self._adopt(True)
        if len(self.load) > 0:
            self.load[0].finish(self.layer)
            self.load.clear()
        self.fresh = False

    def near(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> ref [self.layer] ObjectLayer:
        """(D-7959) The board to edit or read inside the rect (page units: the view): everything the rect needs is
        loaded first (an open_later() still reading is waited for; then the rect's pending nodes and both ends of edges
        crossing it), the rest keeps coming a slice a frame. An edit made now stays undoable after the open ends, its
        ids sit above the document's, and an edge whose end it deleted is dropped as deleting would have dropped it.
        Anything that reads or writes the whole board (a save, an export, select all) uses edit()."""
        _ = self._adopt(True)
        if len(self.load) > 0:
            self.load[0].take(self.layer, x0, y0, x1, y1)
            if self.load[0].done():
                self.load.clear()
        return self.layer

    def edit(mut self) -> ref [self.layer] ObjectLayer:
        """The whole board, to change or to read all of (a save, a search, a selection): the load is finished first."""
        self.finish()
        return self.layer

    def take(mut self) -> ObjectLayer:
        """The whole board moved out (kept for later), an empty one left."""
        self.finish()
        var out = ObjectLayer()
        swap(out, self.layer)
        return out^
