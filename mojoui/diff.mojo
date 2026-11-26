# Compare the screen before and after an update, so hosts change only what changed.

from mojoui.view import View, Node, NAVBAR, ALERT, CANVAS, BOARD, VSTACK, HSTACK, GRID, TABLE, TOAST, AUTO, START, DRAG, EMBED, WEBCOMP, IMAGE

comptime SET_TEXT = 1  # label text, button title, field contents, toggle label
comptime SET_MSG = 2
comptime SET_VALUE = 3  # toggle, dropdown index, slider, progress
comptime SET_IMAGE = 4  # new pixels (same size); hosts read them from the shown view
comptime SET_FRAMES = 5  # a canvas's on_frame message changed (number = new message, 0 = stop)
comptime SET_PLACE = 6  # an object moved on its Board (new x, y in the shown view), or the Board's own size changed
comptime SET_SIZE = 7  # a view's width, height, min or max width changed (new values in the shown view); only in partial diffs
comptime SET_TONES = 9  # a Board's children's tones changed (Board(tones=…): the new ones in the shown view's options)
comptime SET_TIP = 8  # a canvas's tooltip or label (a drawn view's words, its accessible name) changed: text = the new tooltip; hosts read the name from the shown view (mojoui.a11y.explicit_name)


@fieldwise_init
struct Patch(Copyable, Movable, Equatable, Writable):
    var op: Int
    var node: Int
    var text: String
    var number: Int  # new message (SET_MSG) or value (SET_VALUE)

    def __eq__(self, other: Self) -> Bool:
        return self.op == other.op and self.node == other.node and self.text == other.text and self.number == other.number

    def write_to(self, mut writer: Some[Writer]):
        writer.write("Patch(", self.op, ", node=", self.node, ", '", self.text, "', ", self.number, ")")


struct Diff(Copyable, Movable):
    var rebuild: Bool  # the shape changed: hosts that can't update part of the window rebuild all of it
    var patches: List[Patch]  # small in-place changes (node numbers of the new screen)
    var partial: Bool  # with rebuild: `kept` and `resync` say which widgets can stay, so hosts that can, update only the parts that changed
    var kept: List[Int]  # new node → the old node whose widget it keeps, or -1 (built fresh)
    var resync: List[Int]  # kept stacks (new numbers) whose children changed: hosts lay out their child list again

    def __init__(out self, rebuild: Bool, var patches: List[Patch]):
        self.rebuild = rebuild
        self.patches = patches^
        self.partial = False
        self.kept = List[Int]()
        self.resync = List[Int]()

    def __init__(out self, var patches: List[Patch], var kept: List[Int], var resync: List[Int]):
        """A partial rebuild: the screen's shape changed below the root."""
        self.rebuild = True
        self.patches = patches^
        self.partial = True
        self.kept = kept^
        self.resync = resync^


def placed(v: View) -> List[Bool]:
    """Which nodes sit on a Board (their x, y are a patch, not a new layout)."""
    var out = List[Bool](length=len(v.nodes), fill=False)
    for n in v.nodes:
        if n.kind == BOARD:
            for c in n.children:
                out[c] = True
    return out^


def same_shape(a: View, b: View) -> Bool:
    """Same nodes in the same places; only text, messages, values or Board positions may differ."""
    if len(a.nodes) != len(b.nodes):
        return False
    var on_board = placed(b)
    for i in range(len(a.nodes)):
        ref x = a.nodes[i]
        ref y = b.nodes[i]
        if (
            x.kind != y.kind
            or x.style != y.style
            or (x.spacing != y.spacing and x.kind != BOARD)  # a Board's width and height are a patch
            or x.children != y.children
            or (x.options != y.options and x.kind != BOARD)  # a Board's tones are a patch
            or x.hint != y.hint
            or (x.msg2 != y.msg2 and x.kind != CANVAS)  # a canvas starting or stopping frames is a patch
            or (x.size != y.size and x.kind != BOARD)
            or ((x.kind == DRAG or x.kind == EMBED) and x.text != y.text)  # (a new payload or page: built again, not patched)
            or (x.kind == WEBCOMP and x.value != y.value)  # (another widget id: another widget; new props are a patch)
        ):
            return False
        if on_board[i]:
            var z = y.copy()
            z.x = x.x
            z.y = x.y
            if not x.same_layout(z):
                return False
        elif not x.same_layout(y):  # layout settings changed: lay it out again
            return False
        # A Back button appearing or going, a picture becoming tappable or not, or an alert's question changing, is a new layout.
        if (x.kind == NAVBAR or x.kind == IMAGE) and (x.msg == 0) != (y.msg == 0):
            return False
        if x.kind == ALERT and (x.text != y.text or x.hint != y.hint):
            return False
    return True


