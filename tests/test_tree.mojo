# mojoui.tree (goal 68 M1): a depth-limited CART learned from 20 labelled rows of 100k says its rule in words, guesses
# the rest, reports held-out accuracy, and relearns in well under a second.
#   pixi run mojo build -I . tests/test_tree.mojo -o build/g68/bin/test_tree && build/g68/bin/test_tree
from std.time import perf_counter_ns
from std.random import seed, random_float64
from mojoui.tree import Features, learn_tree, held_out, round_between, number_text


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def truth(speed: Float64, person: Float64) -> Int:
    if speed >= 0.1:
        return 0  # moving
    return 1 if person < 1.5 else 2  # person ahead / waiting


def main() raises:
    check(round_between(0.0873, 0.31) == 0.2, "round 0.0873..0.31 → " + String(round_between(0.0873, 0.31)))
    check(round_between(1.42, 1.61) == 1.5, "round 1.42..1.61 → " + String(round_between(1.42, 1.61)))
    check(round_between(12.0, 47.0) == 30.0, "round 12..47 → " + String(round_between(12.0, 47.0)))
    check(round_between(-3.2, -0.4) == -2.0, "round -3.2..-0.4 → " + String(round_between(-3.2, -0.4)))
    check(number_text(2.0) == "2" and number_text(0.1) == "0.1", "number text")
    print("tree-round: ok")

    seed(68)
    var n = 100_000
    var speed = List[Float64](capacity=n)
    var person = List[Float64](capacity=n)
    var noise = List[Float64](capacity=n)
    var place = List[Int](capacity=n)
    for _ in range(n):
        var stopped = random_float64() < 0.4
        speed.append(random_float64(0.0, 0.08) if stopped else random_float64(0.12, 1.5))
        person.append(random_float64(0.3, 6.0))
        noise.append(random_float64())
        place.append(Int(random_float64(0, 3)))
    var classes: List[String] = ["moving", "person ahead", "waiting"]
    var truths = List[Int](capacity=n)
    for r in range(n):
        truths.append(truth(speed[r], person[r]))
    # (20 rows a person labelled: the first 20 that cover the three classes, as someone scrolling would)
    var labels = List[Int](length=n, fill=-1)
    var have = List[Int](length=3, fill=0)
    var given = 0
    var r = 0
    while given < 20:
        var c = truths[r]
        if have[c] < 8:
            labels[r] = c
            have[c] += 1
            given += 1
        r += 1
    var words: List[String] = ["corridor", "room", "door"]
    var t0 = perf_counter_ns()
    var f = Features(n)
    f.add_number("speed", speed.copy())
    f.add_number("person_m", person.copy())
    f.add_number("noise", noise.copy())
    f.add_words("place", place, words.copy())
    var tree = learn_tree(f, labels, classes, 3)
    var h = held_out(f, labels, classes, 3)
    var right = 0
    var sure_sum = 0.0
    for row in range(n):
        var g = tree.predict(f, row)
        if g.cls == truths[row]:
            right += 1
        sure_sum += g.sure
    var ms = Float64(perf_counter_ns() - t0) / 1e6
    print("  rule:", tree.rule())
    print("  held out:", h.right, "of", h.tried, "; on all", n, "rows:", right, "right;", ms, "ms; mean sure", sure_sum / Float64(n))
    check("speed <" in tree.rule() and "person_m" in tree.rule(), "the rule names speed and person_m")
    check(Float64(right) / Float64(n) > 0.9, "accuracy on the rest")
    check(h.tried == 20 and h.right >= 14, "held out")
    check(ms < 1000.0, "learn + held out + 100k guesses under a second: " + String(ms))
    print("tree-learn: ok")

    # (a text column decides: label by place)
    var lab2 = List[Int](length=n, fill=-1)
    for row in range(30):
        lab2[row] = 1 if place[row] == 2 else 0
    var two: List[String] = ["elsewhere", "at a door"]
    var t2 = learn_tree(f, lab2, two, 2)
    print("  rule:", t2.rule())
    check(t2.rule() == "at a door when place is door; otherwise elsewhere", "a word split")
    # (one class only)
    var lab3 = List[Int](length=n, fill=-1)
    for row in range(5):
        lab3[row] = 0
    var t3 = learn_tree(f, lab3, two, 2)
    check(t3.rule().startswith("always elsewhere"), "one class: " + t3.rule())
    print("tree-words: ok")
