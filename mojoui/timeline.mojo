# mojoui.timeline (goal 33 M4, D-357): the Add screen's stage timeline (blade-add.js, "the ring timeline"): one row
# per stage, a ring on the left (empty while pending, spinning while running, a tick when done, a cross when it failed
# or was cancelled) joined to the next by a rail that turns green once the stage is done; the stage's name, its elapsed
# time on the right ("4.2s", "1m 03s", exactly as the original writes it), a detail line, a progress bar while it runs,
# and the CLI twin ("$ mxc pull …"). Built from existing views; its look comes from roles (timeline_roles()).
#
#   Timeline([Stage("Check hardware", STAGE_DONE, 1200, "RTX 4090 · 24 GB", "mxc search qwen"),
#             Stage("Fetch the model", STAGE_RUNNING, 4200, "1.2 GB of 3 GB", "mxc pull qwen", 40),
#             Stage("Compile graph")])

from std.math import fma, floor
from mojoui.view import View, Text, Icon, VStack, HStack, ProgressBar, BODY, CAPTION, TONE_WARN, START, CENTER, STRETCH
from mojoui.theme import Palette, Surface, Shadow

comptime STAGE_PENDING = 0
comptime STAGE_RUNNING = 1  # the active one
comptime STAGE_DONE = 2
comptime STAGE_FAILED = 3
comptime STAGE_CANCELLED = 4

comptime RING = 24  # .ring: 24 × 24, a 2 px border
comptime RAIL = 2  # .stg::before: 2 px wide, from 36 below a row's top to 10 into the next
comptime ROW_PAD = 10  # .stg: padding 10px 0
comptime ELAPSED_W = 46  # .el: min-width 46px


struct Stage(Copyable, Movable):
    var label: String
    var status: Int  # STAGE_PENDING … STAGE_CANCELLED
    var elapsed_ms: Float64  # < 0: not started (no time shown)
    var detail: String
    var twin: String  # the CLI command that does the same ("" for none)
    var percent: Int  # a running stage's progress 0–100, < 0 for none

    def __init__(out self, label: String, status: Int = STAGE_PENDING, elapsed_ms: Float64 = -1, detail: String = "",
                 twin: String = "", percent: Int = -1):
        self.label = label
        self.status = status
        self.elapsed_ms = elapsed_ms
        self.detail = detail
        self.twin = twin
        self.percent = percent


def status_name(status: Int) -> String:
    """The original's class for a stage: pending, running, done, failed, cancelled."""
    if status == STAGE_RUNNING:
        return "running"
    if status == STAGE_DONE:
        return "done"
    if status == STAGE_FAILED:
        return "failed"
    if status == STAGE_CANCELLED:
        return "cancelled"
    return "pending"


def stage_elapsed(start_ms: Float64, end_ms: Float64, status: Int, now_ms: Float64) -> Float64:
    """setupStages' elapsedOf: end − start, running stages counting to now; -1 when it hasn't started (start < 0) or
    has no end yet and isn't running (end < 0)."""
    if start_ms < 0:
        return -1
    var end = end_ms if end_ms >= 0 else (now_ms if status == STAGE_RUNNING else -1.0)
    if end < 0:
        return -1
    return max(0.0, end - start_ms)


def _tenths(x: Float64) -> Int:
    """JavaScript's x.toFixed(1) as a whole number of tenths: the nearest to x's exact value (the larger on a tie),
    so 0.15 (really 0.1499…) is 0.1 and 0.25 is 0.3, as the browser writes them. fma keeps each comparison exact."""
    var k = Int(floor(x * 10.0))
    if fma(x, 10.0, -Float64(k)) < 0:
        k -= 1
    elif fma(x, 10.0, -Float64(k + 1)) >= 0:
        k += 1
    return k + 1 if fma(x, 20.0, -Float64(2 * k + 1)) >= 0 else k


