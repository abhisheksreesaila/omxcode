# Charts drawn by Mojo on a Canvas: KPI tiles, horizontal bars, line/area, columns and histograms,
# in the plain palette's colours (mojoui.theme.Palette.plain), with axes, gridlines, labels, a highlighted selection and hit-testing.
# The same pixels on every platform.
#
#   var bars = BarChart(names, values, selected=2)
#   bars.draw(surface, font)                       # in App.draw()
#   var row = bars.hit(surface_size, scale, x, y)  # a TAP at (x, y) points → the row it landed on

from std.math import log10, floor
from mojoui.canvas import Surface, rgba
from mojoui.text import Font, REGULAR, MEDIUM, LEFT, CENTRE, RIGHT
from mojoui.draw import rect, line, circle, hline, area, with_alpha
from mojoui.theme import Palette
from mojoui.clock import trace_on

# the plain palette's tokens (light)
comptime PAGE = rgba(245, 245, 245)  # neutral background 3
comptime CARD_BG = rgba(255, 255, 255)
comptime INK = rgba(36, 36, 36)  # neutral foreground 1
comptime INK2 = rgba(97, 97, 97)  # neutral foreground 3
comptime INK3 = rgba(140, 140, 140)
comptime GRID = rgba(235, 235, 235)
comptime STROKE = rgba(224, 224, 224)
comptime BRAND = rgba(15, 108, 189)  # brand 80
comptime BRAND_DARK = rgba(17, 94, 163)
comptime BRAND_TINT = rgba(199, 224, 244)
comptime BRAND_WASH = rgba(235, 243, 252)
comptime GOOD = rgba(16, 124, 16)
comptime BAD = rgba(197, 15, 31)
# the plain palette's series (qualitative)
comptime DATA: List[UInt32] = [
    rgba(15, 108, 189), rgba(42, 160, 164), rgba(147, 115, 192), rgba(202, 80, 16), rgba(87, 129, 27),
    rgba(227, 0, 140), rgba(58, 150, 221), rgba(174, 140, 0),
]


# ---------- numbers ----------

def money(cents: Int) -> String:
    """$1.24B, $512M, $12.4K, $940 (three significant digits)."""
    var dollars = Float64(cents) / 100.0
    return "$" + compact(dollars)


def axis_money(cents: Int) -> String:
    """Money for an axis label: no trailing zeros ($5M, $2.5M, $750K)."""
    var t = money(cents)
    var unit = String("")
    var n = t.byte_length()
    if t.endswith("B") or t.endswith("M") or t.endswith("K"):
        unit = String(t[byte = n - 1 :])
        n -= 1
    if "." in t:
        while n > 0 and String(t[byte = n - 1 : n]) == "0":
            n -= 1
        if n > 0 and String(t[byte = n - 1 : n]) == ".":
            n -= 1
    return String(t[byte = : n]) + unit


def compact(x: Float64) -> String:
    var v = abs(x)
    var unit = String("")
    if v >= 1e9:
        v /= 1e9
        unit = "B"
    elif v >= 1e6:
        v /= 1e6
        unit = "M"
    elif v >= 1e4:
        v /= 1e3
        unit = "K"
    var places = 0 if v >= 100 or unit == "" else (1 if v >= 10 else 2)
    return ("-" if x < 0 else "") + fixed(v, places) + unit


