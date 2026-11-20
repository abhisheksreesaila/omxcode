# What changed on a board since it was last drawn (goal 79, D-7940): the damage rects a tiled layer hands the renderer
# (Painter.layer_damage), found by comparing each item's key and box with the last frame's, so no edit path can forget
# to report one. Any drawing code that paints items with ids can use it.
#
#   var snap = DamageSnap()
#   snap.begin()
#   for each item: snap.feed(id, key, x0, y0, x1, y1)   # key: anything that changes when its picture does (rev, colour…)
#   snap.feed_line(id, key, ax, ay, bx, by, pad)        # a straight item (a connector): damage along it, not its box
#   var rects = snap.finish()                           # old and new boxes of items that changed, came or went
#   if snap.fresh: no earlier snapshot (everything is new: no damage to give)

from std.collections import Dict
from std.math import sqrt, ceil

comptime LINE_CHUNK = 96.0  # a line's damage: boxes along it this long (a long diagonal's box would cover a board)


struct DamageSnap(Movable):
    var ids: List[Int]  # the last snapshot, in feed order
    var keys: List[Int]
    var boxes: List[Float64]
    var pads: List[Float64]  # ≥ 0: the item is a line from (x0, y0) to (x1, y1) of its box fields, this much round it
    var at: Dict[Int, Int]  # id → position in the last snapshot
    var have: Bool  # a snapshot exists
    var fresh: Bool  # the last finish() had no snapshot to compare with
    var nids: List[Int]  # the feed in progress
    var nkeys: List[Int]
    var nboxes: List[Float64]
    var npads: List[Float64]
    var seen: List[Bool]
    var out: List[Float64]
    var moved_order: Bool

    def __init__(out self):
        self.ids = List[Int]()
        self.keys = List[Int]()
        self.boxes = List[Float64]()
        self.pads = List[Float64]()
        self.at = Dict[Int, Int]()
        self.have = False
        self.fresh = True
        self.nids = List[Int]()
        self.nkeys = List[Int]()
        self.nboxes = List[Float64]()
        self.npads = List[Float64]()
        self.seen = List[Bool]()
        self.out = List[Float64]()
        self.moved_order = False

    def begin(mut self):
        self.nids.clear()
        self.nkeys.clear()
        self.nboxes.clear()
        self.npads.clear()
        self.out.clear()
        self.seen = List[Bool](length=len(self.ids), fill=False)
        self.moved_order = False

    def _rect(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        self.out.append(x0)
        self.out.append(y0)
        self.out.append(x1)
        self.out.append(y1)

    def _emit(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64, pad: Float64):
        """An item's damage: its box, or for a line, boxes along it."""
        if pad < 0:
            self._rect(x0, y0, x1, y1)
            return
        var dx = x1 - x0
        var dy = y1 - y0
        var n = max(1, Int(ceil(sqrt(dx * dx + dy * dy) / LINE_CHUNK)))
        for c in range(n):
            var ax = x0 + dx * Float64(c) / Float64(n)
            var ay = y0 + dy * Float64(c) / Float64(n)
            var bx = x0 + dx * Float64(c + 1) / Float64(n)
            var by = y0 + dy * Float64(c + 1) / Float64(n)
            self._rect(min(ax, bx) - pad, min(ay, by) - pad, max(ax, bx) + pad, max(ay, by) + pad)

    def feed(mut self, id: Int, key: Int, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        self._feed(id, key, x0, y0, x1, y1, -1)

    def feed_line(mut self, id: Int, key: Int, ax: Float64, ay: Float64, bx: Float64, by: Float64, pad: Float64):
        """A straight item from (ax, ay) to (bx, by), drawing within pad of that segment."""
        self._feed(id, key, ax, ay, bx, by, pad)

    def _feed(mut self, id: Int, key: Int, x0: Float64, y0: Float64, x1: Float64, y1: Float64, pad: Float64):
        var idx = len(self.nids)
        self.nids.append(id)
        self.nkeys.append(key)
        self.nboxes.append(x0)
        self.nboxes.append(y0)
        self.nboxes.append(x1)
        self.nboxes.append(y1)
        self.npads.append(pad)
        if not self.have:
            return
        var p = idx
        if p >= len(self.ids) or self.ids[p] != id:
            self.moved_order = True
            p = self.at.get(id, -1)
        if p < 0:
            self._emit(x0, y0, x1, y1, pad)  # (new)
            return
        self.seen[p] = True
        if (self.keys[p] != key or self.boxes[4 * p] != x0 or self.boxes[4 * p + 1] != y0 or self.boxes[4 * p + 2] != x1 or self.boxes[4 * p + 3] != y1
                or self.pads[p] != pad):
            self._emit(self.boxes[4 * p], self.boxes[4 * p + 1], self.boxes[4 * p + 2], self.boxes[4 * p + 3], self.pads[p])
            self._emit(x0, y0, x1, y1, pad)

    def finish(mut self) -> List[Float64]:
        self.fresh = not self.have
        if self.have:
            for p in range(len(self.ids)):
                if not self.seen[p]:
                    self._emit(self.boxes[4 * p], self.boxes[4 * p + 1], self.boxes[4 * p + 2], self.boxes[4 * p + 3], self.pads[p])
        if len(self.nids) != len(self.ids):
            self.moved_order = True
        swap(self.ids, self.nids)
        swap(self.keys, self.nkeys)
        swap(self.boxes, self.nboxes)
        swap(self.pads, self.npads)
        if self.moved_order or not self.have:
            self.at = Dict[Int, Int]()
            for p in range(len(self.ids)):
                self.at[self.ids[p]] = p
        self.have = True
        return self.out.copy()

    def reset(mut self):
        """Forget the snapshot (the next finish() is fresh)."""
        self.have = False
        self.ids.clear()
        self.keys.clear()
        self.boxes.clear()
        self.pads.clear()
        self.at = Dict[Int, Int]()