def elapsed_text(ms: Float64) -> String:
    """blade-add.js's elapsedText: "" when there is no time (ms < 0); "4.2s" under a minute; then "1m 03s"."""
    if ms < 0:
        return ""
    if ms < 60000:
        var t = _tenths(ms / 1000.0)
        return String(t // 10) + "." + String(t % 10) + "s"
    var s = Int(floor(ms / 1000.0))
    var sec = s % 60
    return String(s // 60) + "m " + ("0" if sec < 10 else "") + String(sec) + "s"


def _bar(height: Int, tag: String) -> View:
    """A piece of rail: an empty column RAIL wide its role colours."""
    var v = VStack(List[View](), spacing=0).width(RAIL)
    if height > 0:
        v = v^.height(height)
    else:
        v = v^.grow()
    return v^.tag(tag)


def _rail_tag(status: Int) -> String:
    return "tl-rail-done" if status == STAGE_DONE else "tl-rail"


def ring(status: Int) -> View:
    """The ring: tagged tl-ring-<status>; a tick when done, a cross when failed or cancelled."""
    var inside = List[View]()
    if status == STAGE_DONE:
        inside.append(Icon("check", 13).tag("tl-ring-icon"))
    elif status == STAGE_FAILED or status == STAGE_CANCELLED:
        inside.append(Icon("close", 13).tag("tl-ring-icon"))
    return VStack(inside^, spacing=0).width(RING).height(RING).align(CENTER).justify(CENTER).tag("tl-ring-" + status_name(status))


def stage_row(stage: Stage, above: String, last: Bool) -> View:
    """One stage. `above`: the rail tag coming down from the stage before ("" for the first)."""
    var st = stage.status
    var name = status_name(st)
    var left = VStack(_bar(ROW_PAD, above if above != "" else "tl-rail-none"), ring(st), _bar(RAIL, "tl-rail-none"),
                      _bar(0, "tl-rail-none" if last else _rail_tag(st)), spacing=0).width(RING).align(CENTER).tag("tl-rails")
    var head = HStack(Text(stage.label).tag("tl-label-pending" if st == STAGE_PENDING else "tl-label").grow(),
                      Text(elapsed_text(stage.elapsed_ms)).min_width(ELAPSED_W).tag("tl-elapsed-running" if st == STAGE_RUNNING else "tl-elapsed"),
                      spacing=10).align(CENTER).tag("tl-head")
    var lines = List[View]()
    lines.append(head^)
    if stage.detail != "":
        var d = Text(stage.detail, CAPTION)
        if st == STAGE_FAILED or st == STAGE_CANCELLED:
            d = d^.tone(TONE_WARN)
        lines.append(d^.tag("tl-detail-" + name if st == STAGE_FAILED or st == STAGE_CANCELLED else "tl-detail"))
    if st == STAGE_RUNNING and stage.percent >= 0:
        lines.append(ProgressBar(min(max(stage.percent, 0), 100)).fill().tag("tl-bar"))
    if stage.twin != "":
        lines.append(HStack(Text("$" + chr(0xA0), CAPTION).tag("tl-prompt"), Text(stage.twin, CAPTION).tag("tl-twin"), spacing=0).tag("tl-twin-line"))
    var right = VStack(lines^, spacing=2).padding(ROW_PAD, 0).align(STRETCH).grow().tag("tl-text")
    return HStack(left^, right^, spacing=12).align(STRETCH).fill().tag("tl-stage-" + name)


def Timeline(stages: List[Stage]) -> View:
    """The stages top to bottom, each ring joined to the next by its rail."""
    var rows = List[View]()
    for k in range(len(stages)):
        var above = "" if k == 0 else _rail_tag(stages[k - 1].status)
        rows.append(stage_row(stages[k], above, k == len(stages) - 1))
    return VStack(rows^, spacing=0).align(STRETCH).tag("timeline")


# ---------- the look (blade-add.css's ring timeline), for a theme to add to its Look's surfaces ----------

def _role(role: String, fill: UInt32 = 0, radius: Int = -1, font: String = "", size: Float64 = 0, ink: UInt32 = 0,
          weight: Int = 0, outline: UInt32 = 0, outline_w: Int = 0) -> Surface:
    return Surface(role, fill, radius, radius, -1, -1, -1, -1, -1, -1, List[Shadow](), 0, 0, 0, -1, font, size, ink, weight,
                   0, 0, outline, outline_w, False, False)


def timeline_roles(p: Palette, mono: String) -> List[Surface]:
    """.stg's values: names 14.5/550 (pending in ink-2), times 11.5 mono quiet (running ink-2), details 12 mono ink-2
    (failed bad, cancelled warn), the twin 11 mono after a quiet "$"; rings 24 round on surface-1 with a 2 px border
    (line; running data-3; done ok; failed bad; cancelled warn); rails line, done ok. Not carried: the running ring's
    spin and its open top."""
    var out: List[Surface] = [
        _role("tl-label", size=14.5, ink=p.ink, weight=550),
        _role("tl-label-pending", size=14.5, ink=p.ink2, weight=550),
        _role("tl-elapsed", font=mono, size=11.5, ink=p.ink3),
        _role("tl-elapsed-running", font=mono, size=11.5, ink=p.ink2),
        _role("tl-detail", font=mono, size=12, ink=p.ink2),
        _role("tl-detail-failed", font=mono, size=12, ink=p.bad),
        _role("tl-detail-cancelled", font=mono, size=12, ink=p.warn),
        _role("tl-twin", font=mono, size=11, ink=p.ink2),
        _role("tl-prompt", font=mono, size=11, ink=p.ink3),
        _role("tl-ring-pending", p.card, RING // 2, ink=p.ink3, outline=p.line_strong, outline_w=2),
        _role("tl-ring-running", p.card, RING // 2, ink=p.ink3, outline=p.series[2 % len(p.series)], outline_w=2),
        _role("tl-ring-done", p.card, RING // 2, ink=p.good, outline=p.good, outline_w=2),
        _role("tl-ring-failed", p.card, RING // 2, ink=p.bad, outline=p.bad, outline_w=2),
        _role("tl-ring-cancelled", p.card, RING // 2, ink=p.warn, outline=p.warn, outline_w=2),
        _role("tl-rail", p.line_strong),
        _role("tl-rail-done", p.good),
    ]
    return out^
