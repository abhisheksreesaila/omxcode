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
# The Board grows downwards (goal 73): sync's height is the window's room; the Board is never shorter, and `height(room)`
# says how tall it is (ask it for the Board's height). A corner dragged down past what the cards below can give, or a
# card that would squeeze another under its minimum, makes it taller (the Board scrolls); a bottom card's corner dragged
# up gives the height back, down to the room. Only the dragged card's row grows: every other card keeps its pixels.
#
# A card is found again as the layout left it: the same tag in the same place; else the same place (the cards before
# it were renumbered: one closed); else the same tag (it changed its own size, which the tiling then puts back).

from mojoui.tiling import Tiling, Rect, GAP


struct BoardTiles(Copyable, Movable):
    var tiles: Tiling
    var tags: Dict[String, String]  # each tile's card, by its tag, at the last layout
    var w: Int  # the Board's size at the last layout
    var h: Int  # (its height as laid out: the window's room, or taller)
    var room: Int  # the window's room at the last layout
    var tall: Int  # how tall the Board was made (0: never): its height is this or the room, whichever is more
    var next: Int  # the next tile's number (t1, t2, …)
    var focus: String  # the tile last touched or added: a new card splits it ("": the last tile)

    def __init__(out self, min_w: Int = 300, min_h: Int = 200):
        self.tiles = Tiling(min_w, min_h)
        self.tags = Dict[String, String]()
        self.w = 0
        self.h = 0
        self.room = 0
        self.tall = 0
        self.next = 1
        self.focus = ""

    def height(self, room: Int) -> Int:
        """The Board's height in a window whose room is `room` high."""
        return max(room, self.tall)

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
                var board = self.height(height)
                self.tiles.insert(ids[i], self.focus, width, board)
                if len(self.tiles) > 1 and self._cramped(width, board):  # (it would squeeze a card: a new row below everything)
                    _ = self.tiles.remove(ids[i])
                    var row = max(self.tiles.min_h, height // 2)
                    self.tiles.insert_below(ids[i], board, row)
                    self.tall = board + GAP + row
                self.focus = ids[i]
        self.w = width
        self.room = height
        self.h = self.height(height)
        self.tags = Dict[String, String]()
        for i in range(len(ids)):
            self.tags[ids[i]] = tags[i]
        return self._places(ids)

    def _cramped(self, width: Int, height: Int) -> Bool:
        for r in self.tiles.rects(width, height):
            if r.w < self.tiles.min_w or r.h < self.tiles.min_h:
                return True
        return False

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
        """Card i's corner dragged by dx, dy: its edges follow the pointer (mojoui.tiling.resize); dragged down past what
        the cards below can give (or, a bottom card, at all), the Board gets taller by the rest; a bottom card dragged up
        in a tall Board makes it shorter again, down to the window's room. Every card's place after."""
        var ids = self.ids(tags, rects)
        if 0 <= i < len(ids) and ids[i] != "":
            var id = ids[i]
            self.focus = id
            _ = self.tiles.resize(id, dx, 0, self.w, self.h)
            var rest = dy
            if dy > 0 and self.tiles.has_below(id):  # (the card below gives way first, as it always has)
                var was = self.tiles.rect_of(id, self.w, self.h).value().h
                _ = self.tiles.resize(id, 0, dy, self.w, self.h)
                rest = dy - (self.tiles.rect_of(id, self.w, self.h).value().h - was)
            elif dy < 0 and not self.tiles.has_below(id) and self.h > self.room:  # (a tall Board's bottom card: shorter first)
                var gave = self.tiles.stretch(id, max(dy, self.room - self.h), self.w, self.h)
                self.h += gave
                rest = 0
            elif dy < 0:
                _ = self.tiles.resize(id, 0, dy, self.w, self.h)
                rest = 0
            if rest > 0:  # (nothing left below to give: the Board gets taller along the card's row)
                self.h += self.tiles.stretch(id, rest, self.w, self.h)
            self.tall = self.h if self.h > self.room else 0
        return self._places(ids)
