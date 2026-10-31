# mojoui.linkdrag: make a link by dragging a column onto another card (goal 41 M8, the approved prototype "A": a column's
# header picked up, dropped on a card, its matching columns shown with how many values match, a small panel confirms).
# A sheet-level controller: headers are drawn on a DataGrid's canvas, so a view-level drag can't carry them; the grid
# says a header is being dragged (DataGrid.drag_headers, GRID_HEADER_DRAG / _DROP, TableCards.dragged) and this
# hit-tests the page's cards by the rectangles the app hands it. Nothing links until Link is pressed.
#
#   var ld = LinkDrag(msg_base=7650)                                    # messages 7650 … 7650 + LD_MESSAGES
#   on GRID_HEADER_DRAG: if not ld.active: ld.begin("shipments", "", "shipment_id", column_values(sheet, c), x, y)
#                        if ld.move(x, y, cards): ld.offer(match_columns(ld.values, cards[ld.target], target_sheet))
#   on GRID_HEADER_DROP: ld.drop()                                      # over a card: the confirm panel; else it ends
#   update(): if ld.update(event): if ld.confirmed: links.add(ld.link())  (ld.line(): "LINK: shipments.shipment_id = dock.mp4 · code (12 of 14)")
#   view():  Board items += ld.views(cards); tones: ld.tone(board_index) (BOARD_TARGET on the card it would land on)
#
# Each DropCard is a card on the page: its name as shown, the table its columns come from ("" its own), its rectangle
# in the Board's coordinates, and its index among the Board's children.

from std.collections import Dict
from mojoui.app import Event
from mojoui.links import Link, End, MatchCount, BY_PERSON
from mojoui.sheet import Sheet, INT, TEXT
from mojoui.view import (View, Text, Button, TextField, VStack, HStack, Spacer, ProgressBar, CAPTION, HEADLINE, PROMINENT, SUBTLE, PLAIN,
                         START, CENTER, BOARD_PLAIN, BOARD_TARGET)

comptime LD_LINK = 0  # the panel's Link
comptime LD_CANCEL = 1
comptime LD_COLUMN = 2  # + k: candidate k picked (k < LD_MAX)
comptime LD_MAX = 6
comptime LD_OFFSET = LD_COLUMN + LD_MAX  # a time link's offset field: Return (event.text = seconds)
comptime LD_OFFSET_TYPED = LD_OFFSET + 1  # … typed in
comptime LD_MESSAGES = LD_OFFSET_TYPED + 1
comptime TIME_COLUMNS: List[String] = ["t", "time", "seconds", "time_s", "t_s", "timestamp"]


def is_time_column(name: String) -> Bool:
    """A column that holds a clock's seconds (t, time, seconds…): dropped on a video it makes a time link."""
    var n = name.lower()
    for ref w in materialize[TIME_COLUMNS]():
        if n == w:
            return True
    return False


@fieldwise_init
struct DropCard(Copyable, Movable, ImplicitlyCopyable):
    var name: String
    var table: String
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var index: Int  # its place among the Board's children
    var timed: Bool  # it has a clock of its own (a video): a time column dropped on it links by time

    def contains(self, x: Float64, y: Float64) -> Bool:
        return Float64(self.x) <= x < Float64(self.x + self.w) and Float64(self.y) <= y < Float64(self.y + self.h)


@fieldwise_init
struct Candidate(Copyable, Movable, ImplicitlyCopyable):
    var column: String
    var count: MatchCount


def column_values(sheet: Sheet, c: Int) -> List[String]:
    """Column c's distinct values as typed (empty cells left out), in the order they first appear."""
    var seen = Dict[String, Bool]()
    var out = List[String]()
    if c < 0 or c >= sheet.columns():
        return out^
    for r in range(sheet.rows()):
        if not sheet.alive(r) or sheet.is_null(c, r):
            continue
        var v = sheet.plain_text(c, r)
        if v != "" and v not in seen:
            seen[v] = True
            out.append(v)
    return out^


