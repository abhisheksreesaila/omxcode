# Review 5's probe, kept: whole documents: an incrementally laid page is a fresh one (lines, heights, drawn ops, caret x, hit), random edits
from mojoui.pagesheet import PageSheet
from mojoui.textedit import Pos
from mojoui.scene import Scene
from mojoui.notesshell import Boxes
from mojoui.graphemes import prev_grapheme, next_grapheme
from mojoui.draw import rect
from std.sys import argv

struct Rng:
    var s: UInt64
    def __init__(out self, seed: Int):
        self.s = UInt64(seed * 2654435761 + 12345)
    def next(mut self, n: Int) -> Int:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Int((self.s >> 33) % UInt64(n))

def piece(mut r: Rng) -> String:
    var all: List[String] = ["the", "quick", "**bold", "bold**", "*it*", "`code`", "```", "```py", "# ", "## ", "- ", "- [ ] ", "1. ", "> ", "\t", "\t\t", "漢字かな交じり文。", "한국어", "नमस्ते", "مرحبا بالعالم", "שלום עולם", "é́", "👩‍👩‍👧‍👦", "🇮🇳🇺🇸", "🇮", "👍🏽", "‍", "́", "​", " ", "\r\n", "\n", "\n\n", "https://example.org/a/b?c=d", "[a](b)", "~~s~~", "a-b-c/d", "supercalifragilisticexpialidocious", "   ", " ", "ﷺ", "กขค", "ไทยภาษา", "İ", "ffi", "﻿", "‮", "𝒳", "​"]
    var k = r.next(len(all) + 2)
    if k >= len(all):
        return String("x") * r.next(400)
    return all[k]

def text(mut r: Rng, n: Int) -> String:
    var t = String("")
    while t.byte_length() < n:
        t += piece(r)
        if r.next(3) > 0:
            t += " "
    return t

def dump(mut s: PageSheet) -> String:
    var t = String("")
    for i in range(len(s.ed.paras)):
        _ = s.lay(i)
        t += "\n#" + String(i) + " h" + String(Int(s.laid[i].height * 64)) + " c" + String(s.laid[i].code) + " "
        for l in s.laid[i].lines:
            t += String(l.start) + "-" + String(l.end) + "@" + String(Int(l.top * 64)) + "h" + String(Int(l.height * 64)) + "b" + String(Int(l.base * 64)) + " "
        for ref g in s.laid[i].segs:
            t += "|" + String(g.text.byte_length()) + ":" + String(g.style.size) + g.style.family
    return t

