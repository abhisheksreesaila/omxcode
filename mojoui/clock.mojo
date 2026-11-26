# A monotonic clock in nanoseconds. Mojo's perf_counter_ns() calls Apple's clock_gettime_nsec_np even when building
# for Android (built with -D MOJOUI_ANDROID), whose libc doesn't have it; there, ask clock_gettime(CLOCK_MONOTONIC)
# directly. And the wall clock in seconds (wall_seconds: what "84 s ago" is measured from; $MOJOUI_NOW, epoch seconds,
# holds it still for tests and shots, as a browser's frozen Date does).
from std.ffi import external_call, c_int
from std.sys import is_defined, CompilationTarget
from std.time import perf_counter_ns
from std.os import getenv
from mojoui import libc

comptime NOW_ENV = "MOJOUI_NOW"
comptime ELAPSED_ENV = "MOJOUI_ELAPSED_MS"


def shown_ms(ms: Float64) -> Float64:
    """A measured duration as an app shows it ("0.4 ms on the GPU"): $MOJOUI_ELAPSED_MS (a number) holds every shown
    timing at that value for tests and shots, as $MOJOUI_NOW holds the wall clock; the measurement itself is untouched."""
    var fixed = getenv(ELAPSED_ENV)
    if fixed != "":
        try:
            return atof(fixed)
        except:
            pass
    return ms


def now_ns() -> Int:
    comptime if is_defined["MOJOUI_ANDROID"]():
        var ts = List[Int](length=2, fill=0)  # struct timespec { seconds; nanoseconds }
        _ = libc.clock_gettime(1, Int(ts.unsafe_ptr()))  # CLOCK_MONOTONIC
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
        _ = libc.clock_gettime(0, Int(ts.unsafe_ptr()))  # CLOCK_REALTIME (Linux, Android)
        var s = Float64(ts[0]) + Float64(ts[1]) / 1e9
        _ = len(ts)
        return s


@fieldwise_init
struct LocalTime(Copyable, Movable, ImplicitlyCopyable):
    """The wall clock in this machine's time zone: what a clock on a counter shows. `zoned` is False when the zone couldn't
    be read and the fields are UTC instead (a real UTC date and time, never a made-up one)."""

    var hour: Int  # 0-23
    var minute: Int
    var weekday: Int  # 0 Sunday … 6 Saturday
    var month: Int  # 1-12
    var day: Int  # 1-31
    var zoned: Bool  # True: the machine's zone (localtime_r); False: UTC (localtime_r failed)


def utc_time(seconds: Int) -> LocalTime:
    """`seconds` since 1970 as a UTC date and time (`zoned` False): days to a civil date by Howard Hinnant's
    civil_from_days, so it is right for any day, leap years included, before or after 1970."""
    var t = seconds
    var days = t // 86400  # floor division: before 1970 the day still starts at midnight
    var rem = t - days * 86400
    var z = days + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097  # [0, 146096]
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365  # [0, 399]
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)  # [0, 365]
    var mp = (5 * doy + 2) // 153  # [0, 11], March first
    var day = doy - (153 * mp + 2) // 5 + 1
    var month = mp + 3 if mp < 10 else mp - 9
    var weekday = (days + 4) % 7  # 1970-01-01 was a Thursday
    if weekday < 0:
        weekday += 7
    return LocalTime(rem // 3600, (rem // 60) % 60, weekday, month, day, False)


def local_time() -> LocalTime:
    """Now in the machine's time zone (libc's localtime_r on wall_seconds, so $MOJOUI_NOW holds it too; $TZ picks the
    zone). When localtime_r fails the result is utc_time's (UTC, `zoned` False): callers that care can say so."""
    return local_time_at(Int(wall_seconds()))


def local_time_at(seconds: Int) -> LocalTime:
    """`seconds` since 1970 in the machine's time zone (see local_time)."""
    var secs = List[Int](length=1, fill=seconds)
    var tm = List[Int](length=8, fill=0)  # (struct tm: 9 c_ints, the offset, the zone's name: 7 Ints, one spare)
    var ok = libc.localtime_r(Int(secs.unsafe_ptr()), Int(tm.unsafe_ptr()))
    var p = Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=Int(tm.unsafe_ptr()))
    var out: LocalTime
    if ok == 0:
        out = utc_time(seconds)
    else:
        out = LocalTime(Int(p.unsafe_offset(2)[]), Int(p.unsafe_offset(1)[]), Int(p.unsafe_offset(6)[]), Int(p.unsafe_offset(4)[]) + 1, Int(p.unsafe_offset(3)[]), True)
    _ = len(secs)
    _ = len(tm)
    return out


def wall_clock_text(t: LocalTime, twelve: Bool = True) -> String:
    """A wall clock's time: "7:38" (twelve-hour, as a kitchen clock reads) or "19:38". (Not mojoui.player.clock_text,
    which reads a duration in seconds.)"""
    var h = t.hour
    if twelve:
        h = h % 12
        if h == 0:
            h = 12
    return String(h) + ":" + ("0" if t.minute < 10 else "") + String(t.minute)


def wall_date_text(t: LocalTime) -> String:
    """A wall clock's date: "Wednesday, November 18". (Not mojoui.numformat.date_text, which prints a date cell.)"""
    var days: List[String] = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    var months: List[String] = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    return days[t.weekday % 7] + ", " + months[(t.month - 1) % 12] + " " + String(t.day)


def trace_on() -> Bool:
    """Tracing for tests and shots: MOJOUI_TRACE or MOJOUI_TEST is set (components print `PLAYER: …`, `CURSOR: …` lines)."""
    return getenv("MOJOUI_TRACE") != "" or getenv("MOJOUI_TEST") != ""
