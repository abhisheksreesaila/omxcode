# mojoui.links: explicit links between cards, a selection, and what each linked card does when a row is picked (goal 41 M6).
#
# The rule (owner, 2026-10-30): cards from the same table are linked implicitly; across tables or modalities nothing
# connects until a Link exists, made by a person or an agent. An app may suggest one; it never joins on its own.
#
#   var links = Links(msg_base=7600)
#   links.add(Link.key(End("orders", "order_id"), End("clip.mp4", "code", "clip.mp4 · detections"), BY_PERSON))
#   links.add(Link.time(End("sensor_log", "t"), End("clip.mp4", "t"), offset=1.2))       # b.t = a.t · scale + offset
#   var m = match_count(order_ids, codes)                                              # m.matched of m.total ("12 of 14")
#   var q = links.join_sql(0, "orders.order_id, detections.frame")                  # SELECT … JOIN … ON a.col = b.col
#   var follows = links.follow(Selection("orders", "orders", 11, "order_id", "S-5012"))  # per linked card: what to match
#   var r = rows.react(follows[k])                                                        # a card's hook → SEEK / HIGHLIGHT / SELECT
#   view(): links.view()   update(): if links.update(event): …   (agent tools: links, link, unlink; docs in Links.view)
#
# No omxcore here (tests run it without the engine linked); the SQL text is run by the caller (tablecard.query_table).
# PLACE links are minimal: an affine map per axis from a picture's pixels to coordinates (geo.NadirCamera does the
# pose-aware version for a moving camera; a place link is for a still picture or a fixed camera).

from std.collections import Dict
from mojoui.app import Event
from mojoui.sqlname import sql_name, quote_ident, column_ref
from mojoui.view import View, Text, Button, TextField, Dropdown, VStack, HStack, Spacer, CAPTION, SUBTLE, ICON_ONLY, CENTER, START, TONE_STRONG

comptime LINK_KEY = 1  # a.col = b.col (rows with the same value)
comptime LINK_TIME = 2  # a.t ↔ b.t: b = a · scale + offset (seconds)
comptime LINK_PLACE = 3  # a picture's (x, y) pixels ↔ b's (lon, lat): per axis b = a · scale + offset

comptime NO_CHANGE = 0  # (a field whose typing the panel doesn't follow: its Return sets it)
comptime BY_PERSON = 0
comptime BY_AGENT = 1

comptime REACT_NONE = 0
comptime REACT_SELECT = 1  # a table: select these rows
comptime REACT_SEEK = 2  # a video: go to this time (and frame)
comptime REACT_HIGHLIGHT = 3  # a page or picture: draw this box

comptime LINKS_OPEN = 0  # (a Links block of messages: the "links" button, the "link" field's change and Return, "unlink")
comptime LINKS_DRAFT = 1
comptime LINKS_ADD = 2
comptime LINKS_REMOVE = 3
comptime LINKS_MAX = 8  # links the panel's rows address one by one (more still work, listed without their controls)
comptime LINKS_UNLINK = 4  # + i: the panel's row i's Unlink
comptime LINKS_OFFSET = LINKS_UNLINK + LINKS_MAX  # + i: row i's offset field's Return (event.text = seconds)
comptime LINKS_LESS = LINKS_OFFSET + LINKS_MAX  # + i: row i's offset nudged down (LINKS_NUDGE seconds)
comptime LINKS_MORE = LINKS_LESS + LINKS_MAX
comptime LINKS_MESSAGES = LINKS_MORE + LINKS_MAX
comptime LINKS_NUDGE = 0.1


@fieldwise_init
struct End(Copyable, Movable, ImplicitlyCopyable):
    """One end of a link: the card a person sees ("clip.mp4"), the table holding the column (a video's analysis rows:
    "clip.mp4 · detections"; "" = the card's own), and the column."""

    var card: String
    var column: String
    var table: String

    def __init__(out self, card: String, column: String):
        self.card = card
        self.column = column
        self.table = String("")

    def table_name(self) -> String:
        return self.table if self.table != "" else self.card

    def sql(self) -> String:
        """The table's SQL name (mojoui.sqlname, as table cards register it)."""
        return sql_name(self.table_name())

    def label(self) -> String:
        return self.card + "." + self.column