def main() raises:
    var seeds = 60 if len(argv()) < 2 else Int(argv()[1])
    var base = 5000 if len(argv()) < 3 else Int(argv()[2])
    var bad = 0
    var edits = 0
    for turn in range(seeds):
        var r = Rng(1000 + base + turn)
        var s = PageSheet()
        var w = 80.0 + Float64(r.next(700))
        s.text_w = w
        s.set_markdown(text(r, r.next(2500)))
        for step in range(60):
            var np = len(s.ed.paras)
            var p = r.next(np)
            var n = s.ed.paras[p].byte_length()
            var a = 0 if n == 0 else prev_grapheme(s.ed.paras[p], 1 + r.next(n))
            var k = r.next(14)
            s.ed.move_to(Pos(p, a), False)
            if k < 3:
                s.insert(text(r, 1 + r.next(30)))
            elif k == 3:
                s.insert(piece(r))
            elif k == 4:
                s.insert("\n")
            elif k == 5:  # select across lines and delete / replace
                var q = min(p + r.next(4), np - 1)
                var m = s.ed.paras[q].byte_length()
                s.ed.move_to(Pos(q, 0 if m == 0 else prev_grapheme(s.ed.paras[q], 1 + r.next(m))), True)
                if r.next(2) == 0:
                    _ = s.key("Delete", 0, 0)
                else:
                    s.insert(piece(r))
            elif k == 6:
                _ = s.key("Backspace", 0, 0)
            elif k == 7:
                _ = s.key("Delete", 0, 0)
            elif k == 8:
                for _ in range(1 + r.next(4)):
                    _ = s.key("z", 2, 0)
            elif k == 9:
                for _ in range(1 + r.next(4)):
                    _ = s.key("Z", 3, 0)
            elif k == 10:
                _ = s.key("Tab", r.next(2), 0)
            elif k == 11:
                s.preedit = "にほん" if r.next(2) == 0 else ""
            elif k == 12:
                w = 80.0 + Float64(r.next(700))
                s.text_w = w
            else:
                _ = s.key("Enter", 0, 0)
            edits += 1
            if r.next(3) == 0:
                # layout of only some paragraphs between
                _ = s.lay(min(p, len(s.ed.paras) - 1))
                continue
            var f = PageSheet()
            f.text_w = w
            f.set_markdown(s.markdown())
            f.preedit = s.preedit
            f.ed.move_to(s.ed.caret.copy(), False)
            var x = dump(s)
            var y = dump(f)
            if len(f.ed.paras) != len(s.ed.paras):
                print("PARAS differ turn", turn, "step", step, len(s.ed.paras), len(f.ed.paras))
                bad += 1
                break
            if x != y:
                bad += 1
                print("DIFF turn", turn, "step", step, "k", k, "w", w)
                for i in range(len(s.ed.paras)):
                    if len(s.laid[i].lines) != len(f.laid[i].lines) or s.laid[i].height != f.laid[i].height:
                        print("   para", i, repr(s.ed.paras[i])[byte=0:min(600, repr(s.ed.paras[i]).byte_length())])
                        var u = String("")
                        var v = String("")
                        for l in s.laid[i].lines:
                            u += String(l.start) + " "
                        for l in f.laid[i].lines:
                            v += String(l.start) + " "
                        print("   inc  ", u)
                        print("   fresh", v)
                        break
                break
            # what it draws
            if step % 6 == 0:
                var bx1 = Boxes()
                var bx2 = Boxes()
                s.scroll = 0
                f.scroll = 0
                s.follow = False
                f.follow = False
                s.ed.move_to(s.ed.caret.copy(), False)
                var A = Scene(1600, 900, 1.6)
                var B = Scene(1600, 900, 1.6)
                var W = w + 220 + 34
                s.show_caret = False
                f.show_caret = False
                s.draw(A, bx1, 0, 0, W, 560, 1.6, "x", 0xFFFFFFFF, 8)
                f.draw(B, bx2, 0, 0, W, 560, 1.6, "x", 0xFFFFFFFF, 8)
                # second draw so lay_more is done either way
                for _ in range(6):
                    s.scroll = 0
                    f.scroll = 0
                    A = Scene(1600, 900, 1.6)
                    B = Scene(1600, 900, 1.6)
                    s.draw(A, bx1, 0, 0, W, 560, 1.6, "x", 0xFFFFFFFF, 8)
                    f.draw(B, bx2, 0, 0, W, 560, 1.6, "x", 0xFFFFFFFF, 8)
                if len(A.kinds) != len(B.kinds) or len(A.texts) != len(B.texts):
                    print("DRAWN differ turn", turn, "step", step, len(A.kinds), len(B.kinds))
                    bad += 1
                    break
                var same = True
                for q in range(len(A.nums)):
                    if A.nums[q] != B.nums[q] and not (A.nums[q] != A.nums[q]):
                        same = False
                for q in range(len(A.texts)):
                    if A.texts[q] != B.texts[q]:
                        same = False
                if not same:
                    print("DRAWN nums differ turn", turn, "step", step)
                    bad += 1
                    break
                w = s.text_w
        if s.text_w != w:
            w = s.text_w
    print("edits", edits, "bad", bad)
    if bad > 0:
        raise Error("an incrementally laid page isn't a fresh one")
    print("pagesheetmodel: ok")
