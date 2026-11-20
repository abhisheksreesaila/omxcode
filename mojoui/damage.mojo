# What changed on a board since it was last drawn (goal 79, D-7940): the damage rects a tiled layer hands the renderer
# (Painter.layer_damage), found by comparing each item's key and box with the last frame's, so no edit path can forget
# to report one. Any drawing code that paints items with ids can use it.
#
#   var snap = DamageSnap()
#   snap.begin()
#   for each item: snap.feed(id, key, x0, y0, x1, y1)   # key: anything that changes when its picture does (rev, colour…)
#   var rects = snap.finish()                           # old and new boxes of items that changed, came or went
#   if snap.fresh: no earlier snapshot (everything is new: no damage to give)

from std.collections import Dict


struct DamageSnap(Movable):
    var ids: List[Int]  # the last snapshot, in feed order
    var keys: List[Int]
    var boxes: List[Float64]
    var at: Dict[Int, Int]  # id → position in the last snapshot
    var have: Bool  # a snapshot exists
    var fresh: Bool  # the last finish() had no snapshot to compare with
    var nids: List[Int]  # the feed in progress
    var nkeys: List[Int]
    var nboxes: List[Float64]
    var seen: List[Bool]
    var out: List[Float64]
    var moved_order: Bool

    def __init__(out self):
        self.ids = List[Int]()
        self.keys = List[Int]()
        self.boxes = List[Float64]()
        self.at = Dict[Int, Int]()
        self.have = False
        self.fresh = True
        self.nids = List[Int]()
        self.nkeys = List[Int]()
        self.nboxes = List[Float64]()
        self.seen = List[Bool]()
        self.out = List[Float64]()
        self.moved_order = False

    def begin(mut self):
        self.nids.clear()
        self.nkeys.clear()
        self.nboxes.clear()
        self.out.clear()
        self.seen = List[Bool](length=len(self.ids), fill=False)
        self.moved_order = False

    def _rect(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        self.out.append(x0)
        self.out.append(y0)
        self.out.append(x1)
        self.out.append(y1)

    def feed(mut self, id: Int, key: Int, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        var idx = len(self.nids)
        self.nids.append(id)
        self.nkeys.append(key)
        self.nboxes.append(x0)
        self.nboxes.append(y0)
        self.nboxes.append(x1)
        self.nboxes.append(y1)
        if not self.have:
            return
        var p = idx
        if p >= len(self.ids) or self.ids[p] != id:
            self.moved_order = True
            p = self.at.get(id, -1)
        if p < 0:
            self._rect(x0, y0, x1, y1)  # (new)
            return
        self.seen[p] = True
        if self.keys[p] != key or self.boxes[4 * p] != x0 or self.boxes[4 * p + 1] != y0 or self.boxes[4 * p + 2] != x1 or self.boxes[4 * p + 3] != y1:
            self._rect(self.boxes[4 * p], self.boxes[4 * p + 1], self.boxes[4 * p + 2], self.boxes[4 * p + 3])
            self._rect(x0, y0, x1, y1)

    def finish(mut self) -> List[Float64]:
        self.fresh = not self.have
        if self.have:
            for p in range(len(self.ids)):
                if not self.seen[p]:
                    self._rect(self.boxes[4 * p], self.boxes[4 * p + 1], self.boxes[4 * p + 2], self.boxes[4 * p + 3])
        if len(self.nids) != len(self.ids):
            self.moved_order = True
        swap(self.ids, self.nids)
        swap(self.keys, self.nkeys)
        swap(self.boxes, self.nboxes)
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
        self.at = Dict[Int, Int]()
