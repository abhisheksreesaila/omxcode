# mojoui.bidi: right-to-left and mixed lines (goal 79, gap 81): which way each character runs (the Unicode bidirectional algorithm,
# UAX #9, in full: embeddings, overrides, isolates, brackets), a line's runs as they stand from left to right, and, from each
# character's width, where the caret stands, which place a press means and what a selection covers. No font, no window.
#
#   var b = bidi_levels(chars)                    # b.levels (even: left to right, odd: right to left), b.base
#   var line = BidiLine(chars, b, from, to, widths)   # one line of it; widths by character, marks 0
#   line.caret_x(at)   line.at(x)   line.spans(a, b)  # in the line's own coordinates, from its left edge
#
# Not wired into mojoui's shaper, TextEdit or PageSheet yet (they measure from the left): the next step of gap 81.
# The character classes are Unicode 16's, the runs that aren't L (docs/goals/79/bidi_table.py makes them).
from std.memory import ArcPointer

comptime L = 0
comptime R = 1
comptime AL = 2
comptime EN = 3
comptime ES = 4
comptime ET = 5
comptime AN = 6
comptime CS = 7
comptime NSM = 8
comptime BN = 9
comptime B = 10
comptime S = 11
comptime WS = 12
comptime ON = 13
comptime LRE = 14
comptime RLE = 15
comptime LRO = 16
comptime RLO = 17
comptime PDF = 18
comptime LRI = 19
comptime RLI = 20
comptime FSI = 21
comptime PDI = 22
comptime MOST = 125  # levels

