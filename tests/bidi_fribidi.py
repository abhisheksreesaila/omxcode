"""What FriBidi (Linux's own, libfribidi.so.0) says of random lines, for tests/test_bidi.mojo: base, characters, levels, the order
from left to right.   python3 tests/bidi_fribidi.py [lines] [seed] > build/bidi.txt"""
import ctypes as C, random, sys
f = C.CDLL("libfribidi.so.0")
f.fribidi_get_par_embedding_levels_ex.restype = C.c_int8
f.fribidi_reorder_line.restype = C.c_int8
n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
r = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
POOL = [list("abcXY"), list("אבגדש"), list("عربيةم"), list("0123456789"), list("٠١٢٣۴۵"), list("+-"), list("#$%°"), list(",.:/"), list("  "), list("()[]{}<>«»"), list("!?*&@;'\"—…"),
        ["́", "ְ", "ً"], ["‎", "‏", "؜"], ["‪", "‫", "‬", "‭", "‮"], ["⁦", "⁧", "⁨", "⁩"], ["\t"], ["‍", "­"], ["語", "é", "ß"]]
for k in range(n):
    plain = r.random() < 0.5
    pools = [p for i, p in enumerate(POOL) if not (plain and i in (12, 13, 14, 16))]
    few = r.sample(pools, r.randint(2, min(7, len(pools))))
    s = "".join(r.choice(r.choice(few)) for _ in range(r.randint(1, 40)))
    u = [ord(c) for c in s]
    m = len(u)
    A = (C.c_uint32 * m)(*u)
    T = (C.c_uint32 * m)()
    BR = (C.c_uint32 * m)()
    LV = (C.c_int8 * m)()
    f.fribidi_get_bidi_types(A, m, T)
    f.fribidi_get_bracket_types(A, m, T, BR)
    base = r.choice([-1, -1, 0, 1])
    p = C.c_uint32({-1: 0x40, 0: 0x110, 1: 0x111}[base])  # ON (first strong, left to right when none), LTR, RTL
    if not f.fribidi_get_par_embedding_levels_ex(T, BR, m, C.byref(p), LV):
        continue
    M = (C.c_int32 * m)(*range(m))
    lv = (C.c_int8 * m)(*LV)
    f.fribidi_reorder_line(0, T, m, 0, p, lv, None, M)
    print(base, p.value & 1, ",".join(f"{c:x}" for c in u), ",".join(str(x) for x in lv), ",".join(str(x) for x in M), sep=" ")
