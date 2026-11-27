# mojoui.merge3: a three-way merge of two JSON documents made from one base, item by item (goal 82 M7).
#
#   var m = merge_keyed(base, mine, theirs, ["nodes", "edges"])     # a JSON Canvas; a mind map: ["nodes"]
#   if m.ok: save m.text on top of theirs              # else: the edits overlap; hold them as a conflict (m.why says where)
#
# For a document whose arrays hold items with a name ("id"), as a whiteboard's objects or a mind map's ideas: what another
# writer did since `base` (`theirs`) and what this window did (`mine`) are put together when they touch different items.
#   - an item they deleted, which mine left as it was, stays deleted (it never comes back);
#   - an item they changed, which mine left as it was, is theirs; one they added is added (after mine's, in their order);
#   - what mine added, changed or deleted, where theirs left the item as it was, is mine;
#   - an item both changed (differently), one deleted on one side and changed on the other, a name added twice with two
#     contents, or a top-level member both changed: not merged (ok False). Nothing is guessed: the caller keeps its edits.
# Items are compared by content (whitespace and key order don't count; `plain` takes out what doesn't count for the app,
# as names it derives); the output keeps mine's text where an item is mine and theirs' where it is theirs, byte for byte.
# Anything that isn't an object with those arrays of named items (no name, a name twice): not merged.

from mojoui.json import Json
from mojoui.jsonedit import members, elements, find_member, MemberSpan, Span2


comptime Plain = def(String) thin -> String


def _same_text(text: String) -> String:
    return text


struct Merged(Copyable, Movable):
    var ok: Bool
    var text: String
    var why: String
    var theirs: Int  # their changes taken (added, changed, deleted items; members)
    var mine: Int  # mine kept (changed against the base)
    var deleted: Int  # items they deleted that stay deleted

    def __init__(out self, ok: Bool = False, text: String = "", why: String = ""):
        self.ok = ok
        self.text = text
        self.why = why
        self.theirs = 0
        self.mine = 0
        self.deleted = 0


struct _Items(Movable):
    var keys: List[String]
    var raw: List[String]
    var canon: List[String]

    def __init__(out self):
        self.keys = List[String]()
        self.raw = List[String]()
        self.canon = List[String]()

    def find(self, key: String) -> Int:
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return i
        return -1


def _canon(text: String, plain: Plain) raises -> String:
    var j = Json.parse(plain(text))
    return j.dump(0)


def _items(text: String, m: MemberSpan, key: String, plain: Plain) raises -> _Items:
    var out = _Items()
    for s in elements(text, m.start, m.end):
        var raw = String(text[byte = s.start : s.end])
        var j = Json.parse(raw)
        var k = j.text(j.get(0, key))
        if k == "":
            raise Error("an item without its " + key)
        if out.find(k) >= 0:
            raise Error("two items named " + k)
        out.keys.append(k)
        out.raw.append(raw)
        out.canon.append(_canon(raw, plain))
    return out^


def _member(text: String, ms: List[MemberSpan], name: String) -> String:
    var at = find_member(ms, name)
    return String(text[byte = ms[at].start : ms[at].end]) if at >= 0 else String("")


def merge_keyed(base: String, mine: String, theirs: String, arrays: List[String], key: String = "id", plain: Plain = _same_text) -> Merged:
    """See the module's notes. A merge of documents that are the same is mine as it is."""
    try:
        var bm = members(base, 0, base.byte_length())
        var mm = members(mine, 0, mine.byte_length())
        var tm = members(theirs, 0, theirs.byte_length())
        var out = Merged(True, "")
        var edits = List[Tuple[Int, Int, String]]()  # spans of mine's text to replace, and with what
        # the top-level members that aren't the arrays
        var names = List[String]()
        for ref x in mm:
            names.append(x.key)
        for ref x in tm:
            if x.key not in names:
                names.append(x.key)
        for ref x in bm:
            if x.key not in names:
                names.append(x.key)
        for n in names:
            if n in arrays:
                continue
            var b = _member(base, bm, n)
            var m = _member(mine, mm, n)
            var t = _member(theirs, tm, n)
            var bc = _canon(b, plain) if b != "" else String("")
            var mc = _canon(m, plain) if m != "" else String("")
            var tc = _canon(t, plain) if t != "" else String("")
            if tc == bc or tc == mc:
                if mc != bc:
                    out.mine += 1
                continue
            if mc != bc:
                return Merged(False, "", "both changed “" + n + "”")
            if m == "" or t == "":  # (a member added or removed by them: rare enough to leave to a person)
                return Merged(False, "", "they added or removed “" + n + "”")
            var at = find_member(mm, n)
            edits.append((mm[at].start, mm[at].end, t))
            out.theirs += 1
        # the arrays, item by item
        for a in arrays:
            var ba = find_member(bm, a)
            var ma = find_member(mm, a)
            var ta = find_member(tm, a)
            if ma < 0 or ta < 0 or ba < 0:
                if ma < 0 and ta < 0:
                    continue
                return Merged(False, "", "“" + a + "” isn't in every version")
            var bi = _items(base, bm[ba], key, plain)
            var mi = _items(mine, mm[ma], key, plain)
            var ti = _items(theirs, tm[ta], key, plain)
            var kept = List[String]()
            var changed = False
            for k in range(len(mi.keys)):
                var name = mi.keys[k]
                var b = bi.find(name)
                var t = ti.find(name)
                if b < 0:  # (mine's new one; theirs may have one of that name too)
                    if t >= 0 and ti.canon[t] != mi.canon[k]:
                        return Merged(False, "", "“" + name + "” added on both sides")
                    kept.append(mi.raw[k])
                    out.mine += 1
                    continue
                var mine_changed = mi.canon[k] != bi.canon[b]
                if t < 0:  # (they deleted it)
                    if mine_changed:
                        return Merged(False, "", "“" + name + "” deleted there and changed here")
                    out.deleted += 1
                    out.theirs += 1
                    changed = True
                    continue
                var theirs_changed = ti.canon[t] != bi.canon[b]
                if theirs_changed and mine_changed and ti.canon[t] != mi.canon[k]:
                    return Merged(False, "", "“" + name + "” changed on both sides")
                if theirs_changed and not mine_changed:
                    kept.append(ti.raw[t])
                    out.theirs += 1
                    changed = True
                else:
                    kept.append(mi.raw[k])
                    if mine_changed:
                        out.mine += 1
            for t in range(len(ti.keys)):
                var name = ti.keys[t]
                if mi.find(name) >= 0:
                    continue
                var b = bi.find(name)
                if b < 0:  # (theirs' new one)
                    kept.append(ti.raw[t])
                    out.theirs += 1
                    changed = True
                elif ti.canon[t] != bi.canon[b]:
                    return Merged(False, "", "“" + name + "” deleted here and changed there")
                else:
                    out.mine += 1  # (deleted here, as it was there: stays deleted)
            if changed:
                var body = String("[")
                for k in range(len(kept)):
                    body += ("," if k > 0 else "") + kept[k]
                edits.append((mm[ma].start, mm[ma].end, body + "]"))
        # mine's text with the spans replaced, from the end
        var text = mine
        for _ in range(len(edits)):
            var at = 0
            for k in range(1, len(edits)):
                if edits[k][0] > edits[at][0]:
                    at = k
            var e = edits.pop(at)
            text = String(text[byte = 0 : e[0]]) + e[2] + String(text[byte = e[1] :])
        out.text = text^
        return out^
    except e:
        return Merged(False, "", "not a document of named items: " + String(e))
