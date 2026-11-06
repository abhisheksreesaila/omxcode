# mojoui.boardtiles: a Board whose cards tile (goal 54). mojoui.tiling kept in step with an app's own cards, so an app
# only says what its cards are (a tag each, in the Board's order) and where they are now; it gets back where each goes.
#
#   var bt = BoardTiles()                                     # (min_w, min_h: mojoui.tiling's minimums)
#   var places = bt.sync(tags, rects, W, H)                   # after every event: a new card splits the one last touched,
#                                                             # a closed card's space goes to its neighbour
#   for i in range(len(places)): card i goes to places[i]
#   places = bt.drop(i, dx, dy, tags, rects)                  # card i's header dragged by dx, dy: where its middle landed,
#                                                             # the card there trades places with it (else it goes back)
#   places = bt.resize(i, dx, dy, tags, rects)                # card i's corner dragged: its edges follow (mojoui.tiling)
#   Board(items, W, H, on_move=…, on_resize=…, clips=True)    # (each card held to exactly its place: mojoui.view)
#
# A card is found again as the layout left it: the same tag in the same place; else the same place (the cards before
# it were renumbered: one closed); else the same tag (it changed its own size, which the tiling then puts back).

from mojoui.tiling import Tiling, Rect


struct BoardTiles(Copyable, Movable):
    var tiles: Tiling
    var tags: Dict[String, String]  # each tile's card, by its tag, at the last layout
    var w: Int  # the Board's size at the last layout
    var h: Int
    var next: Int  # the next tile's number (t1, t2, …)
    var focus: String  # the tile last touched or added: a new card splits it ("": the last tile)

    def __init__(out self, min_w: Int = 300, min_h: Int = 200):
        self.tiles = Tiling(min_w, min_h)
        self.tags = Dict[String, String]()
        self.w = 0
        self.h = 0
        self.next = 1
        self.focus = ""

    def ids(self, tags: List[String], rects: List[Rect]) -> List[String]:
        """Each card's tile ("": a new card), matched in three passes: tag and place, place, tag."""
        var leaves = self.tiles.leaves()
        var old = self.tiles.rects(self.w, self.h)
        var out = List[String]()
        for _ in range(len(tags)):
            out.append("")
        var used = List[Bool]()
        for _ in range(len(leaves)):
            used.append(False)
        for phase in range(3):
            for i in range(len(tags)):
                if out[i] != "":
                    continue
                for j in range(len(leaves)):
                    if used[j]:
                        continue
                    var same_tag = self.tags.get(leaves[j], "") == tags[i]
                    var same_place = i < len(rects) and old[j] == rects[i]
                    if (phase == 0 and same_tag and same_place) or (phase == 1 and same_place) or (phase == 2 and same_tag):
                        out[i] = leaves[j]
                        used[j] = True
                        break
        return out^

    def _places(self, ids: List[String]) -> List[Rect]:
        var leaves = self.tiles.leaves()
        var rects = self.tiles.rects(self.w, self.h)
        var out = List[Rect]()
        for i in range(len(ids)):
            var r = Rect(0, 0, 0, 0)
            for j in range(len(leaves)):
                if leaves[j] == ids[i]:
                    r = rects[j]
                    break
            out.append(r)
        return out^

    def sync(mut self, tags: List[String], rects: List[Rect], width: Int, height: Int) raises -> List[Rect]:
        """The tiles follow the cards (new ones split the focused card, gone ones give their space back), then every
        card's place in a width × height Board, in the order of `tags`."""
        var ids = self.ids(tags, rects)
        for leaf in self.tiles.leaves():
            if leaf not in ids:
                _ = self.tiles.remove(leaf)
        if not self.tiles.has(self.focus):
            self.focus = ""
        for i in range(len(ids)):
            if ids[i] == "":
                ids[i] = "t" + String(self.next)
                self.next += 1
                self.tiles.insert(ids[i], self.focus, width, height)
                self.focus = ids[i]
        self.w = width
        self.h = height
        self.tags = Dict[String, String]()
        for i in range(len(ids)):
            self.tags[ids[i]] = tags[i]
        return self._places(ids)

    def touch(mut self, i: Int, tags: List[String], rects: List[Rect]):
        """Card i was touched: the next new card splits it."""
        var ids = self.ids(tags, rects)
        if 0 <= i < len(ids) and ids[i] != "":
            self.focus = ids[i]

    def drop(mut self, i: Int, dx: Int, dy: Int, tags: List[String], rects: List[Rect]) -> List[Rect]:
        """Card i's header dragged by dx, dy and let go: the card under where its middle landed trades places with it;
        anywhere else, it goes back. Every card's place after."""
        var ids = self.ids(tags, rects)
        if 0 <= i < len(ids) and ids[i] != "":
            self.focus = ids[i]
            var px = rects[i].x + rects[i].w // 2 + dx
            var py = rects[i].y + rects[i].h // 2 + dy
            for j in range(len(rects)):
                ref r = rects[j]
                if j != i and ids[j] != "" and r.x <= px < r.x + r.w and r.y <= py < r.y + r.h:
                    _ = self.tiles.swap(ids[i], ids[j])
                    break
        return self._places(ids)

    def resize(mut self, i: Int, dx: Int, dy: Int, tags: List[String], rects: List[Rect]) -> List[Rect]:
        """Card i's corner dragged by dx, dy: its edges follow the pointer (mojoui.tiling.resize). Every card's place after."""
        var ids = self.ids(tags, rects)
        if 0 <= i < len(ids) and ids[i] != "":
            self.focus = ids[i]
            _ = self.tiles.resize(ids[i], dx, dy, self.w, self.h)
        return self._places(ids)
