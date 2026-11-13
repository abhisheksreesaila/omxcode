# mojoui.tree: a decision tree that learns from a few labelled rows and says its rule in words (goal 68 M1). CART
# (Gini), depth-limited so the rule fits in a sentence, written in Mojo and run where the data is. No Sheet here: any
# table's columns come in as Features (mojoui.learn builds them from a sheet).
#
#   var f = Features(rows)
#   f.add_number("speed", speeds)                     # a number column (NaN: missing)
#   f.add_words("kind", codes, words)                 # a text column: a code per row, the words
#   var labels = List[Int](...)                       # per row: a class index, or -1 (not labelled)
#   var t = learn_tree(f, labels, ["moving", "stopped"], max_depth=3)
#   t.predict(f, row)                                 # Guess(cls, sure): its class and how sure (the leaf's share, smoothed)
#   t.rule()                                          # "stopped when speed < 0.1 and person_m < 1.5"
#   var h = held_out(f, labels, classes, 3)           # right / tried on labelled rows each fold never saw
#
# Splits: a number column splits at a round threshold between two neighbouring values (the fewest digits that
# separate them: 0.1, not 0.0873), left when value < threshold (missing goes right); a text column splits on one word
# (left when it is that word). Ties between equally good splits go to the earlier column.

from std.math import floor, log10, isnan


comptime NO_LABEL = -1


struct Features(Movable):
    var names: List[String]
    var numeric: List[Bool]
    var values: List[List[Float64]]  # per column, per row (a text column: its word's code)
    var words: List[List[String]]  # a text column's words by code (empty for numbers)
    var rows: Int

    def __init__(out self, rows: Int):
        self.names = List[String]()
        self.numeric = List[Bool]()
        self.values = List[List[Float64]]()
        self.words = List[List[String]]()
        self.rows = rows

    def add_number(mut self, name: String, var values: List[Float64]):
        self.names.append(name)
        self.numeric.append(True)
        self.values.append(values^)
        self.words.append(List[String]())

    def add_words(mut self, name: String, codes: List[Int], var words: List[String]):
        var v = List[Float64](capacity=len(codes))
        for c in codes:
            v.append(Float64(c))
        self.names.append(name)
        self.numeric.append(False)
        self.values.append(v^)
        self.words.append(words^)

    def columns(self) -> Int:
        return len(self.names)


@fieldwise_init
struct Guess(Copyable, Movable, ImplicitlyCopyable):
    var cls: Int
    var sure: Float64  # 0–1


@fieldwise_init
struct TreeNode(Copyable, Movable):
    var feature: Int  # -1: a leaf
    var threshold: Float64  # a number column: left when value < threshold
    var word: Int  # a text column: left when its code == word
    var left: Int
    var right: Int
    var counts: List[Int]  # labelled rows reaching here, per class

    def best(self) -> Int:
        var b = 0
        for i in range(len(self.counts)):
            if self.counts[i] > self.counts[b]:
                b = i
        return b

    def total(self) -> Int:
        var n = 0
        for c in self.counts:
            n += c
        return n


