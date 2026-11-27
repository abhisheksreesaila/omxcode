# mojoui.settingswin (goal 79): a settings window the way Personal Note's web one looks: a dimmed app, a floating window
# with a navigation column (heading, close button, search field, groups of pages each with an icon disc; the open page
# lifted as a pill) and a pane (title, blurb, the page's content). Generic: pages are words and Lucide icons; a page's
# content is the app's to draw in the pane's box (skin_cards is the Appearance page's: a card per skin, drawn from
# that skin's own tokens).
#
#   var s = SettingsWindow(); s.groups = …; s.page = 0; var body = s.draw(p, bx, w, h, k, sk)   # → the content box

from mojoui.scene import Painter
from mojoui.skin import Skin, mix, with_alpha
from mojoui.fonttext import TextStyle, measure, line_metrics
from mojoui.notesshell import Boxes, draw_lifted, draw_shadows, draw_bordered, text_at, text_normal
from mojoui.strokeicon import draw_icon

comptime UI = "Geist"


@fieldwise_init
struct SettingsPage(Copyable, Movable):
    var label: String
    var icon: String
    var blurb: String
    var status: String  # a short state ("Paper", "Not installed"): part of the item's name, shown where there's room


struct SettingsWindow(Movable):
    var groups: List[List[SettingsPage]]
    var page: Int  # over all pages, in order
    var title: String
    var search_hint: String

    def __init__(out self, title: String = "Settings", search_hint: String = "Search settings"):
        self.groups = List[List[SettingsPage]]()
        self.page = 0
        self.title = title
        self.search_hint = search_hint

    def draw[P: Painter](self, mut p: P, mut bx: Boxes, w: Float64, h: Float64, k: Float64, sk: Skin) -> Tuple[Float64, Float64, Float64, Float64]:
        p.rect(0, 0, w, h, sk.scrim, 0)
        bx.add("settings.dim", 0, 0, w, h)
        var ww = 900.0
        var wh = 620.0
        var x = (w - ww) / 2
        var y = (h - wh) / 2
        draw_lifted(p, x, y, ww, wh, 20, sk.shadow3, sk.panel)
        bx.add("settings.window", x, y, ww, wh)
        bx.add("settings.frame", x, y, ww, wh)
        # the navigation column
        var nw = 264.0
        p.rect(x, y, nw + 20, wh, with_alpha(sk.ink, 0.035), 20)  # (the window's left corners)
        p.rect(x + nw, y, 20, wh, sk.panel, 0)
        bx.add("settings.nav", x, y, nw, wh)
        var hst = TextStyle(sk.display, sk.display_weight, sk.display_italic, 26)
        hst.letter_spacing = -0.02 * 26
        text_at(p, hst, self.title, x + 24, y + 25.05, 29.9, sk.ink)
        p.rect(x + 214, y + 24, 34, 32, with_alpha(sk.state, 0.06), 16)
        draw_icon(p, "x", x + 222, y + 31, 18, k, sk.ink)
        bx.add("settings.close", x + 214, y + 24, 34, 32)
        bx.add("settings.close-label", x + 214, y + 24, 34, 32)
        draw_bordered(p, x + 14, y + 70, 236, 38, 11, sk.panel, sk.line)
        draw_icon(p, "search", x + 26, y + 81, 16, k, sk.muted)
        var ist = TextStyle(UI, 400, False, 14)
        text_normal(p, ist, self.search_hint, x + 50, y + 70 + 10, sk.muted)
        bx.add("settings.search-box", x + 14, y + 70, 236, 38)
        bx.add("settings.search", x + 50, y + 70, 188, 38)
        bx.add("settings.search-label", x + 50, y + 70, 188, 38)
        var gy = y + 124
        var n = 0
        var cur = SettingsPage("", "", "", "")
        for gi in range(len(self.groups)):
            var gtop = gy
            for ref pg in self.groups[gi]:
                var on = n == self.page
                if on:
                    cur = pg.copy()
                    draw_lifted(p, x + 10, gy, 244, 42, 21, sk.shadow1, sk.panel)
                p.circle(x + 18 + 14, gy + 7 + 14, 14, sk.ink if on else mix(sk.ink, 7, sk.panel))
                draw_icon(p, pg.icon, x + 24, gy + 13, 16, k, sk.panel if on else sk.ink_soft)
                text_normal(p, ist, pg.label, x + 58, gy + 12, sk.ink)
                bx.add("settings.item:" + pg.label + pg.status, x + 10, gy, 244, 42)
                gy += 42
                n += 1
            bx.add("settings.group", x, gtop, nw, gy - gtop)
            gy += 14
        # the pane
        var px = x + nw
        bx.add("settings.pane", px, y, ww - nw, wh)
        var tst = TextStyle(sk.display, sk.display_weight, sk.display_italic, 28)
        tst.letter_spacing = -0.02 * 28
        bx.add("settings.head", px, y, ww - nw, 94.48)
        text_at(p, tst, cur.label, px + 32, y + 26, 32.2, sk.ink)
        bx.add("settings.title:" + cur.label, px + 32, y + 26, ww - nw - 64, 32.19)
        text_at(p, ist, cur.blurb, px + 32, y + 26 + 32.19 + 6, 20.3, sk.muted)
        var cut = String("")
        var m = 0
        for c in cur.blurb.codepoints():
            if m >= 40:
                break
            cut += String(c)
            m += 1
        bx.add("settings.blurb:" + cut, px + 32, y + 64.19, ww - nw - 64, 20.3)
        bx.add("settings.body", px, y + 94.48, ww - nw, wh - 94.48)
        return (px + 32, y + 94.48 + 10, ww - nw - 64, wh - 94.48 - 10)


