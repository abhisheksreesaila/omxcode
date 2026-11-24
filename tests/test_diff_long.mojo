# Goal 81, M2: long lists compare fast and keep their widgets. Adding a row on top of a tagged list keeps every old row's
# widgets however long it is (goal 80's study: past 500 rows all 1,804 were built again); an unchanged list's cost grows
# with its length, not its square; the pairs are as many as the exact longest common run (the old table, kept here) on
# random lists, and valid (rising on both sides, same keys).
#   pixi run mojo run -O3 -I . tests/test_diff_long.mojo
from std.testing import assert_true, assert_equal
from mojoui import *
from mojoui.clock import now_ns
from mojoui.diff import diff, pairs_of, same_key
from std.random import seed, random_ui64


def rows(n: Int, top: Bool) -> View:
    var out = List[View](capacity=n + 1)
    if top:
        out.append(HStack(Text("new"), Button("Go", 1)).tag("new"))
    for i in range(n):
        out.append(HStack(Text("row " + String(i)), Button("Open", 2)).tag("r" + String(i)))
    return VStack(out^, spacing=0)


def same_ms(n: Int) -> Float64:
    """The median of 41 compares of an unchanged list, in ms."""
    var a = rows(n, False)
    var b = rows(n, False)
    var t = List[Int]()
    for _ in range(41):
        var t0 = now_ns()
        var d = diff(a, b)
        t.append(now_ns() - t0)
        if d.rebuild or len(d.patches) > 0:
            return 1.0e9
    sort(t)
    return Float64(t[20]) / 1e6


def longest(old: View, new: View, oc: List[Int], nc: List[Int]) -> Int:
    """The old table's answer: how many children the longest common run pairs."""
    var n = len(oc)
    var m = len(nc)
    var t = List[Int](length=(n + 1) * (m + 1), fill=0)
    for a in range(n - 1, -1, -1):
        for b in range(m - 1, -1, -1):
            if same_key(old.nodes[oc[a]], new.nodes[nc[b]]):
                t[a * (m + 1) + b] = t[(a + 1) * (m + 1) + b + 1] + 1
            else:
                t[a * (m + 1) + b] = max(t[(a + 1) * (m + 1) + b], t[a * (m + 1) + b + 1])
    return t[0]


def pick(n: Int) -> Int:
    return Int(random_ui64(0, UInt64(n - 1)))


def random_list(tags: Int) -> View:
    var out = List[View]()
    for _ in range(pick(60)):
        var k = pick(10)
        if k == 0:
            out.append(Divider())
        elif k == 1:
            out.append(Spacer())
        elif k == 2:
            out.append(Text("x", pick(4)))
        else:
            out.append(Text("x").tag("t" + String(pick(tags))))
    return VStack(out^)


def shuffled(v: View) -> View:
    """v's children, some moved, some dropped, some said twice."""
    var order = List[Int]()
    for k in range(len(v.nodes[0].children)):
        if pick(8) > 0:
            order.append(k)
        if pick(20) == 0:
            order.append(k)
    for _ in range(pick(4)):
        if len(order) > 1:
            var x = order.pop(pick(len(order)))
            order.insert(pick(len(order) + 1), x)
    var out = List[View]()
    for k in order:
        ref n = v.nodes[v.nodes[0].children[k]]
        var c = View([n.copy()])
        out.append(c^)
    return VStack(out^)


def main() raises:
    for n in [600, 2000, 10000]:
        var a = rows(n, False)
        var b = rows(n, True)
        var d = diff(a, b)
        assert_true(d.partial, "a partial rebuild")
        var kept = 0
        for k in range(len(d.kept)):
            if d.kept[k] >= 0:
                kept += 1
                assert_equal(a.nodes[d.kept[k]].kind, b.nodes[k].kind)
        print("FACT lost_" + String(n), len(a.nodes) - kept)
        print("FACT patches_" + String(n), len(d.patches))
    var at499 = same_ms(499)
    var at500 = same_ms(500)
    var at10k = same_ms(10000)
    print("FACT same_499_ms", round(at499, 4))
    print("FACT same_10000_ms", round(at10k, 4))
    print("FACT growth", round((at10k / 10000) / (at500 / 500), 3))
    seed(81)
    var lists = 0
    var fewer = 0
    for k in range(3000):
        var a = random_list(4 if k % 3 == 0 else (20 if k % 3 == 1 else 1000))
        var b = shuffled(a) if k % 2 == 0 else random_list(20)
        ref oc = a.nodes[0].children
        ref nc = b.nodes[0].children
        var p = pairs_of(a, b, oc, nc)
        for i in range(len(p)):
            assert_true(same_key(a.nodes[oc[p[i][0]]], b.nodes[nc[p[i][1]]]), "a pair has the same key")
            assert_true(i == 0 or (p[i][0] > p[i - 1][0] and p[i][1] > p[i - 1][1]), "pairs rise on both sides")
        lists += 1
        if len(p) != longest(a, b, oc, nc):
            fewer += 1
    print("FACT lists", lists)
    print("FACT fewer", fewer)
    # a whole list turned round, and one sorted another way: the exact answers for lists without twins
    var up = List[View]()
    var down = List[View]()
    for i in range(3000):
        up.append(Text("x").tag("t" + String(i)))
        down.append(Text("x").tag("t" + String(2999 - i)))
    var u = VStack(up^)
    var w = VStack(down^)
    var t0 = now_ns()
    assert_equal(len(pairs_of(u, w, u.nodes[0].children, w.nodes[0].children)), 1, "reversed: one stays")
    print("FACT reversed_3000_ms", round(Float64(now_ns() - t0) / 1e6, 2))
    # twins and more edits than it looks for: still valid pairs, and quick
    var many = List[View]()
    var other = List[View]()
    for i in range(3000):
        many.append(Text("x").tag("t" + String(pick(1500))))
        other.append(Text("x").tag("t" + String(pick(1500))))
    var x = VStack(many^)
    var y = VStack(other^)
    t0 = now_ns()
    var p = pairs_of(x, y, x.nodes[0].children, y.nodes[0].children)
    print("FACT tangled_3000_ms", round(Float64(now_ns() - t0) / 1e6, 2))
    for i in range(1, len(p)):
        assert_true(p[i][0] > p[i - 1][0] and p[i][1] > p[i - 1][1], "pairs rise on both sides (tangled)")
    print("diff_long: ok")
