"""What ICU (libicuuc: what Chrome orders lines with) says of random lines, for tests/test_bidi.mojo: base, characters, levels, the
order from left to right.   python3 tests/bidi_icu.py [lines] [seed] > build/bidi.txt
(FriBidi, tried first, differs from ICU on some brackets with marks and turning signs among them: ICU is the web's.)"""
import ctypes as C, glob, random, re, sys
path = sorted(glob.glob("/usr/lib/libicuuc.so.*"))[0]
ver = re.search(r"so[.](\d+)", path).group(1)
I = C.CDLL(path)


def f(name):
    return getattr(I, f"{name}_{ver}")


f("ubidi_open").restype = C.c_void_p
f("ubidi_getLevels").restype = C.POINTER(C.c_uint8)
B = C.c_void_p(f("ubidi_open")())
n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
r = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
POOL = [list("abcXY"), list("אבגדש"), list("عربيةم"), list("0123456789"), list("٠١٢٣۴۵"), list("+-"), list("#$%°"), list(",.:/"), list("  "), list("()[]{}<>«»"), list("!?*&@;'\"—…"),
        ["́", "ְ", "ً"], ["‎", "‏", "؜"], ["‪", "‫", "‬", "‭", "‮"], ["⁦", "⁧", "⁨", "⁩"], ["\t"], ["‍", "­"], ["語", "é", "ß"]]
for k in range(n):
    plain = r.random() < 0.5
    pools = [p for i, p in enumerate(POOL) if not (plain and i in (12, 13, 14, 16))]
    few = r.sample(pools, r.randint(2, min(7, len(pools))))
    s = "".join(r.choice(r.choice(few)) for _ in range(r.randint(1, 40)))
    if re.search("[][(){}][\u200d\u00ad\u200e\u200f\u061c\u202a-\u202e\u2066-\u2069]*[\u0301\u05b0\u064b]", s):  # (ICU doesn't let a mark go with its bracket; Unicode's rule N0 does)
        continue
    u = [ord(c) for c in s]
    m = len(u)
    U = (C.c_uint16 * m)(*u)
    base = r.choice([-1, -1, 0, 1])
    e = C.c_int(0)
    f("ubidi_setPara")(B, U, m, C.c_uint8({-1: 0xFE, 0: 0, 1: 1}[base]), None, C.byref(e))
    L = f("ubidi_getLevels")(B, C.byref(e))
    lv = [L[i] for i in range(m)]
    M = (C.c_int32 * m)()
    f("ubidi_getVisualMap")(B, M, C.byref(e))
    assert e.value <= 0
    print(base, f("ubidi_getParaLevel")(B) & 1, ",".join(f"{c:x}" for c in u), ",".join(map(str, lv)), ",".join(map(str, M)), sep=" ")
