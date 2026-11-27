# mojoui.zlibc (goal 82): the system's zlib, looked up at run time (libz.so.1 on Linux, libz.1.dylib on the Mac: both ship it),
# for what must be small: a PNG's pixels, a PDF's streams. Nothing is linked; no other module's declaration is shared (dlsym).
#
#   var z = zlib_compress(bytes, 6)       # a zlib stream (header, deflate, Adler-32); empty when the system has no zlib

from std.ffi import external_call, c_int


def _dlsym(handle: Int, name: String) -> Int:
    var n = name
    return external_call["dlsym", Int](handle, n.as_c_string_span())


def _fn[T: ImplicitlyCopyable](addr: Int) -> T:
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr)
    return Pointer(to=raw).unsafe_bitcast[T]()[]


def _compress2() -> Int:
    var dlopen = _dlsym(0, "dlopen")
    if dlopen == 0:
        dlopen = _dlsym(-2, "dlopen")
    for name in [String("libz.so.1"), String("/usr/lib/libz.1.dylib"), String("libz.dylib")]:
        var n = name
        var h = _fn[def(Int, c_int) thin abi("C") -> Int](dlopen)(Int(n.as_c_string_span().unsafe_ptr()), c_int(2))
        if h != 0:
            return _dlsym(h, "compress2")
    return 0


def zlib_compress(data: List[UInt8], level: Int = 6) -> List[UInt8]:
    """`data` as a zlib stream at `level` (0–9); empty when there's no zlib here (callers then store their bytes as they are)."""
    var f = _compress2()
    if f == 0:
        return List[UInt8]()
    var cap = len(data) + len(data) // 1000 + 64
    var z = List[UInt8](length=cap, fill=0)
    var zlen = List[Int](length=1, fill=cap)
    var rc = _fn[def(Int, Int, Int, Int, c_int) thin abi("C") -> c_int](f)(Int(z.unsafe_ptr()), Int(zlen.unsafe_ptr()), Int(data.unsafe_ptr()), len(data), c_int(level))
    _ = len(data)
    if rc != 0:
        return List[UInt8]()
    var out = List[UInt8](capacity=zlen[0])
    for i in range(zlen[0]):
        out.append(z[i])
    return out^