@fieldwise_init
struct Link(Copyable, Movable, ImplicitlyCopyable):
    var kind: Int
    var a: End
    var b: End
    var by: Int  # BY_PERSON or BY_AGENT (who made it; an app's suggestion becomes a Link only when one of them confirms it)
    var scale: Float64  # TIME: b = a · scale + offset; PLACE: x → lon
    var offset: Float64
    var scale_y: Float64  # PLACE: y → lat
    var offset_y: Float64

    @staticmethod
    def key(a: End, b: End, by: Int = BY_PERSON) -> Link:
        return Link(LINK_KEY, a, b, by, 1.0, 0.0, 1.0, 0.0)

    @staticmethod
    def time(a: End, b: End, offset: Float64, scale: Float64 = 1.0, by: Int = BY_PERSON) -> Link:
        return Link(LINK_TIME, a, b, by, scale, offset, 1.0, 0.0)

    @staticmethod
    def place(a: End, b: End, scale_x: Float64, offset_x: Float64, scale_y: Float64, offset_y: Float64, by: Int = BY_PERSON) -> Link:
        """a: the picture (column = its x column; y beside it), b: the map (column = lon; lat beside it)."""
        return Link(LINK_PLACE, a, b, by, scale_x, offset_x, scale_y, offset_y)

    def kind_name(self) -> String:
        return "time" if self.kind == LINK_TIME else ("place" if self.kind == LINK_PLACE else "key")

    def label(self) -> String:
        """How the Links panel and an agent read it: "orders.order_id = clip.mp4.code",
        "sensor_log.t ~ clip.mp4.t +1.2 s", "photo.x ~ site.lon (place)"."""
        if self.kind == LINK_TIME:
            var s = self.a.label() + " ~ " + self.b.label() + " " + ("+" if self.offset >= 0 else "") + _num(self.offset) + " s"
            if self.scale != 1.0:
                s += " ×" + _num(self.scale)
            return s
        if self.kind == LINK_PLACE:
            return self.a.label() + " ~ " + self.b.label() + " (place)"
        return self.a.label() + " = " + self.b.label()

    def touches(self, card: String) -> Bool:
        return self.a.card == card or self.b.card == card or self.a.table_name() == card or self.b.table_name() == card

    def same(self, other: Link) -> Bool:
        """The same link either way round (a = b is b = a)."""
        if self.kind != other.kind:
            return False
        var fwd = self.a.label() == other.a.label() and self.b.label() == other.b.label()
        var back = self.a.label() == other.b.label() and self.b.label() == other.a.label()
        return fwd or (back and self.kind == LINK_KEY)

    # time, both ways
    def to_b(self, t: Float64) -> Float64:
        return t * self.scale + self.offset

    def to_a(self, t: Float64) -> Float64:
        return (t - self.offset) / self.scale if self.scale != 0 else t - self.offset

    # place, both ways (pixels → coordinates and back)
    def place_to_b(self, x: Float64, y: Float64) -> Tuple[Float64, Float64]:
        return (x * self.scale + self.offset, y * self.scale_y + self.offset_y)

    def place_to_a(self, lon: Float64, lat: Float64) -> Tuple[Float64, Float64]:
        return ((lon - self.offset) / self.scale, (lat - self.offset_y) / self.scale_y)


def _num(v: Float64) -> String:
    """A short number: 1.2, -3, 0.25 (three places at most)."""
    var r = Float64(Int(abs(v) * 1000.0 + 0.5)) / 1000.0
    var whole = Int(r)
    var s = String(whole)
    var frac = Int((r - Float64(whole)) * 1000.0 + 0.5)
    if frac > 0:
        var f = String(frac)
        while f.byte_length() < 3:
            f = "0" + f
        while f.endswith("0"):
            var cut = String(f[byte = 0 : f.byte_length() - 1])
            f = cut
        s += "." + f
    return ("-" + s) if v < 0 and (whole > 0 or frac > 0) else s


