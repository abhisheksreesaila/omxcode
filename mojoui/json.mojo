# mojoui.json: a small JSON reader and the string writer, with no Python (the .omx metadata, mojoui.omxfile).
#
#   var j = Json.parse(text)                 # raises "not JSON: …" with the position
#   var cols = j.get(0, "columns")           # a node of the root (0) by key; -1 when absent
#   for k in range(j.size(cols)): j.at(cols, k) …    j.text(node), j.number(node), j.real(node), j.flag(node)
#
# Nodes live in flat lists (no recursive struct); a node is an Int. Numbers: number() is the whole number (a decimal's
# whole part), real() any number as a Float64, read to the same bits as Python's json.loads (goal 33 M2); is_whole()
# says which it was written as (no '.', 'e' or 'E': Python's int).

from std.ffi import external_call
from std.sys import CompilationTarget
from mojoui import libc
from mojoui.shared import get_shared, put_shared
from std.memory.alloc import alloc, Layout
from std.bit import count_leading_zeros
from mojoui.pow5 import POW5, POW5_MIN, POW5_COUNT

comptime SLOT_C_LOCALE = 233  # mojoui.shared slot: the process's "C" numeric locale (newlocale once, D-7941)
comptime SLOT_POW5 = 234  # mojoui.shared slot: mojoui.pow5's table, on the heap once (D-7945)


struct _Pow5(Movable):
    var words: List[UInt64]

    def __init__(out self):
        self.words = materialize[POW5]()


def pow5_table() -> Int:
    """The address of mojoui.pow5's words (made once per process; any thread may read them after)."""
    var have = get_shared(SLOT_POW5)
    if have != 0:
        return have
    var a = alloc(Layout[_Pow5].single())
    var p = a^.unsafe_leak()
    p.unsafe_write(_Pow5())
    var addr = Int(p[].words.unsafe_ptr())
    put_shared(SLOT_POW5, addr)
    return addr


def eisel_lemire(w: UInt64, q: Int, neg: Bool, table: Int) -> Tuple[Bool, Float64]:
    """w × 10^q (w ≤ 19 digits, exact) as the nearest Float64, by Lemire's algorithm (fast_float's compute_float: one or
    two 64×64 products with the 128-bit 5^q): (False, 0) when it can't decide (subnormal, infinite, out of the table),
    and the caller asks strtod_l. Gives the same bits as strtod for every case it answers (tests/test_json's million)."""
    if w == 0:
        return (True, -Float64(0.0) if neg else Float64(0.0))
    if q < POW5_MIN or q >= POW5_MIN + POW5_COUNT:
        return (False, Float64(0))
    var tp = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=table)
    var lz = Int(count_leading_zeros(w))
    var m = w << UInt64(lz)
    var index = 2 * (q - POW5_MIN)
    var prod = m.cast[DType.uint128]() * tp.unsafe_offset(index)[].cast[DType.uint128]()
    var hi = (prod >> 64).cast[DType.uint64]()
    var lo = prod.cast[DType.uint64]()
    if hi & 0x1FF == 0x1FF:
        var second = m.cast[DType.uint128]() * tp.unsafe_offset(index + 1)[].cast[DType.uint128]()
        var shi = (second >> 64).cast[DType.uint64]()
        lo = lo + shi
        if shi > lo:
            hi += 1
    var upper = Int(hi >> 63)
    var shift = upper + 9
    var mant = hi >> UInt64(shift)
    var power2 = (((152170 + 65536) * q) >> 16) + 63 + upper - lz + 1023
    if power2 <= 0:
        return (False, Float64(0))
    if lo <= 1 and q >= -4 and q <= 23 and mant & 3 == 1 and (mant << UInt64(shift)) == hi:
        mant &= ~UInt64(1)  # (exactly halfway: round to even)
    mant += mant & 1
    mant >>= 1
    if mant >= (UInt64(2) << 52):
        mant = UInt64(1) << 52
        power2 += 1
    mant &= ~(UInt64(1) << 52)
    if power2 >= 0x7FF:
        return (False, Float64(0))
    var bits = mant | (UInt64(power2) << 52)
    if neg:
        bits |= UInt64(1) << 63
    return (True, Float64(from_bits=bits))


