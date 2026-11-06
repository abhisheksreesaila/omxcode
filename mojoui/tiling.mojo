# mojoui.tiling: cards on a Board kept as a tiling window manager keeps windows (goal 54; Hyprland's "dwindle"). The
# Board's area is a tree of splits: each split puts two parts side by side (V) or one above the other (H) at a ratio, with
# a gap of GAP between them; each leaf is one card. Nothing ever overlaps and nothing is left over, by construction.
#
#   var t = Tiling()                              # (min_w, min_h: the smallest a card is made while the space allows)
#   t.insert("table", "", W, H)                   # the first card: the whole area
#   t.insert("chart", "table", W, H)              # halves the table's space along its longer side, the chart second
#   t.remove("chart")                             # its sibling takes its space back
#   t.resize("table", 120, 0, W, H)               # the table's right edge 120 further (the card beside it gives way)
#   t.swap("table", "video")                      # a drop on another card: they trade places
#   for i in range(len(t)): t.leaves()[i], t.rects(W, H)[i]     # each card's Rect, in the Board's coordinates
#   var saved = t.to_text(); var back = Tiling.from_text(saved)   # "v0.580000(table,h0.500000(chart,%76ideo))"
#
# A resize moves the edge the card shares with its neighbour: the nearest split above it whose divider is that edge
# (right or bottom; a card on the far right or bottom moves its left or top edge instead). Ratios are clamped so both
# sides keep their minimum; the layout clamps again when the area shrinks, so a smaller window squeezes the biggest
# parts first and every card keeps min_w × min_h while the space allows.

comptime GAP = 8
comptime V = 0  # side by side: a | b
comptime H = 1  # one above the other: a / b
comptime LEAF = 2


@fieldwise_init
struct Rect(Copyable, Movable, ImplicitlyCopyable, Equatable, Writable):
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    def __eq__(self, other: Self) -> Bool:
        return self.x == other.x and self.y == other.y and self.w == other.w and self.h == other.h

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.x, ",", self.y, " ", self.w, "x", self.h)


@fieldwise_init
struct _Node(Copyable, Movable):
    var kind: Int  # V, H or LEAF
    var id: String  # a leaf's card
    var ratio: Float64  # a split's share for `a`
    var a: Int
    var b: Int
    var parent: Int  # -1: the root


def _escape(id: String) -> String:
    var s = id.replace("%", "%25").replace(",", "%2C").replace("(", "%28").replace(")", "%29")
    if s.startswith("v") or s.startswith("h"):  # (a name can't read as a split: v0.5(…)
        s = ("%76" if s.startswith("v") else "%68") + String(s[byte=1:])
    return s


def _unescape(s: String) -> String:
    return s.replace("%76", "v").replace("%68", "h").replace("%2C", ",").replace("%28", "(").replace("%29", ")").replace("%25", "%")


