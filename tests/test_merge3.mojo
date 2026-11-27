# mojoui.merge3 (goal 82 M7): a three-way merge by named items. Their deletion of an item mine left alone stays a deletion;
# their additions and changes are taken; mine's are kept; anything that overlaps isn't merged. A random model checks the
# rules on 2,000 seeds against a set-based oracle (and 4 mutants of the rules must each fail it). merge3: ok
from std.testing import assert_true, assert_equal
from std.random import random_ui64, seed
from mojoui.merge3 import merge_keyed, Merged
from mojoui.json import Json


def doc(items: List[String], page: String = '{"columns":1}') -> String:
    var s = String('{"nodes":[')
    for k in range(len(items)):
        s += ("," if k > 0 else "") + items[k]
    return s + '],"edges":[],"pn":{"page":' + page + "}}"


def node(id: String, text: String) -> String:
    return '{"id":"' + id + '","type":"text","text":"' + text + '"}'


def ids_texts(text: String) raises -> List[String]:
    var j = Json.parse(text)
    var out = List[String]()
    var n = j.get(0, "nodes")
    for k in range(j.size(n)):
        out.append(j.text(j.get(j.at(n, k), "id")) + "=" + j.text(j.get(j.at(n, k), "text")))
    return out^


def basics() raises:
    var base = doc([node("a", "A"), node("b", "B"), node("c", "C")])
    # they delete b; mine adds d and changes a
    var theirs = doc([node("a", "A"), node("c", "C")])
    var mine = doc([node("a", "A2"), node("b", "B"), node("c", "C"), node("d", "D")])
    var m = merge_keyed(base, mine, theirs, ["nodes", "edges"])
    assert_true(m.ok, m.why)
    var got = ids_texts(m.text)
    assert_true(len(got) == 3 and got[0] == "a=A2" and got[1] == "c=C" and got[2] == "d=D", "b stays deleted: " + m.text)
    assert_equal(m.deleted, 1)
    # they change c and add e; mine deletes a
    theirs = doc([node("a", "A"), node("b", "B"), node("c", "C3"), node("e", "E")])
    mine = doc([node("b", "B"), node("c", "C")])
    m = merge_keyed(base, mine, theirs, ["nodes", "edges"])
    got = ids_texts(m.text)
    assert_true(m.ok and len(got) == 3 and got[0] == "b=B" and got[1] == "c=C3" and got[2] == "e=E", m.text)
    # overlaps: not merged
    assert_true(not merge_keyed(base, doc([node("a", "A"), node("b", "B2"), node("c", "C")]), doc([node("a", "A"), node("c", "C")]), ["nodes"]).ok, "deleted there, changed here")
    assert_true(not merge_keyed(base, doc([node("a", "X"), node("b", "B"), node("c", "C")]), doc([node("a", "Y"), node("b", "B"), node("c", "C")]), ["nodes"]).ok, "changed on both sides")
    assert_true(merge_keyed(base, doc([node("a", "X"), node("b", "B"), node("c", "C")]), doc([node("a", "X"), node("b", "B"), node("c", "C")]), ["nodes"]).ok, "the same change on both sides")
    assert_true(not merge_keyed(base, doc([node("a", "A"), node("c", "C")]), doc([node("a", "A"), node("b", "B9"), node("c", "C")]), ["nodes"]).ok, "deleted here, changed there")
    # a top-level member: theirs taken when mine left it; both changed: not merged
    m = merge_keyed(base, doc([node("a", "A"), node("b", "B"), node("c", "C")]), doc([node("a", "A"), node("b", "B"), node("c", "C")], '{"columns":2}'), ["nodes", "edges"])
    assert_true(m.ok and m.text.find('"columns":2') >= 0, m.text)
    assert_true(not merge_keyed(base, doc([node("a", "A"), node("b", "B"), node("c", "C")], '{"columns":3}'), doc([node("a", "A"), node("b", "B"), node("c", "C")], '{"columns":2}'), ["nodes"]).ok)
    # whitespace and key order don't count; mine's own bytes kept where it is mine
    var spaced = '{ "nodes" : [ {"type":"text", "id":"a","text":"A"}, ' + node("b", "B") + ", " + node("c", "C") + '],"edges":[],"pn":{"page":{"columns":1}}}'
    m = merge_keyed(base, spaced, doc([node("a", "A"), node("c", "C")]), ["nodes", "edges"])
    assert_true(m.ok and m.text.find('{"type":"text", "id":"a","text":"A"}') >= 0 and ids_texts(m.text).__len__() == 2, m.text)
    # nothing to merge: no names
    assert_true(not merge_keyed('{"nodes":[{"x":1}]}', '{"nodes":[{"x":1}]}', '{"nodes":[{"x":2}]}', ["nodes"]).ok)
    print("  basics: ok", flush=True)