def c_locale() -> Int:
    """The "C" numeric locale for strtod_l, made once per process (0 when newlocale fails)."""
    var have = get_shared(SLOT_C_LOCALE)
    if have != 0:
        return have
    var name = List[UInt8](length=2, fill=0)
    name[0] = 67  # "C"
    var loc = external_call["newlocale", Int](Int32(NUMERIC_MASK), Int(name.unsafe_ptr()), Int(0))
    _ = name^
    if loc != 0:
        put_shared(SLOT_C_LOCALE, loc)
    return loc

comptime J_NULL = 0
comptime J_BOOL = 1
comptime J_NUMBER = 2
comptime J_STRING = 3
comptime J_ARRAY = 4
comptime J_OBJECT = 5
comptime MAX_DEPTH = 64
comptime NUMERIC_MASK = 2 if CompilationTarget.is_linux() else 16  # LC_NUMERIC_MASK: glibc and bionic, Apple


def pow10(e: Int) -> Float64:
    """10^e for 0 ≤ e ≤ 22, exactly (every one is a Float64)."""
    var f = Float64(1)
    for _ in range(e):
        f *= 10
    return f


def c_float(text: String) -> Float64:
    """A JSON number's text as the nearest Float64, the same bits as Python's float(): exact when the digits and the
    power of ten are both exact Float64s (one rounding), else libc's strtod_l in the "C" locale, which rounds correctly
    and ignores a host's setlocale (a comma for the point). Mojo's atof is off by one ulp on some (goal 33, D-325)."""
    var b = text.as_bytes()
    var neg = False
    var w = UInt64(0)
    var digits = 0
    var frac = 0
    var ex = 0
    var i = 0
    if i < len(b) and b[i] == 45:
        neg = True
        i += 1
    var point = False
    while i < len(b) and ((b[i] >= 48 and b[i] <= 57) or b[i] == 46):
        if b[i] == 46:
            point = True
        else:
            if w > 0 or b[i] != 48:
                digits += 1
            if digits <= 19:
                w = w * 10 + UInt64(b[i] - 48)
            if point:
                frac += 1
        i += 1
    if i < len(b) and (b[i] == 101 or b[i] == 69):
        i += 1
        var eneg = False
        if i < len(b) and (b[i] == 43 or b[i] == 45):
            eneg = b[i] == 45
            i += 1
        var ed = 0
        while i < len(b) and b[i] >= 48 and b[i] <= 57:
            if ed < 100000:
                ed = ed * 10 + Int(b[i] - 48)
            i += 1
        ex = -ed if eneg else ed
    if w == 0:
        return -Float64(0.0) if neg else Float64(0.0)
    var e10 = ex - frac
    if digits <= 19 and w <= (UInt64(1) << 53) and -22 <= e10 and e10 <= 22:
        var f = Float64(w)
        f = f * pow10(e10) if e10 >= 0 else f / pow10(-e10)
        return -f if neg else f
    var buf = List[UInt8](length=len(b) + 1, fill=0)  # (NUL-terminated)
    for k in range(len(b)):
        buf[k] = b[k]
    var loc = c_locale()
    var v: Float64
    if loc != 0:
        v = external_call["strtod_l", Float64](Int(buf.unsafe_ptr()), Int(0), loc)
    else:
        v = libc.strtod(Int(buf.unsafe_ptr()))
    _ = buf^
    return v


