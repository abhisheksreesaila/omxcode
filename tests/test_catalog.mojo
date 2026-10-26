# mojoui.catalog: the outlined field (its label is the field's placeholder), filter chips (k sends on_tap + k, the chosen
# one wears filter-chip-on), result rows (badge, the name to tap, the quiet line, the fit mark and size), fit roles,
# a meter, an empty state with its action, Back; and logview's LogPane (head, toggle, lines with their kinds).
from std.testing import assert_equal, assert_true
from mojoui import TEXT, BUTTON, FIELD, PROGRESS, SCROLL
from mojoui.view import View
from mojoui.catalog import OutlinedField, FieldHelp, FieldWithHelp, FilterChips, ResultRow, FitMark, Meter, EmptyState, BackButton, fit_role
from mojoui.logview import LogPane, LogLine, LOG_PLAIN, LOG_OK, LOG_ERROR, log_kind_of, log_role


def texts(v: View) -> List[String]:
    var out = List[String]()
    for n in v.nodes:
        if n.kind == TEXT or n.kind == BUTTON:
            out.append(n.text)
    return out^


def first(v: View, kind: Int) -> Int:
    for k in range(len(v.nodes)):
        if v.nodes[k].kind == kind:
            return k
    return -1



def main() raises:
    var f = OutlinedField("qw", "Search models", on_change=7, on_submit=8)
    assert_equal(f.nodes[0].name, "outlined-field")
    var fi = first(f, FIELD)
    assert_true(fi > 0)
    assert_equal(f.nodes[fi].hint, "Search models")  # (the label shows in the field until something is typed)
    assert_equal(f.nodes[fi].text, "qw")
    assert_equal(f.nodes[fi].msg, 7)
    assert_equal(f.nodes[fi].msg2, 8)
    assert_equal(FieldHelp("help").nodes[0].name, "field-help")
    var fh = FieldWithHelp(OutlinedField("", "Search models", 1), "help")
    assert_equal(fh.nodes[0].spacing, 6)
    assert_equal(texts(fh)[0], "help")

    var chips = FilterChips(["All", "Fits", "Needs porting"], 1, 40)
    var names = List[String]()
    var msgs = List[Int]()
    for n in chips.nodes:
        if n.kind == BUTTON:
            names.append(n.name)
            msgs.append(n.msg)
    assert_equal(len(names), 3)
    assert_equal(names[0], "filter-chip")
    assert_equal(names[1], "filter-chip-on")
    assert_equal(msgs[2], 42)

    var row = ResultRow("MAX", 3, "qwen2.5-0.5b", 100, "Qwen/Qwen2.5-0.5B-Instruct · Qwen2 · 500M · 1 GB", "ok", "fits", "~2.2 GB VRAM")
    assert_equal(row.nodes[0].name, "result-row")
    var t = texts(row)
    assert_equal(t[0], "MAX")
    assert_equal(row.nodes[1].name, "source-badge-3")
    assert_equal(row.nodes[1].w, 52)
    assert_equal(t[1], "qwen2.5-0.5b")
    assert_equal(t[2], "Qwen/Qwen2.5-0.5B-Instruct · Qwen2 · 500M · 1 GB")
    assert_equal(t[3], "fits")
    assert_equal(t[4], "~2.2 GB VRAM")
    var bi = first(row, BUTTON)
    assert_equal(row.nodes[bi].msg, 100)
    assert_equal(row.nodes[bi].name, "result-name")
    var roles = List[String]()
    for n in row.nodes:
        roles.append(n.name)
    assert_true("fit-ok" in roles and "fit-ok-dot" in roles)
    assert_equal(len(texts(ResultRow("HF", 4, "a/b", 1, "", "", "size unknown", ""))), 3)  # (no meta, no size)
    assert_equal(fit_role("port"), "fit-port")
    assert_equal(fit_role(""), "fit-inst")
    assert_equal(fit_role("weird"), "fit-inst")
    assert_equal(FitMark("no", "too big").nodes[2].name, "fit-no")

    var m = Meter("needs", 140, True, "~9 GB")
    var pi = first(m, PROGRESS)
    assert_equal(m.nodes[pi].value, 100)  # (clamped)
    assert_equal(m.nodes[pi].name, "meter-bar-bad")
    assert_equal(Meter("RTX", 50, False, "4 GB").nodes[first(Meter("RTX", 50, False, "4 GB"), PROGRESS)].name, "meter-bar")

    var e = EmptyState("search", "No results", "Nothing matches.", "Clear search", 9)
    var et = texts(e)
    assert_equal(et[0], "No results")
    assert_equal(et[2], "Clear search")
    assert_equal(e.nodes[first(e, BUTTON)].msg, 9)
    assert_equal(first(EmptyState("search", "No models listed", "x"), BUTTON), -1)
    var back = BackButton(5)
    assert_equal(back.nodes[0].text, "Back")
    assert_equal(back.nodes[0].hint, "back")
    assert_equal(back.nodes[0].w, 76)
    assert_equal(back.nodes[0].msg, 5)

    var lines: List[LogLine] = [LogLine("21:34:02", "hardware: needs ~4.6 GB", LOG_PLAIN), LogLine("21:34:03", "graph compiled", LOG_OK), LogLine("", "Traceback: x", log_kind_of("Traceback: x"))]
    var pane = LogPane("LIVE LOG", lines, True, 77, 200)
    var pt = texts(pane)
    assert_equal(pt[0], "LIVE LOG")
    assert_equal(pt[1], "Hide log")
    assert_equal(pane.nodes[first(pane, BUTTON)].msg, 77)
    assert_equal(pt[2], "21:34:02" + chr(160))
    assert_equal(pt[3], "hardware: needs ~4.6 GB")
    assert_equal(pt[6], "Traceback: x")  # (a job's own line has no stamp)
    var pr = List[String]()
    for n in pane.nodes:
        pr.append(n.name)
    assert_true("log-ok" in pr and "log-er" in pr and "log-time" in pr)
    assert_equal(pane.nodes[first(pane, SCROLL)].value, 1)  # pinned to its end
    assert_equal(log_role(LOG_ERROR), "log-er")
    assert_equal(log_kind_of("all fine"), LOG_PLAIN)
    var shut = LogPane("LIVE LOG", lines, False, 77)
    assert_equal(texts(shut)[1], "Show log")
    assert_equal(first(shut, SCROLL), -1)  # (hidden: no lines)
    print("catalog: ok")
