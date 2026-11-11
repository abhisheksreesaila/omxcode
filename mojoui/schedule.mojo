# mojoui.schedule: recurring jobs (goal 66 M3; fh-saas had none, apps used cron on the host). A schedule is a cron
# expression ("0 8 * * 1") or words ("every Monday 08:00"), read in an IANA time zone per tenant from the system's tz
# database (TZif files, their POSIX rule past the last transition). Each due slot becomes one mojoui.jobs job, written
# in the same host.db transaction as the slot's row (name, tenant, slot unique), so a slot is queued at most once across
# restarts and kill -9; slots missed while the server was down are caught up once (the latest, marked catchup).
#
#   var sched = Scheduler(data + "/host.db", queue)
#   var s = Schedule("digest", tenant, Cron.parse_any("every Monday 08:00"), Zone.load("Europe/London"), "digest")
#   _ = sched.due(s, now_s)          # (tick, every few seconds) 1 when it queued a slot's job: kind "digest",
#                                    #   payload {"schedule", "slot": "2026-11-16T08:00:00Z", "catchup"}
#
# Daylight saving (as Vixie cron): a fixed time that a spring-forward skips runs once, at the first moment after the gap
# (02:30 on New York's spring day runs at 03:30 EDT); a fixed time an autumn repeats runs once, at its first occurrence;
# a schedule over every hour ("*/15 * * * *") runs on real time through both. Jobs are at least once (mojoui.jobs): a
# run killed mid-way runs again after the restart, so a runner makes its effect idempotent by the slot.

from std.os import getenv
from std.os.path import exists
from mojoui.jobs import Queue
from mojoui.json import json_string
from mojoui.sqlite import Database, Pool
from mojoui.clock import wall_seconds

comptime MAX_SCAN_DAYS = 400  # slots looked for after a downtime (older ones are simply missed)
comptime SCHEMA = (
    "CREATE TABLE IF NOT EXISTS schedule_state(name TEXT NOT NULL, tenant TEXT NOT NULL, last INTEGER NOT NULL, PRIMARY KEY(name, tenant));"
    "CREATE TABLE IF NOT EXISTS schedule_runs(name TEXT NOT NULL, tenant TEXT NOT NULL, slot TEXT NOT NULL, at REAL NOT NULL,"
    " job INTEGER, catchup INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(name, tenant, slot))"
)


# ---------------------------------------------------------------- the calendar

def days_from_civil(y0: Int, m: Int, d: Int) -> Int:
    """Days since 1970-01-01 (Howard Hinnant's algorithm)."""
    var y = y0 - 1 if m <= 2 else y0
    var era = (y if y >= 0 else y - 399) // 400
    var yoe = y - era * 400
    var mp = m - 3 if m > 2 else m + 9
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def civil_from_days(z0: Int) -> Tuple[Int, Int, Int]:
    var z = z0 + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    return (y + 1 if m <= 2 else y, m, d)


def weekday(days: Int) -> Int:
    """0 Sunday … 6 Saturday."""
    var w = (days + 4) % 7
    return w + 7 if w < 0 else w


def _two(n: Int) -> String:
    return ("0" if n < 10 else "") + String(n)


