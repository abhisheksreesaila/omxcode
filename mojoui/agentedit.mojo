# mojoui.agentedit: what an agent's write changed in a text, and how to take it back without taking the person's later
# edits with it (goal 82 M6; Personal Note's agent_edit.py, F-096, the text half). Pure functions, no database.
#
#   var span = changed_span(before, after)          # (from, to) byte offsets of the lines the write touched: Show marks them
#   var back = merge_text(after, now, before)       # `before` laid over what is there now; None when the person changed
#                                                   # the very words the agent's write changed (never a guess)
#
# A three-way merge: the agent's version (`after`) is the base, what is stored now is the person's, the version to go back
# to is the target. The changed words must still stand, with CONTEXT characters around them, exactly once in what is there
# now; anything less and a short change (a typo fix) could land on other words the person typed, so the answer is None.
# (Offsets here are bytes of UTF-8; the web counts UTF-16 units for its page editor: each side counts in its own editor's.)

comptime CONTEXT = 24  # characters around a change that pin down where it sits


def _trim(before: String, after: String) -> Tuple[Int, Int]:
    """How many bytes both share at the start and at the end (never overlapping), on whole characters."""
    var a = before.as_bytes()
    var b = after.as_bytes()
    var limit = min(len(a), len(b))
    var prefix = 0
    while prefix < limit and a[prefix] == b[prefix]:
        prefix += 1
    while prefix > 0 and prefix < len(a) and (Int(a[prefix]) & 0xC0) == 0x80:  # (back to a character's first byte)
        prefix -= 1
    var suffix = 0
    while suffix < limit - prefix and a[len(a) - 1 - suffix] == b[len(b) - 1 - suffix]:
        suffix += 1
    while suffix > 0 and (Int(a[len(a) - suffix]) & 0xC0) == 0x80:
        suffix -= 1
    return (prefix, suffix)


def _back(s: String, chars: Int, at: Int) -> Int:
    """The byte offset `chars` characters before `at` (0 at most)."""
    var b = s.as_bytes()
    var k = at
    var n = 0
    while k > 0 and n < chars:
        k -= 1
        while k > 0 and (Int(b[k]) & 0xC0) == 0x80:
            k -= 1
        n += 1
    return k


def _ahead(s: String, chars: Int, at: Int) -> Int:
    var b = s.as_bytes()
    var k = at
    var n = 0
    while k < len(b) and n < chars:
        k += 1
        while k < len(b) and (Int(b[k]) & 0xC0) == 0x80:
            k += 1
        n += 1
    return k


def _count(hay: String, needle: String) -> Int:
    if needle == "":
        return 0
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + 1)
    return n


def merge_text(base: String, ours: String, target: String) -> Optional[String]:
    """`target` laid over `ours` (agent_edit.merge_markdown); None when the person changed the very words that differ
    between `base` and `target`."""
    if ours == base:
        return target
    var t = _trim(base, target)
    var prefix = t[0]
    var suffix = t[1]
    var old = String(base[byte = prefix : base.byte_length() - suffix])
    var new = String(target[byte = prefix : target.byte_length() - suffix])
    var before_ctx = String(base[byte = _back(base, CONTEXT, prefix) : prefix])
    var after_end = base.byte_length() - suffix
    var after_ctx = String(base[byte = after_end : _ahead(base, CONTEXT, after_end)])
    var wanted = before_ctx + old + after_ctx
    if _count(ours, wanted) != 1:
        return None
    var at = ours.find(wanted) + before_ctx.byte_length()
    return String(ours[byte = 0:at]) + new + String(ours[byte = at + old.byte_length() :])


def changed_span(before: String, after: String) -> Tuple[Int, Int]:
    """The lines of `after` the write touched, as byte offsets (from, to) (agent_edit.changed_lines): Show scrolls there
    and marks them."""
    var t = _trim(before, after)
    var end = after.byte_length() - t[1]
    var first = t[0]
    var b = after.as_bytes()
    while first < end and b[first] == 10:  # (a paragraph added after a blank line: the line before it isn't part of it)
        first += 1
    var start = 0
    var k = first - 1
    while k >= 0:
        if b[k] == 10:
            start = k + 1
            break
        k -= 1
    var stop = after.find("\n", end)
    if stop < 0:
        stop = after.byte_length()
    return (start, stop)