def node_patches(a: Node, b: Node, i: Int, on_board: Bool, mut patches: List[Patch]):
    """What changed between a kept node's old and new version (i: its new number)."""
    if (on_board and (a.x != b.x or a.y != b.y)) or (b.kind == BOARD and (a.spacing != b.spacing or a.size != b.size)):
        patches.append(Patch(SET_PLACE, i, "", 0))
    if b.kind == BOARD and a.options != b.options:
        patches.append(Patch(SET_TONES, i, "", 0))
    if a.text != b.text:
        patches.append(Patch(SET_TEXT, i, b.text, 0))
    if a.msg != b.msg:
        patches.append(Patch(SET_MSG, i, "", b.msg))
    if a.value != b.value:
        patches.append(Patch(SET_VALUE, i, "", b.value))
    if b.kind == CANVAS and a.msg2 != b.msg2:
        patches.append(Patch(SET_FRAMES, i, "", b.msg2))
    if b.kind == CANVAS and (a.tip != b.tip or a.label != b.label or a.cursor != b.cursor):
        patches.append(Patch(SET_TIP, i, b.tip, 0))
    if a.pixels != b.pixels:
        patches.append(Patch(SET_IMAGE, i, "", 0))
    if sized_differently(a, b):
        patches.append(Patch(SET_SIZE, i, "", 0))


def compatible(x: Node, y: Node, x_on_board: Bool, y_on_board: Bool) -> Bool:
    """Whether y can keep x's widget, patched (its children aside)."""
    if (
        x.kind != y.kind
        or x.style != y.style
        or (x.spacing != y.spacing and x.kind != BOARD)  # a Board's width and height are a patch
        or (x.options != y.options and x.kind != BOARD)  # a Board's tones are a patch
        or x.hint != y.hint
        or (x.msg2 != y.msg2 and x.kind != CANVAS)  # a canvas starting or stopping frames is a patch
        or (x.size != y.size and x.kind != BOARD)
        or x_on_board != y_on_board
    ):
        return False
    if not resizable(x, y):
        return False
    if not x.same_layout_but(y, True, y_on_board):  # (sizes are a patch, SET_SIZE; so is a place on a Board, SET_PLACE)
        return False  # other layout settings changed: lay it out again
    if (x.kind == GRID or x.kind == TABLE) and x.value != y.value:  # (another number of columns: placed again)
        return False
    if x.kind == TOAST and x.text != y.text:  # (a toast's text can't change once it's up: a new toast)
        return False
    if (x.kind == DRAG or x.kind == EMBED) and x.text != y.text:  # (a drag's payload, a frame's page: set when built)
        return False
    if x.kind == WEBCOMP and x.value != y.value:  # (another widget id: another widget)
        return False
    # A Back button appearing or going, a picture becoming tappable or not, or an alert's question changing, is a new layout.
    if (x.kind == NAVBAR or x.kind == IMAGE) and (x.msg == 0) != (y.msg == 0):
        return False
    if x.kind == ALERT and (x.text != y.text or x.hint != y.hint):
        return False
    return True


def resizable(x: Node, y: Node) -> Bool:
    """Whether y's size can be patched onto x's widget: each size is set in both or in neither (setting one where
    there was none changes how the view takes space, which is a new layout)."""
    var x_cap = x.max_w if x.max_w != 0 else x.w
    var y_cap = y.max_w if y.max_w != 0 else y.w
    return ((x.w == 0) == (y.w == 0) and (x.h == 0) == (y.h == 0) and (x_cap == 0) == (y_cap == 0)
            and (max(x.w, x.min_w) == 0) == (max(y.w, y.min_w) == 0))


def sized_differently(a: Node, b: Node) -> Bool:
    return a.w != b.w or a.h != b.h or a.min_w != b.min_w or a.max_w != b.max_w


def resyncable(n: Node) -> Bool:
    """A plain stack (no justify spacers between its children), a grid or a Board: hosts can add, remove and reorder its
    children in place (a grid places them again, row by row; a Board puts new objects where they say)."""
    return ((n.kind == VSTACK or n.kind == HSTACK) and (n.justify_items == AUTO or n.justify_items == START)) or n.kind == GRID or n.kind == BOARD


def same_key(a: Node, b: Node) -> Bool:
    """Children worth pairing up: the same kind of view, style and tag."""
    return a.kind == b.kind and a.style == b.style and a.name == b.name


comptime MAX_EDITS = 1000  # _run_of looks for the exact run up to this many inserted and removed children