comptime _TABLE = (
    ""
    + "0,8,9;1,0,b;1,0,a;1,0,b;1,0,c;1,0,a;1,d,9;1,2,a;1,0,b;1,0,c;1,1,d;1,2,5;1,4,d;1,0,4;1,0,7;1,0,4;1,1,7;1,9,3;1,0,7;1,5,"
    + "d;1b,5,d;1b,3,d;1,5,9;1,0,a;1,19,9;1,0,7;1,0,d;1,3,5;1,3,d;2,1,d;1,0,9;1,1,d;1,1,5;1,1,3;1,0,d;2,2,d;1,0,3;2,4,d;18,0,"
    + "d;20,0,d;1c2,1,d;8,d,d;3,d,d;6,8,d;2,10,d;1,6f,8;5,1,d;9,0,d;6,1,d;2,0,d;6f,0,d;8d,6,8;101,0,d;3,1,d;1,0,5;1,0,1;1,2c,"
    + "8;1,0,1;1,0,8;1,0,1;1,1,8;1,0,1;1,1,8;1,0,1;1,0,8;1,37,1;1,5,6;1,1,d;1,0,2;1,1,5;1,0,2;1,0,7;1,0,2;1,1,d;1,a,8;1,2f,2;"
    + "1,14,8;1,9,6;1,0,5;1,1,6;1,2,2;1,0,8;1,64,2;1,6,8;1,0,6;1,0,d;1,5,8;1,1,2;1,1,8;1,0,d;1,3,8;1,1,2;1,9,3;1,16,2;1,0,8;1"
    + ",1d,2;1,1a,8;1,5a,2;1,a,8;1,e,2;1,2a,1;1,8,8;1,1,1;1,3,d;1,2,1;1,0,8;1,17,1;1,3,8;1,0,1;1,8,8;1,0,1;1,2,8;1,0,1;1,4,8;"
    + "1,2a,1;1,2,8;1,3,1;1,2f,2;1,1,6;1,4,2;1,8,8;1,29,2;1,17,8;1,0,6;1,1f,8;38,0,8;2,0,8;5,7,8;5,0,8;4,6,8;b,1,8;1e,0,8;3b,"
    + "0,8;5,3,8;9,0,8;15,1,8;f,1,5;8,0,5;3,0,8;3,1,8;3a,0,8;5,1,8;5,1,8;3,2,8;4,0,8;1f,1,8;4,0,8;c,1,8;3a,0,8;5,4,8;2,1,8;5,"
    + "0,8;15,1,8;e,0,5;9,5,8;2,0,8;3b,0,8;3,0,8;2,3,8;9,0,8;8,1,8;c,1,8;1f,0,8;3e,0,8;d,0,8;26,5,d;1,0,5;1,0,d;6,0,8;4,0,8;3"
    + "8,0,8;2,2,8;6,2,8;2,3,8;8,1,8;c,1,8;15,6,d;3,0,8;3b,0,8;10,1,8;15,1,8;1d,1,8;3a,1,8;5,3,8;9,0,8;15,1,8;1e,0,8;49,0,8;8"
    + ",2,8;2,0,8;5b,0,8;3,6,8;5,0,5;8,7,8;63,0,8;3,8,8;c,6,8;4a,1,8;1c,0,8;2,0,8;2,0,8;1,3,d;34,d,8;2,4,8;2,1,8;6,a,8;2,23,8"
    + ";a,0,8;67,3,8;2,5,8;2,1,8;3,1,8;1a,1,8;5,2,8;11,3,8;e,0,8;3,1,8;7,0,8;10,0,8;2c0,2,8;31,9,d;67,0,d;280,0,c;1b,1,d;76,2"
    + ",8;1e,1,8;1f,1,8;1f,1,8;41,1,8;2,6,8;9,0,8;3,a,8;8,0,5;2,0,8;13,9,d;7,a,d;1,2,8;1,0,9;1,0,8;76,1,8;23,0,8;77,2,8;5,1,8"
    + ";a,0,8;7,2,8;5,0,d;4,1,d;99,21,d;18,1,8;3,0,8;3b,0,8;2,6,8;2,0,8;2,0,8;3,7,8;7,9,8;3,0,8;31,1e,8;32,3,8;31,0,8;2,4,8;2"
    + ",0,8;6,0,8;29,8,8;d,1,8;21,3,8;3,1,8;2,2,8;39,0,8;2,1,8;4,0,8;2,2,8;3b,7,8;3,1,8;99,2,8;2,c,8;2,6,8;5,0,8;7,0,8;4,1,8;"
    + "c7,3f,8;1be,0,d;2,2,d;c,2,d;e,2,d;e,2,d;e,1,d;2,a,c;1,2,9;2,0,1;1,17,d;1,0,c;1,0,a;1,0,e;1,0,f;1,0,12;1,0,10;1,0,11;1,"
    + "0,7;1,4,5;1,e,d;1,0,7;1,19,d;1,0,c;1,4,9;2,0,13;1,0,14;1,0,15;1,0,16;1,5,9;1,0,3;4,5,3;1,1,4;1,2,d;2,9,3;1,1,4;1,2,d;1"
    + "2,20,5;10,20,8;10,1,d;2,3,d;2,1,d;b,0,d;2,2,d;6,5,d;2,0,d;2,0,d;2,0,d;5,0,5;c,1,d;5,4,d;6,3,d;3,f,d;2a,2,d;5,81,d;1,0,"
    + "4;1,0,5;1,121,d;46,19,d;2,93,d;17,a,d;16,27,d;1,13,3;4f,1c1,d;2,152,d;101,273,d;3,1f,d;2,68,d;e6,5,d;5,2,8;8,6,d;80,0,"
    + "8;61,1f,8;1,5d,d;23,19,d;2,58,d;d,d5,d;1b,f,d;1,0,c;1,3,d;4,18,d;a,3,8;3,0,d;6,1,d;6,2,d;5a,1,8;1,1,d;4,0,d;5b,0,d;c5,"
    + "25,d;a,0,d;2e,1,d;32,f,d;1d,2,d;33,e,d;d,3,d;a8,3,d;64,1,d;20,0,d;19c1,3f,d;5691,36,d;147,2,d;60,3,8;1,0,d;1,9,8;1,1,d"
    + ";1f,1,8;51,1,8;f,21,d;67,0,d;7a,0,8;4,0,8;5,0,8;1a,1,8;2,3,d;1,0,8;c,1,5;3b,3,d;4d,1,8;1b,11,8;e,0,8;27,7,8;1a,a,8;2f,"
    + "2,8;31,0,8;3,3,8;3,1,8;28,0,8;44,5,8;3,1,8;3,1,8;d,0,8;9,0,8;30,0,8;34,0,8;2,2,8;3,1,8;6,1,8;2,0,8;2b,1,8;9,0,8;74,1,d"
    + ";7a,0,8;3,0,8;5,0,8;4f30,0,1;1,0,8;1,9,1;1,0,4;1,25,1;1,1ed,2;1,11,d;1,7e,2;1,0,d;21,c,2;1,2,d;1,f,8;1,9,d;7,f,8;1,1f,"
    + "d;1,0,7;1,0,d;1,0,7;2,0,d;1,0,7;1,8,d;1,0,5;1,1,d;1,1,4;1,2,d;2,0,d;1,1,5;1,0,d;5,8e,2;1,0,9;2,1,d;1,2,5;1,4,d;1,0,4;1"
    + ",0,7;1,0,4;1,1,7;1,9,3;1,0,7;1,5,d;1b,5,d;1b,a,d;7b,1,5;1,2,d;1,1,5;2,6,d;b,4,d;104,0,d;3f,4c,d;4,c,d;4,0,d;5d,0,8;e3,"
    + "0,8;1,1a,3;7b,4,8;486,11e,1;1,0,d;1,e0,1;1,2,8;1,0,1;1,1,8;1,4,1;1,3,8;1,27,1;1,2,8;1,3,1;1,0,8;1,a4,1;1,1,8;1,51,1;1,"
    + "6,d;1,1bf,1;1,23,2;1,3,8;1,7,2;1,9,6;1,5,2;1,9,6;1,1e,1;1,4,8;1,0,d;1,f0,1;1,1e,6;1,2b,1;1,1,8;1,12,1;1,3b,2;1,3,8;1,2"
    + "f,1;1,15,2;1,a,8;1,1e,2;1,11,1;1,3,8;1,79,1;2,0,8;37,e,8;c,13,d;b,0,8;3,1,8;b,2,8;32,3,8;3,1,8;8,0,8;3e,2,8;25,4,8;2,7"
    + ",8;3f,0,8;d,1,8;35,8,8;b,3,8;3,0,8;60,2,8;3,0,8;2,1,8;7,0,8;3,0,8;9e,0,8;4,7,8;16,1,8;3a,1,8;4,0,8;26,6,8;4,4,8;47,5,8"
    + ";e,0,8;2,0,8;2,0,8;f,1,8;56,7,8;3,2,8;2,0,8;18,0,8;55,5,8;2,0,8;5,1,8;2,1,8;ef,3,8;7,1,8;2,1,8;1c,1,8;56,7,8;3,0,8;2,1"
    + ",8;20,c,d;3f,0,8;2,0,8;3,5,8;2,0,8;66,0,8;2,0,8;3,3,8;2,4,8;104,8,8;2,1,8;101,1,8;2,0,8;5,0,8;91,3,8;3,1,8;5,0,8;21,5,"
    + "8;3,1,8;29,5,8;3,3,8;9,0,8;a,5,8;3,2,8;2f,c,8;2,1,8;197,6,8;2,5,8;55,15,8;3,6,8;2,1,8;2,1,8;7b,5,8;4,0,8;2,1,8;2,6,8;2"
    + ",0,8;49,1,8;4,0,8;2,0,8;15c,1,8;c,1,8;35,4,8;6,0,8;2,0,8;18,0,8;7b,7,d;1,3,5;1,10,d;144f,0,8;7,e,8;2cc9,b,8;4,2,8;9c1,"
    + "4,8;3c,6,8;419,0,8;40,3,8;50,0,d;2,0,8;4cb9,1,8;2,3,9;f5d,d5,d;1b,9,3;7,1b3,d;4d,2d,8;3,16,8;221,2,8;a,7,9;1,7,8;3,6,8"
    + ";1f,3,8;3c,1,d;16,41,d;1,2,8;1,0,d;bb,56,d;36b,0,d;1a,0,d;20,0,d;1a,0,d;20,0,d;1a,0,d;20,0,d;1a,0,d;20,0,d;1a,0,d;b,31"
    + ",3;201,36,8;5,31,8;9,0,8;f,0,8;17,4,8;2,e,8;551,6,8;2,10,8;3,6,8;2,1,8;2,4,8;65,0,8;a1,6,8;178,0,8;3e,3,8;10,0,5;1ed,3"
    + ",8;ff,1,8;211,cf,1;1,6,8;1,6c,1;1,6,8;1,324,1;1,4f,2;1,3f,1;1,4f,2;1,af,1;1,ef,2;1,1,d;1,d,2;1,ff,1;1,2b,d;5,63,d;d,e,"
    + "d;3,e,d;2,e,d;2,24,d;b,a,3;1,4,d;20,0,d;3b,5,d;3e,0,d;b3,5,d;9b,3d7,d;5,10,d;4,c,d;4,76,d;5,5e,d;7,b,d;5,0,d;10,b,d;5,"
    + "37,d;9,9,d;7,27,d;9,1d,d;3,b,d;5,1,d;3f,153,d;d,d,d;3,c,d;4,9,d;6,37,d;8,e,d;3,a,d;7,8,d;8,92,d;2,5b,d;1,9,3;c0408,0,9"
    + ";1f,5f,9;81,ef,8")

