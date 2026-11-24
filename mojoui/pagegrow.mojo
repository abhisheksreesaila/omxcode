# Paper that grows (goal 79, review 4, MUST 6): how many pages a board's content needs, as Personal Note's pages.js reckons it.
# A page appears as content crosses any edge of the grid and folds back when it is emptied; a page added on the left or top
# moves every object by whole pages (the view follows by as much, so nothing seems to move).
#
#   var g = settle_pages(columns, rows, box, PAGE_W, PAGE_H)      # after an edit
#   var g = grow_for_drag(columns, rows, box, …)                  # while something is dragged (right and bottom; grows only)
#   var g = grow_for_text(columns, rows, box, line_h, …)          # while words are typed
from std.math import ceil

comptime EDGE_OVERFLOW = 6.0  # past the edge by more than this, a page is added (after an edit)
comptime EDGE_SHRINK = 0.0  # a page folds back when the content is this far from it
comptime EDGE_MARGIN = 24.0  # while dragging or typing, a page appears when the content is this close to the edge


@fieldwise_init
struct PageBox(Copyable, Movable, ImplicitlyCopyable):
    """What the content covers (page px); `any` False: there is none."""
    var any: Bool
    var left: Float64
    var top: Float64
    var right: Float64
    var bottom: Float64

    @staticmethod
    def none() -> PageBox:
        return PageBox(False, 0, 0, 0, 0)

    def take(mut self, x0: Float64, y0: Float64, x1: Float64, y1: Float64):
        if not self.any:
            self = PageBox(True, x0, y0, x1, y1)
            return
        self.left = min(self.left, x0)
        self.top = min(self.top, y0)
        self.right = max(self.right, x1)
        self.bottom = max(self.bottom, y1)


@fieldwise_init
struct PageGrid(Copyable, Movable, ImplicitlyCopyable):
    var columns: Int
    var rows: Int
    var shift_x: Float64  # how far every object moves (pages added on the left or top: positive; folded away there: negative)
    var shift_y: Float64


def settle_pages(columns: Int, rows: Int, box: PageBox, page_w: Float64, page_h: Float64) -> PageGrid:
    """The grid the content needs after an edit."""
    if not box.any:
        return PageGrid(1, 1, 0, 0)
    var b = box
    var g = PageGrid(columns, rows, 0, 0)
    var left = Int(ceil((-EDGE_OVERFLOW - b.left) / page_w)) if b.left < -EDGE_OVERFLOW else 0
    var top = Int(ceil((-EDGE_OVERFLOW - b.top) / page_h)) if b.top < -EDGE_OVERFLOW else 0
    g.columns += left
    g.rows += top
    g.shift_x += Float64(left) * page_w
    g.shift_y += Float64(top) * page_h
    b.left += g.shift_x
    b.right += g.shift_x
    b.top += g.shift_y
    b.bottom += g.shift_y
    if b.right > Float64(g.columns) * page_w + EDGE_OVERFLOW:
        g.columns += Int(ceil((b.right - Float64(g.columns) * page_w - EDGE_OVERFLOW) / page_w))
    if b.bottom > Float64(g.rows) * page_h + EDGE_OVERFLOW:
        g.rows += Int(ceil((b.bottom - Float64(g.rows) * page_h - EDGE_OVERFLOW) / page_h))
    while True:
        if g.columns > 1 and b.left > page_w + EDGE_SHRINK:
            g.columns -= 1
            g.shift_x -= page_w
            b.left -= page_w
            b.right -= page_w
        elif g.columns > 1 and b.right < Float64(g.columns - 1) * page_w - EDGE_SHRINK:
            g.columns -= 1
        else:
            break
    while True:
        if g.rows > 1 and b.top > page_h + EDGE_SHRINK:
            g.rows -= 1
            g.shift_y -= page_h
            b.top -= page_h
            b.bottom -= page_h
        elif g.rows > 1 and b.bottom < Float64(g.rows - 1) * page_h - EDGE_SHRINK:
            g.rows -= 1
        else:
            break
    return g


def grow_for_drag(columns: Int, rows: Int, box: PageBox, page_w: Float64, page_h: Float64) -> PageGrid:
    """While an object is dragged: pages on the right and at the bottom before it reaches the edge; they fold back only once
    it is dropped (settle_pages, which also adds the ones on the left and top: Personal Note adds those during the drag)."""
    return grow_for_text(columns, rows, box, 0, page_w, page_h)


def grow_for_text(columns: Int, rows: Int, box: PageBox, line_h: Float64, page_w: Float64, page_h: Float64) -> PageGrid:
    """While words are typed: a page before they reach the right or bottom edge, a line ahead at the bottom."""
    var g = PageGrid(columns, rows, 0, 0)
    if not box.any:
        return g
    while box.right > Float64(g.columns) * page_w - EDGE_MARGIN:
        g.columns += 1
    while box.bottom + line_h > Float64(g.rows) * page_h - EDGE_MARGIN:
        g.rows += 1
    return g
