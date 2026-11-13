# mojoui.treefile: decision models from other tools, evaluated in Mojo (goal 68 M0): XGBoost's JSON model file,
# LightGBM's text model file, and mojoui.tree's own trees ("omx-tree/1", what Learn saves). Only numbers and text
# are read from the file: nothing in it runs (no pickle, no code).
#
#   var f = Forest.load("stops.xgb.json")       # or "stops.lgb.txt", "stops.tree.json"
#   f.features                                  # the inputs, in the model's order (names from the file when it has them)
#   f.classes                                   # 1 for a regressor or a binary classifier's "probability of class 1"
#   var out = f.predict(row)                    # row: one Float64 per feature (NaN: missing) → the model's output(s)
#   f.kind                                      # "regression", "binary" or "multiclass"
#
# XGBoost: gbtree only (gblinear and dart refused), numeric splits (go left when x < split, missing by default_left),
# the margin = base_score's margin + the leaves; binary:logistic → sigmoid, multi:softprob/softmax → softmax over
# classes (tree_info says each tree's class), reg:* → the margin. LightGBM: numeric splits (left when x <= threshold;
# missing per decision_type: None treats NaN as 0, Zero sends 0/NaN the default way, NaN sends NaN the default way),
# leaves already shrunk; binary → sigmoid(sigmoid_k × raw), multiclass → softmax, regression → raw. Categorical splits
# in either are refused by name ("can't read yet") rather than guessed.

from std.math import exp, isnan, log
from mojoui.json import Json, J_ARRAY, J_STRING, J_NUMBER


@fieldwise_init
struct _Tree(Copyable, Movable):
    var feature: List[Int]  # per node; -1: a leaf
    var threshold: List[Float64]
    var left: List[Int]
    var right: List[Int]
    var default_left: List[Bool]
    var missing: List[Int]  # LightGBM: 0 none, 1 zero, 2 NaN (XGBoost: 2)
    var value: List[Float64]  # a leaf's value
    var le: Bool  # LightGBM's "x <= threshold" (XGBoost: "x < split")
    var cls: Int  # the class its leaves add to

    def leaf(self, row: List[Float64]) -> Float64:
        var n = 0
        while self.feature[n] >= 0:
            var x = row[self.feature[n]]
            var go_left: Bool
            var m = self.missing[n]
            if isnan(x):
                if m == 0:  # (LightGBM's None: NaN counts as 0)
                    x = 0.0
                    go_left = (x <= self.threshold[n]) if self.le else (x < self.threshold[n])
                else:
                    go_left = self.default_left[n]
            elif m == 1 and x == 0.0:
                go_left = self.default_left[n]
            elif self.le:
                go_left = x <= self.threshold[n]
            else:
                go_left = Float32(x) < Float32(self.threshold[n])  # (XGBoost compares as float32: its splits sit on float32 values)
            n = self.left[n] if go_left else self.right[n]
        return self.value[n]


struct Forest(Movable):
    var trees: List[_Tree]
    var features: List[String]
    var classes: Int  # outputs: 1 (regression, binary) or the number of classes
    var kind: String  # regression, binary, multiclass
    var base: List[Float64]  # per output: the starting margin
    var sigmoid_k: Float64
    var format: String  # xgboost, lightgbm, omx-tree
    var class_names: List[String]  # omx-tree's own labels (empty otherwise)

    def __init__(out self, format: String):
        self.trees = List[_Tree]()
        self.features = List[String]()
        self.classes = 1
        self.kind = "regression"
        self.base = List[Float64]()
        self.sigmoid_k = 1.0
        self.format = format
        self.class_names = List[String]()

    @staticmethod
    def load(path: String) raises -> Forest:
        var text = open(path, "r").read()
        var s = String(text.lstrip())
        if s.startswith("{"):
            var j = Json.parse(text)
            if j.get(0, "learner") >= 0:
                return _xgboost(j, path)
            if j.text(j.get(0, "format")) == "omx-tree/1":
                return _omx_tree(j, path)
            raise Error(path + ": a JSON model this app can't read (XGBoost's JSON or omx-tree/1)")
        if s.startswith("tree") or "\nTree=" in s:
            return _lightgbm(text, path)
        raise Error(path + ": not an XGBoost JSON, LightGBM text or omx-tree model")

    def margins(self, row: List[Float64]) -> List[Float64]:
        var m = self.base.copy()
        for t in self.trees:
            m[t.cls] += t.leaf(row)
        return m^

    def predict(self, row: List[Float64]) -> List[Float64]:
        """The model's output: a value (regression), P(class 1) (binary) or every class's probability (multiclass)."""
        var m = self.margins(row)
        if self.kind == "binary":
            m[0] = 1.0 / (1.0 + exp(-self.sigmoid_k * m[0]))
        elif self.kind == "multiclass":
            var top = m[0]
            for v in m:
                top = max(top, v)
            var sum = 0.0
            for i in range(len(m)):
                m[i] = exp(m[i] - top)
                sum += m[i]
            for i in range(len(m)):
                m[i] /= sum
        return m^