# the paired brackets, an opening one and its closing one (BidiBrackets.txt)
comptime _PAIRS = "28 29 5b 5d 7b 7d f3a f3b f3c f3d 169b 169c 2045 2046 207d 207e 208d 208e 2308 2309 230a 230b 2329 232a 2768 2769 276a 276b 276c 276d 276e 276f 2770 2771 2772 2773 2774 2775 27c5 27c6 27e6 27e7 27e8 27e9 27ea 27eb 27ec 27ed 27ee 27ef 2983 2984 2985 2986 2987 2988 2989 298a 298b 298c 298d 2990 298f 298e 2991 2992 2993 2994 2995 2996 2997 2998 29d8 29d9 29da 29db 29fc 29fd 2e22 2e23 2e24 2e25 2e26 2e27 2e28 2e29 2e55 2e56 2e57 2e58 2e59 2e5a 2e5b 2e5c 3008 3009 300a 300b 300c 300d 300e 300f 3010 3011 3014 3015 3016 3017 3018 3019 301a 301b fe59 fe5a fe5b fe5c fe5d fe5e ff08 ff09 ff3b ff3d ff5b ff5d ff5f ff60 ff62 ff63"


def _hex(b: Span[UInt8, _], mut i: Int) -> Int:
    """The hex number at byte i; i goes past it and the separator."""
    var n = 0
    while i < len(b):
        var c = Int(b[i])
        i += 1
        if c >= 48 and c <= 57:
            n = n * 16 + c - 48
        elif c >= 97 and c <= 102:
            n = n * 16 + c - 87
        else:
            break
    return n


