# mojoui.timeseries: numbers recorded over time (a flight's telemetry at 10 Hz, a sensor log), looked up by time. A generic
# component (goal 39 M2): the Player's time cursor on a line chart and the readout of the row under it both ask it.
#
#   var ts = TimeSeries(times)                  # seconds, rising
#   ts.add("alt_m", altitudes)                  # a column per name, one value per time
#   var row = ts.row_at(12.46)                  # the row nearest in time (clamped to the first and last)
#   ts.value("alt_m", row)  ts.column("alt_m")  # one number; a whole column (a chart's points)
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
