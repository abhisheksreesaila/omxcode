# mojoui.numformat: how a column's values read (Numbers' "Data Format"): number, currency, percent, compact,
# dates. One format per column, never per cell (docs/plans/formatting.md): it's applied only to what's on screen,
# so it costs nothing on 100M rows. Values arrive as the engine stores them: integers scaled by 10^scale.

from std.math import floor

comptime AUTO = 0  # as the column's type says (the engine's own text)
comptime NUMBER = 1  # 1,234.50
comptime CURRENCY = 2  # $1,234.50
comptime PERCENT = 3  # 0.364 → 36.4%
comptime COMPACT = 4  # 1.2M, $3.4K
comptime DATE_LONG = 5  # 9 Oct 2025
comptime DATE_MONTH = 6  # Oct 2025
comptime DATE_ISO = 7  # 2025-10-09

comptime NUMBER_STYLES: List[String] = ["Automatic", "Number", "Currency", "Percent", "Compact (1.2M)"]
comptime DATE_STYLES: List[String] = ["Automatic", "9 Oct 2025", "Oct 2025", "2025-10-09"]
comptime MONTHS: List[String] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


@fieldwise_init
struct ColumnFormat(Copyable, Movable):
    var style: Int  # AUTO, NUMBER, CURRENCY, PERCENT, COMPACT, DATE_*
    var decimals: Int  # digits after the point (-1: the column's own)
    var thousands: Bool  # 1,234 rather than 1234
    var parens: Bool  # negatives as (1,234) rather than −1,234
    var symbol: String  # currency symbol

    @staticmethod
    def auto() -> ColumnFormat:
        return ColumnFormat(AUTO, -1, True, False, "$")

    def is_auto(self) -> Bool:
        return self.style == AUTO

    def valid(self) -> Bool:
        """A format read from a file is one this code can draw."""
        return AUTO <= self.style <= DATE_ISO and -1 <= self.decimals <= 9 and self.symbol.byte_length() <= 8

    def summary(self) -> String:
        """What it does, in words (the inspector, tests)."""
        var names = materialize[NUMBER_STYLES]()
        if self.style < AUTO or self.style > DATE_ISO:
            return "Automatic"
        if self.style >= DATE_LONG:
            return "Date " + materialize[DATE_STYLES]()[self.style - DATE_LONG + 1]
        return names[self.style] + (", " + String(self.decimals) + " decimals" if self.decimals >= 0 else "")


def pow10(n: Int) -> Int64:
    var p = Int64(1)
    for _ in range(n):
        p *= 10
    return p


def group_digits(digits: String) -> String:
    var out = String("")
    var n = digits.byte_length()
    for i in range(n):
        if i > 0 and (n - i) % 3 == 0:
            out += ","
        out += String(digits[byte = i : i + 1])
    return out


