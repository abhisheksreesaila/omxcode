# A monotonic clock in nanoseconds. Mojo's perf_counter_ns() calls Apple's clock_gettime_nsec_np even when building
# for Android (built with -D MOJOUI_ANDROID), whose libc doesn't have it; there, ask clock_gettime(CLOCK_MONOTONIC)
# directly. And the wall clock in seconds (wall_seconds: what "84 s ago" is measured from; $MOJOUI_NOW, epoch seconds,
# holds it still for tests and shots, as a browser's frozen Date does).
from std.ffi import external_call, c_int
from std.sys import is_defined, CompilationTarget
from std.time import perf_counter_ns
from std.os import getenv

comptime NOW_ENV = "MOJOUI_NOW"


def now_ns() -> Int:
    comptime if is_defined["MOJOUI_ANDROID"]():
        var ts = List[Int](length=2, fill=0)  # struct timespec { seconds; nanoseconds }
        _ = external_call["clock_gettime", c_int](c_int(1), Int(ts.unsafe_ptr()))  # CLOCK_MONOTONIC
        var ns = ts[0] * 1_000_000_000 + ts[1]
        _ = len(ts)
        return ns
    else:
        return Int(perf_counter_ns())


def clock_time() -> String:
    """The wall clock as "HH:MM:SS" in UTC (a log line's stamp: JavaScript's toTimeString().slice(0, 8) in the zone the
    console's shots and checks use), from wall_seconds (so $MOJOUI_NOW holds it too)."""
    var t = Int(wall_seconds()) % 86400
    var out = String("")
    for v in [t // 3600, (t // 60) % 60, t % 60]:
        out += (":" if out != "" else "") + ("0" if v < 10 else "") + String(v)
    return out


def wall_seconds() -> Float64:
    """Seconds since 1970 (UTC), from the system's clock; $MOJOUI_NOW (a number) holds it at that moment instead."""
    var fixed = getenv(NOW_ENV)
    if fixed != "":
        try:
            return atof(fixed)
        except:
            pass
    comptime if not CompilationTarget.is_linux():  # Apple: the call Mojo's own clock uses (the SDK stubs list it)
        return Float64(external_call["clock_gettime_nsec_np", UInt64](c_int(0))) / 1e9  # CLOCK_REALTIME
    else:
        var ts = List[Int](length=2, fill=0)  # struct timespec { seconds; nanoseconds }
        _ = external_call["clock_gettime", c_int](c_int(0), ts.unsafe_ptr())  # CLOCK_REALTIME (Linux, Android)
        var s = Float64(ts[0]) + Float64(ts[1]) / 1e9
        _ = len(ts)
        return s
