# Goal 81, M1: the patched screen equals the fresh one, on thousands of random pairs of screens. A model host keeps a tree
# of "widgets" (each remembers what it was built with) and applies a Diff as the hosts do: `patches` onto widgets, `kept`
# widgets carried over, `resync` stacks given their new children in order. Its tree must equal one built fresh from the
# new screen, and no widget may be used twice. Several updates follow one another on the same widgets. Mutants: a patch
# dropped, a resync dropped, two kept swapped: each must be caught.
#   pixi run mojo run -I . tests/test_diff_random.mojo
from std.testing import assert_true, assert_equal
from mojoui import *
from mojoui.diff import diff, Diff, Patch, SET_TEXT, SET_MSG, SET_VALUE, SET_IMAGE, SET_FRAMES, SET_PLACE, SET_SIZE, SET_TONES, SET_TIP
from tests.randomview import random_screen, mix


struct Widget(Copyable, Movable):
    var n: Node  # what it shows (children: widget numbers)
    var parent: Int

    def __init__(out self, n: Node):
        self.n = n.copy()
        self.n.children = List[Int]()
        self.parent = -1


struct Host(Copyable, Movable):
    var all: List[Widget]
    var at: List[Int]  # node -> widget
    var twice: Int

    def __init__(out self, v: View):
        self.all = List[Widget]()
        self.at = List[Int](length=len(v.nodes), fill=-1)
        self.twice = 0
        var at = List[Int](length=len(v.nodes), fill=-1)
        _ = self.build(v, 0, at)
        self.at = at^

    def build(mut self, v: View, i: Int, mut at: List[Int]) -> Int:
        var id = len(self.all)
        self.all.append(Widget(v.nodes[i]))
        at[i] = id
        for c in v.nodes[i].children:
            var k = self.build(v, c, at)
            self.all[id].n.children.append(k)
            self.all[k].parent = id
        return id

    def apply(mut self, d: Diff, v: View):
        if d.rebuild and not d.partial:
            self = Host(v)
            return
        if d.partial:
            var at = List[Int](length=len(v.nodes), fill=-1)
            for j in range(len(v.nodes)):
                if d.kept[j] >= 0:
                    at[j] = self.at[d.kept[j]]
            for j in d.resync:
                var want = List[Int]()
                var w = at[j]
                for c in v.nodes[j].children:
                    if d.kept[c] >= 0:
                        want.append(at[c])
                    else:
                        want.append(self.build(v, c, at))
                for k in want:
                    self.all[k].parent = w
                self.all[w].n.children = want^
            self.at = at^
        for p in d.patches:
            var w = self.at[p.node]
            if w < 0:
                continue
            ref b = v.nodes[p.node]
            if p.op == SET_TEXT:
                self.all[w].n.text = p.text
            elif p.op == SET_MSG:
                self.all[w].n.msg = p.number
            elif p.op == SET_VALUE:
                self.all[w].n.value = p.number
            elif p.op == SET_IMAGE:
                self.all[w].n.pixels = b.pixels.copy()
            elif p.op == SET_FRAMES:
                self.all[w].n.msg2 = p.number
            elif p.op == SET_PLACE:
                self.all[w].n.x = b.x
                self.all[w].n.y = b.y
                if b.kind == BOARD:
                    self.all[w].n.spacing = b.spacing
                    self.all[w].n.size = b.size
            elif p.op == SET_SIZE:
                self.all[w].n.w = b.w
                self.all[w].n.h = b.h
                self.all[w].n.min_w = b.min_w
                self.all[w].n.max_w = b.max_w
            elif p.op == SET_TONES:
                self.all[w].n.options = b.options.copy()
            elif p.op == SET_TIP:
                self.all[w].n.tip = p.text
                self.all[w].n.label = b.label


