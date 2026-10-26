# mojoui.feedback: a note, a warning, an empty state (its action only when given); and logview's LogPane (head, toggle,
# lines with their kinds, pinned) and the wall clock held at $MOJOUI_NOW (moved here from the old admin and catalog tests).
from std.testing import assert_equal, assert_true
from mojoui.view import TEXT, BUTTON, ICON, CANVAS, PROGRESS, SCROLL, FIELD, TABLE, CLIPBOARD
from mojoui.view import View, NO_MSG
from mojoui.look import resolve_layout
from themes.omxqua import omxqua


def tags(v: View) -> List[String]:
    var out = List[String]()
    for n in v.nodes:
        if n.name != "":
            out.append(n.name)
    return out^


def first(v: View, kind: Int) -> Int:
    for k in range(len(v.nodes)):
        if v.nodes[k].kind == kind:
            return k
    return -1


def texts(v: View) -> List[String]:
    var out = List[String]()
    for n in v.nodes:
        if n.kind == TEXT or n.kind == BUTTON:
            out.append(n.text)
    return out^


def tagged(v: View, name: String) -> Int:
    for k in range(len(v.nodes)):
        if v.nodes[k].name == name:
            return k
    return -1


def covered(views: List[View], skip: List[String] = []) raises:
    """Every tag the views set has a role in omxqua's look (the theme gives every part its look)."""
    var look = omxqua(False).look.copy()
    for v in views:
        for t in tags(v):
            if t in skip:
                continue
            assert_true(look.surface(t) >= 0, "no role for tag " + t)
from mojoui.feedback import Note, NoteAction, Warning, EmptyState
from mojoui.logview import LogPane, LogLine, LOG_PLAIN, LOG_OK, LOG_ERROR, log_kind_of, log_role
from mojoui.clock import wall_seconds, shown_ms
from mojoui.view import Text
from std.os import setenv, unsetenv


def main() raises:
    var e = EmptyState("search", "No results", "Nothing matches.", "Clear search", 9)
    assert_equal(texts(e)[0], "No results")
    assert_equal(e.nodes[first(e, BUTTON)].msg, 9)
    assert_equal(first(EmptyState("search", "No models listed", "x"), BUTTON), -1)
    covered([Note([Text("a"), NoteAction("Run all", 1)]), Warning([Text("b")]), e.copy()])
    var lines: List[LogLine] = [LogLine("21:34:02", "hardware: needs ~4.6 GB", LOG_PLAIN), LogLine("21:34:03", "graph compiled", LOG_OK), LogLine("", "Traceback: x", log_kind_of("Traceback: x"))]
    var pane = LogPane("LIVE LOG", lines, True, 77, 200)
    var pt = texts(pane)
    assert_equal(pt[0], "LIVE LOG")
    assert_equal(pt[1], "Hide log")
    assert_equal(pane.nodes[first(pane, BUTTON)].msg, 77)
    assert_equal(pt[6], "Traceback: x")
    assert_equal(pane.nodes[first(pane, SCROLL)].value, 1)
    assert_equal(log_role(LOG_ERROR), "log-er")
    assert_equal(first(LogPane("LIVE LOG", lines, False, 77), SCROLL), -1)
    _ = setenv("MOJOUI_NOW", "1792964194.376")
    assert_equal(wall_seconds(), 1792964194.376)
    _ = unsetenv("MOJOUI_NOW")
    assert_true(wall_seconds() > 1.7e9)
    # a shown timing held at $MOJOUI_ELAPSED_MS (goal 32's shots: "0.3 ms" against "0.7 ms" moved a shot, D-553)
    assert_equal(shown_ms(3.25), 3.25)
    _ = setenv("MOJOUI_ELAPSED_MS", "0.5")
    assert_equal(shown_ms(3.25), 0.5)
    _ = unsetenv("MOJOUI_ELAPSED_MS")
    print("feedback: ok")