struct DecisionTree(Copyable, Movable):
    var nodes: List[TreeNode]
    var classes: List[String]
    var names: List[String]  # the feature columns' names (for the rule)
    var numeric: List[Bool]
    var words: List[List[String]]

    def __init__(out self, classes: List[String], f: Features):
        self.nodes = List[TreeNode]()
        self.classes = classes.copy()
        self.names = f.names.copy()
        self.numeric = f.numeric.copy()
        self.words = f.words.copy()

    def leaf_of(self, f: Features, row: Int) -> Int:
        var n = 0
        while self.nodes[n].feature >= 0:
            var v = f.values[self.nodes[n].feature][row]
            var left: Bool
            if self.numeric[self.nodes[n].feature]:
                left = not isnan(v) and v < self.nodes[n].threshold
            else:
                left = Int(v) == self.nodes[n].word
            n = self.nodes[n].left if left else self.nodes[n].right
        return n

    def predict(self, f: Features, row: Int) -> Guess:
        ref leaf = self.nodes[self.leaf_of(f, row)]
        var b = leaf.best()
        var k = len(self.classes)
        return Guess(b, Float64(leaf.counts[b] + 1) / Float64(leaf.total() + k))  # (Laplace: a 2-row leaf isn't "100 %")

    def used(self) -> List[String]:
        """The columns its splits read, in first-use order."""
        var out = List[String]()
        for n in self.nodes:
            if n.feature >= 0 and not (self.names[n.feature] in out):
                out.append(self.names[n.feature])
        return out^

    def depth(self) -> Int:
        return self._depth(0)

    def _depth(self, n: Int) -> Int:
        if self.nodes[n].feature < 0:
            return 0
        return 1 + max(self._depth(self.nodes[n].left), self._depth(self.nodes[n].right))

    def rule(self) -> String:
        """Its rule in words: for each class a leaf predicts (but the most common one), when it says so; then
        "otherwise <the most common>". "stopped when speed < 0.1 and person_m < 1.5; otherwise moving"."""
        return "; ".join(self.rule_lines())

    def rule_lines(self) -> List[String]:
        """rule(), a line per class ("stopped when …", then "otherwise moving")."""
        var lines = List[String]()
        if len(self.nodes) == 0:
            lines.append("nothing learned yet")
            return lines^
        var root = self.nodes[0].best()
        if self.nodes[0].feature < 0:
            lines.append("always " + self.classes[root] + " (no column tells the labels apart yet)")
            return lines^
        for c in range(len(self.classes)):
            if c == root:
                continue
            var paths = List[String]()
            self._paths(0, c, List[Int](), List[Bool](), paths)
            if len(paths) > 0:
                lines.append(self.classes[c] + " when " + " or when ".join(paths))
        if len(lines) == 0:
            lines.append("always " + self.classes[root])
        else:
            lines.append("otherwise " + self.classes[root])
        return lines^

    def _paths(self, n: Int, c: Int, var path: List[Int], var went_left: List[Bool], mut out: List[String]):
        if self.nodes[n].feature < 0:
            if self.nodes[n].best() == c and self.nodes[n].counts[c] > 0:
                out.append(self._say(path, went_left))
            return
        var p2 = path.copy()
        p2.append(n)
        var l2 = went_left.copy()
        l2.append(True)
        self._paths(self.nodes[n].left, c, p2^, l2^, out)
        path.append(n)
        went_left.append(False)
        self._paths(self.nodes[n].right, c, path^, went_left^, out)

    def _say(self, path: List[Int], went_left: List[Bool]) -> String:
        """One leaf's conditions: per column, bounds merged ("0.1 ≤ speed < 0.5"), words said once."""
        var said = List[String]()
        var cols = List[Int]()
        for i in range(len(path)):
            var fcol = self.nodes[path[i]].feature
            if not (fcol in cols):
                cols.append(fcol)
        for fcol in cols:
            var name = self.names[fcol]
            if self.numeric[fcol]:
                var lo = -1e308
                var hi = 1e308
                for i in range(len(path)):
                    if self.nodes[path[i]].feature == fcol:
                        if went_left[i]:
                            hi = min(hi, self.nodes[path[i]].threshold)
                        else:
                            lo = max(lo, self.nodes[path[i]].threshold)
                if lo > -1e308 and hi < 1e308:
                    said.append(number_text(lo) + " ≤ " + name + " < " + number_text(hi))
                elif hi < 1e308:
                    said.append(name + " < " + number_text(hi))
                else:
                    said.append(name + " ≥ " + number_text(lo))
            else:
                var is_word = -1
                var nots = List[String]()
                for i in range(len(path)):
                    if self.nodes[path[i]].feature == fcol:
                        var w = self.nodes[path[i]].word
                        var word = self.words[fcol][w] if 0 <= w < len(self.words[fcol]) else String(w)
                        if went_left[i]:
                            is_word = w
                        else:
                            nots.append(word)
                if is_word >= 0:
                    said.append(name + " is " + (self.words[fcol][is_word] if is_word < len(self.words[fcol]) else String(is_word)))
                else:
                    said.append(name + " isn't " + " or ".join(nots))
        return " and ".join(said)