@fieldwise_init
struct MatchCount(Copyable, Movable, ImplicitlyCopyable):
    var matched: Int  # a's distinct values found in b
    var total: Int  # a's distinct values (empty cells left out)

    def text(self) -> String:
        return String(self.matched) + " of " + String(self.total)


def match_count(a_values: List[String], b_values: List[String]) -> MatchCount:
    """How many of a's distinct values appear in b: what a person sees before confirming a key link ("12 of 14")."""
    var have = Dict[String, Bool]()
    for v in b_values:
        if v != "":
            have[v] = True
    var seen = Dict[String, Bool]()
    var matched = 0
    for v in a_values:
        if v == "" or v in seen:
            continue
        seen[v] = True
        if v in have:
            matched += 1
    return MatchCount(matched, len(seen))


@fieldwise_init
struct Selection(Copyable, Movable):
    """What a person (or an agent) picked: a row of a card's table, its key value in the column picked, and a time when
    the source has one (-1: none)."""

    var card: String
    var table: String
    var row: Int
    var column: String
    var value: String
    var time: Float64
    var names: List[String]  # the whole row, when the picker knows it (a table card's row): its columns' names …
    var cells: List[String]  # … and their values as text (a key link on another column of the row follows too)

    def __init__(out self, card: String, table: String, row: Int, column: String, value: String):
        self.card = card
        self.table = table
        self.row = row
        self.column = column
        self.value = value
        self.time = -1.0
        self.names = List[String]()
        self.cells = List[String]()

    def with_row(var self, names: List[String], cells: List[String]) -> Selection:
        """The selection carrying its whole row: a key link on any of the row's columns follows (D-1261)."""
        self.names = names.copy()
        self.cells = cells.copy()
        return self^

    def value_of(self, column: String) -> String:
        """The selection's value in `column`: its own value for its column (or when it names none), else the row's cell
        ("" when the row isn't known or has no such column)."""
        if column == self.column or self.column == "":
            if self.value != "" or len(self.names) == 0:
                return self.value
        for i in range(min(len(self.names), len(self.cells))):
            if self.names[i] == column:
                return self.cells[i]
        return String("")


@fieldwise_init
struct Follow(Copyable, Movable, ImplicitlyCopyable):
    """What one linked card should match: rows whose `column` holds `value` (a key link), the row at `row` (the same
    table: implicit), or the time `time` in its own clock (a time link). `via` names the link ("" for the same table)."""

    var card: String
    var table: String
    var kind: Int  # LINK_KEY, LINK_TIME, or 0 (the same table)
    var column: String
    var value: String
    var row: Int
    var time: Float64
    var via: String


@fieldwise_init
struct Reaction(Copyable, Movable):
    """What a card does: its hook's answer (REACT_SELECT rows, REACT_SEEK to t / frame, REACT_HIGHLIGHT a box on a page)."""

    var card: String
    var action: Int
    var rows: List[Int]
    var time: Float64
    var frame: Int
    var page: Int
    var x: Float64
    var y: Float64
    var w: Float64
    var h: Float64

    @staticmethod
    def none(card: String) -> Reaction:
        return Reaction(card, REACT_NONE, List[Int](), -1.0, -1, -1, 0, 0, 0, 0)

    def line(self) -> String:
        """A log line: "FOLLOW: clip.mp4 seek t=22.4 frame=560", "FOLLOW: INV-5012 highlight p1 120,340 80x14"."""
        var s = "FOLLOW: " + self.card + " "
        if self.action == REACT_SEEK:
            return s + "seek t=" + _num(self.time) + " frame=" + String(self.frame)
        if self.action == REACT_HIGHLIGHT:
            return s + "highlight p" + String(self.page) + " " + _num(self.x) + "," + _num(self.y) + " " + _num(self.w) + "x" + _num(self.h)
        if self.action == REACT_SELECT:
            return s + "select " + String(len(self.rows)) + " rows"
        return s + "nothing"