def skin_cards[P: Painter](mut p: P, mut bx: Boxes, x: Float64, y: Float64, w: Float64, k: Float64, sk: Skin, chosen: String,
                         choices: List[Skin], labels: List[String]):
    """A page of skins to choose from: a card per skin the app offers, each showing a page on that skin's desk in its own
    colours, the chosen one (by name) ringed and ticked. Cards 14 apart across the width."""
    var n = len(choices)
    if n == 0:
        return
    var cw = (w - 14 * Float64(n - 1)) / Float64(n)
    bx.add("settings.page", x, y, w, 152)
    bx.add("settings.choices", x, y, w, 152)
    for i in range(n):
        var cx = x + Float64(i) * (cw + 14)
        ref s = choices[i]
        var on = s.name == chosen
        if on:
            draw_shadows(p, cx, y, cw, 152, 16, sk.shadow2)
            p.rect(cx - 2, y - 2, cw + 4, 156, sk.ink, 18)
        else:
            draw_shadows(p, cx, y, cw, 152, 16, sk.shadow1, 0.3 * 16 + 1)
        p.rect(cx, y, cw, 152, sk.panel, 16)
        bx.add("settings.choice", cx, y, cw, 152)
        var ax = cx + 8
        var ay = y + 8
        var aw = cw - 16
        draw_bordered(p, ax, ay, aw, 104, 10, s.desk, s.edge)
        p.push_clip(ax + 1, ay + 1, aw - 2, 102)
        var ix = ax + aw * 0.22
        var iw = aw * 0.56
        p.rect(ix - 1, ay + 18 - 1, iw + 2, 104 - 18 + 10 + 2, s.edge, 7)
        p.rect(ix, ay + 18, iw, 104 - 18 + 10, s.panel, 6)
        var lx = ax + aw * 0.30
        var lw = aw * 0.40
        var ink = with_alpha(s.ink, 0.6)
        p.rect(lx, ay + 34, lw, 5, ink, 2.5)
        p.rect(lx, ay + 48, lw, 5, ink, 2.5)
        p.rect(lx + 1, ay + 63, lw - 2, 3, ink, 1.5)
        p.pop_clip()
        bx.add("settings.art", ax, ay, aw, 104)
        var bst = TextStyle(UI, 700, False, 14)
        text_normal(p, bst, labels[i], ax + 4, ay + 104 + 10, sk.ink)
        if on:
            draw_icon(p, "check", cx + cw - 14 - 16, y + 152 - 12 - 16, 16, k, sk.ink)


