# mojoui.asksql: asking a sheet's linked tables (goal 41 M10). Three small pieces between a question and the engine, none
# of them knowing any app, any table or any question:
#
#   var sql = book.sql_for("damaged pallets whose BOL says no exceptions")    # a question → the SQL an agent (or a person)
#                                                                             #   taught for it (AskBook: data, no model)
#   var q = implied_sql("SELECT … FROM shipments JOIN LINKED WHERE detections.damaged …", links)
#        # → "SELECT … FROM shipments JOIN detections ON shipments.shipment_id = detections.code WHERE …": the joins the
#        #   sheet's key links imply, along the shortest chain of links from the FROM table to every table the query names
#   for l in lineage(q): links.derive(...)   # the answer's columns read straight from a table's column (shipments.shipment_id
#                                            #   AS shipment): a row of the answer follows like a row of its source
#
# The rule (owner, 2026-10-30): nothing joins until a link exists. JOIN LINKED never guesses: a table no key link reaches
# is an error that says so. No omxcore here (the SQL text goes to the caller's engine), so it tests with a plain `mojo run`.

from mojoui.links import Links, Link, End, LINK_KEY


def _norm(text: String) -> String:
    """A question as the book keys it: lower case, every run of other characters one space, trimmed."""
    var out = String()
    var gap = False
    for b in text.lower().as_bytes():
        var ok = (b >= UInt8(97) and b <= UInt8(122)) or (b >= UInt8(48) and b <= UInt8(57))
        if ok:
            if gap and out.byte_length() > 0:
                out += " "
            out += chr(Int(b))
            gap = False
        else:
            gap = True
    return out^


struct AskBook(Movable, Sized):
    """Questions in words and the SQL each one means, taught by an agent or a person (the query box's "Ask in words"
    beside its SQL): the next time the question is asked, its SQL runs. A model can fill it later; the book stays."""

    var questions: List[String]
    var sqls: List[String]

    def __init__(out self):
        self.questions = List[String]()
        self.sqls = List[String]()

    def __len__(self) -> Int:
        return len(self.questions)

    def teach(mut self, question: String, sql: String):
        var k = _norm(question)
        if k == "" or String(sql.strip()) == "":
            return
        for i in range(len(self.questions)):
            if self.questions[i] == k:
                self.sqls[i] = sql
                return
        self.questions.append(k)
        self.sqls.append(sql)

    def sql_for(self, question: String) -> String:
        """The SQL taught for this question (case and punctuation ignored), else ""."""
        var k = _norm(question)
        for i in range(len(self.questions)):
            if self.questions[i] == k:
                return self.sqls[i]
        return String("")


def _is_word(b: UInt8) -> Bool:
    return (b >= UInt8(97) and b <= UInt8(122)) or (b >= UInt8(65) and b <= UInt8(90)) or (b >= UInt8(48) and b <= UInt8(57)) or b == UInt8(95)


def _find_word(text: String, word: String, start: Int = 0) -> Int:
    """Where `word` (case ignored) stands alone in `text` from `start` (outside quotes), else -1."""
    var low = text.lower()
    var w = word.lower()
    var bytes = low.as_bytes()
    var n = low.byte_length()
    var m = w.byte_length()
    var quoted = False
    var i = 0
    while i + m <= n:
        if bytes[i] == UInt8(39):
            quoted = not quoted
        if not quoted and i >= start and String(low[byte = i : i + m]) == w:
            var before = i == 0 or not _is_word(bytes[i - 1])
            var after = i + m == n or not _is_word(bytes[i + m])
            if before and after:
                return i
        i += 1
    return -1


def _referenced(text: String) -> List[String]:
    """Every `name.` prefix in the text (outside quotes), lower case, once each: the tables its columns name."""
    var out = List[String]()
    var bytes = text.as_bytes()
    var n = text.byte_length()
    var quoted = False
    var i = 0
    while i < n:
        var b = bytes[i]
        if b == UInt8(39):
            quoted = not quoted
            i += 1
            continue
        if not quoted and _is_word(b) and (i == 0 or not _is_word(bytes[i - 1])):
            var j = i
            while j < n and _is_word(bytes[j]):
                j += 1
            if j < n and bytes[j] == UInt8(46):
                var name = String(text[byte = i:j]).lower()
                if not (name in out):
                    out.append(name)
            i = j
            continue
        i += 1
    return out^