def match_columns(values: List[String], sheet: Sheet) -> List[Candidate]:
    """For each of the sheet's whole-number and text columns, how many of `values` it holds (a key link's "12 of 14"),
    best first; columns with none come last. Compares stored values (a word's code, a number), never formatted text,
    so it reads 7,000 rows × a few columns in a millisecond or two."""
    var out = List[Candidate]()
    for c in range(sheet.stored()):
        var kind = sheet.kind(c)
        if kind != INT and kind != TEXT:
            continue
        var want = Dict[Int, Int]()  # stored value → the value's index
        for i in range(len(values)):
            if kind == INT:
                try:
                    want[Int(values[i])] = i
                except:
                    pass
            else:
                var code = sheet.code_of(c, values[i])
                if code >= 0:
                    want[code] = i
        var found = Dict[Int, Bool]()
        if len(want) > 0:
            for r in range(sheet.rows()):
                if not sheet.alive(r) or sheet.is_null(c, r):
                    continue
                var v = Int(sheet.value(c, r))
                if v in want:
                    found[v] = True
        out.append(Candidate(sheet.name(c), MatchCount(len(found), len(values))))
    # best first (a stable insertion sort: a handful of columns)
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1].count.matched < out[j].count.matched:
            var t = out[j - 1]
            out[j - 1] = out[j]
            out[j] = t
            j -= 1
    return out^