def json_string(s: String) -> String:
    """`s` as a JSON string literal."""
    var out = String('"')
    for c in s.codepoint_slices():
        var o = ord(c)
        if c == '"':
            out += '\\"'
        elif c == "\\":
            out += "\\\\"
        elif c == "\n":
            out += "\\n"
        elif c == "\t":
            out += "\\t"
        elif c == "\r":
            out += "\\r"
        elif o < 32:
            var hex = "0123456789abcdef"
            out += "\\u00" + String(hex[byte = o // 16 : o // 16 + 1]) + String(hex[byte = o % 16 : o % 16 + 1])
        else:
            out += c
    return out + '"'


struct Json(Movable):
    """(D-7941: flat arrays: a node is a kind and one value, a container's children a run of `slots`; the text copied
    once as bytes; a string without escapes taken whole; a short decimal read in place. 5–10× the old reader's speed on
    Personal Note's canvases, the same grammar: the fuzz test parses and refuses exactly what it did.)"""
    var kinds: List[UInt8]
    var val: List[Int]  # J_STRING: its text (texts); J_NUMBER: its number (numbers, reals, whole); J_BOOL: 0 / 1;
    # J_ARRAY / J_OBJECT: its first child's slot
    var cnt: List[Int]  # J_ARRAY / J_OBJECT: how many children
    var texts: List[String]  # strings and keys
    var numbers: List[Int]  # per number: the value (a decimal's whole part)
    var reals: List[Float64]  # per number: the value as a Float64
    var whole: List[Bool]  # per number: written without '.', 'e' or 'E'
    var slots: List[Int]  # containers' children, each container's in a run
    var slot_keys: List[Int]  # an object's slot: its key (texts); -1 in an array
    var src: List[UInt8]
    var pos: Int
    var stack: List[Int]  # (parsing) children of the containers still open, and their keys
    var kstack: List[Int]
    var loc: Int  # (parsing) the "C" locale for strtod_l
    var p5: Int  # (parsing) mojoui.pow5's table (eisel_lemire)
    var lemire_value: Float64  # (parsing) long_decimal's answer
    var end: Int  # (parsing) the text's length (src holds a NUL after it)

    def __init__(out self):
        self.kinds = List[UInt8]()
        self.val = List[Int]()
        self.cnt = List[Int]()
        self.texts = List[String]()
        self.numbers = List[Int]()
        self.reals = List[Float64]()
        self.whole = List[Bool]()
        self.slots = List[Int]()
        self.slot_keys = List[Int]()
        self.src = List[UInt8]()
        self.pos = 0
        self.stack = List[Int]()
        self.kstack = List[Int]()
        self.loc = 0
        self.p5 = 0
        self.lemire_value = 0
        self.end = 0

    @staticmethod
    def parse(text: String) raises -> Json:
        return Json.parse_bytes(Int(text.unsafe_ptr()), text.byte_length())

    @staticmethod
    def parse_bytes(addr: Int, n: Int) raises -> Json:
        """The JSON text in bytes [addr, addr + n) (a slice of a bigger document: mojoui.canvasload parses one node
        at a time, on any thread once c_locale() has run on one)."""
        var j = Json()
        j.kinds = List[UInt8](capacity=n // 8 + 16)
        j.val = List[Int](capacity=n // 8 + 16)
        j.cnt = List[Int](capacity=n // 8 + 16)
        j.reparse(addr, n)
        j.src = List[UInt8]()  # (the text isn't needed once parsed)
        j.stack = List[Int]()
        j.kstack = List[Int]()
        return j^

    def reparse(mut self, addr: Int, n: Int) raises:
        """This reader made over for the JSON text in bytes [addr, addr + n), keeping its lists' memory: one reader
        per thread parses many small documents (mojoui.canvasload's nodes) without allocating for each."""
        self.kinds.clear()
        self.val.clear()
        self.cnt.clear()
        self.texts.clear()
        self.numbers.clear()
        self.reals.clear()
        self.whole.clear()
        self.slots.clear()
        self.slot_keys.clear()
        self.stack.clear()
        self.kstack.clear()
        self.pos = 0
        self.src.resize(n + 1, 0)
        _ = external_call["memcpy", Int](Int(self.src.unsafe_ptr()), addr, n)
        self.src[n] = 0  # (a NUL past the end: strtod_l reads a number in place and stops there at the latest)
        self.end = n
        if self.loc == 0:
            self.loc = c_locale()
        if self.p5 == 0:
            self.p5 = pow5_table()
        _ = self.value(0)
        self.skip()
        if self.pos != self.end:
            raise self.fail("something after the end")

    # ---- reading the tree ----

    def kind(self, node: Int) -> Int:
        return Int(self.kinds[node]) if 0 <= node < len(self.kinds) else -1

    def size(self, node: Int) -> Int:
        return self.cnt[node] if 0 <= node < len(self.kinds) and Int(self.kinds[node]) >= J_ARRAY else 0

    def at(self, node: Int, i: Int) -> Int:
        return self.slots[self.val[node] + i] if 0 <= i < self.size(node) else -1

    def get(self, node: Int, key: String) -> Int:
        if node < 0 or node >= len(self.kinds) or Int(self.kinds[node]) != J_OBJECT:
            return -1
        var first = self.val[node]
        for k in range(self.cnt[node]):
            if self.texts[self.slot_keys[first + k]] == key:
                return self.slots[first + k]
        return -1

    def key(self, node: Int, i: Int) -> String:
        """The key of an object's i-th member ("" for anything else)."""
        if node >= 0 and node < len(self.kinds) and Int(self.kinds[node]) == J_OBJECT and 0 <= i < self.cnt[node]:
            return self.texts[self.slot_keys[self.val[node] + i]]
        return String("")

    def text(self, node: Int, default: String = "") -> String:
        return self.texts[self.val[node]] if 0 <= node < len(self.kinds) and Int(self.kinds[node]) == J_STRING else default

    def number(self, node: Int, default: Int = 0) -> Int:
        return self.numbers[self.val[node]] if 0 <= node < len(self.kinds) and Int(self.kinds[node]) == J_NUMBER else default

    def real(self, node: Int, default: Float64 = 0) -> Float64:
        """Any number as a Float64 (a whole number too); `default` for anything else."""
        return self.reals[self.val[node]] if 0 <= node < len(self.kinds) and Int(self.kinds[node]) == J_NUMBER else default

    def is_whole(self, node: Int) -> Bool:
        """A number written as a whole number (Python reads it as an int); False for decimals and anything else."""
        return 0 <= node < len(self.kinds) and Int(self.kinds[node]) == J_NUMBER and self.whole[self.val[node]]

    def flag(self, node: Int, default: Bool = False) -> Bool:
        return self.val[node] == 1 if 0 <= node < len(self.kinds) and Int(self.kinds[node]) == J_BOOL else default

    def dump(self, node: Int) -> String:
        """A node written back as compact JSON (numbers as parsed: whole ones exactly, decimals as Float64)."""
        var k = self.kind(node)
        if k == J_NULL or k < 0:
            return "null"
        if k == J_BOOL:
            return "true" if self.val[node] == 1 else "false"
        if k == J_NUMBER:
            var v = self.val[node]
            return String(self.numbers[v]) if self.whole[v] else String(self.reals[v])
        if k == J_STRING:
            return json_string(self.texts[self.val[node]])
        var out = String("[") if k == J_ARRAY else String("{")
        for i in range(self.cnt[node]):
            if i > 0:
                out += ","
            if k == J_OBJECT:
                out += json_string(self.key(node, i)) + ":"
            out += self.dump(self.at(node, i))
        return out + ("]" if k == J_ARRAY else "}")

    # ---- parsing ----

    def fail(self, why: String) -> Error:
        return Error("not JSON: " + why + " (at character " + String(self.pos) + ")")

    def skip(mut self):
        var n = self.end
        var p = self.src.unsafe_ptr()
        var i = self.pos
        while i < n:
            var c = p[i]
            if c != 32 and c != 9 and c != 10 and c != 13:
                break
            i += 1
        self.pos = i

    def add(mut self, kind: Int, v: Int) -> Int:
        self.kinds.append(UInt8(kind))
        self.val.append(v)
        self.cnt.append(0)
        return len(self.kinds) - 1

    def literal(mut self, word: String) -> Bool:
        var b = word.as_bytes()
        if self.pos + len(b) > self.end:
            return False
        for i in range(len(b)):
            if self.src[self.pos + i] != b[i]:
                return False
        self.pos += len(b)
        return True

    def close(mut self, node: Int, base: Int):
        """A container's children (stack[base:]) into its run of slots."""
        var first = len(self.slots)
        var n = len(self.stack) - base
        for k in range(n):
            self.slots.append(self.stack[base + k])
            self.slot_keys.append(self.kstack[base + k])
        self.val[node] = first
        self.cnt[node] = n
        self.stack.shrink(base)
        self.kstack.shrink(base)

    def value(mut self, depth: Int) raises -> Int:
        if depth > MAX_DEPTH:
            raise self.fail("nested too deeply")
        self.skip()
        if self.pos >= self.end:
            raise self.fail("it ends early")
        var c = Int(self.src[self.pos])
        if c == ord("{"):
            self.pos += 1
            var node = self.add(J_OBJECT, 0)
            var base = len(self.stack)
            self.skip()
            if self.pos < self.end and Int(self.src[self.pos]) == ord("}"):
                self.pos += 1
                self.close(node, base)
                return node
            while True:
                self.skip()
                if self.pos >= self.end or Int(self.src[self.pos]) != ord('"'):
                    raise self.fail("a key was expected")
                var key = self.string_text()
                self.skip()
                if self.pos >= self.end or Int(self.src[self.pos]) != ord(":"):
                    raise self.fail("a ':' was expected")
                self.pos += 1
                var child = self.value(depth + 1)
                self.stack.append(child)
                self.kstack.append(key)
                self.skip()
                if self.pos < self.end and Int(self.src[self.pos]) == ord(","):
                    self.pos += 1
                    continue
                if self.pos < self.end and Int(self.src[self.pos]) == ord("}"):
                    self.pos += 1
                    self.close(node, base)
                    return node
                raise self.fail("a ',' or '}' was expected")
        if c == ord("["):
            self.pos += 1
            var node = self.add(J_ARRAY, 0)
            var base = len(self.stack)
            self.skip()
            if self.pos < self.end and Int(self.src[self.pos]) == ord("]"):
                self.pos += 1
                self.close(node, base)
                return node
            while True:
                var child = self.value(depth + 1)
                self.stack.append(child)
                self.kstack.append(-1)
                self.skip()
                if self.pos < self.end and Int(self.src[self.pos]) == ord(","):
                    self.pos += 1
                    continue
                if self.pos < self.end and Int(self.src[self.pos]) == ord("]"):
                    self.pos += 1
                    self.close(node, base)
                    return node
                raise self.fail("a ',' or ']' was expected")
        if c == ord('"'):
            return self.add(J_STRING, self.string_text())
        if self.literal("true"):
            return self.add(J_BOOL, 1)
        if self.literal("false"):
            return self.add(J_BOOL, 0)
        if self.literal("null"):
            return self.add(J_NULL, 0)
        if c == ord("-") or (c >= ord("0") and c <= ord("9")):
            return self.number_node()
        raise self.fail("unexpected '" + chr(c) + "'")

    def digits(mut self) -> Int:
        var p = self.src.unsafe_ptr()
        var end = self.end
        var i = self.pos
        while i < end and p[i] >= 48 and p[i] <= 57:
            i += 1
        var n = i - self.pos
        self.pos = i
        return n

    def number_node(mut self) raises -> Int:
        """A JSON number: -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?"""
        var start = self.pos
        var neg = Int(self.src[self.pos]) == ord("-")
        if neg:
            self.pos += 1
        var int_at = self.pos
        var n = self.digits()
        if n == 0:
            raise self.fail("a number was expected")
        if n > 1 and Int(self.src[int_at]) == ord("0"):
            raise self.fail("a number can't start with 0")
        var whole = True
        var frac_at = -1
        var frac_n = 0
        if self.pos < self.end and Int(self.src[self.pos]) == ord("."):
            self.pos += 1
            whole = False
            frac_at = self.pos
            frac_n = self.digits()
            if frac_n == 0:
                raise self.fail("a digit was expected after '.'")
        var has_exp = False
        if self.pos < self.end and (Int(self.src[self.pos]) == ord("e") or Int(self.src[self.pos]) == ord("E")):
            self.pos += 1
            whole = False
            has_exp = True
            if self.pos < self.end and (Int(self.src[self.pos]) == ord("+") or Int(self.src[self.pos]) == ord("-")):
                self.pos += 1
            if self.digits() == 0:
                raise self.fail("a digit was expected in the exponent")
        var at = len(self.numbers)
        var node = self.add(J_NUMBER, at)
        self.whole.append(whole)
        if whole:
            var v = 0
            var sp = self.src.unsafe_ptr()
            for k in range(int_at, self.pos):
                var d = Int(sp[k]) - 48
                if v > (9_223_372_036_854_775_807 - d) // 10:  # (Int64's range: past it Python has an exact int, we'd have to round)
                    raise self.fail("a whole number is too big")
                v = v * 10 + d
            self.numbers.append(-v if neg else v)
            self.reals.append(-Float64(v) if neg else Float64(v))
            return node
        var f: Float64
        if not has_exp and n + frac_n <= 15 and frac_n <= 22:
            # (a short decimal: its digits and the power of ten are exact Float64s, one division rounds it correctly:
            # what c_float's fast path does, without making a string)
            var w = 0
            var sp = self.src.unsafe_ptr()
            for k in range(int_at, int_at + n):
                w = w * 10 + Int(sp[k]) - 48
            for k in range(frac_at, frac_at + frac_n):
                w = w * 10 + Int(sp[k]) - 48
            if w == 0:
                f = -Float64(0.0) if neg else Float64(0.0)
            else:
                f = Float64(w) / pow10(frac_n)
                if neg:
                    f = -f
        elif self.long_decimal(int_at, n, frac_at, frac_n, has_exp, neg):  # (D-7945: Eisel–Lemire, most long decimals)
            f = self.lemire_value
        elif self.loc != 0:  # (a long decimal: libc's correctly rounded reader, in place: the grammar was checked, the
            # byte after the number isn't part of one)
            f = external_call["strtod_l", Float64](Int(self.src.unsafe_ptr()) + start, Int(0), self.loc)
        else:
            var text = List[UInt8](capacity=self.pos - start)
            for k in range(start, self.pos):
                text.append(self.src[k])
            f = c_float(String(unsafe_from_utf8=text))
        self.reals.append(f)
        self.numbers.append(Int(f) if f > -9.2e18 and f < 9.2e18 else (0 if f != f else (-9_223_372_036_854_775_807 if f < 0 else 9_223_372_036_854_775_807)))
        return node

    def long_decimal(mut self, int_at: Int, n: Int, frac_at: Int, frac_n: Int, has_exp: Bool, neg: Bool) -> Bool:
        """A decimal (its grammar already checked) read by eisel_lemire into lemire_value; False when it has more than
        19 significant digits or the algorithm can't decide (then strtod_l reads it)."""
        if self.p5 == 0:
            return False
        var sp = self.src.unsafe_ptr()
        var w = UInt64(0)
        var sig = 0
        for k in range(int_at, int_at + n):
            var d = UInt64(Int(sp[k]) - 48)
            if sig > 0 or d != 0:
                sig += 1
            w = w * 10 + d
        if frac_at >= 0:
            for k in range(frac_at, frac_at + frac_n):
                var d = UInt64(Int(sp[k]) - 48)
                if sig > 0 or d != 0:
                    sig += 1
                w = w * 10 + d
                if sig > 19:
                    return False
        if sig > 19:
            return False
        var e = 0
        if has_exp:
            var k = frac_at + frac_n if frac_at >= 0 else int_at + n
            k += 1  # (the 'e')
            var eneg = False
            if Int(sp[k]) == 43 or Int(sp[k]) == 45:
                eneg = Int(sp[k]) == 45
                k += 1
            while k < self.pos:
                if e < 100000:
                    e = e * 10 + Int(sp[k]) - 48
                k += 1
            if eneg:
                e = -e
        var r = eisel_lemire(w, e - frac_n, neg, self.p5)
        self.lemire_value = r[1]
        return r[0]

    def hex4(mut self) raises -> Int:
        if self.pos + 4 > self.end:
            raise self.fail("a \\u escape ends early")
        var v = 0
        for _ in range(4):
            var b = Int(self.src[self.pos])
            var d: Int
            if b >= ord("0") and b <= ord("9"):
                d = b - ord("0")
            elif b >= ord("a") and b <= ord("f"):
                d = b - ord("a") + 10
            elif b >= ord("A") and b <= ord("F"):
                d = b - ord("A") + 10
            else:
                raise self.fail("a \\u escape needs four hex digits")
            v = v * 16 + d
            self.pos += 1
        return v

    def string_text(mut self) raises -> Int:
        """A string at pos into texts: its index."""
        self.texts.append(self.string())
        return len(self.texts) - 1

    def string(mut self) raises -> String:
        self.pos += 1  # the opening quote
        # (fast path: no escape before the closing quote: the bytes taken whole)
        var q = self.pos
        var n = self.end
        var p = self.src.unsafe_ptr()
        while q < n and p[q] != 34 and p[q] != 92:
            q += 1
        if q < n and self.src[q] == 34:
            var piece = List[UInt8](capacity=q - self.pos)
            piece.extend(Span(self.src)[self.pos:q])
            self.pos = q + 1
            return String(unsafe_from_utf8=piece)
        var out = List[UInt8](capacity=q - self.pos + 16)
        while True:
            if self.pos >= self.end:
                raise self.fail("a string is not closed")
            var b = Int(self.src[self.pos])
            self.pos += 1
            if b == ord('"'):
                break
            if b != ord("\\"):
                out.append(UInt8(b))
                continue
            if self.pos >= self.end:
                raise self.fail("a string is not closed")
            var e = Int(self.src[self.pos])
            self.pos += 1
            if e == ord("n"):
                out.append(10)
            elif e == ord("t"):
                out.append(9)
            elif e == ord("r"):
                out.append(13)
            elif e == ord("b"):
                out.append(8)
            elif e == ord("f"):
                out.append(12)
            elif e == ord('"') or e == ord("\\") or e == ord("/"):
                out.append(UInt8(e))
            elif e == ord("u"):
                var cp = self.hex4()
                if cp >= 0xDC00 and cp < 0xE000:
                    raise self.fail("a lone low surrogate")
                if cp >= 0xD800 and cp < 0xDC00:  # a high surrogate needs its low one right after
                    if self.pos + 1 < self.end and Int(self.src[self.pos]) == ord("\\") and Int(self.src[self.pos + 1]) == ord("u"):
                        self.pos += 2
                        var lo = self.hex4()
                        if lo < 0xDC00 or lo >= 0xE000:
                            raise self.fail("a high surrogate not followed by a low one")
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    else:
                        raise self.fail("a lone high surrogate")
                for x in chr(cp).as_bytes():
                    out.append(x)
            else:
                raise self.fail("a bad escape")
        return String(unsafe_from_utf8=out)
