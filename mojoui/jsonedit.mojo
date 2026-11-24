# Changing a JSON document without rewriting the rest of it (review 3, MUST 5): a program that understands part of a
# document edits that part and leaves every other byte as it was: keys it has never heard of, their order, numbers spelled
# their own way. Text in, text out: spans of the source, never a tree written back.
#
#   for m in members(text, 0, text.byte_length()): … m.key, text[m.start:m.end]     # an object's members, in order
#   for e in elements(text, a, b): …                                                # an array's elements
#   out = patched(text, [Change("text", json_string("new")), Change("x", "12")])    # values replaced, new keys appended
#   out = patched_in(text, "pn", [Change("color", …)])                              # in a nested object (made if missing)
#
# The text must be valid JSON (the caller has parsed it); anything else raises.
from mojoui.json import Json, json_string


@fieldwise_init
struct Span2(Copyable, Movable, ImplicitlyCopyable):
    var start: Int
    var end: Int


struct MemberSpan(Copyable, Movable):
    var key: String
    var key_start: Int  # the key's opening quote
    var start: Int  # the value [start, end)
    var end: Int

    def __init__(out self, key: String, key_start: Int, start: Int, end: Int):
        self.key = key
        self.key_start = key_start
        self.start = start
        self.end = end


@fieldwise_init
struct Change(Copyable, Movable):
    """Member `key`'s new value as JSON text; "" takes the member out."""

    var key: String
    var value: String


def part(text: String, start: Int, end: Int) -> String:
    return String(text[byte=start:end])


def _ws(b: UInt8) -> Bool:
    return b == 32 or b == 10 or b == 13 or b == 9


def _skip(text: String, at: Int, end: Int) -> Int:
    var b = text.as_bytes()
    var i = at
    while i < end and _ws(b[i]):
        i += 1
    return i


def _string_end(text: String, at: Int, end: Int) raises -> Int:
    """One past the closing quote of the string whose opening quote is at `at`."""
    var b = text.as_bytes()
    var i = at + 1
    while i < end:
        if b[i] == 92:
            i += 2
            continue
        if b[i] == 34:
            return i + 1
        i += 1
    raise Error("jsonedit: a string that doesn't end")


def value_end(text: String, at: Int, end: Int) raises -> Int:
    """One past the JSON value that starts at `at`."""
    var b = text.as_bytes()
    if at >= end:
        raise Error("jsonedit: no value")
    if b[at] == 34:
        return _string_end(text, at, end)
    if b[at] == 123 or b[at] == 91:
        var depth = 0
        var i = at
        while i < end:
            if b[i] == 34:
                i = _string_end(text, i, end)
                continue
            if b[i] == 123 or b[i] == 91:
                depth += 1
            elif b[i] == 125 or b[i] == 93:
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
        raise Error("jsonedit: an object or array that doesn't end")
    var i = at
    while i < end and not _ws(b[i]) and b[i] != 44 and b[i] != 125 and b[i] != 93:
        i += 1
    if i == at:
        raise Error("jsonedit: no value")
    return i


def members(text: String, start: Int, end: Int) raises -> List[MemberSpan]:
    """The members of the object at [start, end) (spaces round it allowed)."""
    var out = List[MemberSpan]()
    var b = text.as_bytes()
    var i = _skip(text, start, end)
    if i >= end or b[i] != 123:
        raise Error("jsonedit: not an object")
    i = _skip(text, i + 1, end)
    if i < end and b[i] == 125:
        return out^
    while i < end:
        if b[i] != 34:
            raise Error("jsonedit: not a key")
        var ks = i
        var ke = _string_end(text, i, end)
        i = _skip(text, ke, end)
        if i >= end or b[i] != 58:
            raise Error("jsonedit: no colon")
        i = _skip(text, i + 1, end)
        var ve = value_end(text, i, end)
        out.append(MemberSpan(_key(text, ks, ke), ks, i, ve))
        i = _skip(text, ve, end)
        if i < end and b[i] == 44:
            i = _skip(text, i + 1, end)
            continue
        if i < end and b[i] == 125:
            return out^
        raise Error("jsonedit: neither , nor }")
    raise Error("jsonedit: an object that doesn't end")


