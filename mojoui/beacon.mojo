# mojoui.beacon: one dark pill that says the one thing happening now (goal 33 M5, the OMX Console's Beacon, omxqua's
# .beacon): a lead (a progress ring for a job, a live dot while models run), a label and a value in the mono. Ring draws
# the ring into a Canvas (the app's draw() calls it for the Beacon's canvas). Roles: beacon-slot, beacon, beacon-ring,
# beacon-live, beacon-label, beacon-value (a theme gives their look: themes/omxqua_kit.mojo).
#
#   Beacon("Pulling helper-7b", "35%", RING_CANVAS, version=35)          app.draw: Ring.themed(35.4, theme.look).draw(surface)

from mojoui.view import View, Text, Canvas, VStack, HStack, CENTER, START, SPACE_S
from mojoui.canvas import Surface, rgba
from mojoui.draw import line
from mojoui.theme import Look
from std.math import cos, sin, pi

comptime BEACON_BG = 0xFF0D0B0B  # #0b0b0d
comptime BEACON_INK = 0xFFF5F4F4  # #f4f4f5
comptime BEACON_QUIET = 0xFFAAA1A1  # #a1a1aa
comptime RING_TRACK = 0xFF2F2D2D  # rgb(255 255 255 / .14) over #0b0b0d, opaque (overlapping strokes must not add up)


def Beacon(label: String, value: String, ring: Int = -1, version: Int = 0, live: Bool = False, compact: Bool = False) -> View:
    """The pill in its slot at the top of a bar: a ring (`ring`: its canvas id, the app's draw() paints a Ring), else a
    live dot when `live`, then the label and the value (when there is one) (roles beacon-slot or beacon-slot-compact,
    beacon, beacon-ring, beacon-live, beacon-label, beacon-value)."""
    var items: List[View] = []
    if ring >= 0:
        items.append(Canvas(ring, version).tag("beacon-ring"))
    elif live:
        items.append(VStack(spacing=0).tag("beacon-live"))
    items.append(Text(label).tag("beacon-label"))
    if value != "":
        items.append(Text(value).tag("beacon-value"))
    var pill = HStack(items^, spacing=SPACE_S).align(CENTER).tag("beacon")
    return VStack(pill^, spacing=0).align(START).tag("beacon-slot-compact" if compact else "beacon-slot")


@fieldwise_init
struct Ring(Copyable, Movable):
    var percent: Float64  # 0–100; below 0: unknown (a quarter, as the console shows it)
    var arc: UInt32
    var track: UInt32
    var fill: UInt32  # what's behind it (the pill)

    @staticmethod
    def themed(percent: Float64, accent: UInt32) -> Ring:
        return Ring(percent, accent, RING_TRACK, BEACON_BG)

    @staticmethod
    def themed(percent: Float64, look: Look) -> Ring:
        """In the look's colours: the arc in the live dot's (role beacon-live), on the pill's (role beacon)."""
        var live = look.surface("beacon-live")
        var pill = look.surface("beacon")
        return Ring(percent, look.surfaces[live].fill if live >= 0 else 0xFF6ECF3C, RING_TRACK, look.surfaces[pill].fill if pill >= 0 else BEACON_BG)

    def draw(self, mut s: Surface):
        """A 2.5 pt ring of radius 8 in a 20 × 20 box, its arc from the top, clockwise."""
        s.fill(self.fill)
        var k = Float64(s.width) / 20.0
        var cx = Float64(s.width) / 2
        var cy = Float64(s.height) / 2
        var r = 8.0 * k
        var w = 2.5 * k
        var frac = 0.25 if self.percent < 0 else min(max(self.percent / 100.0, 0.0), 1.0)
        comptime N = 96
        for arc in range(2):  # (the whole track first, then the arc over it)
            for i in range(N):
                var on = Float64(i + 1) <= frac * N + 0.5
                if arc == 1 and not on:
                    break
                var a0 = 2 * pi * Float64(i) / N - pi / 2
                var a1 = 2 * pi * Float64(i + 1) / N - pi / 2
                line(s, cx + r * cos(a0), cy + r * sin(a0), cx + r * cos(a1), cy + r * sin(a1), w, self.arc if arc == 1 else self.track)
