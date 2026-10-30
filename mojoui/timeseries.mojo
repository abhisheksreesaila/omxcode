# mojoui.timeseries: numbers recorded over time (a flight's telemetry at 10 Hz, a sensor log), looked up by time. A generic
# component (goal 39 M2): the Player's time cursor on a line chart and the readout of the row under it both ask it.
#
#   var ts = TimeSeries(times)                  # seconds, rising
#   ts.add("alt_m", altitudes)                  # a column per name, one value per time
#   var row = ts.row_at(12.46)                  # the row nearest in time (clamped to the first and last)
#   ts.value("alt_m", row)  ts.column("alt_m")  # one number; a whole column (a chart's points)
#   ts.at("alt_m", 12.46)                       # linearly interpolated between the rows either side (clamped)
#
# It holds no file format: examples/media reads a CSV with mojoui.csvio and fills one.


struct TimeSeries(Copyable, Movable):
    var times: List[Float64]
    var names: List[String]
    var columns: List[List[Float64]]

    def __init__(out self, var times: List[Float64]):
        self.times = times^
        self.names = List[String]()
        self.columns = List[List[Float64]]()

    def rows(self) -> Int:
        return len(self.times)

    def add(mut self, name: String, var values: List[Float64]):
        """A column called `name`: one value per time (a shorter one is padded with its last value, a longer one cut)."""
        while len(values) < len(self.times):
            values.append(values[len(values) - 1] if len(values) > 0 else 0.0)
        while len(values) > len(self.times):
            _ = values.pop()
        self.names.append(name)
        self.columns.append(values^)

    def index(self, name: String) -> Int:
        """The column called `name` (-1: none)."""
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def column(self, name: String) -> List[Float64]:
        var i = self.index(name)
        return self.columns[i].copy() if i >= 0 else List[Float64]()

    def row_at(self, t: Float64) -> Int:
        """The row whose time is nearest `t` (-1 when the series is empty)."""
        var n = len(self.times)
        if n == 0:
            return -1
        var lo = 0
        var hi = n - 1
        while lo < hi:  # the first row at or after t
            var mid = (lo + hi) // 2
            if self.times[mid] < t:
                lo = mid + 1
            else:
                hi = mid
        if lo > 0 and t - self.times[lo - 1] <= self.times[lo] - t:
            return lo - 1
        return lo

    def value(self, name: String, row: Int) -> Float64:
        """Column `name` at `row` (0 when either is missing)."""
        var i = self.index(name)
        if i < 0 or row < 0 or row >= len(self.times):
            return 0.0
        return self.columns[i][row]

    def bracket(self, t: Float64) -> Tuple[Int, Int, Float64]:
        """The rows either side of `t` and how far t lies from the first to the second (0–1), clamped to the ends."""
        var n = len(self.times)
        if n == 0:
            return (-1, -1, 0.0)
        if n == 1 or t <= self.times[0]:
            return (0, 0, 0.0)
        if t >= self.times[n - 1]:
            return (n - 1, n - 1, 0.0)
        var lo = 0
        var hi = n - 1
        while hi - lo > 1:  # times[lo] <= t < times[hi]
            var mid = (lo + hi) // 2
            if self.times[mid] <= t:
                lo = mid
            else:
                hi = mid
        var span = self.times[hi] - self.times[lo]
        return (lo, hi, (t - self.times[lo]) / span if span > 0 else 0.0)

    def at(self, name: String, t: Float64) -> Float64:
        """Column `name` at time `t`, linearly interpolated between the rows either side (0 when the column is missing)."""
        var i = self.index(name)
        var b = self.bracket(t)
        if i < 0 or b[0] < 0:
            return 0.0
        ref c = self.columns[i]
        return c[b[0]] + (c[b[1]] - c[b[0]]) * b[2]


def metric_label(name: String) -> String:
    """A column's name as a person says it: alt_m → Altitude, speed_ms → Speed, battery_pct → Battery, else its words."""
    if name == "alt_m":
        return String("Altitude")
    if name.startswith("speed"):
        return String("Speed")
    if name.startswith("battery"):
        return String("Battery")
    if name == "heading_deg":
        return String("Heading")
    var words = name.replace("_", " ")
    if words.byte_length() == 0:
        return words^
    return String(words[byte=0:1]).upper() + String(words[byte=1:])


def metric_unit(name: String) -> String:
    if name.endswith("_m"):
        return String("m")
    if name.endswith("_ms"):
        return String("m/s")
    if name.endswith("_pct"):
        return String("%")
    if name.endswith("_deg"):
        return String("°")
    return String("")
