# mojoui.mdinline (goal 79, docs/goals/79-gaps.md 26): how a line of Markdown is styled where its marks stay shown: which bytes
# are marks, bold, slanted, struck, code, a link's words, an address. The rules are those of the web page's parser (Lezer's
# GFM Markdown, CommonMark's flanking rules for * and _), one line at a time (an emphasis that runs over a line's end isn't
# found); test_mdinline holds it to what that parser says of 60 lines.
#
#   var f = inline_flags(line, start)      # one flag set per byte from `start` on: MARK | BOLD | ITALIC | STRIKE | CODE | LINK | URL

comptime MARK = 1
comptime BOLD = 2
comptime ITALIC = 4
comptime STRIKE = 8
comptime CODE = 16
comptime LINK = 32
comptime URL = 64


@fieldwise_init
struct _Run(Copyable, Movable, ImplicitlyCopyable):
    """A run of * _ or ~ that may open or close emphasis."""
    var ch: Int
    var at: Int
    var n: Int  # how many are left
    var size: Int  # how many there were
    var open: Bool
    var close: Bool


def _space(c: Int) -> Bool:
    return c == 32 or c == 9 or c == 0


def _punct(c: Int) -> Bool:
    return (33 <= c <= 47) or (58 <= c <= 64) or (91 <= c <= 96) or (123 <= c <= 126)


def _alnum(c: Int) -> Bool:
    return (48 <= c <= 57) or (65 <= c <= 90) or (97 <= c <= 122) or c >= 128


def _word(c: Int) -> Bool:
    return (48 <= c <= 57) or (65 <= c <= 90) or (97 <= c <= 122) or c == 95


def _starts(b: Span[Byte, _], i: Int, end: Int, word: StaticString) -> Bool:
    var w = word.as_bytes()
    if i + len(w) > end:
        return False
    for k in range(len(w)):
        if b[i + k] != w[k]:
            return False
    return True


def inline_flags(line: String, start: Int) -> List[Int]:
    var b = line.as_bytes()
    var flags = List[Int](length=len(b), fill=0)
    _inline(line, start, len(b), flags)
    return flags^


def _add(mut flags: List[Int], a: Int, e: Int, f: Int):
    for i in range(a, e):
        flags[i] |= f


def _bare_url(b: Span[Byte, _], i: Int, end: Int) -> Int:
    """Where an address written bare at i ends (GFM), -1: none there."""
    var head = 0
    if _starts(b, i, end, "https://"):
        head = 8
    elif _starts(b, i, end, "http://"):
        head = 7
    elif _starts(b, i, end, "www."):
        head = 4
    if head == 0:
        return -1
    # (a domain with a dot in it, then a path only after a "/")
    var e = i + head
    var dot = False
    if head == 4:  # (www. itself ends in one: its name needs none more)
        dot = True
    var last = e
    while e < end and (_word(Int(b[e])) or b[e] == 45 or (b[e] == 46 and e + 1 < end and (_word(Int(b[e + 1])) or b[e + 1] == 45) and e > i + head)):
        if b[e] == 46:
            dot = True
        e += 1
    if e == last or not dot:
        return -1
    if e < end and b[e] == 47:
        while e < end and not _space(Int(b[e])) and b[e] != 60:
            e += 1
    while e > i + head:  # (its last punctuation, and a ) that closes nothing in it, aren't its)
        var c = Int(b[e - 1])
        if c == 63 or c == 33 or c == 46 or c == 44 or c == 58 or c == 42 or c == 95 or c == 126:
            e -= 1
            continue
        if c == 41:
            var depth = 0
            for k in range(i, e):
                if b[k] == 40:
                    depth += 1
                elif b[k] == 41:
                    depth -= 1
            if depth < 0:
                e -= 1
                continue
        break
    return e


def _mail(b: Span[Byte, _], i: Int, end: Int) -> Int:
    """Where a mail address that begins at i ends, -1: none there."""
    var k = i
    while k < end and (_alnum(Int(b[k])) and Int(b[k]) < 128 or b[k] == 46 or b[k] == 45 or b[k] == 95 or b[k] == 43):
        k += 1
    if k == i or k >= end or b[k] != 64:
        return -1
    var dot = -1
    var e = k + 1
    while e < end and (_alnum(Int(b[e])) and Int(b[e]) < 128 or b[e] == 46 or b[e] == 45):
        if b[e] == 46:
            dot = e
        e += 1
    while e > k + 1 and (b[e - 1] == 46 or b[e - 1] == 45):
        e -= 1
    return e if dot > k + 1 and dot < e - 1 else -1


