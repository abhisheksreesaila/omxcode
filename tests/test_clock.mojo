# mojoui.clock's wall clock (goal 77 M7f review): utc_time turns epoch seconds into a real UTC date (leap days, year ends,
# before 1970), local_time_at reads the machine's zone through localtime_r ($TZ, here a fixed POSIX zone so no tz database is
# needed), local_time follows $MOJOUI_NOW, and the texts read hour, minute, weekday, month and day.
#   pixi run mojo run --disable-warnings -I . tests/test_clock.mojo
# Prints one "<name>: ok" line per check, then "clock: ok".
from std.testing import assert_equal, assert_true, assert_false
from std.os import setenv
from mojoui import libc
from mojoui.clock import LocalTime, utc_time, local_time, local_time_at, wall_clock_text, wall_date_text


def same(t: LocalTime, hour: Int, minute: Int, weekday: Int, month: Int, day: Int) raises:
    assert_equal(t.hour, hour, "hour")
    assert_equal(t.minute, minute, "minute")
    assert_equal(t.weekday, weekday, "weekday")
    assert_equal(t.month, month, "month")
    assert_equal(t.day, day, "day")


def main() raises:
    # UTC: the fallback when localtime_r fails is a real date, flagged
    var u = utc_time(1795049100)  # 2026-11-19 00:45 UTC, a Thursday
    same(u, 0, 45, 4, 11, 19)
    assert_false(u.zoned)
    same(utc_time(0), 0, 0, 4, 1, 1)  # 1970-01-01, a Thursday
    same(utc_time(1709208000), 12, 0, 4, 2, 29)  # 2024-02-29 (leap day), a Thursday
    same(utc_time(1798761540), 23, 59, 4, 12, 31)  # 2026-12-31 23:59, a Thursday
    same(utc_time(-1), 23, 59, 3, 12, 31)  # 1969-12-31 23:59:59, a Wednesday
    print("utc_time: ok")

    # the zone: IST-5:30 (UTC+5:30, a POSIX zone: no database), then tzset
    _ = setenv("TZ", "IST-5:30", True)
    libc.tzset()  # (glibc's localtime_r reads the zone once)
    var l = local_time_at(1795049100)
    same(l, 6, 15, 4, 11, 19)  # Thu Nov 19 06:15
    assert_true(l.zoned)
    same(local_time_at(1772308800), 1, 30, 0, 3, 1)  # 2026-02-28 20:00 UTC is Sun Mar 1 01:30 there
    same(local_time_at(1798761540), 5, 29, 5, 1, 1)  # 2026-12-31 23:59 UTC is Fri Jan 1 05:29 there
    print("local_time_at: ok")

    # $MOJOUI_NOW holds local_time
    _ = setenv("MOJOUI_NOW", "1795049100", True)
    same(local_time(), 6, 15, 4, 11, 19)
    print("local_time MOJOUI_NOW: ok")

    # the texts
    assert_equal(wall_clock_text(l), "6:15")
    assert_equal(wall_clock_text(l, twelve=False), "6:15")
    var eve = LocalTime(19, 8, 3, 11, 18, True)
    assert_equal(wall_clock_text(eve), "7:08")
    assert_equal(wall_clock_text(eve, twelve=False), "19:08")
    assert_equal(wall_clock_text(LocalTime(0, 5, 0, 1, 1, True)), "12:05")
    assert_equal(wall_clock_text(LocalTime(12, 0, 0, 1, 1, True)), "12:00")
    assert_equal(wall_date_text(l), "Thursday, November 19")
    assert_equal(wall_date_text(eve), "Wednesday, November 18")
    assert_equal(wall_date_text(local_time_at(1772308800)), "Sunday, March 1")
    print("texts: ok")
    print("clock: ok")