struct BidiData(Movable):
    """The tables, read once by whoever keeps it."""
    var first: List[Int]
    var last: List[Int]
    var cls: List[Int]
    var low: List[UInt8]  # the classes of the first 0x3000 characters, straight
    var open: List[Int]
    var close: List[Int]

    def __init__(out self):
        self.first = List[Int]()
        self.last = List[Int]()
        self.cls = List[Int]()
        self.open = List[Int]()
        self.close = List[Int]()
        self.low = List[UInt8](length=0x3000, fill=UInt8(L))
        var t = String(_TABLE)
        var b = t.as_bytes()
        var i = 0
        var at = 0
        while i < len(b):
            var start = at + _hex(b, i)
            var end = start + _hex(b, i)
            var k = _hex(b, i)
            self.first.append(start)
            self.last.append(end)
            self.cls.append(k)
            for c in range(start, min(end + 1, 0x3000)):
                self.low[c] = UInt8(k)
            at = end
        var p = String(_PAIRS)
        var pb = p.as_bytes()
        i = 0
        while i < len(pb):
            self.open.append(_hex(pb, i))
            self.close.append(_hex(pb, i))

    def of(self, c: Int) -> Int:
        """A character's bidi class."""
        if c < 0x3000:
            return Int(self.low[c])
        var lo = 0
        var hi = len(self.first) - 1
        while lo <= hi:
            var mid = (lo + hi) // 2
            if c < self.first[mid]:
                hi = mid - 1
            elif c > self.last[mid]:
                lo = mid + 1
            else:
                return self.cls[mid]
        return L

    def opens(self, c: Int) -> Int:
        """The closing bracket of an opening one (0: it isn't one). U+2329 and U+3008 are one."""
        for k in range(len(self.open)):
            if self.open[k] == c:
                return 0x3009 if c == 0x2329 else self.close[k]
        return 0

    def closes(self, c: Int) -> Int:
        """A closing bracket, as opens() says it (0: it isn't one)."""
        for k in range(len(self.close)):
            if self.close[k] == c:
                return 0x3009 if c == 0x232A else c
        return 0


struct Bidi(Copyable, Movable):
    """A paragraph's directions: its own (base 0 or 1) and each character's level."""
    var base: Int
    var levels: List[Int]
    var cls: List[Int]  # the classes, as the text has them

    def __init__(out self):
        self.base = 0
        self.levels = List[Int]()
        self.cls = List[Int]()

    def plain(self) -> Bool:
        """Left to right throughout: nothing of this module is needed."""
        for v in self.levels:
            if v != 0:
                return False
        return True