struct CardRows(Copyable, Movable):
    """A card's rows as its react hook reads them: any card that has a table (a table card's sheet, a video's analysis
    rows, a document's OCR words) hands its columns as text and names its roles, and `react` turns a Follow into what
    it should do. Roles: a time column (and a frame column) make a video seek; page + box columns make a page highlight;
    neither: the rows are selected."""

    var card: String
    var table: String
    var columns: List[String]
    var cells: List[String]  # row-major
    var time_column: String
    var frame_column: String
    var box_columns: List[String]  # page, x, y, w, h ("" none)

    def __init__(out self, card: String, table: String, columns: List[String]):
        self.card = card
        self.table = table
        self.columns = columns.copy()
        self.cells = List[String]()
        self.time_column = String("")
        self.frame_column = String("")
        self.box_columns = List[String]()

    def seeks(mut self, time_column: String, frame_column: String = ""):
        self.time_column = time_column
        self.frame_column = frame_column

    def highlights(mut self, page: String, x: String, y: String, w: String, h: String):
        self.box_columns = [page, x, y, w, h]

    def add_row(mut self, values: List[String]):
        for c in range(len(self.columns)):
            self.cells.append(values[c] if c < len(values) else String(""))

    def rows(self) -> Int:
        return len(self.cells) // max(len(self.columns), 1)

    def index(self, name: String) -> Int:
        for c in range(len(self.columns)):
            if self.columns[c] == name:
                return c
        return -1

    def cell(self, row: Int, c: Int) -> String:
        return self.cells[row * len(self.columns) + c]

    def column(self, name: String) -> List[String]:
        var out = List[String]()
        var c = self.index(name)
        if c >= 0:
            for r in range(self.rows()):
                out.append(self.cell(r, c))
        return out^

    def _number(self, row: Int, name: String) -> Float64:
        var c = self.index(name)
        if c < 0:
            return 0.0
        try:
            return atof(self.cell(row, c))
        except:
            return 0.0

    def matching(self, f: Follow) -> List[Int]:
        """The rows a Follow names: the same row (implicit), rows holding the key, or the row nearest the time."""
        var out = List[Int]()
        if f.kind == 0:
            if 0 <= f.row < self.rows():
                out.append(f.row)
            return out^
        if f.kind == LINK_KEY:
            var c = self.index(f.column)
            if c >= 0:
                for r in range(self.rows()):
                    if self.cell(r, c) == f.value:
                        out.append(r)
            return out^
        if f.kind == LINK_TIME and self.index(f.column) >= 0 and self.rows() > 0:
            var best = 0
            var gap = abs(self._number(0, f.column) - f.time)
            for r in range(1, self.rows()):
                var d = abs(self._number(r, f.column) - f.time)
                if d < gap:
                    gap = d
                    best = r
            out.append(best)
        return out^

    def react(self, f: Follow) -> Reaction:
        """The hook: what this card does for a Follow."""
        var rows = self.matching(f)
        if len(rows) == 0 and not (f.kind == LINK_TIME and self.time_column != ""):
            return Reaction.none(self.card)
        if self.time_column != "" and self.index(self.time_column) >= 0:  # a video: the earliest matching row's time
            var t = f.time if f.kind == LINK_TIME else 1e300
            var frame = -1
            if f.kind != LINK_TIME:
                for r in rows:
                    var rt = self._number(r, self.time_column)
                    if rt < t:
                        t = rt
                        frame = Int(self._number(r, self.frame_column)) if self.frame_column != "" else -1
            return Reaction(self.card, REACT_SEEK, rows^, t, frame, -1, 0, 0, 0, 0)
        if len(self.box_columns) == 5 and self.index(self.box_columns[1]) >= 0:  # a page: the first matching row's box
            var r = rows[0]
            var b = self.box_columns.copy()
            return Reaction(self.card, REACT_HIGHLIGHT, rows^, -1.0, -1, Int(self._number(r, b[0])), self._number(r, b[1]),
                            self._number(r, b[2]), self._number(r, b[3]), self._number(r, b[4]))
        return Reaction(self.card, REACT_SELECT, rows^, -1.0, -1, -1, 0, 0, 0, 0)