def _key(text: String, ks: Int, ke: Int) raises -> String:
    var raw = text[byte=ks + 1:ke - 1]
    if raw.find("\\") < 0:
        return String(raw)
    var j = Json.parse(String(text[byte=ks:ke]))
    return j.text(0)


def elements(text: String, start: Int, end: Int) raises -> List[Span2]:
    """The elements of the array at [start, end)."""
    var out = List[Span2]()
    var b = text.as_bytes()
    var i = _skip(text, start, end)
    if i >= end or b[i] != 91:
        raise Error("jsonedit: not an array")
    i = _skip(text, i + 1, end)
    if i < end and b[i] == 93:
        return out^
    while i < end:
        var ve = value_end(text, i, end)
        out.append(Span2(i, ve))
        i = _skip(text, ve, end)
        if i < end and b[i] == 44:
            i = _skip(text, i + 1, end)
            continue
        if i < end and b[i] == 93:
            return out^
        raise Error("jsonedit: neither , nor ]")
    raise Error("jsonedit: an array that doesn't end")


def find_member(ms: List[MemberSpan], key: String) -> Int:
    """The member of that name (the last one, as JSON readers take duplicates), -1 when there is none."""
    for i in range(len(ms) - 1, -1, -1):
        if ms[i].key == key:
            return i
    return -1


def patched(text: String, changes: List[Change]) raises -> String:
    """The object with those members' values replaced (or taken out, or added at its end); everything else byte for byte."""
    if len(changes) == 0:
        return text
    var ms = members(text, 0, text.byte_length())
    var out = String("")
    var at = 0
    var left = 0  # members still there
    var gone = List[Bool](length=len(ms), fill=False)
    var put = List[Int](length=len(ms), fill=-1)
    var used = List[Bool](length=len(changes), fill=False)
    for c in range(len(changes)):
        var i = find_member(ms, changes[c].key)
        if i >= 0:
            used[c] = True
            if changes[c].value == "":
                for k in range(len(ms)):
                    if ms[k].key == changes[c].key:
                        gone[k] = True
            else:
                put[i] = c
    for i in range(len(ms)):
        if not gone[i]:
            left += 1
    # members are copied with what lies between them; one taken out goes with a comma beside it
    var first = True
    var open_at = _skip(text, 0, text.byte_length()) + 1
    out += part(text, 0, open_at)
    at = open_at
    for i in range(len(ms)):
        if gone[i]:
            at = ms[i].end
            continue
        var lead = part(text, at, ms[i].key_start)
        if first:
            lead = String(lead.replace(",", "")) if at != open_at else lead
        elif lead.find(",") < 0:
            lead = "," + lead
        out += lead + part(text, ms[i].key_start, ms[i].start)
        out += changes[put[i]].value if put[i] >= 0 else part(text, ms[i].start, ms[i].end)
        at = ms[i].end
        first = False
    for c in range(len(changes)):
        if not used[c] and changes[c].value != "":
            out += (String("") if first else String(",")) + json_string(changes[c].key) + ":" + changes[c].value
            first = False
    # (the end: what follows the last member; a comma that stood before a removed last one has gone with it)
    out += part(text, at, text.byte_length())
    return out


def member_text(text: String, key: String) raises -> String:
    """Member `key`'s value as JSON text ("" when there is none)."""
    var ms = members(text, 0, text.byte_length())
    var i = find_member(ms, key)
    return part(text, ms[i].start, ms[i].end) if i >= 0 else String("")


def patched_in(text: String, key: String, changes: List[Change]) raises -> String:
    """`patched`, inside the object that is member `key` (made when missing or not an object)."""
    if len(changes) == 0:
        return text
    var inner = member_text(text, key)
    if not inner.startswith("{"):
        inner = "{}"
    return patched(text, [Change(key, patched(inner, changes))])