def fixed(x: Float64, places: Int) -> String:
    """x with `places` decimals and thousands commas (-5.3 → "-5.3")."""
    var scale = 10**places
    var n = Int(abs(x) * Float64(scale) + 0.5)
    var sign = String("-") if x < 0 and n != 0 else String("")
    if places == 0:
        return sign + grouped(n)
    var frac = String(n % scale)
    while frac.byte_length() < places:
        frac = "0" + frac
    return sign + grouped(n // scale) + "." + frac


def grouped(n: Int) -> String:
    """12,345,678"""
    var s = String(abs(n))
    var out = String("")
    var count = 0
    for i in range(s.byte_length() - 1, -1, -1):
        out = String(s[byte=i]) + out
        count += 1
        if count % 3 == 0 and i > 0:
            out = "," + out
    return ("-" if n < 0 else "") + out


def nice_step(x: Float64) -> Float64:
    """A round gridline step for values up to x (about 4 steps): 1, 2, 2.5 or 5 × 10^k."""
    if x <= 0:
        return 1
    var raw = x / 4.0
    var p = 10.0 ** floor(log10(raw))
    for m in [1.0, 2.0, 2.5, 5.0, 10.0]:
        if m * p >= raw * 0.999:
            return m * p
    return 10 * p


def fitted_floor(values: List[Float64]) -> Float64:
    """A round number just under the lowest value, for a y axis that starts there (a series of 58.6 to 61.4: 58)."""
    if len(values) == 0:
        return 0.0
    var lo = values[0]
    var hi = values[0]
    for v in values:
        lo = min(lo, v)
        hi = max(hi, v)
    var step = nice_step(max(hi - lo, 1e-9))
    return floor(lo / step) * step


def nice_max(x: Float64) -> Float64:
    """A round number ≥ x for an axis top (1, 2, 2.5, 5 × 10^k)."""
    if x <= 0:
        return 1
    var p = 10.0 ** floor(log10(x))
    for m in [1.0, 2.0, 2.5, 5.0, 10.0]:
        if m * p >= x * 0.999:
            return m * p
    return 10 * p


# ---------- tiles ----------

struct KpiTile(Movable):
    """A headline number: label, value, a note below, and a sparkline. `accent` = the focal tile (brand blue)."""

    var label: String
    var value: String
    var note: String
    var spark: List[Float64]
    var accent: Bool

    var pal: Palette  # the colours and canvas font it draws with

    def __init__(out self, label: String, value: String, note: String, var spark: List[Float64], accent: Bool = False):
        self.label = label
        self.value = value
        self.note = note
        self.spark = spark^
        self.accent = accent
        self.pal = Palette.plain()

    def themed(var self, pal: Palette) -> Self:
        """The same chart in another palette (a theme's palette)."""
        self.pal = pal.copy()
        return self^

    def draw(self, mut s: Surface, font: Font):
        var k = s.scale
        s.fill(self.pal.page)
        var bg = self.pal.accent if self.accent else self.pal.card
        var ink = self.pal.card if self.accent else self.pal.ink
        var ink2 = with_alpha(self.pal.card, 0.82) if self.accent else self.pal.ink2
        var w = Float64(s.width)
        var h = Float64(s.height)
        # a soft drop under the tile
        rect(s, 1 * k, 2.5 * k, w - 2 * k, h - 3.5 * k, rgba(0, 0, 0, 22), 8 * k)
        rect(s, 0.5 * k, 0.5 * k, w - 1 * k, h - 2 * k, rgba(0, 0, 0, 18), 8 * k)
        rect(s, 1 * k, 1 * k, w - 2 * k, h - 3 * k, bg, 8 * k)
        var pad = 16 * k
        font.draw(s, self.label, pad, pad + 13 * k, 13 * k, ink2, self.pal.medium)
        font.draw(s, self.value, pad, pad + 13 * k + 38 * k, 34 * k, ink, self.pal.medium)
        font.draw(s, self.note, pad, h - 16 * k, 12 * k, ink2)
        # sparkline, bottom right
        var n = len(self.spark)
        if n >= 2:
            var top = 0.0
            for v in self.spark:
                top = max(top, v)
            var x0 = w * 0.55
            var x1 = w - pad
            var y1 = h - 18 * k
            var y0 = y1 - 34 * k
            var xs = List[Float64]()
            var ys = List[Float64]()
            for i in range(n):
                xs.append(x0 + (x1 - x0) * Float64(i) / Float64(n - 1))
                ys.append(y1 - (y1 - y0) * (self.spark[i] / top if top > 0 else 0))
            var line_color = self.pal.card if self.accent else self.pal.accent
            area(s, xs, ys, y1, with_alpha(line_color, 0.30), with_alpha(line_color, 0.0))
            for i in range(n - 1):
                line(s, xs[i], ys[i], xs[i + 1], ys[i + 1], 1.75 * k, line_color)


# ---------- horizontal bars ----------

struct BarChart(Movable):
    """Ranked horizontal bars with names on the left and values on the right. selected: -1 = none."""

    var names: List[String]
    var values: List[Float64]
    var labels: List[String]  # the value text for each bar
    var selected: Int
    var table: Bool  # a table: names left, values right, a slim data bar under each row
    var places: List[Float64]  # each bar's row, fractional while bars move to new places (empty: row i)

    var pal: Palette  # the colours and canvas font it draws with

    def __init__(out self, var names: List[String], var values: List[Float64], var labels: List[String], selected: Int = -1,
                 table: Bool = False):
        self.names = names^
        self.values = values^
        self.labels = labels^
        self.selected = selected
        self.table = table
        self.places = List[Float64]()
        self.pal = Palette.plain()

    def themed(var self, pal: Palette) -> Self:
        """The same chart in another palette (a theme's palette)."""
        self.pal = pal.copy()
        return self^

    def moving(var self, var places: List[Float64]) -> Self:
        """The bars at fractional rows (bars sliding to their new order)."""
        self.places = places^
        return self^

    def row_height(self, s_height: Float64) -> Float64:
        return s_height / Float64(max(len(self.names), 1))

    def draw(self, mut s: Surface, font: Font):
        var k = s.scale
        s.fill(self.pal.card)
        var n = len(self.names)
        if n == 0:
            return
        if self.table:
            self.draw_table(s, font)
            return
        var name_w = 0.0
        var value_w = 0.0
        for i in range(n):
            name_w = max(name_w, font.measure(self.names[i], 13 * k, self.pal.regular))
            value_w = max(value_w, font.measure(self.labels[i], 13 * k, self.pal.medium))
        var x0 = name_w + 12 * k
        var x1 = Float64(s.width) - value_w - 10 * k
        var top = 0.0
        for v in self.values:
            top = max(top, v)
        var rh = self.row_height(Float64(s.height))
        for i in range(n):
            var cy = rh * ((self.places[i] if i < len(self.places) else Float64(i)) + 0.5)
            var on = self.selected < 0 or self.selected == i
            var bar_w = (x1 - x0) * (self.values[i] / top if top > 0 else 0)
            var bh = min(rh * 0.62, 26 * k)
            if self.labels[i] != "—":  # (no figure at all: no bar, not a zero's sliver)
                rect(s, x0, cy - bh / 2, max(bar_w, 2 * k), bh, self.pal.accent if on else self.pal.accent_tint, 3 * k)
            var base = cy + 4.5 * k
            font.draw(s, self.names[i], x0 - 12 * k, base, 13 * k, self.pal.ink if on else self.pal.ink3, self.pal.medium if self.selected == i else self.pal.regular, RIGHT)
            font.draw(s, self.labels[i], x0 + bar_w + 8 * k, base, 13 * k, self.pal.ink if on else self.pal.ink3, self.pal.medium)

    def draw_table(self, mut s: Surface, font: Font):
        var k = s.scale
        var n = len(self.names)
        var top = 0.0
        for v in self.values:
            top = max(top, v)
        var rh = self.row_height(Float64(s.height))
        var w = Float64(s.width)
        for i in range(n):
            var y = rh * Float64(i)
            var on = self.selected < 0 or self.selected == i
            var base = y + rh / 2 + 1 * k
            font.draw(s, self.names[i], 0, base, 13 * k, self.pal.ink if on else self.pal.ink3, self.pal.medium if self.selected == i else self.pal.regular)
            font.draw(s, self.labels[i], w, base, 13 * k, self.pal.ink if on else self.pal.ink3, self.pal.medium, RIGHT)
            var bar = w * (self.values[i] / top if top > 0 else 0)
            rect(s, 0, base + 6 * k, w, 3 * k, self.pal.raised, 1.5 * k)
            rect(s, 0, base + 6 * k, bar, 3 * k, self.pal.accent if on else self.pal.accent_tint, 1.5 * k)
            if i < n - 1:
                hline(s, 0, w, y + rh - 1, self.pal.line)

    def hit(self, height_pt: Float64, y_pt: Float64) -> Int:
        """The row a tap at y (points) landed on, or -1."""
        if len(self.names) == 0 or y_pt < 0 or y_pt >= height_pt:
            return -1
        return min(Int(y_pt / (height_pt / Float64(len(self.names)))), len(self.names) - 1)


# ---------- line / area over time ----------

def thin_labels(widths: List[Float64], xs: List[Float64], gap: Float64) -> List[Int]:
    """Which x labels to draw so none touch: every k-th (the same stride throughout), and the last (drawn ending at
    the plot's edge) only if it clears the one before. widths[i] = 0: no label there."""
    var n = len(xs)
    var shown = List[Int]()
    var widest = 0.0
    for w in widths:
        widest = max(widest, w)
    var every = 1
    if n > 1 and xs[n - 1] > xs[0]:
        every = max(Int((widest + gap) / ((xs[n - 1] - xs[0]) / Float64(n - 1)) + 0.999), 1)
    var drawn_right = -1.0e18
    for i in range(n):
        if widths[i] == 0.0 or (i % every != 0 and i != n - 1):
            continue
        var last = i == n - 1 and n > 1
        var x0 = xs[i] - widths[i] if last else xs[i] - widths[i] / 2
        if x0 < drawn_right + gap:
            continue
        shown.append(i)
        drawn_right = xs[i] if last else xs[i] + widths[i] / 2
    return shown^


struct LineChart(Movable):
    """A value over time (e.g. 36 months) as a line over a fading area, with a y-axis in money."""

    var labels: List[String]  # x labels ("" = no label at that point)
    var values: List[Float64]  # in cents
    var selected: Int
    var second: List[Float64]  # an optional second series, a share 0–1 (e.g. margin), on its own right-hand axis
    var marker: Int  # an event to mark (index into values), or -1
    var marker_text: String
    var money: Bool  # the values are cents (the axis reads $5K); else plain numbers (5K)
    var xs: List[Float64]  # where each point sits along x, rising (a time in seconds); empty: 0, 1, 2…, evenly spaced
    var floor: Float64  # the y axis starts here (0 unless from_value says otherwise)
    var cursor: Float64  # a vertical cursor at this x value (with_cursor), in the units of xs (or point numbers)
    var has_cursor: Bool

    var pal: Palette  # the colours and canvas font it draws with

    def __init__(out self, var labels: List[String], var values: List[Float64], selected: Int = -1):
        self.labels = labels^
        self.values = values^
        self.selected = selected
        self.money = True
        self.second = List[Float64]()
        self.marker = -1
        self.marker_text = ""
        self.xs = List[Float64]()
        self.floor = 0.0
        self.cursor = 0.0
        self.has_cursor = False
        self.pal = Palette.plain()

    def with_second(var self, var values: List[Float64]) -> Self:
        """A second line (a share 0–1, e.g. margin) on its own percent axis at the right."""
        self.second = values^
        return self^

    def numbers(var self, money: Bool) -> Self:
        """Whether the values are money (cents, the axis in $) or plain numbers."""
        self.money = money
        return self^

    def axis_label(self, v: Float64) -> String:
        """An axis step: money without trailing zeros ($2.5M), or a plain number the same way (2.5M, 750K, 40)."""
        if self.money:
            return axis_money(Int(v))
        var t = compact(v)
        var unit = String("")
        var n = t.byte_length()
        if t.endswith("B") or t.endswith("M") or t.endswith("K"):
            unit = String(t[byte = n - 1 :])
            n -= 1
        if "." in String(t[byte = : n]):
            while n > 0 and String(t[byte = n - 1 : n]) == "0":
                n -= 1
            if n > 0 and String(t[byte = n - 1 : n]) == ".":
                n -= 1
        return String(t[byte = : n]) + unit

    def with_marker(var self, index: Int, text: String) -> Self:
        """A vertical line at an event (e.g. "Jul 14 · rate table v7")."""
        self.marker = index
        self.marker_text = text
        return self^

    def with_x(var self, var xs: List[Float64]) -> Self:
        """Places the points by these x values (rising, one per point: seconds into a recording) instead of evenly."""
        self.xs = xs^
        return self^

    def from_value(var self, floor: Float64) -> Self:
        """Starts the y axis at `floor` instead of 0 (a flight's altitude of 58–62 m fills the chart, not its top edge)."""
        self.floor = floor
        return self^

    def fitted(var self) -> Self:
        """The y axis starts at a round number just under the lowest value."""
        self.floor = fitted_floor(self.values)
        return self^

    def with_cursor(var self, x: Float64) -> Self:
        """A vertical cursor with a dot on the line at x (in the units of the points' x values): the playhead of a recording.
        The chart prints `CURSOR: t=…` (3 decimals) each time it draws it, when tracing (MOJOUI_TRACE or MOJOUI_TEST)."""
        self.cursor = x
        self.has_cursor = True
        return self^

    def themed(var self, pal: Palette) -> Self:
        """The same chart in another palette (a theme's palette)."""
        self.pal = pal.copy()
        return self^

    def x_first(self) -> Float64:
        if len(self.xs) > 0:
            return self.xs[0]
        return 0.0

    def x_last(self) -> Float64:
        if len(self.xs) > 0:
            return self.xs[len(self.xs) - 1]
        return Float64(max(len(self.values) - 1, 1))

    def x_pixel(self, x: Float64, left: Float64, right: Float64) -> Float64:
        """The pixel column of the x value `x` (clamped to the plot)."""
        var span = max(self.x_last() - self.x_first(), 1e-12)
        return left + (right - left) * min(max((x - self.x_first()) / span, 0.0), 1.0)

    def x_value(self, pixel: Float64, left: Float64, right: Float64) -> Float64:
        """The x value under pixel column `pixel` (clamped to the plot): x_pixel's inverse."""
        var f = min(max((pixel - left) / max(right - left, 1e-9), 0.0), 1.0)
        return self.x_first() + f * (self.x_last() - self.x_first())

    def axis_steps(self) -> Tuple[Float64, Int]:
        """The gridline step and how many steps the y axis climbs from its floor."""
        var span = max(self.max_value() - self.floor, 0.0)
        var step = nice_step(span)
        return (step, max(Int(span / step + 0.999), 1))

    def plot_box(self, w: Float64, h: Float64, k: Float64, font: Font) -> SIMD[DType.float64, 4]:
        """(left, top, right, bottom) of the plotting area, in pixels."""
        var axis = self.axis_steps()
        var step = axis[0]
        var widest = 0.0  # (every step's label: "1.5M" is wider than the top's "2M")
        var steps = axis[1]
        for g in range(steps + 1):
            widest = max(widest, font.measure(self.axis_label(self.floor + step * Float64(g)), 12 * k, self.pal.regular))
        var axis_w = widest + 10 * k
        var right_w = (font.measure("100%", 12 * k, self.pal.regular) + 12 * k) if len(self.second) > 1 else 8 * k
        return SIMD[DType.float64, 4](axis_w, 10 * k + (16 * k if self.marker >= 0 else 0.0), w - right_w, h - 26 * k)

    def max_value(self) -> Float64:
        var top = 0.0
        for v in self.values:
            top = max(top, v)
        return top

    def draw(self, mut s: Surface, font: Font):
        var k = s.scale
        s.fill(self.pal.card)
        var n = len(self.values)
        if n < 2:
            return
        var box = self.plot_box(Float64(s.width), Float64(s.height), k, font)
        var left = box[0]
        var top = box[1]
        var right = box[2]
        var bottom = box[3]
        var axis = self.axis_steps()
        var step = axis[0]
        var lines = axis[1]
        var axis_top = step * Float64(lines)
        for g in range(lines + 1):  # gridlines and y labels at round steps
            var y = bottom - (bottom - top) * Float64(g) / Float64(lines)
            hline(s, left, right, y, self.pal.line if g > 0 else self.pal.line_strong)
            font.draw(s, self.axis_label(self.floor + step * Float64(g)), left - 8 * k, y + 4 * k, 12 * k, self.pal.ink2, self.pal.regular, RIGHT)
        var xs = List[Float64]()
        var ys = List[Float64]()
        for i in range(n):
            var at = Float64(i)
            if len(self.xs) == n:
                at = self.xs[i]
            xs.append(self.x_pixel(at, left, right))
            ys.append(bottom - (bottom - top) * (self.values[i] - self.floor) / axis_top)
        var widths = List[Float64]()  # x labels: every k-th one, so none touch (24 months: Jan, Apr, Jul… on a small chart)
        for i in range(n):
            widths.append(font.measure(self.labels[i], 12 * k, self.pal.regular) if self.labels[i] != "" else 0.0)
        for i in thin_labels(widths, xs, 8 * k):
            font.draw(s, self.labels[i], xs[i], bottom + 18 * k, 12 * k, self.pal.ink2, self.pal.regular, RIGHT if i == n - 1 and n > 1 else CENTRE)
        area(s, xs, ys, bottom, with_alpha(self.pal.accent, 0.22), with_alpha(self.pal.accent, 0.0))
        for i in range(n - 1):
            line(s, xs[i], ys[i], xs[i + 1], ys[i + 1], 2.25 * k, self.pal.accent)
        if len(self.second) == n:  # the share, on its own axis (rounded to whole percent steps)
            var lo = 1.0
            var hi = 0.0
            for v in self.second:
                lo = min(lo, v)
                hi = max(hi, v)
            lo = Float64(Int(lo * 100.0 - 1)) / 100.0
            hi = Float64(Int(hi * 100.0 + 2)) / 100.0
            var col = self.pal.data(3)
            var prev_y = 0.0
            for i in range(n):
                var y2 = bottom - (bottom - top) * (self.second[i] - lo) / max(hi - lo, 0.0001)
                if i > 0:
                    line(s, xs[i - 1], prev_y, xs[i], y2, 2 * k, col)
                prev_y = y2
            for g in range(3):
                var share = lo + (hi - lo) * Float64(g) / 2.0
                var gy = bottom - (bottom - top) * Float64(g) / 2.0
                font.draw(s, String(Int(share * 100.0 + 0.5)) + "%", right + 6 * k, gy + 4 * k, 12 * k, col, self.pal.regular)
        if 0 <= self.marker < n:  # an event, marked across the plot
            var mx = xs[self.marker]
            var dash = top
            while dash < bottom:
                line(s, mx, dash, mx, min(dash + 4 * k, bottom), 1.5 * k, self.pal.warn)
                dash += 8 * k
            var tw = font.measure(self.marker_text, 11.5 * k, self.pal.medium)
            var tx = min(max(mx - tw / 2, left), right - tw)
            font.draw(s, self.marker_text, tx, top - 5 * k, 11.5 * k, self.pal.warn, self.pal.medium)
        if self.has_cursor:  # the playhead: a line across the plot and a dot where the series is at that x
            var cx = self.x_pixel(self.cursor, left, right)
            var j = 0
            while j < n - 2 and xs[j + 1] <= cx:
                j += 1
            var along = min(max((cx - xs[j]) / max(xs[j + 1] - xs[j], 1e-9), 0.0), 1.0)
            var cy = ys[j] + (ys[j + 1] - ys[j]) * along
            line(s, cx, top, cx, bottom, 1.5 * k, with_alpha(self.pal.ink, 0.7))
            circle(s, cx, cy, 6 * k, self.pal.card)
            circle(s, cx, cy, 4.5 * k, self.pal.accent)
            if trace_on():
                print("CURSOR: t=" + fixed(self.cursor, 3), flush=True)
        if 0 <= self.selected < n:
            var x = xs[self.selected]
            var y = ys[self.selected]
            line(s, x, top, x, bottom, 1 * k, with_alpha(self.pal.accent, 0.45))
            circle(s, x, y, 6 * k, self.pal.card)
            circle(s, x, y, 4.5 * k, self.pal.accent)
            var tag = money(Int(self.values[self.selected]))
            var tw = font.measure(tag, 12 * k, self.pal.medium) + 16 * k
            var tx = min(max(x - tw / 2, left), right - tw)
            var ty = max(y - 34 * k, top)
            rect(s, tx, ty, tw, 22 * k, self.pal.ink, 4 * k)
            font.draw(s, tag, tx + tw / 2, ty + 15.5 * k, 12 * k, self.pal.card, self.pal.medium, CENTRE)

    def hit(self, width_px: Float64, height_px: Float64, scale: Float64, font: Font, x_pt: Float64) -> Int:
        """The point nearest a tap at x (points), or -1 outside the plot."""
        var n = len(self.values)
        if n < 2:
            return -1
        var box = self.plot_box(width_px, height_px, scale, font)
        var x = x_pt * scale
        if x < box[0] - 12 * scale or x > box[2] + 12 * scale:
            return -1
        var i = Int((x - box[0]) / (box[2] - box[0]) * Float64(n - 1) + 0.5)
        return min(max(i, 0), n - 1)

    def value_at(self, width_px: Float64, height_px: Float64, scale: Float64, font: Font, x_pt: Float64) -> Float64:
        """The x value under a pointer at x (points), clamped to the plot: where a tap on the chart seeks a recording to."""
        var box = self.plot_box(width_px, height_px, scale, font)
        return self.x_value(x_pt * scale, box[0], box[2])


# ---------- columns and histograms ----------

struct ColumnChart(Movable):
    """Vertical bars with a label under each (categories) or under some (histogram bins).
    `gap` = space between bars as a share of each slot (small for histograms)."""

    var labels: List[String]
    var values: List[Float64]
    var top_labels: List[String]  # text above each bar ("" = none)
    var selected: Int
    var gap: Float64
    var color: UInt32

    var pal: Palette  # the colours and canvas font it draws with

    def __init__(out self, var labels: List[String], var values: List[Float64], var top_labels: List[String],
                 selected: Int = -1, gap: Float64 = 0.35, color: UInt32 = BRAND):
        self.labels = labels^
        self.values = values^
        self.top_labels = top_labels^
        self.selected = selected
        self.gap = gap
        self.color = color
        self.pal = Palette.plain()

    def themed(var self, pal: Palette) -> Self:
        """The same chart in another palette (a theme's palette)."""
        self.pal = pal.copy()
        return self^

    def draw(self, mut s: Surface, font: Font):
        var k = s.scale
        s.fill(self.pal.card)
        var n = len(self.values)
        if n == 0:
            return
        var left = 4 * k
        var right = Float64(s.width) - 4 * k
        var top = 22 * k
        var bottom = Float64(s.height) - 24 * k
        var vmax = 0.0
        for v in self.values:
            vmax = max(vmax, v)
        var slot = (right - left) / Float64(n)
        var last_label_end = -1e9
        hline(s, left, right, bottom, self.pal.line_strong)
        for i in range(n):
            var on = self.selected < 0 or self.selected == i
            var bh = (bottom - top) * (self.values[i] / vmax if vmax > 0 else 0)
            var bw = slot * (1 - self.gap)
            var x = left + slot * Float64(i) + (slot - bw) / 2
            var fill = self.color if on else self.pal.accent_tint
            rect(s, x, bottom - bh, bw, bh, fill, min(3 * k, bh / 2))
            rect(s, x, bottom - min(3 * k, bh), bw, min(3 * k, bh), fill)  # square bottoms on the axis
            if i < len(self.top_labels) and self.top_labels[i] != "":
                font.draw(s, self.top_labels[i], x + bw / 2, bottom - bh - 7 * k, 12 * k, self.pal.ink if on else self.pal.ink3, self.pal.medium, CENTRE)
            if self.labels[i] != "":
                var lw = font.measure(self.labels[i], 12 * k, self.pal.regular)
                if x + bw / 2 - lw / 2 >= last_label_end + 6 * k and x + bw / 2 + lw / 2 <= Float64(s.width) - 4 * k:  # only labels that fit
                    font.draw(s, self.labels[i], x + bw / 2, bottom + 17 * k, 12 * k, self.pal.ink2 if on else self.pal.ink3,
                              self.pal.medium if self.selected == i else self.pal.regular, CENTRE)
                    last_label_end = x + bw / 2 + lw / 2

    def hit(self, width_pt: Float64, x_pt: Float64) -> Int:
        var n = len(self.values)
        if n == 0 or x_pt < 4 or x_pt > width_pt - 4:
            return -1
        return min(Int((x_pt - 4) / ((width_pt - 8) / Float64(n))), n - 1)


# ---------- heatmap ----------

struct Heatmap(Movable):
    """Values on a rows × columns grid, each cell tinted by its value (low: the warning colour; high: the
    accent), the value written in it. For shares (margin %) or counts."""

    var rows: List[String]
    var cols: List[String]
    var values: List[Float64]  # row-major
    var percent: Bool  # values are shares 0–1
    var selected: Int  # a highlighted cell (row * len(cols) + col), or -1
    var pal: Palette

    def __init__(out self, var rows: List[String], var cols: List[String], var values: List[Float64], percent: Bool = True, selected: Int = -1):
        self.rows = rows^
        self.cols = cols^
        self.values = values^
        self.percent = percent
        self.selected = selected
        self.pal = Palette.plain()

    def themed(var self, pal: Palette) -> Self:
        self.pal = pal.copy()
        return self^

    def label_w(self, font: Font, k: Float64) -> Float64:
        var w = 0.0
        for r in self.rows:
            w = max(w, font.measure(r, 12 * k, self.pal.regular))
        return w + 12 * k

    def draw(self, mut s: Surface, font: Font):
        var k = s.scale
        s.fill(self.pal.card)
        var nr = len(self.rows)
        var nc = len(self.cols)
        if nr == 0 or nc == 0:
            return
        var lo = 1e18
        var hi = -1e18
        for v in self.values:
            lo = min(lo, v)
            hi = max(hi, v)
        var left = self.label_w(font, k)
        var head = 22 * k
        var cw = (Float64(s.width) - left) / Float64(nc)
        var ch = (Float64(s.height) - head) / Float64(nr)
        for c in range(nc):
            font.draw(s, self.cols[c], left + cw * (Float64(c) + 0.5), 15 * k, 12 * k, self.pal.ink2, self.pal.regular, CENTRE)
        for r in range(nr):
            var y = head + ch * Float64(r)
            font.draw(s, self.rows[r], left - 8 * k, y + ch / 2 + 4 * k, 12 * k, self.pal.ink2, self.pal.regular, RIGHT)
            for c in range(nc):
                var i = r * nc + c
                var v = self.values[i] if i < len(self.values) else 0.0
                var t = (v - lo) / (hi - lo) if hi > lo else 0.5
                var fill = with_alpha(self.pal.accent, 0.15 + 0.7 * t) if t >= 0.35 else with_alpha(self.pal.warn, 0.15 + 0.6 * (0.35 - t) / 0.35)
                rect(s, left + cw * Float64(c) + 2 * k, y + 2 * k, cw - 4 * k, ch - 4 * k, fill, 4 * k)
                if i == self.selected:
                    rect(s, left + cw * Float64(c) + 1 * k, y + 1 * k, cw - 2 * k, 2 * k, self.pal.ink)
                var text = (fixed(v * 100.0, 1) + "%") if self.percent else compact(v)  # (negative margins too)
                font.draw(s, text, left + cw * (Float64(c) + 0.5), y + ch / 2 + 4.5 * k, 12.5 * k, self.pal.ink, self.pal.medium, CENTRE)

    def hit(self, width_pt: Float64, height_pt: Float64, font: Font, x_pt: Float64, y_pt: Float64) -> Int:
        """The cell under a tap (row * columns + column), or -1."""
        var nr = len(self.rows)
        var nc = len(self.cols)
        if nr == 0 or nc == 0:
            return -1
        var left = self.label_w(font, 1.0)
        if x_pt < left or y_pt < 22:
            return -1
        var c = Int((x_pt - left) / ((width_pt - left) / Float64(nc)))
        var r = Int((y_pt - 22) / ((height_pt - 22) / Float64(nr)))
        if r >= nr or c >= nc:
            return -1
        return r * nc + c

