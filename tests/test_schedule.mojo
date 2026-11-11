# Goal 66 M3: mojoui.schedule without a server: cron and words, time zones from the tz database (checked against
# Python's zoneinfo), New York's spring-forward and autumn days, a schedule over every hour, and a downtime caught up once.
from std.os import makedirs, getenv
from mojoui.schedule import Cron, Zone, Scheduler, Schedule, slots, iso_utc, days_from_civil, civil_from_days
from mojoui.jobs import Queue
from mojoui import libc


def ok(c: Bool, what: String) raises:
    if not c:
        raise Error("FAILED: " + what)


def show(s: List[Int]) -> String:
    var out = String("")
    for t in s:
        out += iso_utc(t) + " "
    return out^


def main() raises:
    var c = Cron("*/15 9-17 * * mon-fri")
    ok(c.minute[45] and not c.minute[50] and c.hour[17] and not c.hour[8] and c.dow[5] and not c.dow[6], "fields")
    ok(Cron("0 0 * * 7").dow[0], "7 is Sunday")
    var refused = 0
    for bad in ["", "* * * *", "60 * * * *", "* 24 * * *", "*/0 * * * *", "a b c d e"]:
        try:
            _ = Cron(String(bad))
        except:
            refused += 1
    ok(refused == 6, "bad expressions refused: " + String(refused))
    ok(civil_from_days(days_from_civil(2026, 3, 8))[2] == 8 and iso_utc(1767225600) == "2026-01-01T00:00:00Z", "calendar")
    print("cron: ok")

    ok(Cron.parse_any("every Monday 08:00").text == "0 8 * * 1", "monday: " + Cron.parse_any("every Monday 08:00").text)
    ok(Cron.parse_any("every 15 minutes").text == "*/15 * * * *", "15 minutes")
    ok(Cron.parse_any("every weekday at 09:30").text == "30 9 * * 1-5", "weekday")
    ok(Cron.parse_any("every day 23:05").text == "5 23 * * *", "day")
    ok(Cron.parse_any("every month on the 1st 09:00").text == "0 9 1 * *", "month")
    ok(Cron.parse_any("0 8 * * 1").text == "0 8 * * 1", "cron passes through")
    var wed = 1794398400  # 2026-11-11 12:00Z, a Wednesday
    var london = slots(Cron.parse_any("every Monday 08:00"), Zone.load("Europe/London"), wed, wed + 7 * 86400)
    var ny = slots(Cron.parse_any("every Monday 08:00"), Zone.load("America/New_York"), wed, wed + 7 * 86400)
    ok(len(london) == 1 and iso_utc(london[0]) == "2026-11-16T08:00:00Z", "London: " + show(london))
    ok(len(ny) == 1 and iso_utc(ny[0]) == "2026-11-16T13:00:00Z", "New York: " + show(ny))
    print("words: ok")

    var cases = [("Asia/Kolkata", 1767225600, 19800), ("Europe/London", 1782864000, 3600), ("Europe/London", 1767225600, 0),
                 ("Australia/Lord_Howe", 1767225600, 39600), ("Australia/Lord_Howe", 1782864000, 37800),
                 ("America/New_York", 2224713600, -14400), ("America/New_York", 2208988800, -18000),
                 ("Australia/Sydney", 2208988800, 39600), ("Australia/Sydney", 2224713600, 36000)]
    for k in cases:
        var z = Zone.load(String(k[0]))
        ok(z.offset(k[1]) == k[2], String(k[0]) + " at " + iso_utc(k[1]) + ": " + String(z.offset(k[1])) + " not " + String(k[2]))
    var bad_zone = 0
    for n in ["../../etc/passwd", "/etc/localtime", "No/Such_Zone", "Europe/London\n"]:
        try:
            _ = Zone.load(String(n))
        except:
            bad_zone += 1
    ok(bad_zone == 4, "bad zone names refused")
    print("tz: ok 9 offsets as Python's zoneinfo (2040's from the POSIX rule)")

    var nyz = Zone.load("America/New_York")
    var spring = slots(Cron("30 2 * * *"), nyz, 1772841600, 1773100800)
    ok(show(spring) == "2026-03-07T07:30:00Z 2026-03-08T07:30:00Z 2026-03-09T06:30:00Z ", "spring: " + show(spring))
    print("spring: ok 02:30 on 2026-03-08 runs once, at 03:30 EDT")
    var autumn = slots(Cron("30 1 * * *"), nyz, 1793404800, 1793664000)
    ok(show(autumn) == "2026-10-31T05:30:00Z 2026-11-01T05:30:00Z 2026-11-02T06:30:00Z ", "autumn: " + show(autumn))
    print("autumn: ok 01:30 on 2026-11-01 runs once, the first time")
    var wild = slots(Cron("*/30 * * * *"), nyz, 1793505600, 1793520000)
    ok(len(wild) == 8, "every 30 minutes through the repeated hour: " + show(wild))
    print("wildcard: ok every 30 minutes runs 8 times in 4 real hours across the autumn change")

    var dir = getenv("TMPDIR", "/tmp") + "/mojoui-schedule-" + String(libc.getpid())
    makedirs(dir, exist_ok=True)
    var q = Queue(dir + "/host.db")
    var sched = Scheduler(dir + "/host.db", q)
    var s = Schedule("digest", "t1", Cron.parse_any("every day 08:00"), Zone.load("Europe/London"), "digest", "")
    var t0 = 1794398400
    ok(sched.due(s, t0) == 0, "the first look starts the clock")
    ok(sched.due(s, t0 + 5 * 86400) == 1, "five days down: one catch-up")
    ok(sched.due(s, t0 + 5 * 86400) == 0 and sched.due(s, t0 + 5 * 86400 + 60) == 0, "not again")
    var db = sched.db()
    ok(db.count("SELECT count(*) FROM jobs WHERE kind = 'digest'") == 1 and db.one_text("SELECT payload FROM jobs").find('"catchup": true') >= 0, "one catch-up job: " + db.one_text("SELECT payload FROM jobs"))
    ok(db.one_text("SELECT payload FROM jobs").find("2026-11-16T08:00:00Z") >= 0, "the latest missed slot")
    ok(sched.due(s, t0 + 6 * 86400) == 1 and db.count("SELECT count(*) FROM schedule_runs WHERE catchup = 0") == 1, "the next day on time")
    print("catchup: ok five missed days → one job for the latest slot")