# ---- a settings page's form (goal 82 M6): rows of a label and a control, drawn in the pane's box ----------------------
# A choice (pills, one chosen), a text field (tap to type in it; Enter ends, Escape puts it back), a secret field (what is
# typed shows as dots; once saved, only "Saved in <where>"), a line of words, buttons, a status line. The app keeps the
# values; taps come back as names: "choice:<id>:<k>", "button:<id>:<k>", "field:<id>" (typing started there).
#
#   var f = SettingsForm(); f.rows.append(FormRow.choice("provider", "Use", ["Claude Code", "Azure", …], 0)) …
#   f.draw(p, bx, x, y, w, k, sk);  var hit = f.tap(bx, x, y);  f.type(text) / f.backspace() / f.done() / f.cancel()

comptime ROW_CHOICE = 0
comptime ROW_FIELD = 1
comptime ROW_SECRET = 2
comptime ROW_NOTE = 3
comptime ROW_BUTTONS = 4
comptime ROW_STATUS = 5


struct FormRow(Copyable, Movable):
    var kind: Int
    var id: String
    var label: String
    var value: String  # a field's text; a note's or status's words; a secret's "saved" words when one is saved
    var hint: String  # a field's placeholder
    var options: List[String]  # a choice's pills, or the buttons
    var chosen: Int
    var error: Bool  # a status that is a refusal

    def __init__(out self, kind: Int, id: String, label: String, value: String = "", hint: String = "", options: List[String] = List[String](), chosen: Int = 0):
        self.kind = kind
        self.id = id
        self.label = label
        self.value = value
        self.hint = hint
        self.options = options.copy()
        self.chosen = chosen
        self.error = False