def pairs_of(old: View, new: View, oc: List[Int], nc: List[Int]) -> List[Tuple[Int, Int]]:
    """Old and new children paired in order (the longest common run of same_key children): (old position, new position).
    Linear for a list that didn't change or changed in a few places, however long (goal 81, M2)."""
    var n = len(oc)
    var m = len(nc)
    var out = List[Tuple[Int, Int]](capacity=min(n, m))
    var head = 0
    while head < n and head < m and same_key(old.nodes[oc[head]], new.nodes[nc[head]]):
        out.append((head, head))
        head += 1
    var tail = 0
    while tail < n - head and tail < m - head and same_key(old.nodes[oc[n - 1 - tail]], new.nodes[nc[m - 1 - tail]]):
        tail += 1
    if head + tail < n and head + tail < m:  # (what's between: each distinct key numbered)
        var ids = Dict[String, Int]()
        var a = _numbered(old, oc, head, n - tail, ids)
        var b = _numbered(new, nc, head, m - tail, ids)
        for p in _run_of(a, b, len(ids)):
            out.append((head + p[0], head + p[1]))
    for k in range(tail):
        out.append((n - tail + k, m - tail + k))
    return out^


def _numbered(v: View, children: List[Int], start: Int, end: Int, mut ids: Dict[String, Int]) -> List[Int]:
    """Children start..end by their same_key, as numbers."""
    var out = List[Int](capacity=end - start)
    for k in range(start, end):
        ref n = v.nodes[children[k]]
        var key = String(n.kind) + "/" + String(n.style) + "/" + n.name
        var id = ids.get(key, len(ids))
        if id == len(ids):
            ids[key] = id
        out.append(id)
    return out^


def _run_of(a: List[Int], b: List[Int], keys: Int) -> List[Tuple[Int, Int]]:
    """The longest common run of a and b (numbers below `keys`), as positions. Exact when no number comes twice on a side
    (a sort, however large) or when at most MAX_EDITS were inserted and removed; past that, the k-th of a number pairs
    with the k-th (in order, maybe not the longest)."""
    var old_at = List[Int](length=keys, fill=-1)
    var seen_b = List[Int](length=keys, fill=0)
    var unique = True
    for i in range(len(a)):
        if old_at[a[i]] >= 0:
            unique = False
        old_at[a[i]] = i
    for x in b:
        seen_b[x] += 1
        if seen_b[x] > 1:
            unique = False
    if unique:
        var at = List[Int](capacity=len(b))
        for x in b:
            at.append(old_at[x])
        return _rising(at)
    var exact = List[Tuple[Int, Int]]()
    if _edits(a, b, exact):
        return exact^
    var next = List[Int](length=len(a), fill=-1)  # next[i]: the next place of a[i]'s number in a
    var first = List[Int](length=keys, fill=-1)
    for i in range(len(a) - 1, -1, -1):
        next[i] = first[a[i]]
        first[a[i]] = i
    var at = List[Int](capacity=len(b))
    for x in b:
        at.append(first[x])
        if first[x] >= 0:
            first[x] = next[first[x]]
    return _rising(at)


def _rising(at: List[Int]) -> List[Tuple[Int, Int]]:
    """The longest rising run of at (-1: no place): (value, position)."""
    var ends = List[Int]()  # ends[l]: the position that ends the best run of length l + 1
    var before = List[Int](length=len(at), fill=-1)
    for j in range(len(at)):
        if at[j] < 0:
            continue
        var lo = 0
        var hi = len(ends)
        while lo < hi:
            var mid = (lo + hi) // 2
            if at[ends[mid]] < at[j]:
                lo = mid + 1
            else:
                hi = mid
        if lo > 0:
            before[j] = ends[lo - 1]
        if lo == len(ends):
            ends.append(j)
        else:
            ends[lo] = j
    var out = List[Tuple[Int, Int]]()
    if len(ends) > 0:
        var j = ends[len(ends) - 1]
        while j >= 0:
            out.append((at[j], j))
            j = before[j]
    out.reverse()
    return out^