def number_text(v: Float64) -> String:
    """A threshold as people write it: 2 not 2.0, 0.1 not 0.10000000000000001."""
    if v == floor(v) and v < 1e15 and v > -1e15:
        return String(Int(v))
    var s = String(v)
    return s


def round_between(a: Float64, b: Float64) -> Float64:
    """The number with the fewest digits in (a, b] (a < b): a split that reads well and separates the same rows."""
    var span = max(abs(a), abs(b))
    var p = 1.0
    if span > 0:
        var e = Int(floor(log10(span))) + 1
        p = 1.0
        if e > 0:
            for _ in range(e):
                p *= 10.0
        else:
            for _ in range(-e):
                p /= 10.0
    var mid = (a + b) / 2.0
    for _ in range(24):
        var lo = floor(a / p) * p + p  # (the multiples of p in (a, b]: the one nearest the middle)
        var hi = floor(b / p) * p
        if lo <= hi:
            var v = min(max(floor(mid / p + 0.5) * p, lo), hi)
            # (round off the float noise of p's powers: 0.30000000000000004 → 0.3)
            var digits = 0
            var q = p
            while q < 1.0 and digits < 15:
                q *= 10.0
                digits += 1
            var m = 1.0
            for _ in range(digits):
                m *= 10.0
            var r = floor(v * m + 0.5) / m
            if r > a and r <= b:
                return r
            return v
        p /= 10.0
    return (a + b) / 2.0


@fieldwise_init
struct _Split(Copyable, Movable, ImplicitlyCopyable):
    var feature: Int
    var threshold: Float64
    var word: Int
    var score: Float64  # weighted Gini of the two sides (lower is better)


def _gini(counts: List[Int], n: Int) -> Float64:
    if n == 0:
        return 0.0
    var s = 1.0
    for c in counts:
        var p = Float64(c) / Float64(n)
        s -= p * p
    return s


def _sort_by(mut idx: List[Int], vals: List[Float64]):
    """idx ordered by vals (insertion sort: a few hundred labelled rows)."""
    for i in range(1, len(idx)):
        var x = idx[i]
        var j = i - 1
        while j >= 0 and vals[idx[j]] > vals[x]:
            idx[j + 1] = idx[j]
            j -= 1
        idx[j + 1] = x


def _best_split(f: Features, rows: List[Int], labels: List[Int], k: Int, min_leaf: Int) -> _Split:
    var n = len(rows)
    var all = List[Int](length=k, fill=0)
    for r in rows:
        all[labels[r]] += 1
    var best = _Split(-1, 0.0, -1, _gini(all, n) - 1e-9)
    for fc in range(f.columns()):
        ref vals = f.values[fc]
        if f.numeric[fc]:
            var idx = List[Int]()
            var missing = List[Int](length=k, fill=0)
            var n_missing = 0
            for r in rows:
                if isnan(vals[r]):
                    missing[labels[r]] += 1
                    n_missing += 1
                else:
                    idx.append(r)
            _sort_by(idx, vals)
            var left = List[Int](length=k, fill=0)
            for i in range(len(idx) - 1):
                left[labels[idx[i]]] += 1
                var a = vals[idx[i]]
                var b = vals[idx[i + 1]]
                if not (a < b):
                    continue
                var nl = i + 1
                var nr = n - nl
                if nl < min_leaf or nr < min_leaf:
                    continue
                var right = List[Int](length=k, fill=0)
                for c in range(k):
                    right[c] = all[c] - left[c]
                var score = (Float64(nl) * _gini(left, nl) + Float64(nr) * _gini(right, nr)) / Float64(n)
                if score < best.score - 1e-12:
                    best = _Split(fc, round_between(a, b), -1, score)
        else:
            var seen = List[Int]()
            for r in rows:
                var w = Int(vals[r])
                if not (w in seen):
                    seen.append(w)
            if len(seen) < 2:
                continue
            for w in seen:
                var left = List[Int](length=k, fill=0)
                var nl = 0
                for r in rows:
                    if Int(vals[r]) == w:
                        left[labels[r]] += 1
                        nl += 1
                var nr = n - nl
                if nl < min_leaf or nr < min_leaf:
                    continue
                var right = List[Int](length=k, fill=0)
                for c in range(k):
                    right[c] = all[c] - left[c]
                var score = (Float64(nl) * _gini(left, nl) + Float64(nr) * _gini(right, nr)) / Float64(n)
                if score < best.score - 1e-12:
                    best = _Split(fc, 0.0, w, score)
    return best


