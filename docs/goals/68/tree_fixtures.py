"""Goal 68 M0's decision-model fixtures: XGBoost and LightGBM models (binary, multiclass, regression; missing values),
saved in their own text formats, with each library's own predictions for 300 rows, and an ONNX and a skops model of the
same data (scikit-learn), for tests/test_treefile.mojo and the plugin runner. Run in the models environment:
    pixi run -e models python -I docs/goals/68/tree_fixtures.py OUT_DIR"""
import json
import sys
from pathlib import Path

import numpy as np

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
rng = np.random.default_rng(68)
n = 2000
speed = rng.uniform(0, 1.5, n)
person = rng.uniform(0.3, 6, n)
turn = rng.uniform(-0.6, 0.6, n)
X = np.stack([speed, person, turn], 1)
X[rng.random(n) < 0.05, 1] = np.nan  # (missing values: the default direction)
names = ["speed", "person_m", "turn_rate"]
y_bin = ((speed < 0.1) & (np.nan_to_num(person, nan=9) < 1.5)).astype(int)
y_multi = np.where(speed >= 0.1, 0, np.where(np.nan_to_num(person, nan=9) < 1.5, 1, 2))
y_reg = 2.0 * speed - 0.3 * np.nan_to_num(person) + turn
test = X[:300]
expect = {}

import xgboost as xgb

for name, y, params in (("bin", y_bin, {"objective": "binary:logistic"}), ("multi", y_multi, {"objective": "multi:softprob", "num_class": 3}),
                        ("reg", y_reg, {"objective": "reg:squarederror"})):
    d = xgb.DMatrix(X, label=y, feature_names=names)
    b = xgb.train({**params, "max_depth": 3, "eta": 0.3, "base_score": 0.5 if name != "reg" else 0.2}, d, 12)
    b.save_model(str(out / f"xgb_{name}.json"))
    p = b.predict(xgb.DMatrix(test, feature_names=names))
    expect[f"xgb_{name}.json"] = p.reshape(len(test), -1).tolist()

import lightgbm as lgb

for name, y, params in (("bin", y_bin, {"objective": "binary"}), ("multi", y_multi, {"objective": "multiclass", "num_class": 3}),
                        ("reg", y_reg, {"objective": "regression"})):
    m = lgb.train({**params, "num_leaves": 7, "learning_rate": 0.3, "verbose": -1, "min_data_in_leaf": 5}, lgb.Dataset(X, label=y, feature_name=names), 12)
    m.save_model(str(out / f"lgb_{name}.txt"))
    p = m.predict(test)
    expect[f"lgb_{name}.txt"] = np.asarray(p).reshape(len(test), -1).tolist()

(out / "rows.json").write_text(json.dumps([[None if np.isnan(v) else float(v) for v in r] for r in test]))
(out / "expect.json").write_text(json.dumps(expect))

# (scikit-learn: an ONNX file and a skops file of one classifier; never pickle)
from sklearn.ensemble import RandomForestClassifier

Xf = np.nan_to_num(X, nan=9.0)
rf = RandomForestClassifier(n_estimators=10, max_depth=4, random_state=0).fit(Xf, y_multi)
import skops.io as sio

sio.dump(rf, out / "rf.skops")
# (a skops file holding a function: FunctionTransformer(eval) would call it at predict time; it must be refused)
from sklearn.preprocessing import FunctionTransformer

sio.dump(FunctionTransformer(eval), out / "function.skops")  # (builtins.eval: an untrusted function)
(out / "rf_expect.json").write_text(json.dumps({"rows": Xf[:50].tolist(), "labels": rf.predict(Xf[:50]).tolist(), "proba": rf.predict_proba(Xf[:50]).tolist()}))

# (an ONNX model built with onnx's own helper: a logistic regression from scikit-learn's coefficients, inputs "input"
# [N, 3] float32 → "probabilities" [N, 3])
import onnx
from onnx import TensorProto, helper
from sklearn.linear_model import LogisticRegression

lr = LogisticRegression(max_iter=2000).fit(Xf, y_multi)
W = helper.make_tensor("W", TensorProto.FLOAT, [3, 3], lr.coef_.T.astype(np.float32).flatten().tolist())
B = helper.make_tensor("B", TensorProto.FLOAT, [3], lr.intercept_.astype(np.float32).tolist())
g = helper.make_graph([helper.make_node("MatMul", ["input", "W"], ["z0"]), helper.make_node("Add", ["z0", "B"], ["z"]),
                       helper.make_node("Softmax", ["z"], ["probabilities"], axis=1)], "stops",
                      [helper.make_tensor_value_info("input", TensorProto.FLOAT, [None, 3])],
                      [helper.make_tensor_value_info("probabilities", TensorProto.FLOAT, [None, 3])], [W, B])
m = helper.make_model(g, opset_imports=[helper.make_opsetid("", 17)], ir_version=9)  # (ONNX Runtime 1.31 reads IR up to 13)
onnx.checker.check_model(m)
(out / "lr.onnx").write_bytes(m.SerializeToString())
(out / "lr_expect.json").write_text(json.dumps({"rows": Xf[:50].tolist(), "proba": lr.predict_proba(Xf[:50]).tolist()}))
print("fixtures in", out)