def _float_text(s: String) raises -> Float64:
    """A number XGBoost wrote as text ("5E-1", "[5.0000000E-1]"): the first, when it wrote one per class."""
    return _float_list(s)[0]


def _float_list(s: String) raises -> List[Float64]:
    """XGBoost 3's per-class numbers ("[5E-1,5E-1,5E-1]"), or one."""
    var out = List[Float64]()
    for w in String(s.strip().lstrip("[").rstrip("]")).split(","):
        out.append(Float64(String(w.strip())))
    return out^


def _xgboost(j: Json, path: String) raises -> Forest:
    var f = Forest("xgboost")
    var learner = j.get(0, "learner")
    var gb = j.get(learner, "gradient_booster")
    var name = j.text(j.get(gb, "name"))
    if name != "gbtree":
        raise Error(path + ": an XGBoost " + name + " model (only gbtree is read)")
    var mp = j.get(learner, "learner_model_param")
    var num_class = Int(_float_text(j.text(j.get(mp, "num_class"), "0")))
    var bases = _float_list(j.text(j.get(mp, "base_score"), "0.5"))
    var base_score = bases[0]
    var objective = j.text(j.get(j.get(learner, "objective"), "name"))
    var names_node = j.get(learner, "feature_names")
    if names_node >= 0 and j.kind(names_node) == J_ARRAY:
        for i in range(j.size(names_node)):
            f.features.append(j.text(j.at(names_node, i)))
    var nf = Int(_float_text(j.text(j.get(mp, "num_feature"), "0")))
    while len(f.features) < nf:
        f.features.append("f" + String(len(f.features)))
    if objective.startswith("binary:logistic") or objective == "reg:logistic":
        f.kind = "binary"
        f.classes = 1
        f.base.append(log(base_score / (1.0 - base_score)))
    elif objective.startswith("multi:"):
        f.kind = "multiclass"
        f.classes = num_class
        for c in range(num_class):
            f.base.append(bases[c] if c < len(bases) else base_score)
    elif objective.startswith("reg:"):
        f.kind = "regression"
        f.base.append(base_score)
    else:
        raise Error(path + ": XGBoost objective " + objective + " isn't read yet (binary:logistic, multi:*, reg:*)")
    var model = j.get(gb, "model")
    var trees = j.get(model, "trees")
    var info = j.get(model, "tree_info")
    for t in range(j.size(trees)):
        var tn = j.at(trees, t)
        var cats = j.get(tn, "categories")
        if cats >= 0 and j.size(cats) > 0:
            raise Error(path + ": an XGBoost tree with categorical splits (can't read yet)")
        var si = j.get(tn, "split_indices")
        var sc = j.get(tn, "split_conditions")
        var lc = j.get(tn, "left_children")
        var rc = j.get(tn, "right_children")
        var dl = j.get(tn, "default_left")
        var n = j.size(si)
        var tree = _Tree(List[Int](), List[Float64](), List[Int](), List[Int](), List[Bool](), List[Int](), List[Float64](), False,
                         Int(j.real(j.at(info, t))) if info >= 0 and f.kind == "multiclass" else 0)
        for i in range(n):
            var l = Int(j.real(j.at(lc, i)))
            tree.feature.append(Int(j.real(j.at(si, i))) if l >= 0 else -1)
            tree.threshold.append(j.real(j.at(sc, i)))
            tree.left.append(l)
            tree.right.append(Int(j.real(j.at(rc, i))))
            tree.default_left.append(j.real(j.at(dl, i)) != 0.0)
            tree.missing.append(2)
            tree.value.append(j.real(j.at(sc, i)))
        f.trees.append(tree^)
    return f^


def _ints(s: String) raises -> List[Int]:
    var out = List[Int]()
    for w in s.split(" "):
        if String(w) != "":
            out.append(Int(String(w)))
    return out^


def _floats(s: String) raises -> List[Float64]:
    var out = List[Float64]()
    for w in s.split(" "):
        var t = String(w)
        if t != "":
            out.append(Float64(t) if t != "inf" and t != "-inf" else (1e308 if t == "inf" else -1e308))
    return out^