def fixed(v: Int64, scale: Int, decimals: Int, thousands: Bool) -> String:
    """|v| / 10^scale with `decimals` digits (rounded half away from zero), no sign."""
    var a = v if v >= 0 else -v
    var d = min(decimals if decimals >= 0 else scale, 9)
    while d > scale and a > Int64(9_000_000_000_000_000_000) // pow10(d - scale):  # (more places would overflow: fewer)
        d -= 1
    var scaled: Int64
    if d >= scale:
        scaled = a * pow10(d - scale)
    else:
        var div = pow10(scale - d)
        scaled = (a + div // 2) // div
    var p = pow10(d)
    var whole = String(scaled // p)
    var text = group_digits(whole) if thousands else whole
    if d > 0:
        var frac = String(scaled % p)
        while frac.byte_length() < d:
            frac = "0" + frac
        text += "." + frac
    return text


def signed(text: String, negative: Bool, parens: Bool) -> String:
    var zero = True  # (−0.00 reads as 0.00)
    for ch in text.codepoint_slices():
        var c = String(ch)
        if c >= "1" and c <= "9":
            zero = False
    if not negative or zero:
        return text
    return "(" + text + ")" if parens else "−" + text


def compact_text(v: Int64, scale: Int, decimals: Int) -> String:
    var x = Float64(v if v >= 0 else -v) / Float64(pow10(scale))
    var unit = String("")
    if x >= 1e9:
        x /= 1e9
        unit = "B"
    elif x >= 1e6:
        x /= 1e6
        unit = "M"
    elif x >= 1e3:
        x /= 1e3
        unit = "K"
    var d = decimals if decimals >= 0 else (1 if unit != "" else 0)
    var tenth = Int64(x * Float64(pow10(d)) + 0.5)
    if tenth >= 1000 * pow10(d) and unit != "B":  # 999,950 → 1,000.0K reads as 1.0M (the rounding carries)
        var units: List[String] = ["", "K", "M", "B"]
        var next = 1
        for k in range(len(units)):
            if units[k] == unit:
                next = k + 1
        tenth = (tenth + 500) // 1000
        unit = units[next]
    return fixed(tenth, d, d, True) + unit


def civil(days: Int) -> Tuple[Int, Int, Int]:
    """Days since 1970-01-01 → (year, month, day)."""
    var z = days + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + (3 if mp < 10 else -9)
    return (y + (1 if m <= 2 else 0), m, d)


def format_number(v: Int64, scale: Int, f: ColumnFormat) -> String:
    """A number column's value (scaled by 10^scale) in format f."""
    var neg = v < 0
    if f.style == PERCENT:
        var d = f.decimals if f.decimals >= 0 else max(scale - 2, 0)
        var text = fixed(v, scale - 2, d, f.thousands) if scale >= 2 else fixed(v * pow10(2 - scale), 0, d, f.thousands)
        return signed(text + "%", neg, f.parens)
    if f.style == COMPACT:
        return signed(compact_text(v, scale, f.decimals), neg, f.parens)
    if f.style == CURRENCY:
        var d = f.decimals if f.decimals >= 0 else 2
        return signed(f.symbol + fixed(v, scale, d, f.thousands), neg, f.parens)
    return signed(fixed(v, scale, f.decimals, f.thousands), neg, f.parens)


def two(n: Int) -> String:
    return ("0" if n < 10 else "") + String(n)


def date_text(days: Int64) -> String:
    var ymd = civil(Int(days))
    return String(ymd[0]) + "-" + two(ymd[1]) + "-" + two(ymd[2])


def parse_decimal(text: String, scale: Int) raises -> Int64:
    """"12.5" with scale 2 → 1250; rounds extra digits away. Reads what the formats print back: "$1,234.50",
    "−3.0" (a real minus sign), "(1,234)" (negative), "€9", "36.4%" (0.364)."""
    var t = String(text.strip())
    for sym in ["$", "€", "£", "₹", ",", " "]:
        t = t.replace(sym, "")
    t = t.replace("−", "-")
    var neg = False
    if t.startswith("(") and t.endswith(")"):
        var inner = String(t[byte = 1 : t.byte_length() - 1])
        t = inner
        neg = True
    var percent = t.endswith("%")
    if percent:
        var number = String(t[byte = : t.byte_length() - 1])
        t = number
    if t.startswith("-"):
        neg = not neg
        var rest = String(t[byte=1:])
        t = rest
    if percent:  # 36.4% is 0.364: two more places, then shift
        var scaled = parse_decimal(t, scale + 2)  # (36.4 at scale+2 places, ÷ 10^4 = 0.364 at scale places)
        var div = pow10(4)
        var v = (scaled + div // 2) // div
        return -v if neg else v
    var dot = t.find(".")
    var whole = t if dot < 0 else String(t[byte=:dot])
    var frac = String("") if dot < 0 else String(t[byte=dot + 1:])
    for c in (whole + frac).codepoint_slices():
        if not (ord("0") <= ord(c) <= ord("9")):
            raise Error("not a number: '" + text + "'")
    var v = (Int64(Int(whole)) if whole != "" else 0) * pow10(scale)
    var f: Int64 = 0
    var digits = 0
    for c in frac.codepoint_slices():
        if digits < scale:
            f = f * 10 + Int64(ord(c) - ord("0"))
            digits += 1
    for _ in range(scale - digits):
        f *= 10
    v += f
    return -v if neg else v


def decimal_text(v: Int64, scale: Int) -> String:
    if scale == 0:
        return String(v)
    var p = pow10(scale)
    var a = v if v >= 0 else -v
    var frac = String(a % p)
    while frac.byte_length() < scale:
        frac = "0" + frac
    return ("-" if v < 0 else "") + String(a // p) + "." + frac


def format_date(days: Int64, f: ColumnFormat) -> String:
    var ymd = civil(Int(days))
    var months = materialize[MONTHS]()
    if f.style == DATE_LONG:
        return String(ymd[2]) + " " + months[ymd[1] - 1] + " " + String(ymd[0])
    if f.style == DATE_MONTH:
        return months[ymd[1] - 1] + " " + String(ymd[0])
    return String(ymd[0]) + "-" + ("0" if ymd[1] < 10 else "") + String(ymd[1]) + "-" + ("0" if ymd[2] < 10 else "") + String(ymd[2])


# ---------- a measured value as people read it (en-US; an app's numbers, not a column's) ----------


def rounded(v: Float64, digits: Int) -> Float64:
    """v rounded half away from zero to `digits` decimals (JavaScript's Math.round(v * 10^d) / 10^d for v ≥ 0)."""
    var m = 1.0
    for _ in range(digits):
        m *= 10
    return floor(abs(v) * m + 0.5) / m * (1.0 if v >= 0 else -1.0)


def round1(v: Float64) -> Float64:
    return rounded(v, 1)


def grouped(n: Int) -> String:
    """A whole number with en-US thousands commas: 1234567 → "1,234,567"."""
    return ("-" if n < 0 else "") + group_digits(String(abs(n)))


def en_number(v: Float64, digits: Int = 0) -> String:
    """toLocaleString("en-US", {maximumFractionDigits: digits}): thousands with commas, no trailing zeros
    (1234.5, 2 → "1,234.5"; 0.04, 1 → "0"; -2.25, 1 → "-2.3")."""
    var r = rounded(v, digits)
    var whole = Int(floor(abs(r)))
    var frac = abs(r) - Float64(whole)
    var out = grouped(whole)
    if digits > 0:
        var m = 1
        for _ in range(digits):
            m *= 10
        var f = Int(floor(frac * Float64(m) + 0.5))
        if f >= m:
            out = grouped(whole + 1)
            f = 0
        if f > 0:
            var t = String(f)
            while t.byte_length() < digits:
                t = "0" + t
            while t.endswith("0"):
                var shorter = String(t[byte = : t.byte_length() - 1])
                t = shorter^
            out += "." + t
    return ("-" if r < 0 else "") + out


def duration_short(seconds: Float64) -> String:
    """A duration in its largest whole unit: "45s", "5m", "1h", "1m 5s"."""
    var sec = Int(floor(seconds + 0.5))
    if sec >= 3600 and sec % 3600 == 0:
        return String(sec // 3600) + "h"
    if sec >= 60 and sec % 60 == 0:
        return String(sec // 60) + "m"
    if sec >= 60:
        return String(sec // 60) + "m " + String(sec % 60) + "s"
    return String(sec) + "s"


def byte_size(bytes: Float64) -> String:
    """A size in decimal units as a file manager shows it: "988 MB", "2.5 GB", "–" when unknown (0 or less)."""
    if bytes <= 0:
        return "–"
    var mb = max(1, Int(floor(bytes / 1e6 + 0.5)))
    if mb >= 1000:
        var tenths = Int(floor(bytes / 1e8 + 0.5))
        return String(tenths // 10) + "." + String(tenths % 10) + " GB"
    return String(mb) + " MB"


def utc_date_time(ts: Float64) -> String:
    """Seconds since 1970 as an en-US month, day and 24-hour time in UTC: "Oct 25, 21:34"."""
    var secs = Int(floor(ts))
    var days = secs // 86400
    var rem = secs - days * 86400
    var ymd = civil(days)
    return materialize[MONTHS]()[ymd[1] - 1] + " " + String(ymd[2]) + ", " + two(rem // 3600) + ":" + two((rem % 3600) // 60)