def _inline(line: String, start: Int, end: Int, mut flags: List[Int]):
    var b = line.as_bytes()
    var runs = List[_Run]()
    var i = start
    while i < end:
        var c = Int(b[i])
        if c == 92 and i + 1 < end and _punct(Int(b[i + 1])):  # \*
            i += 2
            continue
        if c == 96:  # `code`
            var n = 0
            while i + n < end and b[i + n] == 96:
                n += 1
            var k = i + n
            var close = -1
            while k < end:
                if b[k] != 96:
                    k += 1
                    continue
                var m = 0
                while k + m < end and b[k + m] == 96:
                    m += 1
                if m == n:
                    close = k
                    break
                k += m
            if close >= 0:
                _add(flags, i, i + n, MARK)
                _add(flags, i + n, close, CODE)
                _add(flags, close, close + n, MARK)
                i = close + n
            else:
                i += n
            continue
        if c == 60:  # <http://…>
            var k = i + 1
            while k < end and b[k] != 62 and b[k] != 60 and not _space(Int(b[k])):
                k += 1
            var scheme = False
            for q in range(i + 2, k):
                if b[q] == 58 or b[q] == 64:
                    scheme = True
            if k < end and b[k] == 62 and scheme:
                _add(flags, i, i + 1, MARK)
                _add(flags, i + 1, k, URL)
                _add(flags, k, k + 1, MARK)
                i = k + 1
                continue
        if c == 91 or (c == 33 and i + 1 < end and b[i + 1] == 91):  # [words](address "title"), [words][ref], [words]
            var e = _link(line, i, end, flags)
            if e > i:
                i = e
                continue
            i += 1 if c == 91 else 2
            continue
        var before = Int(b[i - 1]) if i > start else 0
        if (c == 104 or c == 119) and (i == start or not _word(before)):
            var e = _bare_url(b, i, end)
            if e > i:
                _add(flags, i, e, URL)
                i = e
                continue
        if _alnum(c) and c < 128 and (i == start or not (_word(before) or before == 46 or before == 45 or before == 43)):
            var e = _mail(b, i, end)
            if e > i:
                _add(flags, i, e, URL)
                i = e
                continue
        if c == 42 or c == 95 or c == 126:
            var n = 0
            while i + n < end and Int(b[i + n]) == c:
                n += 1
            var after = Int(b[i + n]) if i + n < end else 0
            var left = not _space(after) and (not _punct(after) or _space(before) or _punct(before))
            var right = not _space(before) and (not _punct(before) or _space(after) or _punct(after))
            if c == 95:
                runs.append(_Run(c, i, n, n, left and (not right or _punct(before)), right and (not left or _punct(after))))
            elif c == 42:
                runs.append(_Run(c, i, n, n, left, right))
            elif n == 2:
                runs.append(_Run(c, i, n, n, left, right))
            i += n
            continue
        i += 1
    # (CommonMark's "process emphasis": each closer takes the nearest opener of its kind)
    var k = 0
    while k < len(runs):
        if not runs[k].close or runs[k].n == 0:
            k += 1
            continue
        var found = False
        var o = k - 1
        while o >= 0:
            if runs[o].ch == runs[k].ch and runs[o].open and runs[o].n > 0:
                var sum3 = (runs[o].close or runs[k].open) and (runs[o].size + runs[k].size) % 3 == 0 and not (runs[o].size % 3 == 0 and runs[k].size % 3 == 0)
                if runs[k].ch == 126 or not sum3:
                    found = True
                    break
            o -= 1
        if not found:
            k += 1
            continue
        var use = 2 if runs[o].n >= 2 and runs[k].n >= 2 else 1
        var f = STRIKE if runs[k].ch == 126 else (BOLD if use == 2 else ITALIC)
        var a = runs[o].at + runs[o].n - use  # (the opener's last ones, the closer's first)
        var z = runs[k].at + (runs[k].size - runs[k].n)
        _add(flags, a, a + use, MARK)
        _add(flags, z, z + use, MARK)
        _add(flags, a, z + use, f)
        runs[o].n -= use
        runs[k].n -= use
        for q in range(o + 1, k):  # (what is between can't cross it)
            runs[q].n = 0
        if runs[k].n == 0:
            k += 1


def _link(line: String, i: Int, end: Int, mut flags: List[Int]) -> Int:
    """A link or picture at i: its flags set, and where it ends; i when there is none."""
    var b = line.as_bytes()
    var open = i + (2 if b[i] == 33 else 1)
    var depth = 1
    var k = open
    var close = -1
    while k < end:
        var c = Int(b[k])
        if c == 92:
            k += 2
            continue
        if c == 96:  # (code hides brackets)
            var n = 0
            while k + n < end and b[k + n] == 96:
                n += 1
            var q = k + n
            while q < end:
                var m = 0
                while q + m < end and b[q + m] == 96:
                    m += 1
                if m == n:
                    break
                q += max(m, 1)
            k = q + n if q < end else k + n
            continue
        if c == 91:
            depth += 1
        elif c == 93:
            depth -= 1
            if depth == 0:
                close = k
                break
        k += 1
    if close < 0:
        return i
    for q in range(open, close):  # (a link's words hold no other link: the inner one is it)
        if b[q] == 91 and b[q - 1] != 92 and b[q - 1] != 33 and b[i] != 33:
            return i
    if close + 1 < end and b[close + 1] == 40:
        var p = close + 2
        while p < end and _space(Int(b[p])):
            p += 1
        var u0 = p
        if p < end and b[p] == 60:
            while p < end and b[p] != 62:
                p += 1
            p += 1
        else:
            var d = 0
            while p < end and not _space(Int(b[p])):
                if b[p] == 92:
                    p += 1
                elif b[p] == 40:
                    d += 1
                elif b[p] == 41:
                    if d == 0:
                        break
                    d -= 1
                p += 1
        var u1 = min(p, end)
        while p < end and _space(Int(b[p])):
            p += 1
        if p < end and (b[p] == 34 or b[p] == 39):
            var quote = b[p]
            p += 1
            while p < end and b[p] != quote:
                p += 1
            p += 1
            while p < end and _space(Int(b[p])):
                p += 1
        if p < end and b[p] == 41:
            _inline(line, open, close, flags)
            _add(flags, i, p + 1, LINK)
            _add(flags, i, open, MARK)
            _add(flags, close, close + 2, MARK)
            _add(flags, u0, u1, URL)
            _add(flags, p, p + 1, MARK)
            return p + 1
    var e = close + 1
    if close == open:  # ([] is nothing)
        return i
    if e < end and b[e] == 91:
        var q = e + 1
        while q < end and b[q] != 93:
            q += 1
        if q < end:
            e = q + 1
    _inline(line, open, close, flags)
    _add(flags, i, e, LINK)
    _add(flags, i, open, MARK)
    _add(flags, close, close + 1, MARK)
    return e