struct LinkDrag(Movable):
    var msg_base: Int
    var active: Bool  # a header is being dragged
    var confirming: Bool  # dropped on a card: the panel asks
    var confirmed: Bool  # the last update() was Link
    var from_card: String
    var from_table: String
    var from_column: String
    var values: List[String]  # the column's distinct values
    var x: Float64  # the pointer (the Board's coordinates)
    var y: Float64
    var target: Int  # the card under it (an index into the cards handed to move()), -1 none
    var target_card: DropCard
    var candidates: List[Candidate]
    var chosen: Int
    var version: Int
    var time: Bool  # a time link: the column is a clock, the card a video
    var offset: Float64  # its offset: the column's clock = the video's + offset (seconds)
    var offset_text: String

    def __init__(out self, msg_base: Int):
        self.msg_base = msg_base
        self.active = False
        self.confirming = False
        self.confirmed = False
        self.from_card = ""
        self.from_table = ""
        self.from_column = ""
        self.values = List[String]()
        self.x = 0
        self.y = 0
        self.target = -1
        self.target_card = DropCard("", "", 0, 0, 0, 0, -1, False)
        self.candidates = List[Candidate]()
        self.chosen = 0
        self.version = 0
        self.time = False
        self.offset = 0.0
        self.offset_text = "0"

    def begin(mut self, card: String, table: String, column: String, var values: List[String], x: Float64, y: Float64):
        """A header was picked up: card `card` (its table `table`, "" its own), its column and the column's values."""
        self.active = True
        self.confirming = False
        self.from_card = card
        self.from_table = table
        self.from_column = column
        self.values = values^
        self.x = x
        self.y = y
        self.target = -1
        self.candidates = List[Candidate]()
        self.chosen = 0
        self.version += 1

    def move(mut self, x: Float64, y: Float64, cards: List[DropCard]) -> Bool:
        """The pointer moved to (x, y); True when the card under it changed (offer() its candidates then)."""
        self.x = x
        self.y = y
        self.version += 1
        var at = -1
        for k in range(len(cards)):
            if cards[k].name != self.from_card and cards[k].contains(x, y):
                at = k  # (later cards are drawn above earlier ones)
        if at == self.target:
            return False
        self.target = at
        self.candidates = List[Candidate]()
        self.chosen = 0
        self.time = False
        if at >= 0:
            self.target_card = cards[at]
        return True

    def offer(mut self, var candidates: List[Candidate]):
        """The target's columns with their counts (match_columns), best first."""
        self.candidates = candidates^
        self.chosen = 0
        self.version += 1

    def offer_time(mut self):
        """The target is a video and the column a clock: the link is a time link (its offset set in the panel)."""
        self.candidates = [Candidate("time", MatchCount(0, 0))]
        self.chosen = 0
        self.time = True
        self.offset = 0.0
        self.offset_text = "0"
        self.version += 1

    def drop(mut self) -> Bool:
        """Let go: over a card with columns, the confirm panel opens (True); else the drag just ends."""
        self.active = False
        self.version += 1
        if self.target >= 0 and len(self.candidates) > 0:
            self.confirming = True
            return True
        self.target = -1
        return False

    def cancel(mut self):
        self.active = False
        self.confirming = False
        self.target = -1
        self.version += 1

    def busy(self) -> Bool:
        return self.active or self.confirming

    def choice(self) -> Candidate:
        return self.candidates[self.chosen] if 0 <= self.chosen < len(self.candidates) else Candidate("", MatchCount(0, 0))

    def link(self) -> Link:
        """The link the panel confirms: from_card.from_column = target · chosen column; a time link: the video's clock
        (a) and the column's (b), b = a + offset."""
        var t = self.target_card
        if self.time:
            return Link.time(End(t.name, "t"), End(self.from_card, self.from_column, self.from_table), self.offset, by=BY_PERSON)
        return Link.key(End(self.from_card, self.from_column, self.from_table), End(t.name, self.choice().column, t.table), BY_PERSON)

    def line(self) -> String:
        """The trace line a check reads: "LINK: shipments.shipment_id = dock.mp4 · code (12 of 14)"; a time link:
        "LINK: forklift_log.t ~ dock.mp4 · time +3.4 s"."""
        var c = self.choice()
        if self.time:
            return "LINK: " + self.from_card + "." + self.from_column + " ~ " + self.target_card.name + " · time " + ("+" if self.offset >= 0 else "") + String(self.offset) + " s"
        return "LINK: " + self.from_card + "." + self.from_column + " = " + self.target_card.name + " · " + c.column + " (" + c.count.text() + ")"

    def owns(self, message: Int) -> Bool:
        return self.msg_base <= message < self.msg_base + LD_MESSAGES

    def update(mut self, event: Event) -> Bool:
        """True when the event was the panel's: Link (confirmed: read link() and line(), then it closes), Cancel, a column."""
        self.confirmed = False
        if not self.owns(event.message):
            return False
        var m = event.message - self.msg_base
        if m == LD_OFFSET_TYPED:
            self.offset_text = event.text
        elif m == LD_OFFSET or (m == LD_LINK and self.confirming and self.time):
            var text = event.text if m == LD_OFFSET and event.text != "" else self.offset_text
            try:
                self.offset = atof(String(text.strip()).replace("+", "").replace(" s", ""))
                self.offset_text = String(text.strip())
            except:
                pass
        if m == LD_LINK and self.confirming:
            self.confirmed = True
            self.confirming = False
        elif m == LD_CANCEL:
            self.confirming = False
            self.active = False
        elif m >= LD_COLUMN and m - LD_COLUMN < len(self.candidates):
            self.chosen = m - LD_COLUMN
        if not self.confirming and not self.active:
            self.target = -1
        self.version += 1
        return True

    def tone(self, board_index: Int) -> Int:
        """A Board child's tone while this shows: the card a drop lands on is BOARD_TARGET."""
        if self.busy() and self.target >= 0 and self.target_card.index == board_index:
            return BOARD_TARGET
        return BOARD_PLAIN

    # ---------- what floats on the page ----------

    def views(self, page_w: Int) -> List[View]:
        """Board items (place them last, so they sit above the cards): the column at the pointer while dragging, the
        target's matching columns, and the confirm panel beside it once dropped. `page_w`: the Board's width (the panel
        goes left of the card when there's no room right of it)."""
        var out = List[View]()
        var b = self.msg_base
        if self.active:
            var gw = 20 + 7 * len(self.from_column.codepoints())
            out.append(Text(self.from_column, CAPTION).tag("link-ghost").at(Int(self.x) + 10, Int(self.y) + 8).width(gw).height(26))
        if self.target >= 0 and self.busy() and len(self.candidates) > 0:
            var t = self.target_card
            var rows = List[View]()
            rows.append(Text(("Drop to link by time" if self.active else "Linked by time") if self.time else ("Drop on a column" if self.active else "Matching columns"), CAPTION))
            var shown = 1  # (the best, and the others that match at least half as well: a stray number isn't a candidate)
            while shown < min(len(self.candidates), 3) and self.candidates[shown].count.matched * 2 >= max(self.candidates[0].count.matched, 1):
                shown += 1
            for k in range(shown):
                var c = self.candidates[k]
                var said = c.count.text() + " match" if c.count.matched > 0 else String("no match")
                if self.time:
                    said = "its clock, with an offset"
                rows.append(HStack(Button(c.column, b + LD_COLUMN + k, PROMINENT if k == self.chosen else SUBTLE).tag("link-column-" + c.column)
                                   .tooltip("Link on " + t.name + "'s " + c.column + ": " + said),
                                   Text(said, CAPTION).tone(4 if c.count.matched > 0 and k == self.chosen else 0), spacing=8).align(CENTER))
            var lw = min(max(t.w - 24, 160), 260)
            var lh = 34 + 36 * shown
            out.append(VStack(rows^, spacing=4).align(START).tag("link-columns").at(t.x + 12, t.y + t.h - lh - 12).width(lw).height(lh))
        if self.confirming and self.time:
            var t = self.target_card
            var parts = List[View]()
            parts.append(Text("Link by time?", HEADLINE))
            parts.append(Text(self.from_card + " · " + self.from_column, CAPTION).tag("link-end"))
            parts.append(Text("runs with", CAPTION))
            parts.append(Text(t.name + " · its clock", CAPTION).tag("link-end"))
            parts.append(HStack(Text("Offset", CAPTION), TextField(self.offset_text, "seconds", b + LD_OFFSET_TYPED, b + LD_OFFSET).width(80).tag("link-offset")
                                .label("Offset in seconds: " + self.from_column + " = the video's time + offset"), Text("s", CAPTION), spacing=6).align(CENTER))
            parts.append(Text(self.from_column + " = " + t.name + "'s time + offset", CAPTION))
            parts.append(HStack(Button("Link", b + LD_LINK, PROMINENT).tooltip("Link " + self.from_card + " to " + t.name + " by time"),
                                Button("Cancel", b + LD_CANCEL, SUBTLE), spacing=8))
            var pw = 228
            var ph = 220
            var px = t.x + t.w + 14
            if px + pw > page_w:
                px = max(t.x - pw - 14, 0)
            var py = min(max(Int(self.y) - 16, t.y), max(t.y + t.h - 60, t.y))
            out.append(VStack(parts^, spacing=6).align(START).tag("link-confirm").at(px, py).width(pw).height(ph))
        elif self.confirming:
            var t = self.target_card
            var c = self.choice()
            var missing = c.count.total - c.count.matched
            var parts = List[View]()
            parts.append(Text("Link these?", HEADLINE))
            parts.append(Text(self.from_card + " · " + self.from_column, CAPTION).tag("link-end"))
            parts.append(Text("same as", CAPTION))
            parts.append(Text(t.name + " · " + c.column, CAPTION).tag("link-end"))
            var share = (c.count.matched * 100) // c.count.total if c.count.total > 0 else 0
            parts.append(ProgressBar(share).tag("link-meter").label(c.count.text() + " match"))
            parts.append(Text(c.count.text() + " match" + (" · " + String(missing) + " not in " + t.name if missing > 0 else String("")), CAPTION))
            parts.append(HStack(Button("Link", b + LD_LINK, PROMINENT).tooltip("Link " + self.from_card + "." + self.from_column + " to " + t.name + "." + c.column),
                                Button("Cancel", b + LD_CANCEL, SUBTLE), spacing=8))
            var pw = 216
            var ph = 204
            var px = t.x + t.w + 14
            if px + pw > page_w:
                px = max(t.x - pw - 14, 0)
            var py = min(max(Int(self.y) - 16, t.y), max(t.y + t.h - 60, t.y))  # (where it was let go: that part of the page is in view)
            out.append(VStack(parts^, spacing=6).align(START).tag("link-confirm").at(px, py).width(pw).height(ph))
        return out^