def parse_link(text: String, by: Int = BY_AGENT) raises -> Link:
    """A link from how it reads: "orders.order_id = clip.mp4.code" (key), "sensor_log.t ~ clip.mp4.t +1.2"
    (time: offset in seconds, optional "×scale"). A card's name may hold dots; the column is after the last one."""
    var t = String(text.strip())
    if t.find(" = ") >= 0:
        var parts = t.split(" = ")
        return Link.key(_end(String(parts[0])), _end(String(parts[1])), by)
    if t.find(" ~ ") >= 0:
        var parts = t.split(" ~ ")
        var rest = String(parts[1].strip()).split(" ")
        var offset = 0.0
        var scale = 1.0
        for k in range(1, len(rest)):
            var w = String(rest[k])
            if w.startswith("×") or w.startswith("x"):
                scale = atof(String(w[byte = 2 if w.startswith("×") else 1 :]))
            elif w != "s" and w != "":
                offset = atof(String(w[byte = 1:]) if w.startswith("+") else w)
        return Link.time(_end(String(parts[0])), _end(String(rest[0])), offset, scale, by)
    raise Error('a link reads "card.column = card.column" (key) or "card.column ~ card.column +seconds" (time), not "' + t + '"')


def _end(text: String) raises -> End:
    var s = String(text.strip())
    var dot = s.rfind(".")
    if dot <= 0 or dot == s.byte_length() - 1:
        raise Error('"' + s + '" isn\'t card.column')
    return End(String(s[byte = 0:dot]), String(s[byte = dot + 1 :]))


