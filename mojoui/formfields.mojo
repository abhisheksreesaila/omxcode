# mojoui.formfields: a form's fields from where its words sit (goal 41 M7). Generic: the caller says which labels to look
# for (data, never code: a bill of lading's "Order no." and "Exceptions", an invoice's "Total"), and each label's value
# is the words beside it (to its right on its line) or under it (the next line, aligned with it), whichever is nearer.
#
#   var labels = List[FieldLabel]()
#   labels.append(FieldLabel("order_no", "Order no."))
#   labels.append(FieldLabel("exceptions", "Exceptions"))
#   var found = find_fields(words, labels)        # words: a TextTable (OCR rows); List[Field]: name, value, page, box, found
#
# The rule (no per-form numbers; distances are in the label's own line height h, so it holds at any size or zoom):
#   label   the label's words in order on one line (case and a trailing colon ignored); of several places, the first in
#           reading order that starts its line (a label opens a line or a cell; the same word inside a sentence doesn't).
#   right   the nearest word on the label's line to its right, at most 12 h away, with no other label between.
#   below   the nearest word under it, top at most 4 h below the label, left edge within 2 h of the label's (or overlapping
#           it), with no other label between; scored by its gap plus half its sideways offset (in h).
#   choice  the word on its line, unless the word under it is more than 3 times nearer (gaps in h): a label with a word
#           beside it is an inline label; one heading a cell has its value under it (and, maybe, another cell's
#           words far along its line). Then grown into its phrase: the words on its line whose gaps are under 1.2 of its
#           height; never another label's words. Its box is their union, its confidence their lowest.

from mojoui.pdfsource import Box
from mojoui.texttable import TextTable

comptime RIGHT_REACH = 12.0  # label line heights
comptime BELOW_REACH = 4.0
comptime BELOW_ALIGN = 2.0
comptime PHRASE_GAP = 1.2  # word heights
comptime RIGHT_BIAS = 3.0


@fieldwise_init
struct FieldLabel(Copyable, Movable, ImplicitlyCopyable):
    """A field to find: its name (a column name, e.g. "order_no") and the label printed beside its value."""

    var name: String
    var label: String


@fieldwise_init
struct Field(Copyable, Movable, ImplicitlyCopyable):
    """A field found on a page: its value's text, its box (the table's unit: page points for documents) and the reader's
    lowest confidence over its words. found = False: no label, or nothing beside it (value "", box empty, page -1)."""

    var name: String
    var value: String
    var page: Int
    var box: Box
    var confidence: Float64
    var found: Bool
    var label_box: Box


def _norm(s: String) -> String:
    """Lower case, without trailing colons or full stops' neighbours that differ between readers (":" only)."""
    var t = s.lower()
    while t.byte_length() > 0 and t.endswith(":"):
        var cut = String(t[byte = 0 : t.byte_length() - 1])
        t = cut
    return t


def _same_line(a: Box, b: Box) -> Bool:
    return abs(a.cy() - b.cy()) <= 0.6 * max(a.h, b.h)


def _label_words(label: String) -> List[String]:
    var out = List[String]()
    for p in label.split(" "):
        var s = _norm(String(p))
        if s.byte_length() > 0:
            out.append(s)
    return out^


def _right_neighbour(t: TextTable, rows: List[Int], i: Int) -> Int:
    """The next word to the right of row i on its line, within 1.5 of its height (-1: none)."""
    var best = -1
    var gap = 1e18
    var a = t.box(i)
    for j in rows:
        if j == i:
            continue
        var b = t.box(j)
        if _same_line(a, b) and b.x >= a.x + a.w * 0.5:
            var g = b.x - a.right()
            if g < 1.5 * max(a.h, b.h) and g < gap:
                gap = g
                best = j
    return best


def _starts_line(t: TextTable, rows: List[Int], i: Int) -> Bool:
    var a = t.box(i)
    for j in rows:
        if j == i:
            continue
        var b = t.box(j)
        if _same_line(a, b) and b.x < a.x and a.x - b.right() < 1.0 * max(a.h, b.h):
            return False
    return True


def _find_label(t: TextTable, rows: List[Int], label: String) -> List[Int]:
    """The label's words (rows), at its best place on the page (empty: not there)."""
    var want = _label_words(label)
    var found = List[List[Int]]()
    if len(want) == 0:
        return List[Int]()
    for i in rows:
        if _norm(t.text[i]) != want[0]:
            continue
        var seq = List[Int]()
        seq.append(i)
        var cur = i
        var ok = True
        for k in range(1, len(want)):
            var nxt = _right_neighbour(t, rows, cur)
            if nxt < 0 or _norm(t.text[nxt]) != want[k]:
                ok = False
                break
            seq.append(nxt)
            cur = nxt
        if ok:
            found.append(seq^)
    if len(found) == 0:
        return List[Int]()
    var best = -1
    for pass_ in range(2):  # first: places that start their line; then any
        for k in range(len(found)):
            if pass_ == 0 and not _starts_line(t, rows, found[k][0]):
                continue
            if best < 0:
                best = k
            else:
                var a = t.box(found[k][0])
                var b = t.box(found[best][0])
                if a.y < b.y - 0.5 * a.h or (abs(a.y - b.y) <= 0.5 * a.h and a.x < b.x):
                    best = k
        if best >= 0:
            break
    return found[best].copy()