struct Tiling(Copyable, Movable, Sized):
    var nodes: List[_Node]
    var root: Int  # -1: empty
    var min_w: Int
    var min_h: Int

    def __init__(out self, min_w: Int = 240, min_h: Int = 160):
        self.nodes = List[_Node]()
        self.root = -1
        self.min_w = min_w
        self.min_h = min_h

    def __len__(self) -> Int:
        return len(self.leaves())

    # ---- reading

    def _leaves(self, n: Int, mut out: List[String]):
        if n < 0:
            return
        if self.nodes[n].kind == LEAF:
            out.append(self.nodes[n].id)
        else:
            self._leaves(self.nodes[n].a, out)
            self._leaves(self.nodes[n].b, out)

    def leaves(self) -> List[String]:
        """The cards, in reading order (left before right, top before bottom)."""
        var out = List[String]()
        self._leaves(self.root, out)
        return out^

    def _find(self, id: String) -> Int:
        for i in range(len(self.nodes)):
            if self.nodes[i].kind == LEAF and self.nodes[i].id == id:
                return i
        return -1

    def has(self, id: String) -> Bool:
        return self._find(id) >= 0

    def _min(self, n: Int, horizontal: Bool) -> Int:
        """The smallest width (horizontal) or height a part can have with every card in it at its minimum."""
        ref node = self.nodes[n]
        if node.kind == LEAF:
            return self.min_w if horizontal else self.min_h
        var ma = self._min(node.a, horizontal)
        var mb = self._min(node.b, horizontal)
        if (node.kind == V) == horizontal:  # (the split runs along this axis: both sides and the gap)
            return ma + GAP + mb
        return max(ma, mb)

    def _split_at(self, n: Int, span: Int, horizontal: Bool) -> Int:
        """How much of `span` (the gap left out) part `a` of split n gets: its ratio, clamped so both sides keep their
        minimum when the span allows; otherwise shared by the minimums' proportion. Always 1 … span - 1."""
        ref node = self.nodes[n]
        var room = span - GAP
        var ma = self._min(node.a, horizontal)
        var mb = self._min(node.b, horizontal)
        var size = Int(Float64(room) * node.ratio + 0.5)
        if ma + mb <= room:
            size = max(ma, min(size, room - mb))
        else:
            size = Int(Float64(room) * Float64(ma) / Float64(ma + mb) + 0.5)
        return max(1, min(size, room - 1)) if room >= 2 else max(0, room // 2)

    def _place(self, n: Int, r: Rect, mut ids: List[String], mut out: List[Rect]):
        ref node = self.nodes[n]
        if node.kind == LEAF:
            ids.append(node.id)
            out.append(r)
            return
        if node.kind == V:
            var wa = self._split_at(n, r.w, True)
            self._place(node.a, Rect(r.x, r.y, wa, r.h), ids, out)
            self._place(node.b, Rect(r.x + wa + GAP, r.y, r.w - wa - GAP, r.h), ids, out)
        else:
            var ha = self._split_at(n, r.h, False)
            self._place(node.a, Rect(r.x, r.y, r.w, ha), ids, out)
            self._place(node.b, Rect(r.x, r.y + ha + GAP, r.w, r.h - ha - GAP), ids, out)

    def rects(self, width: Int, height: Int, x: Int = 0, y: Int = 0) -> List[Rect]:
        """Each card's place in a width × height area starting at (x, y), in the order of leaves()."""
        var ids = List[String]()
        var out = List[Rect]()
        if self.root >= 0:
            self._place(self.root, Rect(x, y, width, height), ids, out)
        return out^

    def rect_of(self, id: String, width: Int, height: Int) -> Optional[Rect]:
        var ids = self.leaves()
        var rs = self.rects(width, height)
        for i in range(len(ids)):
            if ids[i] == id:
                return rs[i]
        return None

    def _rect_of_node(self, target: Int, width: Int, height: Int) -> Rect:
        """The area node `target` fills (a split's too)."""
        var path = List[Int]()
        var k = target
        while k >= 0:
            path.append(k)
            k = self.nodes[k].parent
        var r = Rect(0, 0, width, height)
        var i = len(path) - 1
        while i > 0:
            var n = path[i]
            var child = path[i - 1]
            ref node = self.nodes[n]
            if node.kind == V:
                var wa = self._split_at(n, r.w, True)
                r = Rect(r.x, r.y, wa, r.h) if child == node.a else Rect(r.x + wa + GAP, r.y, r.w - wa - GAP, r.h)
            else:
                var ha = self._split_at(n, r.h, False)
                r = Rect(r.x, r.y, r.w, ha) if child == node.a else Rect(r.x, r.y + ha + GAP, r.w, r.h - ha - GAP)
            i -= 1
        return r

    # ---- changing

    def insert(mut self, id: String, beside: String, width: Int, height: Int) raises:
        """A new card: the whole area if it's the first; else it halves `beside`'s space (the last card's when `beside`
        isn't here) along that space's longer side, the new card second (right or below)."""
        if self.has(id):
            raise Error("tiling: " + id + " is already here")
        self.nodes.append(_Node(LEAF, id, 0.5, -1, -1, -1))
        var new = len(self.nodes) - 1
        if self.root < 0:
            self.root = new
            return
        var at = self._find(beside)
        if at < 0:
            var ls = self.leaves()
            at = self._find(ls[len(ls) - 1])
        var r = self._rect_of_node(at, width, height)
        var up = self.nodes[at].parent
        self.nodes.append(_Node(V if r.w >= r.h else H, "", 0.5, at, new, up))
        var split = len(self.nodes) - 1
        self.nodes[at].parent = split
        self.nodes[new].parent = split
        if up < 0:
            self.root = split
        elif self.nodes[up].a == at:
            self.nodes[up].a = split
        else:
            self.nodes[up].b = split

    def remove(mut self, id: String) -> Bool:
        """The card goes; its sibling (a card or a whole part) takes the space they shared. False when it isn't here."""
        var n = self._find(id)
        if n < 0:
            return False
        var up = self.nodes[n].parent
        if up < 0:
            self.root = -1
            self.nodes = List[_Node]()
            return True
        var sib = self.nodes[up].b if self.nodes[up].a == n else self.nodes[up].a
        var top = self.nodes[up].parent
        self.nodes[sib].parent = top
        if top < 0:
            self.root = sib
        elif self.nodes[top].a == up:
            self.nodes[top].a = sib
        else:
            self.nodes[top].b = sib
        self._compact()
        return True

    def _copy(self, n: Int, parent: Int, mut out: List[_Node]) -> Int:
        out.append(_Node(self.nodes[n].kind, self.nodes[n].id, self.nodes[n].ratio, -1, -1, parent))
        var me = len(out) - 1
        if self.nodes[n].kind != LEAF:
            var a = self._copy(self.nodes[n].a, me, out)
            var b = self._copy(self.nodes[n].b, me, out)
            out[me].a = a
            out[me].b = b
        return me

    def _compact(mut self):
        """The node list rebuilt from the root: removed nodes dropped, ratios kept exactly."""
        var out = List[_Node]()
        if self.root >= 0:
            self.root = self._copy(self.root, -1, out)
        self.nodes = out^

    def swap(mut self, a: String, b: String) -> Bool:
        """Two cards trade places (a drop on another card)."""
        var na = self._find(a)
        var nb = self._find(b)
        if na < 0 or nb < 0 or na == nb:
            return False
        self.nodes[na].id = b
        self.nodes[nb].id = a
        return True

    def resize(mut self, id: String, dx: Int, dy: Int, width: Int, height: Int) -> Bool:
        """The card grows by dx, dy (negative: shrinks) in a width × height area: its right edge moves by dx (its left
        edge, when it's on the far right), its bottom edge by dy (its top, at the bottom). True when anything moved."""
        var n = self._find(id)
        if n < 0:
            return False
        var moved = False
        if dx != 0:
            moved = self._move_edge(n, dx, V, width, height) or moved
        if dy != 0:
            moved = self._move_edge(n, dy, H, width, height) or moved
        return moved

    def _move_edge(mut self, n: Int, d: Int, kind: Int, width: Int, height: Int) -> Bool:
        # the nearest split of this kind with the card in its first part (its divider is the card's right/bottom edge);
        # else the nearest with the card in its second part (the left/top edge, moved the other way)
        var pick = -1
        var grow_a = True
        var child = n
        var k = self.nodes[n].parent
        var second = -1
        while k >= 0:
            if self.nodes[k].kind == kind:
                if self.nodes[k].a == child:
                    pick = k
                    break
                if second < 0:
                    second = k
            child = k
            k = self.nodes[k].parent
        if pick < 0:
            if second < 0:
                return False
            pick = second
            grow_a = False
        var r = self._rect_of_node(pick, width, height)
        var horizontal = kind == V
        var room = (r.w if horizontal else r.h) - GAP
        if room <= 0:
            return False
        var before = self._split_at(pick, r.w if horizontal else r.h, horizontal)
        var want = before + (d if grow_a else -d)
        var ma = self._min(self.nodes[pick].a, horizontal)
        var mb = self._min(self.nodes[pick].b, horizontal)
        if ma + mb <= room:
            want = max(ma, min(want, room - mb))
        else:
            want = max(1, min(want, room - 1))
        if want == before:
            return False
        self.nodes[pick].ratio = Float64(want) / Float64(room)
        return True

    # ---- text

    def _text(self, n: Int) -> String:
        ref node = self.nodes[n]
        if node.kind == LEAF:
            return _escape(node.id)
        var r = Int(node.ratio * 1000000.0 + 0.5)
        var digits = String(r)
        while digits.byte_length() < 6:
            digits = "0" + digits
        return ("v" if node.kind == V else "h") + "0." + digits + "(" + self._text(node.a) + "," + self._text(node.b) + ")"

    def to_text(self) -> String:
        """The tree as text: a leaf is its card's name; a split is v|h, its ratio, then (a,b). "" when empty."""
        return self._text(self.root) if self.root >= 0 else String("")

    @staticmethod
    def from_text(text: String, min_w: Int = 240, min_h: Int = 160) raises -> Tiling:
        var t = Tiling(min_w, min_h)
        var s = String(text.strip())
        if s == "":
            return t^
        var at = 0
        t.root = t._parse(s, at, -1)
        if at != s.byte_length():
            raise Error("tiling: text left over at " + String(at) + " in " + s)
        return t^

    def _parse(mut self, s: String, mut at: Int, parent: Int) raises -> Int:
        var b = s.as_bytes()
        var n = s.byte_length()
        if at + 1 < n and (b[at] == UInt8(118) or b[at] == UInt8(104)) and (b[at + 1] == UInt8(48) or b[at + 1] == UInt8(49)):
            # v0.580( … , … )
            var kind = V if b[at] == UInt8(118) else H
            var open = at
            while open < n and b[open] != UInt8(40):
                open += 1
            if open >= n:
                raise Error("tiling: no ( after a split at " + String(at))
            var ratio = Float64(String(s[byte = at + 1 : open]))
            self.nodes.append(_Node(kind, "", ratio, -1, -1, parent))
            var me = len(self.nodes) - 1
            at = open + 1
            var a = self._parse(s, at, me)
            if at >= n or b[at] != UInt8(44):
                raise Error("tiling: expected , at " + String(at))
            at += 1
            var c = self._parse(s, at, me)
            if at >= n or b[at] != UInt8(41):
                raise Error("tiling: expected ) at " + String(at))
            at += 1
            self.nodes[me].a = a
            self.nodes[me].b = c
            return me
        var start = at
        while at < n and b[at] != UInt8(44) and b[at] != UInt8(41) and b[at] != UInt8(40):
            at += 1
        if at == start:
            raise Error("tiling: an empty card name at " + String(at))
        self.nodes.append(_Node(LEAF, _unescape(String(s[byte=start:at])), 0.5, -1, -1, parent))
        return len(self.nodes) - 1