def implied_sql(text: String, links: Links) raises -> String:
    """`text` with its `JOIN LINKED` written out: from the table after FROM, the key links' joins along the shortest chain
    to every table whose columns the query names (table.column). No JOIN LINKED: `text` as it is. Raises when a named
    table no chain of key links reaches."""
    var at = _find_word(text, "LINKED")
    if at < 0:
        return text
    var join = String(String(text[byte = 0:at]).rstrip())
    if not join.lower().endswith("join"):
        raise Error('write "FROM <table> JOIN LINKED": the links decide the joins')
    var head = String(String(join[byte = 0 : join.byte_length() - 4]).rstrip())
    var f = _find_word(head, "FROM")
    if f < 0:
        raise Error('JOIN LINKED needs "FROM <table>" before it')
    var root = String(String(head[byte = f + 4 :]).strip()).lower()
    if root.find(" ") >= 0:
        raise Error("JOIN LINKED joins from one table: FROM " + root)
    var tail = String(text[byte = at + 6 :])
    # the key links as a graph over SQL names
    var a = List[String]()
    var b = List[String]()
    var ca = List[String]()
    var cb = List[String]()
    for l in links.items:
        if l.kind == LINK_KEY:
            a.append(l.a.sql())
            b.append(l.b.sql())
            ca.append(l.a.column)
            cb.append(l.b.column)
    var known = List[String]()
    for i in range(len(a)):
        if not (a[i] in known):
            known.append(a[i])
        if not (b[i] in known):
            known.append(b[i])
    var want = List[String]()
    for t in _referenced(head + " " + tail):
        if t != root:
            want.append(t)
    # breadth first from root: each table's parent edge
    var order = List[String]()
    var parent_edge = List[Int]()
    var parent_dir = List[Bool]()  # True: the edge runs a → b from its parent
    order.append(root)
    parent_edge.append(-1)
    parent_dir.append(True)
    var k = 0
    while k < len(order):
        var t = order[k]
        for i in range(len(a)):
            var nxt = String("")
            var fwd = True
            if a[i] == t:
                nxt = b[i]
            elif b[i] == t:
                nxt = a[i]
                fwd = False
            if nxt != "" and not (nxt in order):
                order.append(nxt)
                parent_edge.append(i)
                parent_dir.append(fwd)
        k += 1
    var needed = List[Bool]()
    for _ in range(len(order)):
        needed.append(False)
    for t in want:
        var idx = -1
        for i in range(len(order)):
            if order[i] == t:
                idx = i
        if idx < 0:
            if t in known:
                raise Error("no chain of links reaches " + t + " from " + root + ": link them first")
            continue  # (an alias or a table no link names: the engine judges it)
        while idx > 0 and not needed[idx]:
            needed[idx] = True
            var e = parent_edge[idx]
            var from_t = a[e] if parent_dir[idx] else b[e]
            for i in range(len(order)):
                if order[i] == from_t:
                    idx = i
    var joins = String("")
    for i in range(1, len(order)):
        if not needed[i]:
            continue
        var e = parent_edge[i]
        joins += " JOIN " + order[i] + " ON " + a[e] + "." + ca[e] + " = " + b[e] + "." + cb[e]
    return String(head[byte = 0:f]) + "FROM " + root + joins + tail


@fieldwise_init
struct Lineage(Copyable, Movable, ImplicitlyCopyable):
    """An answer's column read straight from a table's column: `column` (as the answer names it) ← table.source."""

    var column: String
    var table: String
    var source: String


def lineage(text: String) -> List[Lineage]:
    """The answer's columns that are a plain table.column (with or without AS name), from the query's first SELECT list."""
    var out = List[Lineage]()
    var s = _find_word(text, "SELECT")
    var f = _find_word(text, "FROM", max(s, 0))
    if s < 0 or f < 0:
        return out^
    var body = String(String(text[byte = s + 6 : f]).strip())
    var d = _find_word(body, "DISTINCT")
    if d == 0:
        body = String(String(body[byte = 8:]).strip())
    var depth = 0
    var start = 0
    var items = List[String]()
    var bytes = body.as_bytes()
    for i in range(body.byte_length()):
        var c = bytes[i]
        if c == UInt8(40):
            depth += 1
        elif c == UInt8(41):
            depth -= 1
        elif c == UInt8(44) and depth == 0:
            items.append(String(String(body[byte = start:i]).strip()))
            start = i + 1
    items.append(String(String(body[byte = start:]).strip()))
    for item in items:
        var words = item.split(" ")
        var parts = List[String]()
        for w in words:
            if String(w) != "":
                parts.append(String(w))
        if len(parts) == 0:
            continue
        var src = parts[0]
        var dot = src.find(".")
        if dot <= 0 or src.find("(") >= 0:
            continue
        var name = String(src[byte = dot + 1 :])
        if len(parts) == 3 and parts[1].lower() == "as":
            name = parts[2]
        elif len(parts) == 2:
            name = parts[1]
        elif len(parts) != 1:
            continue
        var ok = True
        for b in String(src[byte = dot + 1 :]).as_bytes():
            if not _is_word(b):
                ok = False
        if ok:
            out.append(Lineage(name, String(src[byte = 0:dot]).lower(), String(src[byte = dot + 1 :])))
    return out^