def needs_bidi(text: String) -> Bool:
    """A quick look at UTF-8: whether anything in it may run right to left (a lead byte of the Hebrew and Arabic blocks, the
    signs that turn text, or an unusual plane). False: every line is as it was without this module."""
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if (c >= 0xD6 and c <= 0xDF) or c == 0xE0 or c == 0xEF or (c == 0xE2 and i + 1 < len(b) and (Int(b[i + 1]) == 0x80 or Int(b[i + 1]) == 0x81)) or c == 0xF0:
            if c == 0xE2 and i + 2 < len(b):  # (200E, 200F, 202A–202E, 2066–2069; not the dashes and quotes)
                var two = Int(b[i + 2])
                if not ((Int(b[i + 1]) == 0x80 and (two == 0x8E or two == 0x8F or (two >= 0xAA and two <= 0xAE))) or (Int(b[i + 1]) == 0x81 and two >= 0xA6 and two <= 0xA9)):
                    continue
            return True
    return False


def _is_initiator(k: Int) -> Bool:
    return k == LRI or k == RLI or k == FSI


def _removed(k: Int) -> Bool:
    return k == LRE or k == RLE or k == LRO or k == RLO or k == PDF or k == BN


def _first_strong(cls: List[Int], start: Int, end: Int) -> Int:
    """P2, P3: 0, 1, or -1 when nothing says (isolates are skipped)."""
    var depth = 0
    for i in range(start, end):
        var k = cls[i]
        if _is_initiator(k):
            depth += 1
        elif k == PDI:
            if depth > 0:
                depth -= 1
        elif depth == 0:
            if k == L:
                return 0
            if k == R or k == AL:
                return 1
            if k == B:
                return -1
    return -1


def bidi_levels(chars: List[Int], data: BidiData, base: Int = -1) -> Bidi:
    """The levels of a paragraph's characters (base: 0, 1, or -1 for the first strong character's way)."""
    var n = len(chars)
    var out = Bidi()
    for c in chars:
        out.cls.append(data.of(c))
    out.levels = List[Int](length=n, fill=0)
    # each isolate's end
    var match_of = List[Int](length=n, fill=-1)
    var opened = List[Int]()
    for i in range(n):
        if _is_initiator(out.cls[i]):
            opened.append(i)
        elif out.cls[i] == PDI and len(opened) > 0:
            var o = opened.pop()
            match_of[o] = i
            match_of[i] = o
    out.base = base if base >= 0 else max(_first_strong(out.cls, 0, n), 0)
    # X1–X8
    var t = out.cls.copy()
    var sl = [out.base]
    var so = [-1]
    var si = [False]
    var over_iso = 0
    var over_emb = 0
    var valid = 0
    for i in range(n):
        var k = out.cls[i]
        var top = sl[len(sl) - 1]
        if k == RLE or k == LRE or k == RLO or k == LRO:
            out.levels[i] = top
            var rtl = k == RLE or k == RLO
            var next = ((top + 1) | 1) if rtl else ((top + 2) & ~1)
            if next <= MOST and over_iso == 0 and over_emb == 0:
                sl.append(next)
                so.append(R if k == RLO else (L if k == LRO else -1))
                si.append(False)
            elif over_iso == 0:
                over_emb += 1
        elif _is_initiator(k):
            out.levels[i] = top
            if so[len(so) - 1] >= 0:
                t[i] = so[len(so) - 1]
            var rtl = k == RLI
            if k == FSI:
                rtl = _first_strong(out.cls, i + 1, match_of[i] if match_of[i] >= 0 else n) == 1
            var next = ((top + 1) | 1) if rtl else ((top + 2) & ~1)
            if next <= MOST and over_iso == 0 and over_emb == 0:
                valid += 1
                sl.append(next)
                so.append(-1)
                si.append(True)
            else:
                over_iso += 1
        elif k == PDI:
            if over_iso > 0:
                over_iso -= 1
            elif valid > 0:
                over_emb = 0
                while not si[len(si) - 1]:
                    _ = sl.pop()
                    _ = so.pop()
                    _ = si.pop()
                _ = sl.pop()
                _ = so.pop()
                _ = si.pop()
                valid -= 1
            out.levels[i] = sl[len(sl) - 1]
            if so[len(so) - 1] >= 0:
                t[i] = so[len(so) - 1]
        elif k == PDF:
            out.levels[i] = top
            if over_iso > 0:
                pass
            elif over_emb > 0:
                over_emb -= 1
            elif not si[len(si) - 1] and len(sl) > 1:
                _ = sl.pop()
                _ = so.pop()
                _ = si.pop()
        elif k == B:
            out.levels[i] = out.base
        else:
            out.levels[i] = top
            if k != BN and so[len(so) - 1] >= 0:
                t[i] = so[len(so) - 1]
    # X9, X10: the level runs of what isn't removed, joined over isolates into sequences
    var starts = List[Int]()  # level runs: indices into `kept`
    var kept = List[Int]()
    for i in range(n):
        if not _removed(out.cls[i]):
            kept.append(i)
    var run_of = List[Int](length=n, fill=-1)
    for q in range(len(kept)):
        if q == 0 or out.levels[kept[q]] != out.levels[kept[q - 1]]:
            starts.append(q)
        run_of[kept[q]] = len(starts) - 1
    var embed = out.levels.copy()
    for r in range(len(starts)):
        var head = kept[starts[r]]
        if out.cls[head] == PDI and match_of[head] >= 0:  # (goes on a sequence that has begun)
            continue
        var seq = List[Int]()
        var run = r
        while True:
            var q = starts[run]
            var end = starts[run + 1] if run + 1 < len(starts) else len(kept)
            while q < end:
                seq.append(kept[q])
                q += 1
            var last = seq[len(seq) - 1]
            if not (_is_initiator(out.cls[last]) and match_of[last] >= 0):
                break
            run = run_of[match_of[last]]
        _resolve(chars, data, out, t, embed, seq, kept)
    # what was removed stands with what is before it
    for i in range(n):
        if _removed(out.cls[i]):
            out.levels[i] = out.levels[i - 1] if i > 0 else out.base
    return out^


