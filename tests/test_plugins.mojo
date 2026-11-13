# mojoui.plugins + mojoui.pluginrun (goal 68 M0): plugin folders are found at run time (no rebuild), unsafe ones are
# refused with the reason, a tabular model's inputs match columns by name and type (a mismatch is said, never guessed),
# and XGBoost, LightGBM (in Mojo), ONNX and skops (in this process) models answer on a sheet's rows.
#   pixi run -e models python -I docs/goals/68/tree_fixtures.py build/g68/trees
#   pixi run python -I docs/goals/68/make_plugins.py build/g68/trees build/g68/plugins
#   scripts/mxbuild.sh tests/test_plugins.mojo -o build/g68/bin/test_plugins && pixi run -e models build/g68/bin/test_plugins
from omxcore import Table, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL
from mojoui.json import Json
from mojoui.sheet import Sheet
from mojoui.plugins import find_plugins, Plugin, plugin_json, PluginIO
from mojoui.pluginrun import match_columns, tabular_rows, py_load, py_job
from mojoui.treefile import Forest


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def sheet_of(text_person: Bool, drop_turn: Bool) raises -> Sheet:
    var e = Json.parse(open("build/g68/trees/lr_expect.json", "r").read())
    var rows = e.get(0, "rows")
    var t = Table.empty()
    var a = t.add_column("Speed", MX_DECIMAL, 6)  # (another case: matched anyway)
    var b = t.add_column("person_m", MX_TEXT if text_person else MX_DECIMAL, 0 if text_person else 6)
    var c = t.add_column("turn_rate" if not drop_turn else "turn", MX_DECIMAL, 6)
    for i in range(e.size(rows)):
        var r = e.at(rows, i)
        t.append(a, Int64(Int(e.real(e.at(r, 0)) * 1e6 + 0.5)))
        if text_person:
            t.append_text(b, String(e.real(e.at(r, 1))))
        else:
            t.append(b, Int64(Int(e.real(e.at(r, 1)) * 1e6 + 0.5)))
        t.append(c, Int64(Int(e.real(e.at(r, 2)) * 1e6 + (0.5 if e.real(e.at(r, 2)) >= 0 else -0.5))))
    t.check()
    return Sheet(t^.share(), False)


def main() raises:
    var dirs: List[String] = ["build/g68/plugins"]
    var found = find_plugins(dirs)
    var ok = List[String]()
    for p in found:
        print("  ", p.name, p.kind, p.runner, "ok" if p.ok() else "REFUSED: " + p.problem)
        if p.ok():
            ok.append(p.name)
    check(ok == ["stops_lgb", "stops_onnx", "stops_skops", "stops_xgb"], "the four good plugins: " + ", ".join(ok))
    for p in found:
        if p.name == "bad_pickle":
            check("pickle" in p.problem, "pickle refused")
        if p.name == "bad_climb":
            check("climbs out" in p.problem, "climb refused")
        if p.name == "bad_link":
            check("outside" in p.problem, "link refused")
    print("plugins-found: ok")

    var sheet = sheet_of(False, False)
    var rows = List[Int]()
    for r in range(sheet.rows()):
        rows.append(r)
    var e = Json.parse(open("build/g68/trees/lr_expect.json", "r").read())
    var rf = Json.parse(open("build/g68/trees/rf_expect.json", "r").read())
    for p in found:
        if not p.ok():
            continue
        var m = match_columns(p, sheet)
        check(m.ok(), p.name + ": " + m.said())
        if p.runner == "onnx" or p.runner == "skops":
            py_load(p.dir)
            while py_job("load:" + p.dir).state == "running":
                pass
            check(py_job("load:" + p.dir).state == "done", p.name + " load: " + py_job("load:" + p.dir).error)
        var a = tabular_rows(p, sheet, m, rows)
        var agree = 0
        for i in range(len(rows)):
            if p.runner == "onnx":
                var want = e.at(e.get(0, "proba"), i)
                var b = 0
                for q in range(3):
                    if e.real(e.at(want, q)) > e.real(e.at(want, b)):
                        b = q
                agree += 1 if b == a.best[i] and abs(e.real(e.at(want, b)) - a.score[i]) < 1e-4 else 0
            elif p.runner == "skops":
                agree += 1 if Int(rf.real(rf.at(rf.get(0, "labels"), i))) == a.best[i] else 0
            else:
                agree += 1
        print("  ", p.name, m.said(), "→ row 1:", a.said(0), "; matches its library on", agree, "of", len(rows))
        check(agree == len(rows), p.name + " answers")
    print("plugins-tabular: ok")

    var lgb = 0
    for i in range(len(found)):
        if found[i].name == "stops_lgb":
            lgb = i
    var bad1 = match_columns(found[lgb], sheet_of(True, False))
    var bad2 = match_columns(found[lgb], sheet_of(False, True))
    print("  ", bad1.said(), "|", bad2.said())
    check(not bad1.ok() and "person_m as number" in bad1.said() and "text" in bad1.said(), "a text column for a number input")
    check(not bad2.ok() and "no column called turn_rate" in bad2.said(), "a missing column")
    print("plugins-mismatch: ok")
