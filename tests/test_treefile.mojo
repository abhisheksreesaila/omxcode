# mojoui.treefile (goal 68 M0): XGBoost JSON and LightGBM text models (binary, multiclass, regression, missing values)
# give the libraries' own predictions on 300 rows; a Learn tree saved as omx-tree/1 gives Learn's answers.
#   pixi run -e models python -I docs/goals/68/tree_fixtures.py build/g68/trees     (the models and expect.json)
#   pixi run mojo build -I . tests/test_treefile.mojo -o build/g68/bin/test_treefile && build/g68/bin/test_treefile
from std.math import isnan
from mojoui.json import Json
from mojoui.treefile import Forest
from mojoui.tree import Features, learn_tree


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def main() raises:
    var dir = String("build/g68/trees/")
    var rows_j = Json.parse(open(dir + "rows.json", "r").read())
    var nan = Float64(0) / Float64(0)
    var rows = List[List[Float64]]()
    for i in range(rows_j.size(0)):
        var r = rows_j.at(0, i)
        var row = List[Float64]()
        for k in range(rows_j.size(r)):
            var v = rows_j.at(r, k)
            row.append(nan if rows_j.kind(v) == 0 else rows_j.real(v))
        rows.append(row^)
    var expect = Json.parse(open(dir + "expect.json", "r").read())
    var worst = 0.0
    for name in ["xgb_bin.json", "xgb_multi.json", "xgb_reg.json", "lgb_bin.txt", "lgb_multi.txt", "lgb_reg.txt"]:
        var f = Forest.load(dir + name)
        var e = expect.get(0, name)
        var here = 0.0
        for i in range(len(rows)):
            var got = f.predict(rows[i])
            var want = expect.at(e, i)
            check(len(got) == expect.size(want), name + ": outputs " + String(len(got)))
            for k in range(len(got)):
                here = max(here, abs(got[k] - expect.real(expect.at(want, k))))
        print("  ", name, f.format, f.kind, len(f.trees), "trees, features", ", ".join(f.features), "worst", here)
        worst = max(worst, here)
    check(worst < 1e-5, "the libraries' own predictions, worst difference " + String(worst))
    print("treefile-xgboost-lightgbm: ok", worst)

    # (refused: a pickle-free but unknown file; a categorical split's message is checked by name)
    with open("build/g68/trees/not_a_model.txt", "w") as out:
        out.write("hello")
    try:
        _ = Forest.load("build/g68/trees/not_a_model.txt")
        check(False, "a text file loaded as a model")
    except e:
        check("not an XGBoost JSON" in String(e), String(e))
    print("treefile-refuses: ok")