def _between(a: Box, b: Box, c: Box, horizontal: Bool) -> Bool:
    """Does box c sit between a and b (along x on a line, or along y under a)?"""
    if horizontal:
        return _same_line(a, c) and c.x >= a.right() - 0.5 and c.right() <= b.x + 0.5
    return c.y >= a.bottom() - 0.5 and c.bottom() <= b.y + 0.5 and c.right() > min(a.x, b.x) and c.x < max(a.right(), b.right())


def find_fields(t: TextTable, labels: List[FieldLabel], page: Int = -1) -> List[Field]:
    """Each label's value on `page` (-1: the first page where the label is found)."""
    var pages = List[Int]()
    if page >= 0:
        pages.append(page)
    else:
        for p in range(t.pages()):
            pages.append(p)
    var out = List[Field]()
    for li in range(len(labels)):
        out.append(Field(labels[li].name, "", -1, Box(0, 0, 0, 0), 0, False, Box(0, 0, 0, 0)))
    for p in pages:
        var rows = t.on_page(p)
        # every label's place on this page first: one label's words are never another's value
        var places = List[List[Int]]()
        var is_label = List[Bool](length=t.rows(), fill=False)
        for li in range(len(labels)):
            var seq = _find_label(t, rows, labels[li].label)
            for i in seq:
                is_label[i] = True
            places.append(seq^)
        var label_boxes = List[Box]()
        for li in range(len(labels)):
            if len(places[li]) > 0:
                var b = t.box(places[li][0])
                for i in places[li]:
                    b = b.union(t.box(i))
                label_boxes.append(b)
            else:
                label_boxes.append(Box(0, 0, 0, 0))
        for li in range(len(labels)):
            if out[li].found or len(places[li]) == 0:
                continue
            var L = label_boxes[li]
            var h = max(L.h, 1.0)
            var right = -1
            var right_s = 1e18
            var below = -1
            var below_s = 1e18
            for j in rows:
                if is_label[j]:
                    continue
                var b = t.box(j)
                if _same_line(L, b) and b.x >= L.right() - 1.0:
                    var gap = b.x - L.right()
                    if gap <= RIGHT_REACH * h and max(gap, 0.0) / h < right_s:
                        var blocked = False
                        for k in range(len(labels)):
                            if k != li and len(places[k]) > 0 and _between(L, b, label_boxes[k], True):
                                blocked = True
                        if not blocked:
                            right_s = max(gap, 0.0) / h
                            right = j
                elif b.y >= L.bottom() - 0.25 * h:
                    var dy = b.y - L.bottom()
                    var dx = abs(b.x - L.x)
                    var overlaps = b.x < L.right() and b.right() > L.x
                    var sc = max(dy, 0.0) / h + 0.5 * dx / h
                    if dy <= BELOW_REACH * h and (dx <= BELOW_ALIGN * h or overlaps) and sc < below_s:
                        var blocked = False
                        for k in range(len(labels)):
                            if k != li and len(places[k]) > 0 and _between(L, b, label_boxes[k], False):
                                blocked = True
                        if not blocked:
                            below_s = sc
                            below = j
            # a label with a word on its line is an inline label ("Date  2026-10-14"); one without heads a cell (its
            # value under it). The line wins unless what's under the label is more than RIGHT_BIAS times nearer.
            var seed = below
            if right >= 0 and (below < 0 or right_s <= RIGHT_BIAS * max(below_s, 0.5)):
                seed = right
            if seed < 0:
                continue
            # the seed's phrase: grow left and right along its line
            var phrase = List[Int]()
            phrase.append(seed)
            var grew = True
            while grew:
                grew = False
                var lo = t.box(phrase[0])
                var hi = t.box(phrase[len(phrase) - 1])
                for j in rows:
                    if is_label[j] or j in phrase:
                        continue
                    var b = t.box(j)
                    var wh = max(b.h, hi.h)
                    if _same_line(hi, b) and b.x >= hi.x + hi.w * 0.5 and b.x - hi.right() < PHRASE_GAP * wh:
                        phrase.append(j)
                        grew = True
                        break
                    if _same_line(lo, b) and b.right() <= lo.x + lo.w * 0.5 and lo.x - b.right() < PHRASE_GAP * max(b.h, lo.h):
                        phrase.insert(0, j)
                        grew = True
                        break
            var text = String("")
            var box = t.box(phrase[0])
            var conf = 1.0
            for k in range(len(phrase)):
                var j = phrase[k]
                if k > 0:
                    text += " "
                text += t.text[j]
                box = box.union(t.box(j))
                conf = min(conf, t.confidence[j])
            out[li] = Field(labels[li].name, text, p, box, conf, True, L)
    return out^
