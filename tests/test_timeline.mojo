# mojoui.timeline (goal 33 M4): elapsed times written exactly as blade-add.js's elapsedText writes them (values from
# running the original under node, ties included), setupStages' elapsed rule, and each state's ring, rail, name,
# time, detail, bar and twin.
#   scripts/mxbuild.sh tests/test_timeline.mojo -o build/test_timeline && build/test_timeline
from std.testing import assert_equal, assert_true, assert_false
from mojoui.view import View, TEXT, ICON, PROGRESS, TONE_WARN
from mojoui.theme import Palette
from mojoui.timeline import (Stage, Timeline, elapsed_text, stage_elapsed, status_name, timeline_roles, STAGE_PENDING,
                             STAGE_RUNNING, STAGE_DONE, STAGE_FAILED, STAGE_CANCELLED)


def elapsed() raises:
    var ms: List[Float64] = [0, 49, 50, 51, 149, 150, 250, 350, 1050, 1150, 4200, 4250, 4350, 9950, 12345.678, 59949, 59950,
                             59999, 60000, 63000, 63999, 599999, 600000, 3599999, 3600000, 7384512.5, 2050, 2150, 1250.0000001]
    var want: List[String] = ["0.0s", "0.0s", "0.1s", "0.1s", "0.1s", "0.1s", "0.3s", "0.3s", "1.1s", "1.1s", "4.2s", "4.3s",
                              "4.3s", "9.9s", "12.3s", "59.9s", "60.0s", "60.0s", "1m 00s", "1m 03s", "1m 03s", "9m 59s",
                              "10m 00s", "59m 59s", "60m 00s", "123m 04s", "2.0s", "2.1s", "1.3s"]
    for i in range(len(ms)):
        assert_equal(elapsed_text(ms[i]), want[i], "elapsedText(" + String(ms[i]) + ")")
    assert_equal(elapsed_text(-1), "", "no time")
    # elapsedOf: start → end; running counts to now; no start, or no end while not running: no time
    assert_equal(stage_elapsed(1000, 5200, STAGE_DONE, 9000), 4200.0)
    assert_equal(stage_elapsed(1000, -1, STAGE_RUNNING, 9000), 8000.0)
    assert_equal(stage_elapsed(1000, -1, STAGE_FAILED, 9000), -1.0)
    assert_equal(stage_elapsed(-1, -1, STAGE_PENDING, 9000), -1.0)
    assert_equal(stage_elapsed(5000, 4000, STAGE_DONE, 9000), 0.0, "never below 0")


def find(v: View, tag: String) -> Int:
    for i in range(len(v.nodes)):
        if v.nodes[i].name == tag:
            return i
    return -1


def count(v: View, tag: String) -> Int:
    var n = 0
    for node in v.nodes:
        if node.name == tag:
            n += 1
    return n


def text_in(v: View, row: Int, tag: String) -> String:
    """The text of the first node tagged `tag` inside the subtree at `row` (depth first)."""
    var todo: List[Int] = [row]
    while len(todo) > 0:
        var i = todo.pop()
        if v.nodes[i].name == tag:
            return v.nodes[i].text
        for k in range(len(v.nodes[i].children) - 1, -1, -1):
            todo.append(v.nodes[i].children[k])
    return "<none>"


def views() raises:
    var stages: List[Stage] = [
        Stage("Check hardware", STAGE_DONE, 1200, "NVIDIA GeForce RTX 4090 · 24 GB", "mxc search qwen2.5-0.5b"),
        Stage("Fetch the model", STAGE_RUNNING, 63500, "1.2 GB of 3 GB · 40 MB/s", "mxc pull qwen2.5-0.5b", 40),
        Stage("Compile graph", STAGE_FAILED, 4250, "out of memory", "mxc serve qwen2.5-0.5b"),
        Stage("Serve on localhost", STAGE_CANCELLED, -1, "cancelled"),
        Stage("Smoke test"),
    ]
    var v = Timeline(stages)
    assert_equal(v.nodes[0].name, "timeline")
    assert_equal(len(v.nodes[0].children), 5)
    var names: List[String] = ["done", "running", "failed", "cancelled", "pending"]
    for k in range(5):
        assert_equal(status_name(stages[k].status), names[k])
        assert_equal(v.nodes[v.nodes[0].children[k]].name, "tl-stage-" + names[k])
        assert_equal(count(v, "tl-ring-" + names[k]), 1)
    var r0 = v.nodes[0].children[0]
    var r1 = v.nodes[0].children[1]
    var r2 = v.nodes[0].children[2]
    var r3 = v.nodes[0].children[3]
    var r4 = v.nodes[0].children[4]
    # names and times
    assert_equal(text_in(v, r0, "tl-label"), "Check hardware")
    assert_equal(text_in(v, r0, "tl-elapsed"), "1.2s")
    assert_equal(text_in(v, r1, "tl-elapsed-running"), "1m 03s", "a running stage's time")
    assert_equal(text_in(v, r2, "tl-elapsed"), "4.3s")
    assert_equal(text_in(v, r3, "tl-elapsed"), "", "not started: no time")
    assert_equal(text_in(v, r4, "tl-label-pending"), "Smoke test", "a pending name is quiet")
    # details: plain, failed and cancelled carry their own roles (and a warning tone where roles aren't known)
    assert_equal(text_in(v, r0, "tl-detail"), "NVIDIA GeForce RTX 4090 · 24 GB")
    assert_equal(text_in(v, r2, "tl-detail-failed"), "out of memory")
    assert_equal(v.nodes[find(v, "tl-detail-failed")].value, TONE_WARN)
    assert_equal(text_in(v, r3, "tl-detail-cancelled"), "cancelled")
    assert_equal(text_in(v, r4, "tl-detail"), "<none>", "no detail, no line")
    # the progress bar: only on the running stage
    assert_equal(count(v, "tl-bar"), 1)
    var bar = find(v, "tl-bar")
    assert_equal(v.nodes[bar].kind, PROGRESS)
    assert_equal(v.nodes[bar].value, 40)
    # the twin: "$ " then the command
    assert_equal(text_in(v, r1, "tl-twin"), "mxc pull qwen2.5-0.5b")
    assert_equal(text_in(v, r1, "tl-prompt"), "$" + chr(0xA0))
    assert_equal(count(v, "tl-twin"), 3)
    # rings: a tick when done, a cross when failed or cancelled, nothing otherwise
    var icons = List[String]()
    for node in v.nodes:
        if node.kind == ICON:
            icons.append(node.text)
    assert_equal(len(icons), 3)
    assert_equal(icons[0], "check")
    assert_equal(icons[1], "close")
    assert_equal(icons[2], "close")
    # rails: the done stage's rail is green, down into the next row; the last stage has none
    assert_equal(count(v, "tl-rail-done"), 2, "below the done ring, and above the running one")
    assert_equal(count(v, "tl-rail"), 6, "running → failed → cancelled → pending: 3 below, 3 above")
    var single = Timeline([Stage("Only", STAGE_DONE, 10)])
    assert_equal(count(single, "tl-rail-done"), 0, "one stage: no rail")
    var roles = timeline_roles(Palette.plain(), "Geist Mono")
    assert_equal(roles[0].role, "tl-label")
    assert_equal(roles[11].outline, Palette.plain().good)


def main() raises:
    elapsed()
    views()
    print("timeline: ok")