struct SettingsForm(Movable):
    var rows: List[FormRow]
    var editing: String  # the field being typed into ("": none)
    var draft: String  # its words while typed (a secret's never leave here but to the app's save)
    var was: String  # its words before typing began (Escape puts them back)
    var secret_out: String  # a secret field's words once its typing ended, until the app takes them (take_secret)

    def __init__(out self):
        self.rows = List[FormRow]()
        self.editing = ""
        self.draft = ""
        self.was = ""
        self.secret_out = ""

    def row(self, id: String) -> Int:
        for k in range(len(self.rows)):
            if self.rows[k].id == id:
                return k
        return -1

    def value(self, id: String) -> String:
        var k = self.row(id)
        if k < 0:
            return ""
        return self.draft if self.editing == id else self.rows[k].value

    def draw[P: Painter](self, mut p: P, mut bx: Boxes, x: Float64, y: Float64, w: Float64, k: Float64, sk: Skin) -> Float64:
        var lst = TextStyle(UI, 500, False, 14)
        var vst = TextStyle(UI, 400, False, 14)
        var cy = y + 6
        var lw = 132.0
        for ref r in self.rows:
            if r.kind == ROW_NOTE or r.kind == ROW_STATUS:
                var col = sk.danger if r.error else sk.muted
                for line in _wrapped(vst, r.value, w):
                    text_at(p, vst, line, x, cy, 20, col)
                    cy += 20
                bx.add("settings.form." + r.id, x, cy - 20, w, 20)
                cy += 10
                continue
            if r.kind == ROW_BUTTONS:
                var bx0 = x
                for i in range(len(r.options)):
                    var bw = measure(TextStyle(UI, 600, False, 13), r.options[i]) + 28
                    draw_lifted(p, bx0, cy, bw, 32, 16, sk.shadow2, sk.panel)
                    text_at(p, TextStyle(UI, 600, False, 13), r.options[i], bx0 + 14, cy, 32, sk.ink)
                    bx.add("settings.button:" + r.id + ":" + String(i), bx0, cy, bw, 32)
                    bx0 += bw + 10
                cy += 32 + 14
                continue
            text_at(p, lst, r.label, x, cy, 36, sk.ink)
            var fx = x + lw
            var fw = w - lw
            if r.kind == ROW_CHOICE:
                var px = fx
                var pst = TextStyle(UI, 500, False, 13)
                for i in range(len(r.options)):
                    var pw = measure(pst, r.options[i]) + 26
                    var on = i == r.chosen
                    if on:
                        p.rect(px, cy + 2, pw, 32, sk.ink, 16)
                    else:
                        draw_bordered(p, px, cy + 2, pw, 32, 16, sk.panel, sk.line)
                    text_at(p, pst, r.options[i], px + 13, cy + 2, 32, sk.panel if on else sk.ink)
                    bx.add("settings.choice:" + r.id + ":" + String(i), px, cy + 2, pw, 32)
                    px += pw + 8
            else:
                var typing = self.editing == r.id
                draw_bordered(p, fx, cy, fw, 36, 10, sk.panel, sk.ink if typing else sk.line, 2 if typing else 1)
                var shown = self.draft if typing else r.value
                var col = sk.ink
                if r.kind == ROW_SECRET:
                    if typing:
                        shown = String("•") * _count_chars(self.draft)
                    elif r.value != "":
                        col = sk.muted
                if shown == "" and not typing:
                    shown = r.hint
                    col = sk.muted
                p.push_clip(fx + 1, cy + 1, fw - 2, 34)
                text_at(p, vst, shown, fx + 12, cy, 36, col)
                if typing:
                    var cx = fx + 12 + measure(vst, shown)
                    p.rect(cx + 1, cy + 9, 1.5, 18, sk.ink, 0)
                p.pop_clip()
                bx.add("settings.field:" + r.id, fx, cy, fw, 36)
            cy += 36 + 12
        return cy - y

    def tap(mut self, bx: Boxes, x: Float64, y: Float64) -> String:
        """What a tap in the form meant ("" nothing); a tap on a field starts typing there (a tap elsewhere ends it)."""
        var hit = bx.hit_any(x, y, ["settings.choice:", "settings.button:", "settings.field:"])
        if hit == "":
            return ""
        var name = String(hit[byte = 9:])  # (after "settings.")
        var at = name.find("@")  # (a name drawn twice this frame: Boxes adds @2)
        if at >= 0:
            var _cut3 = String(name[byte = 0:at])
            name = _cut3^
        if name.startswith("field:"):
            var id = String(name[byte = 6:])
            if self.editing != id:
                _ = self.done()
                var k = self.row(id)
                self.editing = id
                self.was = self.rows[k].value
                self.draft = "" if self.rows[k].kind == ROW_SECRET else self.rows[k].value
            return name
        _ = self.done()
        if name.startswith("choice:"):
            var rest = String(name[byte = 7:])
            var c = rest.rfind(":")
            var k = self.row(String(rest[byte = 0:c]))
            try:
                self.rows[k].chosen = Int(String(rest[byte = c + 1 :]))
            except:
                pass
        return name

    def type(mut self, text: String) -> Bool:
        if self.editing == "":
            return False
        for c in text.codepoints():
            if Int(c) >= 32:
                self.draft += String(c)
        return True

    def backspace(mut self) -> Bool:
        if self.editing == "":
            return False
        var n = _count_chars(self.draft)
        var out = String("")
        var i = 0
        for c in self.draft.codepoints():
            if i < n - 1:
                out += String(c)
            i += 1
        self.draft = out^
        return True

    def done(mut self) -> String:
        """Typing ends: the field keeps its words (a secret's go to the caller: returned, and the row keeps only its saved
        words). Returns the id of the field that ended ("" none)."""
        if self.editing == "":
            return ""
        var id = self.editing
        var k = self.row(id)
        if self.rows[k].kind != ROW_SECRET:
            self.rows[k].value = self.draft
        elif self.draft != "":
            self.secret_out = self.draft
        self.draft = ""
        self.editing = ""
        return id

    def cancel(mut self):
        if self.editing != "":
            var k = self.row(self.editing)
            self.rows[k].value = self.was
        self.editing = ""
        self.draft = ""

    def take_secret(mut self) -> String:
        """A secret field's typed words, handed over once (then gone from here)."""
        var s = self.secret_out
        self.secret_out = ""
        return s^

    def say(mut self, id: String, words: String, error: Bool = False):
        var k = self.row(id)
        if k >= 0:
            self.rows[k].value = words
            self.rows[k].error = error


def _count_chars(s: String) -> Int:
    var n = 0
    for _ in s.codepoints():
        n += 1
    return n


def _wrapped(st: TextStyle, text: String, w: Float64) -> List[String]:
    var out = List[String]()
    var line = String("")
    for wd in text.split(" "):
        var trial = String(wd) if line == "" else line + " " + String(wd)
        if line != "" and measure(st, trial) > w:
            out.append(line)
            line = String(wd)
        else:
            line = trial
    if line != "":
        out.append(line)
    return out^