def _edits(a: List[Int], b: List[Int], mut out: List[Tuple[Int, Int]]) -> Bool:
    """Myers' shortest edit script ("An O(ND) Difference Algorithm", 1986): the pairs it leaves alone, or False past
    MAX_EDITS edits."""
    var n = len(a)
    var m = len(b)
    var most = min(n + m, MAX_EDITS)
    var off = most + 1
    var v = List[Int](length=2 * most + 3, fill=0)  # v[off + k]: how far along a, on diagonal k = x - y
    var trace = List[Int]()  # v[off - d .. off + d] as it was before step d, one after another
    var found = -1
    for d in range(most + 1):
        for k in range(-d, d + 1):
            trace.append(v[off + k])
        for k in range(-d, d + 1, 2):
            var x: Int
            if k == -d or (k != d and v[off + k - 1] < v[off + k + 1]):
                x = v[off + k + 1]
            else:
                x = v[off + k - 1] + 1
            while x < n and x - k < m and a[x] == b[x - k]:
                x += 1
            v[off + k] = x
            if x >= n and x - k >= m:
                found = d
                break
        if found >= 0:
            break
    if found < 0:
        return False
    var x = n
    var y = m
    for d in range(found, 0, -1):
        var at = d * d + d  # (step d's saved row starts at d*d; its diagonal 0 is d further)
        var k = x - y
        var down = k == -d or (k != d and trace[at + k - 1] < trace[at + k + 1])
        var pk = k + 1 if down else k - 1
        var px = trace[at + pk]
        var sx = px if down else px + 1  # (where the straight run of this step began)
        while x > sx:
            x -= 1
            y -= 1
            out.append((x, y))
        x = px
        y = px - pk
    while x > 0:
        x -= 1
        y -= 1
        out.append((x, y))
    out.reverse()
    return True


def unkeep(new: View, n: Int, mut kept: List[Int]):
    """Node n and everything under it are built fresh."""
    var todo: List[Int] = [n]
    while len(todo) > 0:
        var k = todo.pop()
        kept[k] = -1
        for c in new.nodes[k].children:
            todo.append(c)


struct Reconciler:
    var old_board: List[Bool]
    var new_board: List[Bool]
    var kept: List[Int]
    var resync: List[Int]
    var patches: List[Patch]

    def __init__(out self, old: View, new: View):
        self.old_board = placed(old)
        self.new_board = placed(new)
        self.kept = List[Int](length=len(new.nodes), fill=-1)
        self.resync = List[Int]()
        self.patches = List[Patch]()

    def keep(mut self, old: View, new: View, o: Int, n: Int) -> Bool:
        """Whether new node n keeps old node o's widget; records it (and everything under it) if so."""
        if not compatible(old.nodes[o], new.nodes[n], self.old_board[o], self.new_board[n]):
            return False
        var saved_patches = len(self.patches)
        var saved_resync = len(self.resync)
        ref oc = old.nodes[o].children
        ref nc = new.nodes[n].children
        if resyncable(new.nodes[n]):
            var pairs = pairs_of(old, new, oc, nc)
            var changed = len(pairs) != len(oc) or len(pairs) != len(nc)
            ref grid = new.nodes[n]
            var ends = grid.kind == GRID and (grid.style == 1 or grid.hint == "E")  # (its last column is placed another way: an item that comes into it or leaves it is built again)
            for p in pairs:
                var moved = ends and (p[0] % max(grid.value, 1) == grid.value - 1) != (p[1] % max(grid.value, 1) == grid.value - 1)
                if moved or not self.keep(old, new, oc[p[0]], nc[p[1]]):
                    unkeep(new, nc[p[1]], self.kept)
                    changed = True
            if changed:
                self.resync.append(n)
        else:
            var ok = len(oc) == len(nc)
            if ok:
                for k in range(len(nc)):
                    if not self.keep(old, new, oc[k], nc[k]):
                        ok = False
                        break
            if not ok:
                unkeep(new, n, self.kept)
                self.patches.resize(saved_patches, Patch(0, 0, "", 0))
                self.resync.resize(saved_resync, 0)
                return False
        self.kept[n] = o
        node_patches(old.nodes[o], new.nodes[n], n, self.new_board[n], self.patches)
        return True


def diff(old: View, new: View) -> Diff:
    """Patches when the shape is the same; otherwise a partial rebuild that keeps every widget it can (or, when even
    the root changed, a full one)."""
    if len(old.nodes) == 0 or len(new.nodes) == 0:
        return Diff(True, List[Patch]())
    var r = Reconciler(old, new)
    if not r.keep(old, new, 0, 0):
        return Diff(True, List[Patch]())
    var same = len(r.resync) == 0 and len(old.nodes) == len(new.nodes)  # (every stack kept its children)
    for p in r.patches:
        if p.op == SET_SIZE:  # (hosts that only patch rebuild for a size: only partial diffs carry SET_SIZE)
            same = False
    if same:
        for k in range(len(r.kept)):
            if r.kept[k] != k:
                same = False
                break
    if same:  # the same shape, node for node
        return Diff(False, r.patches.copy())
    return Diff(r.patches.copy(), r.kept.copy(), r.resync.copy())