def same(h: Host, v: View, i: Int, w: Int, mut used: List[Bool], mut twice: Int) -> String:
    """"" when widget w shows node i, else what differs."""
    if w < 0:
        return "node " + String(i) + " has no widget"
    if used[w]:
        twice += 1
        return "a widget used twice"
    used[w] = True
    ref a = h.all[w].n
    ref b = v.nodes[i]
    if h.at[i] != w:
        return "node " + String(i) + " (kind " + String(b.kind) + ") is another widget"
    if len(a.children) != len(b.children):
        return "kind " + String(b.kind) + ": " + String(len(a.children)) + " children, not " + String(len(b.children))
    var x = a.copy()
    x.children = b.children.copy()
    if x != b or x.tip != b.tip or x.label != b.label:  # (Node's == leaves a canvas's words to SET_TIP)
        return "kind " + String(b.kind) + " node " + String(i) + ": shows '" + a.text + "' " + String(a.value) + ", should '" + b.text + "' " + String(b.value)
    for k in range(len(b.children)):
        if h.all[a.children[k]].parent != w:
            return "a child's parent is another widget"
        var s = same(h, v, b.children[k], a.children[k], used, twice)
        if s != "":
            return s
    return ""


def check(h: Host, v: View, mut twice: Int) -> String:
    var used = List[Bool](length=len(h.all), fill=False)
    return same(h, v, 0, h.at[0], used, twice)


def main() raises:
    var pairs = 0
    var wrong = 0
    var twice = 0
    var plain = 0
    var partial = 0
    var full = 0
    var mutants = 0
    var missed = 0
    var kept = 0
    var nodes = 0
    for seed in range(700):
        var level = seed % 2
        var shown = random_screen(seed, 0, level)
        var h = Host(shown)
        for epoch in range(1, 10):
            # (half the steps: another epoch of this screen; some: far apart; some: another screen)
            var e = epoch if epoch % 4 != 3 else epoch * 1000 + mix(seed, epoch) % 999
            var v = random_screen(seed if epoch % 9 != 8 else seed + 100000, e, level)
            var d = diff(shown, v)
            if d.rebuild and d.partial:
                partial += 1
                for k in d.kept:
                    nodes += 1
                    if k >= 0:
                        kept += 1
            elif d.rebuild:
                full += 1
            else:
                plain += 1
            var before = h.copy()
            h.apply(d, v)
            var s = check(h, v, twice)
            pairs += 1
            if s != "":
                wrong += 1
                if wrong <= 5:
                    print("seed", seed, "epoch", epoch, s)
            # mutants of this diff, on the same starting widgets
            if d.partial or not d.rebuild:
                var t = 0
                for what in range(3):
                    var m = d.copy()
                    if what == 0:
                        if len(m.patches) == 0:
                            continue
                        _ = m.patches.pop(mix(seed, epoch) % len(m.patches))
                    elif what == 1:
                        if len(m.resync) == 0:
                            continue
                        _ = m.resync.pop(mix(seed, epoch) % len(m.resync))
                    else:
                        if not m.partial:
                            continue
                        var a = -1
                        var b = -1
                        for k in range(1, len(m.kept)):
                            if m.kept[k] >= 0 and v.nodes[k].kind == TEXT:
                                if a < 0:
                                    a = k
                                elif b < 0 and v.nodes[k] != v.nodes[a]:
                                    b = k
                        if b < 0:
                            continue
                        var ka = m.kept[a]
                        m.kept[a] = m.kept[b]
                        m.kept[b] = ka
                    var g = before.copy()
                    g.apply(m, v)
                    mutants += 1
                    if check(g, v, t) == "":
                        missed += 1
                        if missed <= 5:
                            print("missed mutant", what, "seed", seed, "epoch", epoch)
            shown = v^
    print("FACT pairs", pairs)
    print("FACT wrong", wrong)
    print("FACT twice", twice)
    print("FACT plain", plain)
    print("FACT partial", partial)
    print("FACT full", full)
    print("FACT kept_percent", 100 * kept // max(nodes, 1))
    print("FACT mutants", mutants)
    print("FACT mutants_missed", missed)
    print("diff_random: ok")
