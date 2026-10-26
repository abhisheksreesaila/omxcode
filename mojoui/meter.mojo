# mojoui.meter: how full something is (goal 33 M7, D-415): a meter (a label, a bar, a figure, in a row), and a usage
# bar (parts of a whole side by side on a track: this one in its colour, the others faint, the rest free) with the
# figures under it. Sizes and colours come from the theme (roles; Usage.themed reads the look).
#
#   Meter("GPU memory", 38, False, "9.1 / 24 GB")
#   UsageBar(FIT_CANVAS, version, ["this 3.1 GB", "others 0 GB", "free 14.9 GB of 24 GB"])     app.draw: Usage.themed(3.1 / 24, 0, look).draw(surface)

from mojoui.view import View, Text, Canvas, HStack, VStack, Spacer, ProgressBar, CENTER, START, SPACE_S, SPACE_M
from mojoui.canvas import Surface
from mojoui.draw import rect
from mojoui.theme import Look, Palette, mix
from mojoui.marks import SignalDot


def Meter(label: String, percent: Int, bad: Bool, figure: String) -> View:
    """A label, a bar `percent` full (the bad colour when `bad`) and a figure, in a row (roles meter, meter-label,
    meter-bar, meter-bar-bad, meter-figure)."""
    return HStack(Text(label).tag("meter-label"), ProgressBar(min(max(percent, 0), 100)).grow().tag("meter-bar-bad" if bad else "meter-bar"),
                  Text(figure).tag("meter-figure"), spacing=SPACE_M).align(CENTER).fill().tag("meter")


def UsageBar(canvas: Int, version: Int, figures: List[String]) -> View:
    """A usage bar (a Canvas the app's draw() paints with a Usage) over its figures spread across (roles usage-bar,
    usage-figures)."""
    var caps: List[View] = []
    for k in range(len(figures)):
        if k > 0:
            caps.append(Spacer())
        caps.append(Text(figures[k]))
    return VStack(Canvas(canvas, version).fill().tag("usage-bar"), HStack(caps^, spacing=SPACE_S).fill().tag("usage-figures"),
                  spacing=SPACE_S).align(START).fill()


@fieldwise_init
struct Usage(Copyable, Movable):
    var mine: Float64  # this one's share, 0–1
    var others: Float64  # everyone else's, 0–1 (drawn first, faint)
    var color: UInt32
    var other_color: UInt32
    var track: UInt32
    var fill: UInt32  # what's behind the bar

    @staticmethod
    def themed(mine: Float64, others: Float64, look: Look, p: Palette, signal: Int = 1) -> Usage:
        """This one in the look's `signal` colour (role signal-dot-<signal>; else the palette's first series), the others
        in the faint ink, on the state layer over the raised surface."""
        var k = look.surface("signal-dot-" + String(signal))
        var c = look.surfaces[k].fill if k >= 0 else p.series[0]
        return Usage(mine, others, c, p.ink3, mix(p.raised, p.ink, 0.08), p.raised)

    def draw(self, mut s: Surface):
        """The track with round ends, the others from the left, then this one."""
        s.fill(self.fill)
        var w = Float64(s.width)
        var h = Float64(s.height)
        rect(s, 0, 0, w, h, self.track, h / 2)
        var x = 0.0
        if self.others > 0:
            rect(s, 0, 0, w * self.others, h, self.other_color, 0)
            x = w * self.others
        if self.mine > 0:
            rect(s, x, 0, w * self.mine, h, self.color, 0)


def ChartRow(signal: Int, label: String, bar: View, figure: String, strong: Bool = False, figure_strong: Bool = False, compact: Bool = False) -> View:
    """One bar of a bar chart: its label after a signal dot (strong: this one), the bar (a BarView), the figure (roles
    chart-row, chart-label (chart-label-compact): its column's width, chart-name(-strong), chart-figure(-strong): the
    figure's column)."""
    var label_view = HStack(SignalDot(signal), Text(label).tag("chart-name-strong" if strong else "chart-name"), spacing=SPACE_S).align(CENTER).justify(START).tag("chart-label-compact" if compact else "chart-label")
    return HStack(label_view^, bar.copy(), Text(figure).tag("chart-figure-strong" if figure_strong else "chart-figure"), spacing=SPACE_M).align(CENTER).fill().tag("chart-row")


def ShareBar(percent: Int, mine: Bool = False) -> View:
    """A bar's share of the largest, on a track (a ProgressBar: every host's own); `mine`: this one, ringed (roles
    share-bar, share-bar-mine)."""
    return ProgressBar(min(max(percent, 0), 100)).grow().tag("share-bar-mine" if mine else "share-bar")