struct Links(Movable, Sized):
    """A sheet's links. Each is made by a person or an agent; this never adds one by itself."""

    var items: List[Link]
    var msg_base: Int
    var draft: String  # the "link" field's text
    var open: Bool  # the list shown (the "links" button)
    var problem: String  # why the last add failed ("" none)
    var changed: Int  # bumps on every add / remove
    var notes: List[String]  # per link, what the panel says under it ("orders ↔ clip.mp4 · 12 of 14 match"; "": its cards)
    var derived: List[Link]  # where a query's answer came from (answer.order = orders.order_id): provenance, not a
    # guess, so a row of the answer follows like a row of its source; never listed, never joined (D-1262)
    var schemas: Dict[String, List[String]]  # per table (its SQL name), the columns it has (`know`): a key link's column
    # must be one of them (D-1341); a table not known yet is checked when it becomes known (`know`, `resolve`)

    def __init__(out self, msg_base: Int = 0):
        self.schemas = Dict[String, List[String]]()
        self.notes = List[String]()
        self.derived = List[Link]()
        self.items = List[Link]()
        self.msg_base = msg_base
        self.draft = String("")
        self.open = False
        self.problem = String("")
        self.changed = 0

    def __len__(self) -> Int:
        return len(self.items)

    def know(mut self, table: String, columns: List[String]) -> Int:
        """The app tells which columns a table has (a table card's name and its columns): key links are checked against
        them from now on, and a link already made on it whose column isn't there is unlinked (`problem` says why). How
        many links that removed."""
        self.schemas[sql_name(table)] = columns.copy()
        return self._drop_invalid()

    def check(self, link: Link) raises:
        """Raises when a key link's end names a column its table doesn't have (as far as `know` was told), or a column
        no table could have (empty, or a control character in it). Time and place links only paint; they write no SQL."""
        if link.kind != LINK_KEY:
            return
        for e in [link.a, link.b]:
            if e.column == "":
                raise Error(e.card + " has no column named")
            for b in e.column.as_bytes():
                if b < UInt8(32) or b == UInt8(127):
                    raise Error('"' + e.column + '" isn\'t a column name')
            var got = self.schemas.get(e.sql())
            if got:
                var cols = got.value().copy()
                if not (e.column in cols):
                    raise Error('"' + e.column + '" isn\'t a column of ' + e.table_name() + " (its columns: " + ", ".join(cols) + ")")

    def _drop_invalid(mut self) -> Int:
        """Unlinks every key link `check` now refuses (its table became known, or its end was resolved to another table)."""
        var n = 0
        var i = len(self.items) - 1
        while i >= 0:
            try:
                self.check(self.items[i])
            except e:
                self.problem = "Unlinked " + self.items[i].label() + ": " + String(e)
                _ = self.remove(i)
                n += 1
            i -= 1
        return n

    def add(mut self, link: Link) raises -> Int:
        """Adds it (its index); raises for a link that's already there, a key link inside one table (that's implicit), or
        one whose column its table doesn't have (`check`)."""
        self.check(link)
        for i in range(len(self.items)):
            if self.items[i].same(link):
                raise Error(link.label() + " is already linked")
        if link.kind == LINK_KEY and link.a.table_name() == link.b.table_name():
            raise Error("cards from the same table are already linked")
        self.items.append(link)
        self.notes.append(String(""))
        self.changed += 1
        return len(self.items) - 1

    def derive(mut self, link: Link):
        """Records that `link.a` (an answer's column) holds values read from `link.b` (its source's column): a selection
        on the answer follows through it. Replaces what was known about that answer column."""
        var kept = List[Link]()
        for l in self.derived:
            if l.a.label() != link.a.label():
                kept.append(l)
        kept.append(link)
        self.derived = kept^

    def forget_derived(mut self, card: String):
        """The answer card `card` is gone (or answered again): what it derived from is forgotten."""
        var kept = List[Link]()
        for l in self.derived:
            if l.a.card != card:
                kept.append(l)
        self.derived = kept^

    def resolve(mut self, card: String, table: String) -> Int:
        """A card's columns live in another table (a video's analysis rows: "clip.mp4" → "clip.mp4 · detections"): every
        end naming the card and no table gets it, so a typed link on a video joins its rows. How many ends changed. A key
        link whose column the new table doesn't have (when it's known) is unlinked, `problem` saying why."""
        var n = 0
        for i in range(len(self.items)):
            if self.items[i].a.card == card and self.items[i].a.table == "" and table != card:
                self.items[i].a.table = table
                n += 1
            if self.items[i].b.card == card and self.items[i].b.table == "" and table != card:
                self.items[i].b.table = table
                n += 1
        if n > 0:
            self.changed += 1
            _ = self._drop_invalid()
        return n

    def remove(mut self, i: Int) -> Bool:
        if i < 0 or i >= len(self.items):
            return False
        _ = self.items.pop(i)
        if i < len(self.notes):
            _ = self.notes.pop(i)
        self.changed += 1
        return True

    def remove_label(mut self, label: String) -> Bool:
        for i in range(len(self.items)):
            if self.items[i].label() == label:
                return self.remove(i)
        return False

    def list(self) -> List[String]:
        var out = List[String]()
        for l in self.items:
            out.append(l.label())
        return out^

    def for_card(self, card: String) -> List[Int]:
        var out = List[Int]()
        for i in range(len(self.items)):
            if self.items[i].touches(card):
                out.append(i)
        return out^

    def join_sql(self, i: Int, select: String = "*") raises -> String:
        """The query a key link implies, over the tables' SQL names, every name quoted (a header may hold spaces or anything
        else): SELECT <select> FROM "a" JOIN "b" ON "a"."col" = "b"."col"."""
        if i < 0 or i >= len(self.items) or self.items[i].kind != LINK_KEY:
            raise Error("link " + String(i) + " is no key link")
        var l = self.items[i]
        self.check(l)
        var a = l.a.sql()
        var b = l.b.sql()
        return ("SELECT " + select + " FROM " + quote_ident(a) + " JOIN " + quote_ident(b) + " ON " + column_ref(a, l.a.column)
                + " = " + column_ref(b, l.b.column))

    def follow(self, sel: Selection, same_table: List[String] = []) -> List[Follow]:
        """Per linked card, what it should match for this selection: through each key link touching the selection's card
        (the selection's value in that link's column: its own column's, or the row's cell when it carries its row), each
        time link (its time in the other clock), and the cards in `same_table` (other cards showing the selection's table:
        the same row, implicitly). Key links chain: a value reached through one is followed on through the next link on the
        same column (equal to equal is equal), never back to a card already reached (D-1261). A query's answer follows
        through what it was derived from (`derive`: its source's rows are selected), then on as its source would."""
        var out = List[Follow]()
        for c in same_table:
            if c != sel.card:
                out.append(Follow(c, sel.table, 0, sel.column, sel.value, sel.row, -1.0, ""))
        var seen = List[String]()  # cards (and tables) reached
        seen.append(sel.card)
        seen.append(sel.table)
        # the frontier: (card, table, column it holds the value in ("" = any of the row's), value) to follow on from
        var q_card = List[String]()
        var q_table = List[String]()
        var q_col = List[String]()
        var q_val = List[String]()
        var head = 0
        var all = self.items.copy()
        for l in self.derived:
            all.append(l)
        var first = True
        while first or head < len(q_card):
            var card = sel.card
            var table = sel.table
            var column = sel.column
            var value = sel.value
            if not first:
                card = q_card[head]
                table = q_table[head]
                column = q_col[head]
                value = q_val[head]
                head += 1
            for l in all:
                var mine_a = l.a.card == card or l.a.table_name() == table
                var mine_b = l.b.card == card or l.b.table_name() == table
                if not (mine_a or mine_b):
                    continue
                var there = l.b if mine_a else l.a
                if there.card in seen or there.table_name() in seen:
                    continue
                if l.kind == LINK_KEY:
                    var here = l.a if mine_a else l.b
                    var v = String("")
                    if first:
                        v = sel.value_of(here.column)
                    elif here.column == column:
                        v = value
                    if v == "":
                        continue  # (a key link is about one column; another column's value means nothing there)
                    out.append(Follow(there.card, there.table_name(), LINK_KEY, there.column, v, -1, -1.0, l.label()))
                    seen.append(there.card)
                    seen.append(there.table_name())
                    q_card.append(there.card)
                    q_table.append(there.table_name())
                    q_col.append(there.column)
                    q_val.append(v)
                elif l.kind == LINK_TIME and first and sel.time >= 0:
                    var t = l.to_b(sel.time) if mine_a else l.to_a(sel.time)
                    out.append(Follow(there.card, there.table_name(), LINK_TIME, there.column, "", -1, t, l.label()))
            first = False
        return out^

    # ---------- a person's and an agent's way in ----------

    def view(self) -> View:
        """The links as controls, which an agent sees as three tools: `links` (shows the list; its description lists
        them), `link` (type "a.col = b.col" or "a.t ~ b.t +seconds", Return adds it) and `unlink` (pick one to remove)."""
        var b = self.msg_base
        var summary = String("No links yet") if len(self.items) == 0 else "; ".join(self.list())
        var head = Button("Links · " + String(len(self.items)), b + LINKS_OPEN, SUBTLE, icon="share").tag("links").tooltip(
            "Show the links on this sheet (" + summary + ")")
        var items = List[View]()
        items.append(head^)
        if self.open:
            for l in self.items:
                items.append(Text(l.label() + " · " + l.kind_name() + (" · by an agent" if l.by == BY_AGENT else ""), CAPTION))
        items.append(TextField(self.draft, "orders.order_id = clip.mp4.code", b + LINKS_DRAFT, b + LINKS_ADD).fill().tag("link").tooltip(
            'Link two cards: "card.column = card.column" (rows with the same value) or "card.column ~ card.column +seconds" '
            + "(two clocks); press Return (submit) to add it. Nothing links until you do."))
        if self.problem != "":
            items.append(Text(self.problem, CAPTION))
        if len(self.items) > 0:
            var opts: List[String] = ["Unlink…"]
            for l in self.items:
                opts.append(l.label())
            items.append(Dropdown(opts^, 0, b + LINKS_REMOVE).fill().tag("unlink").tooltip("Remove a link"))
        return VStack(items^, spacing=6).tag("links-panel")

    def panel(self) -> List[View]:
        """The inspector's Links panel (the approved prototype "C"): one quiet row per link (its columns, its kind, its
        cards and match, Unlink; a time link's offset as a settable field with − and +), the empty state's hint, and the
        `link` field an agent (or a person) types a link into. Hand it to Inspector as its sections."""
        var b = self.msg_base
        var rows = List[View]()
        if len(self.items) == 0:
            rows.append(Text("No links yet. Drag a column's header onto another card to link them: nothing joins until you do.", CAPTION))
        for i in range(len(self.items)):
            ref l = self.items[i]
            var said = l.a.column + (" = " if l.kind == LINK_KEY else " ≈ ") + l.b.column
            var note = self.notes[i] if i < len(self.notes) and self.notes[i] != "" else l.a.card + " ↔ " + l.b.card
            var parts = List[View]()
            parts.append(HStack(Text(said).tone(TONE_STRONG), Text(l.kind_name(), CAPTION).tag("link-kind"), Spacer(),
                                Button("Unlink", b + LINKS_UNLINK + i, SUBTLE).tag("unlink-" + String(i)).tooltip("Remove the link " + l.label())
                                if i < LINKS_MAX else Spacer(), spacing=6).fill().align(CENTER))
            parts.append(Text(note + (" · by an agent" if l.by == BY_AGENT else ""), CAPTION))
            if l.kind == LINK_TIME and i < LINKS_MAX:
                parts.append(HStack(Text("Offset", CAPTION), Button("−", b + LINKS_LESS + i, SUBTLE).tooltip("0.1 s earlier"),
                                    TextField(_num(l.offset), "seconds", NO_CHANGE, b + LINKS_OFFSET + i).width(72).tag("offset-" + String(i))
                                    .label("Offset of " + l.b.card + "'s clock, in seconds"),
                                    Button("+", b + LINKS_MORE + i, SUBTLE).tooltip("0.1 s later"), Text("s", CAPTION), spacing=4).align(CENTER))
            rows.append(VStack(parts^, spacing=4).fill().align(START).tag("link-row"))
        var add = List[View]()
        add.append(Text("Drag a column onto a card to add one; hold a card to see what it's linked to. Or type one:", CAPTION))
        add.append(TextField(self.draft, "orders.order_id = clip.mp4.code", b + LINKS_DRAFT, b + LINKS_ADD).fill().tag("link").tooltip(
            'Link two cards: "card.column = card.column" (rows with the same value) or "card.column ~ card.column +seconds" '
            + "(two clocks); press Return (submit) to add it. Nothing links until you do."))
        if self.problem != "":
            add.append(Text(self.problem, CAPTION))
        var out = List[View]()
        rows.insert(0, Text("On this sheet", CAPTION).tone(TONE_STRONG))  # (a plain heading: Liquid's section-title role wrapped a long one)
        add.insert(0, Text("Add a link", CAPTION).tone(TONE_STRONG))
        out.append(VStack(rows^, spacing=8).fill().align(START))
        out.append(VStack(add^, spacing=8).fill().align(START))
        return out^

    def owns(self, message: Int) -> Bool:
        return self.msg_base <= message < self.msg_base + LINKS_MESSAGES

    def update(mut self, event: Event) -> Bool:
        """True when the event was the panel's (a link may have been added or removed: watch `changed`)."""
        if not self.owns(event.message):
            return False
        var m = event.message - self.msg_base
        if m == LINKS_OPEN:
            self.open = not self.open
        elif m == LINKS_DRAFT:
            self.draft = event.text
        elif m == LINKS_ADD:
            var text = event.text if event.text != "" else self.draft
            try:
                _ = self.add(parse_link(text, BY_PERSON))  # (a host can't tell a person's typing from an agent's)
                self.draft = String("")
                self.problem = String("")
            except e:
                self.problem = String(e)
        elif m == LINKS_REMOVE:
            if event.number >= 1:
                _ = self.remove(event.number - 1)
        elif LINKS_UNLINK <= m < LINKS_OFFSET:
            _ = self.remove(m - LINKS_UNLINK)
        elif LINKS_OFFSET <= m < LINKS_MORE + LINKS_MAX:
            var i = (m - LINKS_UNLINK) % LINKS_MAX
            if i < len(self.items) and self.items[i].kind == LINK_TIME:
                if m < LINKS_LESS:
                    try:
                        self.items[i].offset = atof(String(event.text.strip()))
                        self.problem = String("")
                    except:
                        self.problem = '"' + event.text + '" isn\'t a number of seconds'
                else:
                    self.items[i].offset += -LINKS_NUDGE if m < LINKS_MORE else LINKS_NUDGE
                    self.items[i].offset = Float64(Int(self.items[i].offset * 1000.0 + (0.5 if self.items[i].offset >= 0 else -0.5))) / 1000.0
                self.changed += 1
        return True