def _grow(f: Features, rows: List[Int], labels: List[Int], k: Int, depth: Int, max_depth: Int, min_leaf: Int, mut t: DecisionTree) -> Int:
    var counts = List[Int](length=k, fill=0)
    for r in rows:
        counts[labels[r]] += 1
    var me = len(t.nodes)
    t.nodes.append(TreeNode(-1, 0.0, -1, -1, -1, counts.copy()))
    var pure = False
    for c in counts:
        pure = pure or c == len(rows)
    if depth >= max_depth or pure or len(rows) < 2 * min_leaf:
        return me
    var s = _best_split(f, rows, labels, k, min_leaf)
    if s.feature < 0:
        return me
    var l = List[Int]()
    var r = List[Int]()
    for row in rows:
        var v = f.values[s.feature][row]
        var go_left = (not isnan(v) and v < s.threshold) if f.numeric[s.feature] else Int(v) == s.word
        if go_left:
            l.append(row)
        else:
            r.append(row)
    var li = _grow(f, l, labels, k, depth + 1, max_depth, min_leaf, t)
    var ri = _grow(f, r, labels, k, depth + 1, max_depth, min_leaf, t)
    t.nodes[me].feature = s.feature
    t.nodes[me].threshold = s.threshold
    t.nodes[me].word = s.word
    t.nodes[me].left = li
    t.nodes[me].right = ri
    # (a split whose two sides say the same class says nothing: fold it back into a leaf)
    if t.nodes[li].feature < 0 and t.nodes[ri].feature < 0 and t.nodes[li].best() == t.nodes[ri].best():
        t.nodes[me].feature = -1
        t.nodes[me].left = -1
        t.nodes[me].right = -1
    return me


def learn_tree(f: Features, labels: List[Int], classes: List[String], max_depth: Int = 3, min_leaf: Int = 1) -> DecisionTree:
    """A tree from the rows with a label (labels[r] >= 0); the others are only predicted."""
    var rows = List[Int]()
    for r in range(len(labels)):
        if labels[r] >= 0:
            rows.append(r)
    return learn_rows(f, rows, labels, classes, max_depth, min_leaf)


def learn_rows(f: Features, rows: List[Int], labels: List[Int], classes: List[String], max_depth: Int = 3, min_leaf: Int = 1) -> DecisionTree:
    var t = DecisionTree(classes, f)
    var kept = _grow(f, rows, labels, len(classes), 0, max_depth, min_leaf, t)
    _ = kept
    return t^


@fieldwise_init
struct HeldOut(Copyable, Movable, ImplicitlyCopyable):
    var right: Int
    var tried: Int

    def share(self) -> Float64:
        return Float64(self.right) / Float64(self.tried) if self.tried > 0 else 0.0


def held_out(f: Features, labels: List[Int], classes: List[String], max_depth: Int = 3, min_leaf: Int = 1) -> HeldOut:
    """How often a tree learned without a labelled row gets it right: each labelled row left out once (up to 200
    rows), else 10 folds. A held-out row is never in the tree that guesses it."""
    var rows = List[Int]()
    for r in range(len(labels)):
        if labels[r] >= 0:
            rows.append(r)
    var n = len(rows)
    if n < 2:
        return HeldOut(0, 0)
    var folds = n if n <= 200 else 10
    var right = 0
    for k in range(folds):
        var train = List[Int]()
        var test = List[Int]()
        for i in range(n):
            if i % folds == k:
                test.append(rows[i])
            else:
                train.append(rows[i])
        var t = learn_rows(f, train, labels, classes, max_depth, min_leaf)
        for r in test:
            if t.predict(f, r).cls == labels[r]:
                right += 1
    return HeldOut(right, n)