def _lightgbm(text: String, path: String) raises -> Forest:
    var f = Forest("lightgbm")
    var num_class = 1
    var objective = String("regression")
    var lines = text.split("\n")
    var i = 0
    # (the header: up to the first Tree=)
    while i < len(lines) and not String(lines[i]).startswith("Tree="):
        var l = String(lines[i].strip())
        if l.startswith("num_class="):
            num_class = Int(String(l[byte=10:]))
        elif l.startswith("objective="):
            objective = String(l[byte=10:])
        elif l.startswith("feature_names="):
            for w in String(l[byte=14:]).split(" "):
                f.features.append(String(w))
        i += 1
    var words = objective.split(" ")
    var obj = String(words[0])
    if obj == "binary":
        f.kind = "binary"
        for w in words:
            if String(w).startswith("sigmoid:"):
                f.sigmoid_k = Float64(String(String(w)[byte=8:]))
    elif obj == "multiclass" or obj == "softmax":
        f.kind = "multiclass"
    elif obj.startswith("regression") or obj == "huber" or obj == "fair" or obj == "quantile" or obj == "mape":
        f.kind = "regression"
    else:
        raise Error(path + ": LightGBM objective " + obj + " isn't read yet (binary, multiclass, regression)")
    f.classes = num_class if f.kind == "multiclass" else 1
    for _ in range(f.classes):
        f.base.append(0.0)
    var t = 0
    while i < len(lines):
        var l = String(lines[i].strip())
        if not l.startswith("Tree="):
            if l.startswith("end of trees"):
                break
            i += 1
            continue
        var fields = Dict[String, String]()
        i += 1
        while i < len(lines) and String(lines[i].strip()) != "":
            var kv = String(lines[i].strip())
            var eq = kv.find("=")
            if eq > 0:
                fields[String(kv[byte=:eq])] = String(kv[byte = eq + 1 :])
            i += 1
        var leaves = _floats(fields.get("leaf_value", ""))
        var tree = _Tree(List[Int](), List[Float64](), List[Int](), List[Int](), List[Bool](), List[Int](), List[Float64](), True, t % f.classes)
        if Int(fields.get("num_leaves", "1")) <= 1:
            tree.feature.append(-1)
            tree.threshold.append(0.0)
            tree.left.append(-1)
            tree.right.append(-1)
            tree.default_left.append(False)
            tree.missing.append(0)
            tree.value.append(leaves[0] if len(leaves) > 0 else 0.0)
        else:
            var sf = _ints(fields.get("split_feature", ""))
            var th = _floats(fields.get("threshold", ""))
            var dt = _ints(fields.get("decision_type", ""))
            var lc = _ints(fields.get("left_child", ""))
            var rc = _ints(fields.get("right_child", ""))
            var n_in = len(sf)
            # (inner nodes 0..n_in-1, then leaves n_in + k; a child < 0 is leaf -child - 1)
            for k in range(n_in):
                if dt[k] & 1:
                    raise Error(path + ": a LightGBM tree with categorical splits (can't read yet)")
                tree.feature.append(sf[k])
                tree.threshold.append(th[k])
                tree.left.append(lc[k] if lc[k] >= 0 else n_in + (-lc[k] - 1))
                tree.right.append(rc[k] if rc[k] >= 0 else n_in + (-rc[k] - 1))
                tree.default_left.append((dt[k] & 2) != 0)
                tree.missing.append((dt[k] >> 2) & 3)
                tree.value.append(0.0)
            for v in leaves:
                tree.feature.append(-1)
                tree.threshold.append(0.0)
                tree.left.append(-1)
                tree.right.append(-1)
                tree.default_left.append(False)
                tree.missing.append(0)
                tree.value.append(v)
        f.trees.append(tree^)
        t += 1
    if len(f.trees) == 0:
        raise Error(path + ": a LightGBM file without trees")
    return f^


def _omx_tree(j: Json, path: String) raises -> Forest:
    """mojoui.tree's own export: numeric splits on named features, leaves with per-class counts → one-hot of its best
    class's share (the same 'sure' as Learn: Laplace-smoothed)."""
    var f = Forest("omx-tree")
    var fs = j.get(0, "features")
    for i in range(j.size(fs)):
        f.features.append(j.text(j.at(fs, i)))
    var cs = j.get(0, "classes")
    for i in range(j.size(cs)):
        f.class_names.append(j.text(j.at(cs, i)))
    var k = len(f.class_names)
    f.kind = "multiclass"
    f.classes = k
    var nodes = j.get(0, "nodes")
    # (one tree per class: leaves hold log(share), so the softmax gives back each leaf's smoothed shares)
    for c in range(k):
        var tree = _Tree(List[Int](), List[Float64](), List[Int](), List[Int](), List[Bool](), List[Int](), List[Float64](), False, c)
        for i in range(j.size(nodes)):
            var n = j.at(nodes, i)
            if j.get(n, "word") >= 0 and Int(j.real(j.get(n, "word"))) >= 0:
                raise Error(path + ": a tree that splits on words can't be saved as a plugin yet")
            tree.feature.append(Int(j.real(j.get(n, "feature"))))
            tree.threshold.append(j.real(j.get(n, "threshold")))
            tree.left.append(Int(j.real(j.get(n, "left"))))
            tree.right.append(Int(j.real(j.get(n, "right"))))
            tree.default_left.append(False)
            tree.missing.append(2)
            var counts = j.get(n, "counts")
            var total = 0.0
            for q in range(j.size(counts)):
                total += j.real(j.at(counts, q))
            tree.value.append(log((j.real(j.at(counts, c)) + 1.0) / (total + Float64(k))) if j.size(counts) > c else 0.0)
        f.trees.append(tree^)
        f.base.append(0.0)
    return f^