def _resolve(chars: List[Int], data: BidiData, mut out: Bidi, mut t: List[Int], embed: List[Int], seq: List[Int], kept: List[Int]):
    """W1–W7, N0–N2, I1–I2 over one isolating run sequence."""
    var m = len(seq)
    var level = embed[seq[0]]
    var e = level & 1
    # sos, eos
    var before = out.base
    var after = out.base
    for q in range(len(kept)):
        if kept[q] == seq[0] and q > 0:
            before = embed[kept[q - 1]]
        if kept[q] == seq[m - 1] and q + 1 < len(kept):
            after = embed[kept[q + 1]]
    if _is_initiator(out.cls[seq[m - 1]]):  # (one without its end: the paragraph's)
        after = out.base
    var sos = R if max(level, before) & 1 else L
    var eos = R if max(level, after) & 1 else L
    # W1
    var prev = sos
    for q in range(m):
        var i = seq[q]
        if t[i] == NSM:
            t[i] = ON if (q > 0 and (_is_initiator(out.cls[seq[q - 1]]) or out.cls[seq[q - 1]] == PDI)) and prev != L and prev != R else prev
            if q > 0 and (_is_initiator(t[seq[q - 1]]) or t[seq[q - 1]] == PDI):
                t[i] = ON
        prev = t[i]
    # W2, W3
    var strong = sos
    for q in range(m):
        var i = seq[q]
        if t[i] == L or t[i] == R or t[i] == AL:
            strong = t[i]
        elif t[i] == EN and strong == AL:
            t[i] = AN
    for q in range(m):
        if t[seq[q]] == AL:
            t[seq[q]] = R
    # W4
    for q in range(1, m - 1):
        var i = seq[q]
        var a = t[seq[q - 1]]
        var b = t[seq[q + 1]]
        if t[i] == ES and a == EN and b == EN:
            t[i] = EN
        elif t[i] == CS and a == b and (a == EN or a == AN):
            t[i] = a
    # W5, W6
    var q = 0
    while q < m:
        if t[seq[q]] == ET:
            var z = q
            while z < m and t[seq[z]] == ET:
                z += 1
            if (q > 0 and t[seq[q - 1]] == EN) or (z < m and t[seq[z]] == EN):
                for k in range(q, z):
                    t[seq[k]] = EN
            q = z
        else:
            q += 1
    for k in range(m):
        var v = t[seq[k]]
        if v == ES or v == ET or v == CS:
            t[seq[k]] = ON
    # W7
    strong = sos
    for k in range(m):
        var i = seq[k]
        if t[i] == L or t[i] == R:
            strong = t[i]
        elif t[i] == EN and strong == L:
            t[i] = L
    # N0
    var es = List[Int]()  # the open ones: where, and what closes them
    var ec = List[Int]()
    var pa = List[Int]()
    var pb = List[Int]()
    for k in range(m):
        var i = seq[k]
        if t[i] != ON:
            continue
        var o = data.opens(chars[i])
        if o != 0:
            if len(es) == 63:
                break
            es.append(k)
            ec.append(o)
            continue
        var c = data.closes(chars[i])
        if c != 0:
            for z in range(len(ec) - 1, -1, -1):
                if ec[z] == c:
                    pa.append(es[z])
                    pb.append(k)
                    while len(es) > z:
                        _ = es.pop()
                        _ = ec.pop()
                    break
    for x in range(1, len(pa)):  # (in the order they open)
        var y = x
        while y > 0 and pa[y - 1] > pa[y]:
            pa.swap_elements(y, y - 1)
            pb.swap_elements(y, y - 1)
            y -= 1
    var way = R if e == 1 else L
    for x in range(len(pa)):
        var same = False
        var other = False
        for k in range(pa[x] + 1, pb[x]):
            var v = _strong(t[seq[k]])
            same = same or v == way
            other = other or (v >= 0 and v != way)
        var to = -1
        if same:
            to = way
        elif other:
            var ctx = sos
            for k in range(pa[x] - 1, -1, -1):
                var v = _strong(t[seq[k]])
                if v >= 0:
                    ctx = v
                    break
            to = (1 - way) if ctx != way else way
        if to >= 0:
            for at in [pa[x], pb[x]]:
                t[seq[at]] = to
                var k = at + 1  # (marks on it go with it)
                while k < m and out.cls[seq[k]] == NSM:
                    t[seq[k]] = to
                    k += 1
    # N1, N2
    q = 0
    while q < m:
        if _neutral(t[seq[q]]):
            var z = q
            while z < m and _neutral(t[seq[z]]):
                z += 1
            var a = _strong(t[seq[q - 1]]) if q > 0 else sos
            var b = _strong(t[seq[z]]) if z < m else eos
            for k in range(q, z):
                t[seq[k]] = a if a == b else way
            q = z
        else:
            q += 1
    # I1, I2
    for k in range(m):
        var i = seq[k]
        if e == 0:
            out.levels[i] = level + (1 if t[i] == R else (2 if t[i] == AN or t[i] == EN else 0))
        else:
            out.levels[i] = level + (1 if t[i] == L or t[i] == EN or t[i] == AN else 0)


