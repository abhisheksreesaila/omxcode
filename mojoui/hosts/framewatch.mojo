# Frames as the display shows them, counted apart from any bench (goal 79, continuation 22; off unless MOJOUI_FRAME_WATCH=1):
# a CADisplayLink of its own ticks at every refresh and looks at which IOSurface of the canvas's ring the window server
# holds; a refresh at which that changed showed a new picture. Beside it, each of the host's own frames: when the clock
# that drove it was started, when it fired, how long it took.
from mojoui.clock import now_ns


struct FrameWatch(Movable):
    var on: Bool
    var link: Int  # the CADisplayLink (0: none)
    var clock_started: Int  # when the host's frame clock was last started (ns)
    var begins: List[Int]  # each tick: when it fired
    var ends: List[Int]
    var waits: List[Int]  # from the clock's start to its first tick (ns; 0 for a tick of a clock that was running)
    var drew: List[Bool]
    var fresh: Bool  # the clock was started and hasn't ticked
    var refreshes: List[Int]
    var changes: Int  # refreshes at which the window server held a different surface
    var holding: Int

    def __init__(out self, on: Bool):
        self.on = on
        self.link = 0
        self.clock_started = 0
        self.begins = List[Int]()
        self.ends = List[Int]()
        self.waits = List[Int]()
        self.drew = List[Bool]()
        self.fresh = False
        self.refreshes = List[Int]()
        self.changes = 0
        self.holding = 0

    def started(mut self):
        if self.on:
            self.clock_started = Int(now_ns())
            self.fresh = True

    def ticked(mut self, began: Int, drew: Bool):
        if not self.on:
            return
        self.begins.append(began)
        self.ends.append(Int(now_ns()))
        self.waits.append(began - self.clock_started if self.fresh else 0)
        self.drew.append(drew)
        self.fresh = False

    def refreshed(mut self, holding: Int):
        self.refreshes.append(Int(now_ns()))
        if holding != self.holding:
            self.changes += 1
        self.holding = holding

    def clear(mut self):
        self.begins.clear()
        self.ends.clear()
        self.waits.clear()
        self.drew.clear()
        self.refreshes.clear()
        self.changes = 0

    def stalls(self) -> String:
        """Each gap between two ticks over 20 ms: at which ms, how long, and what the tick before it took (µs)."""
        var out = String("")
        for i in range(1, len(self.begins)):
            if self.begins[i] - self.begins[i - 1] > 20_000_000:
                out += " stall@" + String((self.begins[i - 1] - self.begins[0]) // 1_000_000) + ":" + String((self.begins[i] - self.begins[i - 1]) // 1_000_000) + "ms,took" + String((self.ends[i - 1] - self.begins[i - 1]) // 1000)
        return out

    def line(self) -> String:
        """What was seen since clear(): refreshes a second, new pictures a second, the host's ticks."""
        var secs = Float64(self.refreshes[len(self.refreshes) - 1] - self.refreshes[0]) / 1e9 if len(self.refreshes) > 1 else 0.0
        var took = List[Int]()
        var gaps = List[Int]()
        var waits = List[Int]()
        var empty = 0
        for i in range(len(self.begins)):
            took.append(self.ends[i] - self.begins[i])
            if i > 0:
                gaps.append(self.begins[i] - self.begins[i - 1])
            if self.waits[i] > 0:
                waits.append(self.waits[i])
            if not self.drew[i]:
                empty += 1
        var span = Float64(self.begins[len(self.begins) - 1] - self.begins[0]) / 1e9 if len(self.begins) > 1 else 0.0
        return (" drawn_hz=" + _hz(len(self.begins) - 1 - empty, span) + " refreshes=" + String(len(self.refreshes)) + " refresh_hz=" + _hz(len(self.refreshes) - 1, secs) + " new_pictures_hz=" + _hz(self.changes, secs)
                + " ticks=" + String(len(self.begins)) + " empty=" + String(empty) + " tick_gap_p50=" + _ms(gaps, 0.5) + " tick_gap_p95=" + _ms(gaps, 0.95)
                + " tick_took_p50=" + _ms(took, 0.5) + " tick_took_p95=" + _ms(took, 0.95) + " clock_starts=" + String(len(waits))
                + self.stalls() + " start_to_tick_p50=" + _ms(waits, 0.5) + " start_to_tick_p95=" + _ms(waits, 0.95))


def _ms(v_in: List[Int], q: Float64) -> String:
    if len(v_in) == 0:
        return "-"
    var v = v_in.copy()
    sort(v)
    var t = v[min(len(v) - 1, Int(q * Float64(len(v))))] // 100_000
    return String(t // 10) + "." + String(t % 10)


def _hz(n: Int, secs: Float64) -> String:
    if secs <= 0:
        return "-"
    var t = Int(Float64(n) / secs * 10 + 0.5)
    return String(t // 10) + "." + String(t % 10)
