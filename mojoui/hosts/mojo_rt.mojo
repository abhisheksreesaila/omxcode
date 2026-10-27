# The Mojo runtime functions a small Mojo app needs, written in Mojo,
# so the app is self-contained (no Modular runtime library, no C shim).
#
# UNOFFICIAL: names and signatures were read from compiled Mojo 1.1 code
# (LLVM IR call sites). Recheck with `llvm-nm -u` after upgrading Mojo.
# Must be its own file: Mojo refuses to define these in a module that calls them.

from std.ffi import external_call, c_int


@export("KGEN_CompilerRT_AlignedAlloc")
def aligned_alloc(align: Int, size: Int) abi("C") -> Int:
    var out: Int = 0
    var a = align if align >= 8 else 8  # posix_memalign needs >= pointer size
    # (Pointer(to=out) is passed as a typed pointer, so the compiler sees `out` escape and reads it after the call:
    # checked in the LLVM IR and the arm64-apple-macosx assembly, `ldr x8, [sp, #8]` after `bl _posix_memalign`, D-577.
    # The lesson's lost write was an Int(address); and a List buffer here would allocate inside the allocator.)
    if external_call["posix_memalign", c_int](Pointer(to=out), a, size) != 0:
        return 0
    return out


@export("KGEN_CompilerRT_AlignedFree")
def aligned_free(ptr: Int) abi("C"):
    external_call["free", NoneType](ptr)


@export("KGEN_CompilerRT_GetStackTrace")
def get_stack_trace(buf: Int, depth: Int) abi("C") -> Int:
    """Returns 0: "no stack trace". Error messages still work; traces don't."""
    return 0


@export("KGEN_CompilerRT_fprintf")
def runtime_fprintf(stream: Int, fmt: Int) abi("C") -> c_int:
    """Used only when a Mojo internal check fails, right before stopping.

    Writes the raw format string to stderr; %-codes aren't expanded, so on a
    device you see "At: %s:%llu:%llu: Assert Error: %s" without the details:
    reproduce on Linux (full Mojo runtime) to read the real message. (C declares
    this variadic; on Apple arm64 the extra arguments go on the stack and on
    other arm64/x86-64 targets in later registers, so taking just the first two
    is safe everywhere.)
    """
    var n = external_call["strlen", Int](fmt)
    _ = external_call["write", Int](2, fmt, n)
    return c_int(n)