def iso_utc(t: Int) -> String:
    """2026-11-16T08:00:00Z."""
    var days = t // 86400
    var secs = t - days * 86400
    var c = civil_from_days(days)
    return String(c[0]) + "-" + _two(c[1]) + "-" + _two(c[2]) + "T" + _two(secs // 3600) + ":" + _two((secs // 60) % 60) + ":" + _two(secs % 60) + "Z"


# ---------------------------------------------------------------- time zones

@fieldwise_init
struct _When(Copyable, Movable):
    var kind: Int  # 0 Mm.w.d, 1 Jn (1–365, no Feb 29), 2 n (0–365)
    var a: Int
    var b: Int
    var c: Int
    var secs: Int  # local time of day the change happens


struct Zone(Copyable, Movable):
    var name: String
    var times: List[Int]  # transitions, UTC seconds
    var offs: List[Int]  # the UTC offset from each transition on
    var first: Int  # the offset before the first transition
    var has_rule: Bool  # the POSIX rule after the last transition
    var std: Int
    var dst: Int
    var has_dst: Bool
    var start: _When
    var end: _When

    def __init__(out self, name: String):
        self.name = name
        self.times = List[Int]()
        self.offs = List[Int]()
        self.first = 0
        self.has_rule = False
        self.std = 0
        self.dst = 0
        self.has_dst = False
        self.start = _When(0, 0, 0, 0, 0)
        self.end = _When(0, 0, 0, 0, 0)

    @staticmethod
    def utc() -> Zone:
        return Zone("UTC")

    @staticmethod
    def valid_name(name: String) -> Bool:
        """An IANA name: letters, digits, '/', '_', '-', '+', no '.' segments or leading '/' (it becomes a path)."""
        if name == "" or name.byte_length() > 64 or name.startswith("/") or name.find("..") >= 0:
            return False
        for b in name.as_bytes():
            var c = Int(b)
            if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 47 or c == 95 or c == 45 or c == 43):
                return False
        return True

    @staticmethod
    def load(name: String) raises -> Zone:
        """A zone from the tz database ($TZDIR or /usr/share/zoneinfo). Raises on an unknown or malformed name."""
        if name == "UTC" or name == "Etc/UTC" or name == "":
            return Zone.utc()
        if not Zone.valid_name(name):
            raise Error("not a time zone name: " + name)
        var dir = getenv("TZDIR", "/usr/share/zoneinfo")
        var path = dir + "/" + name
        if not exists(path):
            raise Error("unknown time zone: " + name)
        var data: List[UInt8]
        with open(path, "r") as f:
            data = f.read_bytes()
        return Zone.parse(name, data)

    @staticmethod
    def parse(name: String, data: List[UInt8]) raises -> Zone:
        var z = Zone(name)
        if len(data) < 44 or data[0] != UInt8(ord("T")) or data[1] != UInt8(ord("Z")) or data[2] != UInt8(ord("i")) or data[3] != UInt8(ord("f")):
            raise Error("not a TZif file: " + name)
        var version = Int(data[4])
        var p = 0
        var size = 4  # (version 1's times are 32-bit)
        if version >= ord("2"):  # skip version 1's block to the 64-bit one
            p = 44 + _block_len(data, 0, 4)
            size = 8
        if p + 44 > len(data):
            raise Error("a short TZif file: " + name)
        var isut = _u32(data, p + 20)
        var isstd = _u32(data, p + 24)
        var leap = _u32(data, p + 28)
        var timecnt = _u32(data, p + 32)
        var typecnt = _u32(data, p + 36)
        var charcnt = _u32(data, p + 40)
        var q = p + 44
        var types_at = q + timecnt * size + timecnt
        if types_at + typecnt * 6 > len(data) or typecnt == 0:
            raise Error("a short TZif file: " + name)
        var type_off = List[Int]()
        var type_dst = List[Bool]()
        for i in range(typecnt):
            type_off.append(_i32(data, types_at + i * 6))
            type_dst.append(data[types_at + i * 6 + 4] != 0)
        for i in range(timecnt):
            var t = _i64(data, q + i * 8) if size == 8 else _i32(data, q + i * 4)
            var idx = Int(data[q + timecnt * size + i])
            z.times.append(t)
            z.offs.append(type_off[idx] if idx < typecnt else 0)
        z.first = type_off[0]
        for i in range(typecnt):  # (RFC 8536: before the first transition, the first standard-time type)
            if not type_dst[i]:
                z.first = type_off[i]
                break
        if size == 8:
            var foot = types_at + typecnt * 6 + charcnt + leap * 12 + isstd + isut
            if foot < len(data) and data[foot] == UInt8(10):
                var e = foot + 1
                while e < len(data) and data[e] != UInt8(10):
                    e += 1
                var tz = String(from_utf8_lossy=Span(data)[foot + 1 : e])
                if tz != "":
                    z._rule(tz)
        return z^

    def _rule(mut self, tz: String) raises:
        """A POSIX TZ string: std offset [dst [offset] ,start[/time],end[/time]]."""
        var s = tz.as_bytes()
        var i = _skip_name(s, 0)
        var r = _offset(s, i)
        self.std = -r[0]
        i = r[1]
        self.has_rule = True
        if i >= len(s):
            return
        self.has_dst = True
        i = _skip_name(s, i)
        self.dst = self.std + 3600
        if i < len(s) and s[i] != UInt8(ord(",")):
            r = _offset(s, i)
            self.dst = -r[0]
            i = r[1]
        if i >= len(s) or s[i] != UInt8(ord(",")):
            self.has_dst = False
            return
        var a = _when(s, i + 1)
        self.start = a[0].copy()
        i = a[1]
        if i >= len(s) or s[i] != UInt8(ord(",")):
            raise Error("a POSIX TZ rule without its end: " + tz)
        var b = _when(s, i + 1)
        self.end = b[0].copy()

    def offset(self, t: Int) -> Int:
        """The UTC offset (seconds east) at UTC time t."""
        var n = len(self.times)
        if n == 0 or t < self.times[0]:
            return self._from_rule(t) if n == 0 and self.has_rule else self.first
        if t >= self.times[n - 1] and self.has_rule:
            return self._from_rule(t)
        var lo = 0
        var hi = n - 1
        while lo < hi:
            var mid = (lo + hi + 1) // 2
            if self.times[mid] <= t:
                lo = mid
            else:
                hi = mid - 1
        return self.offs[lo]

    def _from_rule(self, t: Int) -> Int:
        if not self.has_dst:
            return self.std
        var y = civil_from_days((t + self.std) // 86400)[0]
        var on = _rule_day(self.start, y) * 86400 + self.start.secs - self.std  # (the change at local standard time)
        var off = _rule_day(self.end, y) * 86400 + self.end.secs - self.dst  # (back at local daylight time)
        if on < off:
            return self.dst if on <= t and t < off else self.std
        return self.std if off <= t and t < on else self.dst  # (southern: daylight across the new year)


def _block_len(data: List[UInt8], p: Int, size: Int) -> Int:
    var isut = _u32(data, p + 20)
    var isstd = _u32(data, p + 24)
    var leap = _u32(data, p + 28)
    var timecnt = _u32(data, p + 32)
    var typecnt = _u32(data, p + 36)
    var charcnt = _u32(data, p + 40)
    return timecnt * size + timecnt + typecnt * 6 + charcnt + leap * (size + 4) + isstd + isut


def _u32(d: List[UInt8], p: Int) -> Int:
    return (Int(d[p]) << 24) | (Int(d[p + 1]) << 16) | (Int(d[p + 2]) << 8) | Int(d[p + 3])


def _i32(d: List[UInt8], p: Int) -> Int:
    var v = _u32(d, p)
    return v - (1 << 32) if v >= (1 << 31) else v


def _i64(d: List[UInt8], p: Int) -> Int:
    var hi = _i32(d, p)
    return hi * (1 << 32) + _u32(d, p + 4)


def _skip_name(s: Span[UInt8, _], i0: Int) -> Int:
    var i = i0
    if i < len(s) and s[i] == UInt8(ord("<")):
        while i < len(s) and s[i] != UInt8(ord(">")):
            i += 1
        return i + 1
    while i < len(s) and ((s[i] >= UInt8(ord("A")) and s[i] <= UInt8(ord("Z"))) or (s[i] >= UInt8(ord("a")) and s[i] <= UInt8(ord("z")))):
        i += 1
    return i


def _num(s: Span[UInt8, _], i0: Int) -> Tuple[Int, Int]:
    var i = i0
    var n = 0
    while i < len(s) and s[i] >= UInt8(ord("0")) and s[i] <= UInt8(ord("9")):
        n = n * 10 + Int(s[i]) - 48
        i += 1
    return (n, i)


def _offset(s: Span[UInt8, _], i0: Int) -> Tuple[Int, Int]:
    """[+-]hh[:mm[:ss]] as seconds (POSIX: positive west); and where it ended."""
    var i = i0
    var sign = 1
    if i < len(s) and (s[i] == UInt8(ord("+")) or s[i] == UInt8(ord("-"))):
        sign = -1 if s[i] == UInt8(ord("-")) else 1
        i += 1
    var h = _num(s, i)
    var secs = h[0] * 3600
    i = h[1]
    if i < len(s) and s[i] == UInt8(ord(":")):
        var m = _num(s, i + 1)
        secs += m[0] * 60
        i = m[1]
        if i < len(s) and s[i] == UInt8(ord(":")):
            var x = _num(s, i + 1)
            secs += x[0]
            i = x[1]
    return (sign * secs, i)


def _when(s: Span[UInt8, _], i0: Int) raises -> Tuple[_When, Int]:
    var i = i0
    var w = _When(0, 0, 0, 0, 7200)
    if i < len(s) and s[i] == UInt8(ord("M")):
        var m = _num(s, i + 1)
        var n = _num(s, m[1] + 1)
        var d = _num(s, n[1] + 1)
        w = _When(0, m[0], n[0], d[0], 7200)
        i = d[1]
    elif i < len(s) and s[i] == UInt8(ord("J")):
        var j = _num(s, i + 1)
        w = _When(1, j[0], 0, 0, 7200)
        i = j[1]
    else:
        var j = _num(s, i)
        w = _When(2, j[0], 0, 0, 7200)
        i = j[1]
    if i < len(s) and s[i] == UInt8(ord("/")):
        var o = _offset(s, i + 1)
        w.secs = o[0]
        i = o[1]
    return (w^, i)


def _leap(y: Int) -> Bool:
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0


def _rule_day(w: _When, y: Int) -> Int:
    """The day (days since the epoch) a POSIX rule names in year y."""
    if w.kind == 1:
        var d = w.a - 1
        if _leap(y) and w.a >= 60:
            d += 1
        return days_from_civil(y, 1, 1) + d
    if w.kind == 2:
        return days_from_civil(y, 1, 1) + w.a
    var first = days_from_civil(y, w.a, 1)
    var day = first + (w.c - weekday(first) + 7) % 7 + (w.b - 1) * 7
    var next_month = days_from_civil(y + 1, 1, 1) if w.a == 12 else days_from_civil(y, w.a + 1, 1)
    while day >= next_month:  # (week 5: the last such day)
        day -= 7
    return day


# ---------------------------------------------------------------- cron

def _field(text: String, lo: Int, hi: Int, names: List[String]) raises -> List[Bool]:
    var out = List[Bool](length=hi + 1, fill=False)
    for part in text.split(","):
        var p = String(part).lower()
        var step = 1
        var slash = p.find("/")
        if slash >= 0:
            step = atol(String(p[byte = slash + 1 :]))
            var head = String(p[byte = : slash])
            p = head
            if step <= 0:
                raise Error("a cron step must be positive: " + text)
        var a = lo
        var b = hi
        if p != "*":
            var dash = p.find("-")
            a = _value(String(p) if dash < 0 else String(p[byte = : dash]), names)
            b = a if dash < 0 else _value(String(p[byte = dash + 1 :]), names)
            if slash >= 0 and dash < 0:
                b = hi
        if a < lo or b > hi or a > b:
            raise Error("out of range in cron: " + text)
        var v = a
        while v <= b:
            out[v] = True
            v += step
    return out^


def _value(t: String, names: List[String]) raises -> Int:
    for i in range(len(names)):
        if names[i] == t:
            return i
    return atol(t)


struct Cron(Copyable, Movable):
    var minute: List[Bool]
    var hour: List[Bool]
    var dom: List[Bool]
    var month: List[Bool]
    var dow: List[Bool]
    var dom_any: Bool
    var dow_any: Bool
    var every_hour: Bool  # the hour field covers every hour: runs on real time through DST changes
    var text: String

    def __init__(out self, text: String) raises:
        var f = List[String]()
        for p in text.split(" "):
            if String(p) != "":
                f.append(String(p))
        if len(f) != 5:
            raise Error("cron needs five fields: " + text)
        var none = List[String]()
        var months = List[String]()
        for m in ["", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]:
            months.append(m)
        var days = List[String]()
        for d in ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]:
            days.append(d)
        self.minute = _field(f[0], 0, 59, none)
        self.hour = _field(f[1], 0, 23, none)
        self.dom = _field(f[2], 1, 31, none)
        self.month = _field(f[3], 1, 12, months)
        var dow7 = _field(f[4], 0, 7, days)
        self.dow = List[Bool](length=7, fill=False)
        for i in range(8):
            if dow7[i]:
                self.dow[i % 7] = True
        self.dom_any = f[2] == "*"
        self.dow_any = f[4] == "*"
        self.every_hour = True
        for h in range(24):
            self.every_hour = self.every_hour and self.hour[h]
        self.text = text

    @staticmethod
    def parse_any(text: String) raises -> Cron:
        """Cron's five fields, or words: "every minute", "every 15 minutes", "every hour", "every day 08:00",
        "every Monday 08:00", "every weekday 09:30", "every weekend 10:00", "every month on the 1st 09:00"."""
        var t = text.strip().lower()
        if not t.startswith("every"):
            return Cron(String(t))
        return Cron(words_to_cron(String(t)))

    def matches(self, local: Int) -> Bool:
        """Local wall-clock seconds (as if UTC) match the expression."""
        var days = local // 86400
        var secs = local - days * 86400
        if not self.minute[(secs // 60) % 60] or not self.hour[secs // 3600]:
            return False
        var c = civil_from_days(days)
        if not self.month[c[1]]:
            return False
        var d = self.dom[c[2]]
        var w = self.dow[weekday(days)]
        if self.dom_any or self.dow_any:
            return d and w
        return d or w  # (both restricted: either, as cron)


def words_to_cron(t: String) raises -> String:
    var parts = List[String]()
    for p in t.split(" "):
        if String(p) != "" and String(p) != "at" and String(p) != "on" and String(p) != "the":
            parts.append(String(p))
    if len(parts) < 2 or parts[0] != "every":
        raise Error("not a schedule: " + t)
    var hh = 0
    var mm = 0
    var last = parts[len(parts) - 1]
    var colon = last.find(":")
    if colon > 0:
        hh = atol(String(last[byte = : colon]))
        mm = atol(String(last[byte = colon + 1 :]))
        if hh < 0 or hh > 23 or mm < 0 or mm > 59:
            raise Error("not a time of day: " + last)
        _ = parts.pop()
    var at = String(mm) + " " + String(hh)
    var w = parts[1]
    if w == "minute":
        return "* * * * *"
    if w == "hour":
        return String(mm) + " * * * *"
    if len(parts) >= 3 and (parts[2] == "minutes" or parts[2] == "minute"):
        return "*/" + String(atol(w)) + " * * * *"
    if len(parts) >= 3 and (parts[2] == "hours" or parts[2] == "hour"):
        return String(mm) + " */" + String(atol(w)) + " * * *"
    if w == "day":
        return at + " * * *"
    if w == "weekday":
        return at + " * * 1-5"
    if w == "weekend":
        return at + " * * 0,6"
    if w == "month":
        var day = 1
        if len(parts) >= 3:
            var d = parts[2].replace("st", "").replace("nd", "").replace("rd", "").replace("th", "")
            day = atol(d)
        return at + " " + String(day) + " * *"
    var names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    for i in range(7):
        var n = String(names[i])
        if w == n or w == n + "s" or w == String(n[byte = :3]):
            return at + " * * " + String(i)
    raise Error("not a schedule: " + t)


def slots(cron: Cron, zone: Zone, after: Int, until: Int) -> List[Int]:
    """The UTC instants in (after, until] when the schedule is due, in order (DST rules in the header)."""
    var out = List[Int]()
    if until <= after:
        return out^
    var lo = max(after, until - MAX_SCAN_DAYS * 86400)
    var start = ((lo + min(zone.offset(lo), zone.offset(lo - 86400))) // 60) * 60 - 60
    var stop = until + max(zone.offset(until), zone.offset(until + 86400)) + 60
    var local = start
    while local <= stop:
        if cron.matches(local):
            var o1 = zone.offset(local - 86400 - 7200)
            var o2 = zone.offset(local + 86400)
            var c1 = local - o1
            var c2 = local - o2
            var v1 = zone.offset(c1) == o1
            var v2 = o2 != o1 and zone.offset(c2) == o2
            if v1 and v2:  # (autumn: this wall time happens twice)
                _add(out, min(c1, c2), after, until)
                if cron.every_hour:
                    _add(out, max(c1, c2), after, until)
            elif v1:
                _add(out, c1, after, until)
            elif v2:
                _add(out, c2, after, until)
            elif not cron.every_hour:  # (spring: skipped; a fixed time runs once just after the gap)
                _add(out, local - o1, after, until)
        local += 60
    sort(out)
    var uniq = List[Int]()
    for i in range(len(out)):
        if i == 0 or out[i] != out[i - 1]:
            uniq.append(out[i])
    return uniq^


def _add(mut out: List[Int], t: Int, after: Int, until: Int):
    if t > after and t <= until:
        out.append(t)


# ---------------------------------------------------------------- the scheduler

@fieldwise_init
struct Schedule(Copyable, Movable):
    var name: String
    var tenant: String
    var cron: Cron
    var zone: Zone
    var kind: String  # the job's kind
    var extra: String  # more payload fields, as `"k": v, …` ("" none)


struct Scheduler(ImplicitlyCopyable, Movable):
    var path: String
    var pool: Pool
    var queue: Queue

    def __init__(out self, path: String, queue: Queue) raises:
        self.path = path
        self.pool = Pool.shared()
        self.queue = queue
        self.db().exec(SCHEMA)

    def db(self) raises -> Database:
        return self.pool.open(self.path)

    def due(self, s: Schedule, now: Int) raises -> Int:
        """Queues the schedule's latest due slot since it was last looked at (one job: catchup when more than one slot
        was due, after a downtime). The first look only starts the clock. 1 when a job was queued."""
        var db = self.db()
        db.begin()
        var queued = 0
        try:
            var q = db.prepare("SELECT last FROM schedule_state WHERE name = ? AND tenant = ?")
            q.bind(1, s.name)
            q.bind(2, s.tenant)
            if not q.step():
                var ins = db.prepare("INSERT INTO schedule_state(name, tenant, last) VALUES (?, ?, ?)")
                ins.bind(1, s.name)
                ins.bind(2, s.tenant)
                ins.bind(3, now)
                ins.run()
                db.commit()
                return 0
            var last = q.int(0)
            q.reset()
            if now <= last:
                db.commit()
                return 0
            var due = slots(s.cron, s.zone, last, now)
            if len(due) > 0:
                var slot = due[len(due) - 1]
                var catchup = len(due) > 1
                var key = iso_utc(slot)
                var run = db.prepare("INSERT OR IGNORE INTO schedule_runs(name, tenant, slot, at, catchup) VALUES (?, ?, ?, ?, ?)")
                run.bind(1, s.name)
                run.bind(2, s.tenant)
                run.bind(3, key)
                run.bind(4, wall_seconds())
                run.bind(5, 1 if catchup else 0)
                run.run()
                if db.changes() == 1:
                    var payload = ('{"schedule": ' + json_string(s.name) + ', "slot": ' + json_string(key) + ', "catchup": '
                                   + ("true" if catchup else "false") + ', "missed": ' + String(len(due) - 1)
                                   + (", " + s.extra if s.extra != "" else "") + "}")
                    var job = self.queue.add_in(db, s.kind, payload, s.tenant)
                    var mark = db.prepare("UPDATE schedule_runs SET job = ? WHERE name = ? AND tenant = ? AND slot = ?")
                    mark.bind(1, job)
                    mark.bind(2, s.name)
                    mark.bind(3, s.tenant)
                    mark.bind(4, key)
                    mark.run()
                    queued = 1
            var up = db.prepare("UPDATE schedule_state SET last = ? WHERE name = ? AND tenant = ?")
            up.bind(1, now)
            up.bind(2, s.name)
            up.bind(3, s.tenant)
            up.run()
            db.commit()
        except e:
            _ = db.rollback_quiet()
            raise e^
        if queued:
            self.queue.wake()
        return queued