def rnd(n: Int) -> Int:
    return Int(random_ui64(0, UInt64(n - 1)))


def model(mutant: Int) raises -> Int:
    """Random base/mine/theirs; the oracle's rules on sets; how many seeds disagree with merge_keyed. Mutants: the oracle is
    wrong in one rule each, so a merge that agreed with it would be wrong."""
    var bad = 0
    for s in range(2000):
        seed(s * 7 + 1)
        var base = List[String]()
        var texts = List[String]()
        var n = 1 + rnd(5)
        for k in range(n):
            base.append(String("n") + String(k))
            texts.append(String("t") + String(k))
        var mine_ids = List[String]()
        var mine_t = List[String]()
        var their_ids = List[String]()
        var their_t = List[String]()
        for k in range(n):  # each side: keep, change or delete each item
            var a = rnd(3)
            if a != 2:
                mine_ids.append(base[k])
                mine_t.append(texts[k] if a == 0 else texts[k] + "m")
            var b = rnd(3)
            if b != 2:
                their_ids.append(base[k])
                their_t.append(texts[k] if b == 0 else texts[k] + ("m" if rnd(4) == 0 else "t"))
        if rnd(2) == 0:
            mine_ids.append("x1")
            mine_t.append("new")
        if rnd(2) == 0:
            their_ids.append("y1")
            their_t.append("new")
        var bn = List[String]()
        for k in range(n):
            bn.append(node(base[k], texts[k]))
        var mn = List[String]()
        for k in range(len(mine_ids)):
            mn.append(node(mine_ids[k], mine_t[k]))
        var tn = List[String]()
        for k in range(len(their_ids)):
            tn.append(node(their_ids[k], their_t[k]))
        # the oracle
        var ok = True
        var want = List[String]()
        for k in range(n):
            var mi = -1
            var ti = -1
            for q in range(len(mine_ids)):
                if mine_ids[q] == base[k]:
                    mi = q
            for q in range(len(their_ids)):
                if their_ids[q] == base[k]:
                    ti = q
            var mc = mi >= 0 and mine_t[mi] != texts[k]
            var tc = ti >= 0 and their_t[ti] != texts[k]
            if mi < 0 and ti < 0:
                continue
            if mi < 0:
                if tc:
                    ok = False
                continue
            if ti < 0:
                if mc and mutant != 1:
                    ok = False
                continue
            if mc and tc and mine_t[mi] != their_t[ti]:
                if mutant != 2:
                    ok = False
                continue
            want.append(base[k] + "=" + (their_t[ti] if (tc and not mc) != (mutant == 3) else mine_t[mi]))
        for q in range(len(mine_ids)):
            if mine_ids[q] == "x1":
                want.append("x1=new")
        for q in range(len(their_ids)):
            if their_ids[q] == "y1" and mutant != 4:
                want.append("y1=new")
        var m = merge_keyed(doc(bn), doc(mn), doc(tn), ["nodes", "edges"])
        if m.ok != ok:
            bad += 1
            continue
        if not ok:
            continue
        var got = ids_texts(m.text)
        var same = len(got) == len(want)
        if same:
            for w in want:
                if w not in got:
                    same = False
        if not same:
            bad += 1
    return bad


def main() raises:
    basics()
    var wrong = model(0)
    print("FACT merge3_seeds 2000", flush=True)
    print("FACT merge3_wrong " + String(wrong), flush=True)
    assert_equal(wrong, 0, "the merge agrees with the oracle")
    var caught = 0
    for mu in range(1, 5):
        if model(mu) > 0:
            caught += 1
    print("FACT merge3_mutants_caught " + String(caught) + " of 4", flush=True)
    assert_equal(caught, 4)
    print("merge3: ok", flush=True)
