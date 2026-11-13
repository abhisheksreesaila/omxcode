"""Goal 68 M0's test plugin folders (from docs/goals/68/tree_fixtures.py's models) in OUT: four that work (an XGBoost
JSON, a LightGBM text, an ONNX and a skops model, each a folder with plugin.json) and three that must be refused (a
pickle, a path that climbs out, a link that points out).  pixi run python -I docs/goals/68/make_plugins.py TREES OUT"""
import json
import os
import shutil
import sys
from pathlib import Path

trees, out = Path(sys.argv[1]), Path(sys.argv[2])
if out.exists():
    shutil.rmtree(out)
out.mkdir(parents=True)
classes = ["moving", "person ahead", "waiting"]
num = lambda n: {"name": n, "type": "number"}  # noqa: E731


def plugin(name, runner, model_file, src, inputs, params, about):
    d = out / name
    d.mkdir()
    if src:
        shutil.copy(trees / src, d / model_file)
    (d / "plugin.json").write_text(json.dumps({"format": "omx-plugin/1", "name": name, "kind": "tabular", "runner": runner, "about": about,
                                               "licence": "MIT", "source": "file:" + (src or model_file), "inputs": inputs,
                                               "outputs": [{"name": "label", "type": "text"}, {"name": "score", "type": "number"}],
                                               "files": {"model": model_file}, "params": params}, indent=1))
    return d


plugin("stops_xgb", "tree", "model.json", "xgb_multi.json", [], {"classes": classes}, "XGBoost: why a robot stopped")
plugin("stops_lgb", "tree", "model.txt", "lgb_bin.txt", [num("speed"), num("person_m"), num("turn_rate")], {"classes": ["other", "person ahead"]},
       "LightGBM: a person in the way")
plugin("stops_onnx", "onnx", "model.onnx", "lr.onnx", [num("speed"), num("person_m"), num("turn_rate")], {"classes": classes}, "ONNX logistic regression")
plugin("stops_skops", "skops", "model.skops", "rf.skops", [num("speed"), num("person_m"), num("turn_rate")], {"classes": classes}, "scikit-learn forest (skops)")
plugin("bad_skops", "skops", "model.skops", "function.skops", [num("speed"), num("person_m"), num("turn_rate")], {}, "a function inside: refused at load")
bad = plugin("bad_pickle", "skops", "model.pkl", None, [num("speed")], {}, "a pickle: refused")
(bad / "model.pkl").write_bytes(b"\x80\x04K\x01.")
plugin("bad_climb", "tree", "../stops_xgb/model.json", None, [], {}, "a path out of its folder: refused")
link = plugin("bad_link", "tree", "model.json", None, [], {}, "a link out of its folder: refused")
os.symlink("/etc/hostname", link / "model.json")
print(out)