def _strong(k: Int) -> Int:
    return L if k == L else (R if k == R or k == EN or k == AN else -1)


def _neutral(k: Int) -> Bool:
    return k == B or k == S or k == WS or k == ON or _is_initiator(k) or k == PDI


struct BidiRun(Copyable, Movable):
    """Characters [start, end) that run one way, at their place from the left."""
    var start: Int
    var end: Int
    var level: Int

    def __init__(out self, start: Int, end: Int, level: Int):
        self.start = start
        self.end = end
        self.level = level


def line_levels(b: Bidi, start: Int, end: Int) -> List[Int]:
    """L1: a line's levels: what separates, and white space at its end or before a separator, goes the paragraph's way."""
    var out = List[Int](capacity=end - start)
    for i in range(start, end):
        out.append(b.levels[i])
    var reset = True
    for i in range(end - 1, start - 1, -1):
        var k = b.cls[i]
        if k == B or k == S:
            reset = True
            out[i - start] = b.base
        elif k == WS or _is_initiator(k) or k == PDI or _removed(k):
            if reset:
                out[i - start] = b.base
        else:
            reset = False
    return out^


def visual_runs(levels: List[Int], start: Int = 0) -> List[BidiRun]:
    """L2: a line's runs from left to right (levels: the line's; its characters are numbered from `start`)."""
    var runs = List[BidiRun]()
    var most = 0
    var least = MOST + 2
    for i in range(len(levels)):
        most = max(most, levels[i])
        if levels[i] & 1:
            least = min(least, levels[i])
        if i > 0 and levels[i] == levels[i - 1]:
            runs[len(runs) - 1].end += 1
        else:
            runs.append(BidiRun(start + i, start + i + 1, levels[i]))
    var v = most
    while v >= least:
        var i = 0
        while i < len(runs):
            if runs[i].level >= v:
                var z = i
                while z < len(runs) and runs[z].level >= v:
                    z += 1
                for k in range((z - i) // 2):
                    runs.swap_elements(i + k, z - 1 - k)
                i = z
            else:
                i += 1
        v -= 1
    return runs^


struct BidiLine(Copyable, Movable):
    """One line [start, end) of a paragraph as it stands: where each character is. A character of no width (a mark, a sign that
    turns text) belongs to the one before it: no caret stands between them."""
    var start: Int
    var end: Int
    var base: Int
    var width: Float64
    var level: List[Int]
    var x0: List[Float64]  # each character's left and right edges
    var x1: List[Float64]
    var head: List[Bool]  # a caret may stand before it

    def __init__(out self, b: Bidi, start: Int, end: Int, widths: List[Float64]):
        """widths: of every character of the paragraph."""
        self.start = start
        self.end = end
        self.base = b.base
        self.level = line_levels(b, start, end)
        var n = end - start
        self.x0 = List[Float64](length=n, fill=0)
        self.x1 = List[Float64](length=n, fill=0)
        self.head = List[Bool](length=n, fill=True)
        for i in range(1, n):
            if widths[start + i] == 0:
                self.head[i] = False
                self.level[i] = self.level[i - 1]
        var x = 0.0
        for r in visual_runs(self.level, start):
            if r.level & 1:
                for i in range(r.end - 1, r.start - 1, -1):
                    self.x0[i - start] = x
                    x += widths[i]
                    self.x1[i - start] = x
            else:
                for i in range(r.start, r.end):
                    self.x0[i - start] = x
                    x += widths[i]
                    self.x1[i - start] = x
        self.width = x

    def _cluster_end(self, i: Int) -> Int:
        var z = i + 1
        while z < len(self.head) and not self.head[z]:
            z += 1
        return z

    def _lead(self, i: Int) -> Float64:
        """The edge of character i that comes first in reading."""
        return self.x1[i] if self.level[i] & 1 else self.x0[i]

    def _trail(self, i: Int) -> Float64:
        """The edge of the cluster of i that comes last in reading."""
        return self.x0[i] if self.level[i] & 1 else self.x1[i]

    def caret_x(self, at: Int, after: Bool = False) -> Float64:
        """Where the caret stands before character `at` (of the paragraph). Between two directions there are two places: the
        one at the character that goes the paragraph's way, where typing its own language goes on; `after`: always at the end of
        the character before (the caret came there by it)."""
        var n = len(self.level)
        if n == 0:
            return 0
        var i = min(max(at - self.start, 0), n)
        while i < n and not self.head[i]:
            i -= 1
        if i == 0:
            return self._lead(0) if self.level[0] & 1 == self.base & 1 else (self.width if self.base & 1 else 0.0)
        var before = i - 1
        while not self.head[before]:
            before -= 1
        if i == n:
            return self._trail(before) if self.level[before] & 1 == self.base & 1 else (0.0 if self.base & 1 else self.width)
        if after:
            return self._trail(before)
        if self.level[i] & 1 == self.level[before] & 1 or self.level[i] & 1 == self.base & 1:
            return self._lead(i)
        return self._trail(before)

    def at(self, x: Float64) -> Int:
        """The place a press at x means: before or after the character it is on, whichever edge is nearer."""
        var n = len(self.level)
        if n == 0:
            return self.start
        if x <= 0:
            return self.end if self.base & 1 else self.start
        if x >= self.width:
            return self.start if self.base & 1 else self.end
        for i in range(n):
            if not self.head[i] or x < self.x0[i] or x >= self.x1[i]:
                continue
            var left = x < (self.x0[i] + self.x1[i]) / 2
            return self.start + (i if left == (self.level[i] & 1 == 0) else self._cluster_end(i))
        return self.end

    def spans(self, a: Int, b: Int) -> List[Tuple[Float64, Float64]]:
        """What a selection of [a, b) covers, from left to right (several stretches when it crosses a direction)."""
        var xs = List[Tuple[Float64, Float64]]()
        var lo = max(a - self.start, 0)
        var hi = min(b - self.start, len(self.level))
        for r in visual_runs(self.level):
            var f = max(r.start, lo)
            var e = min(r.end, hi)
            if f >= e:
                continue
            var l = min(self.x0[f], self.x0[e - 1])
            var m = max(self.x1[f], self.x1[e - 1])
            if len(xs) > 0 and xs[len(xs) - 1][1] >= l:
                xs[len(xs) - 1] = (xs[len(xs) - 1][0], m)
            elif m > l:
                xs.append((l, m))
        return xs^

    def moved(self, at: Int, right: Bool) -> Int:
        """The place an arrow key goes to from `at`, as it looks (Left and Right as drawn); -1 past the line's edge."""
        var x = self.caret_x(at)
        var best = -1
        var bx = 0.0
        for i in range(len(self.level) + 1):
            if i < len(self.level) and not self.head[i]:
                continue
            var cx = self.caret_x(self.start + i)
            if (cx > x + 0.01 if right else cx < x - 0.01) and (best < 0 or (cx < bx if right else cx > bx)):
                best = self.start + i
                bx = cx
        return best
