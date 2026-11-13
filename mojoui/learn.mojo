# mojoui.learn: Learn from my labels, on any sheet (goal 68 M1). A person names a label column, labels about 20 rows
# (typed, or picked from the labels so far), presses Learn: a decision tree (mojoui.tree, in Mojo, on the sheet's own
# columns) fills the rest, says its rule in words, how sure it is per row, and how often it was right on labelled rows
# it never saw. Change a label and it learns again.
#
#   var panel = LearnPanel(msg_base=7900)                   # messages 7900 … 7900 + LEARN_MESSAGES
#   view():    Inspector(["Learn"], 0, …, panel.view(sheet, row), …)
#   update():  var did = panel.update(event)                 # LP_ADD, LP_LEARN, LP_PICK (+ panel.picked), LP_ROWS, LP_CLOSED
#   LP_ADD:    var t = with_label_column(sheet, panel.label) # the sheet's table + an empty text column; the app swaps it in
#   LP_LEARN:  var l = learn_sheet(sheet, panel.label); panel.learned(l); swap in l.table   (learned + sure columns)
#   LP_ROWS:   label_rows(panel.rows_text) → (row, label) pairs the app writes (the agent's way to label)
#
# Tags (an agent's tools): label-name, add-label, label-pick-<k>, label-new, label-rows, learn, learn-close.
# The tree reads every column but the label's own, its outputs, times and ids (t, t_ns, *_ns, id, *_id, frame, row,
# episode) and text columns that are nearly all different (names, paths).

from std.time import perf_counter_ns
from omxcore import Table, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL, INT as MX_INT, DATE as MX_DATE, BOOL as MX_BOOL
from mojoui.app import Event
from mojoui.sheet import Sheet, TEXT as SHEET_TEXT, DECIMAL as SHEET_DECIMAL
from mojoui.tree import Features, DecisionTree, HeldOut, learn_tree, held_out
from mojoui.view import (View, Text, Button, TextField, TextArea, VStack, HStack, Spacer, CAPTION, HEADLINE, PROMINENT, SUBTLE,
                         CENTER, START, TONE_ACCENT, TONE_WARN)

comptime LEARN_MESSAGES = 40  # name, add, learn, close, new label, rows, rows submit, then picks (32)
comptime LP_NAME = 0
comptime LP_ADD_MSG = 1
comptime LP_LEARN_MSG = 2
comptime LP_CLOSE = 3
comptime LP_NEW = 4  # the new-label field's text
comptime LP_NEW_SUBMIT = 5  # … its Return: write it in the selected row
comptime LP_ROWS_TEXT = 6
comptime LP_ROWS_MSG = 7  # label-rows' Return
comptime LP_PICK_MSG = 8  # … 39: pick label k (k < MAX_PICKS)
comptime MAX_PICKS = 32
comptime LEARN_DEPTH = 3
comptime ENOUGH = 20  # labels that are "about enough" (what the panel asks for)

comptime LP_NONE = 0  # what update() asks the app to do
comptime LP_ADD = 1
comptime LP_LEARN = 2
comptime LP_PICK = 3
comptime LP_ROWS = 4
comptime LP_CLOSED = 5


def learned_name(label: String) -> String:
    return label + " (learned)"


def sure_name(label: String) -> String:
    return label + " sure %"


def _skipped(name: String, label: String) -> Bool:
    var n = name.lower()
    if name == label or name == learned_name(label) or name == sure_name(label):
        return True
    if n == "t" or n == "t_ns" or n.endswith("_ns") or n == "time" or n == "timestamp" or n == "id" or n.endswith("_id"):
        return True
    return n == "frame" or n == "row" or n == "episode" or n == "item"


def features_of(sheet: Sheet, label: String) -> Features:
    """The sheet's columns a tree may read (see the header), as numbers or words."""
    var n = sheet.rows()
    var f = Features(n)
    for c in range(sheet.columns()):
        var name = sheet.name(c)
        if _skipped(name, label):
            continue
        var kind = sheet.kind(c)
        if kind == SHEET_TEXT:
            var words = sheet.word_count(c)
            if words > 50 and words * 2 > n:
                continue
            var codes = List[Int](capacity=n)
            var names = List[String](capacity=words)
            for w in range(words):
                names.append(sheet.text_of(c, Int64(w)))
            for r in range(n):
                codes.append(-1 if sheet.is_null(c, r) else Int(sheet.value(c, r)))
            f.add_words(name, codes, names^)
        else:
            var div = 1.0
            for _ in range(sheet.scale(c) if kind == SHEET_DECIMAL else 0):
                div *= 10.0
            var v = List[Float64](capacity=n)
            var nan = Float64(0) / Float64(0)
            for r in range(n):
                v.append(nan if sheet.is_null(c, r) else Float64(sheet.value(c, r)) / div)
            f.add_number(name, v^)
    return f^


struct Learned(Movable):
    var table: Table  # the sheet's table with <label> (learned) and <label> sure % filled
    var tree: DecisionTree
    var held: HeldOut
    var classes: List[String]
    var labelled: Int
    var rows: Int
    var ms: Float64  # reading the columns, learning, the held-out runs and guessing every row
    var table_ms: Float64  # writing the new table

    def __init__(out self, var table: Table, var tree: DecisionTree, held: HeldOut, var classes: List[String], labelled: Int, rows: Int, ms: Float64, table_ms: Float64):
        self.table = table^
        self.tree = tree^
        self.held = held
        self.classes = classes^
        self.labelled = labelled
        self.rows = rows
        self.ms = ms
        self.table_ms = table_ms

    def take_table(mut self) -> Table:
        """The new table, handed over (an empty one left behind)."""
        var t = Table.empty()
        swap(self.table, t)
        return t^


def copy_table(t: Table, drop: List[String]) raises -> Table:
    """t's columns but the ones named in drop, values and nulls as they are (text by word)."""
    var out = Table.empty()
    for c in range(t.columns()):
        if t.name(c) in drop:
            continue
        var k = t.kind(c)
        var d = out.add_column(t.name(c), k, t.scale(c))
        var codes = List[Int64]()
        if k == MX_TEXT:
            var words = t.dictionary(c)
            for w in words:
                codes.append(Int64(out.add_word(d, String(w))))
        for r in range(t.rows()):
            if t.is_null(c, r):
                out.append_null(d)
            elif k == MX_TEXT:
                out.append(d, codes[Int(t.get(c, r))])
            else:
                out.append(d, t.get(c, r))
    return out^


def with_label_column(sheet: Sheet, label: String) raises -> Table:
    """The sheet's table (its edits in) and an empty text column `label` at the end."""
    if label == "":
        raise Error("Name the label column first (for example: cause)")
    if sheet.index(label) >= 0:
        raise Error("There's already a column " + label + ": pick another name, or label in that one")
    var base = sheet.frame.bake()
    var t = copy_table(base, List[String]())
    var c = t.add_column(label, MX_TEXT)
    for _ in range(t.rows()):
        t.append_null(c)
    t.check()
    return t^


def learn_sheet(sheet: Sheet, label: String, depth: Int = LEARN_DEPTH) raises -> Learned:
    """A tree from the rows labelled in `label`; the sheet's table back with what it guessed for every row."""
    var lc = sheet.index(label)
    if lc < 0:
        raise Error("No column " + label + " to learn from")
    var t0 = perf_counter_ns()
    var n = sheet.rows()
    var classes = List[String]()
    var labels = List[Int](length=n, fill=-1)
    var labelled = 0
    for r in range(n):
        if not sheet.alive(r) or sheet.is_null(lc, r):
            continue
        var text = String(sheet.plain_text(lc, r).strip())
        if text == "":
            continue
        var k = -1
        for i in range(len(classes)):
            if classes[i] == text:
                k = i
        if k < 0:
            k = len(classes)
            classes.append(text)
        labels[r] = k
        labelled += 1
    if len(classes) < 2:
        raise Error("Label rows with at least two different labels first (" + String(labelled) + " labelled, " + String(len(classes)) + " kind)")
    var f = features_of(sheet, label)
    if f.columns() == 0:
        raise Error("No column to learn from: the sheet has only the labels, times and ids")
    var tree = learn_tree(f, labels, classes, depth)
    var held = held_out(f, labels, classes, depth)
    var guess = List[Int](capacity=n)
    var sure = List[Int](capacity=n)
    for r in range(n):
        var g = tree.predict(f, r)
        guess.append(g.cls)
        sure.append(Int(g.sure * 100.0 + 0.5))
    var ms = Float64(perf_counter_ns() - t0) / 1e6
    var t1 = perf_counter_ns()
    var drop = List[String]()
    drop.append(learned_name(label))
    drop.append(sure_name(label))
    var out = copy_table(sheet.frame.bake(), drop)
    var cg = out.add_column(learned_name(label), MX_TEXT)
    var codes = List[Int64]()
    for c in classes:
        codes.append(Int64(out.add_word(cg, c)))
    var cs = out.add_column(sure_name(label), MX_INT)
    for r in range(out.rows()):
        out.append(cg, codes[guess[r]] if r < n else 0)
        out.append(cs, Int64(sure[r]) if r < n else 0)
    out.check()
    var table_ms = Float64(perf_counter_ns() - t1) / 1e6
    return Learned(out^, tree^, held, classes^, labelled, n, ms, table_ms)


def label_rows(text: String) -> List[Tuple[Int, String]]:
    """"12 person ahead" pieces (a row number from 1, then its label; ",", ";" or a new line between): the agent's labels."""
    var out = List[Tuple[Int, String]]()
    for chunk in text.replace(";", "\n").replace(",", "\n").split("\n"):
        var line = String(chunk.strip())
        var sp = line.find(" ")
        if sp <= 0:
            continue
        try:
            var row = Int(String(line[byte=:sp]))
            var lab = String(line[byte = sp + 1 :].strip())
            if row >= 1 and lab != "":
                out.append((row - 1, lab))
        except:
            pass
    return out^


def _grouped(n: Int) -> String:
    var s = String(n)
    var out = String("")
    var k = 0
    for i in range(s.byte_length() - 1, -1, -1):
        out = String(s[byte = i : i + 1]) + out
        k += 1
        if k % 3 == 0 and i > 0:
            out = "," + out
    return out


struct LearnPanel(Movable):
    var msg_base: Int
    var open: Bool
    var label: String  # the label column ("" until one is named)
    var name_text: String
    var new_text: String
    var rows_text: String
    var picks: List[String]  # the labels so far (the chips)
    var picked: String  # the label LP_PICK writes
    var rule: String
    var rule_lines: List[String]
    var said: String  # a problem, in words (what to do next)
    var held: HeldOut
    var labelled: Int
    var filled: Int
    var ms: Float64
    var used: List[String]
    var learned_once: Bool

    def __init__(out self, msg_base: Int):
        self.msg_base = msg_base
        self.open = False
        self.label = ""
        self.name_text = ""
        self.new_text = ""
        self.rows_text = ""
        self.picks = List[String]()
        self.picked = ""
        self.rule = ""
        self.rule_lines = List[String]()
        self.said = ""
        self.held = HeldOut(0, 0)
        self.labelled = 0
        self.filled = 0
        self.ms = 0.0
        self.used = List[String]()
        self.learned_once = False

    def owns(self, m: Int) -> Bool:
        return self.msg_base <= m < self.msg_base + LEARN_MESSAGES

    def reset(mut self):
        """A new sheet: nothing named or learned yet."""
        var base = self.msg_base
        var was_open = self.open
        self = LearnPanel(base)
        self.open = was_open

    def count_labels(mut self, sheet: Sheet):
        """How many rows carry a label, and which labels (the chips), read from the sheet."""
        self.labelled = 0
        var lc = sheet.index(self.label)
        if lc < 0:
            return
        for r in range(sheet.rows()):
            if sheet.alive(r) and not sheet.is_null(lc, r):
                var t = String(sheet.plain_text(lc, r).strip())
                if t != "":
                    self.labelled += 1
                    if not (t in self.picks) and len(self.picks) < MAX_PICKS:
                        self.picks.append(t)

    def learned(mut self, l: Learned):
        self.rule = l.tree.rule()
        self.rule_lines = l.tree.rule_lines()
        self.held = l.held
        self.labelled = l.labelled
        self.filled = l.rows - l.labelled
        self.ms = l.ms + l.table_ms
        self.used = l.tree.used()
        self.said = ""
        self.learned_once = True
        for c in l.classes:
            if not (c in self.picks) and len(self.picks) < MAX_PICKS:
                self.picks.append(c)

    def update(mut self, event: Event) -> Int:
        var m = event.message - self.msg_base
        if m == LP_NAME:
            self.name_text = event.text
        elif m == LP_ADD_MSG:
            var name = String(self.name_text.strip())
            if name == "":
                self.said = "Name the label column first (for example: cause)"
                return LP_NONE
            self.label = name
            self.said = ""
            return LP_ADD
        elif m == LP_LEARN_MSG:
            return LP_LEARN
        elif m == LP_CLOSE:
            self.open = False
            return LP_CLOSED
        elif m == LP_NEW:
            self.new_text = event.text
        elif m == LP_NEW_SUBMIT:
            if String(self.new_text.strip()) != "":
                self.picked = String(self.new_text.strip())
                if not (self.picked in self.picks) and len(self.picks) < MAX_PICKS:
                    self.picks.append(self.picked)
                self.new_text = ""
                return LP_PICK
        elif m == LP_ROWS_TEXT:
            self.rows_text = event.text
        elif m == LP_ROWS_MSG:
            return LP_ROWS
        elif m >= LP_PICK_MSG and m < LP_PICK_MSG + MAX_PICKS:
            var k = m - LP_PICK_MSG
            if k < len(self.picks):
                self.picked = self.picks[k]
                return LP_PICK
        return LP_NONE

    def view(self, rows: Int, row: Int) -> List[View]:
        """The inspector's Learn page: name a column → label rows → Learn → the rule, how right, how sure."""
        var b = self.msg_base
        var parts = List[View]()
        if self.label == "":
            parts.append(Text("Teach a column by example", HEADLINE))
            parts.append(Text("Name a label column, label about " + String(ENOUGH) + " rows, press Learn. A small decision tree fills in the other "
                              + _grouped(rows) + " rows and says its rule in words.", CAPTION).max_width(300))
            parts.append(TextField(self.name_text, "Label column, e.g. cause", on_change=b + LP_NAME, on_submit=b + LP_ADD_MSG).fill()
                         .tag("label-name").label("Label column").tooltip("The new column you'll label: its name"))
            parts.append(HStack(Spacer(), Button("Add label column", b + LP_ADD_MSG, PROMINENT, icon="row-plus").tag("add-label")).fill())
        else:
            var head = "Label rows in " + self.label
            parts.append(Text(head, HEADLINE))
            var left = max(ENOUGH - self.labelled, 0)
            var counting = String(self.labelled) + " labelled" + (" · about " + String(left) + " more" if left > 0 else " · enough to learn")
            parts.append(Text(counting, CAPTION).tag("label-count"))
            if len(self.picks) == 0:
                parts.append(Text("Type a label in a cell of " + self.label + ", or write one below: it goes in row " + _grouped(row + 1) + ", then the next row", CAPTION).max_width(300))
            else:
                parts.append(Text("Type a label in a cell of " + self.label + ", or pick one for row " + _grouped(row + 1) + ":", CAPTION).max_width(300))
            var chips = List[View]()
            for k in range(min(len(self.picks), MAX_PICKS)):
                chips.append(Button(self.picks[k], b + LP_PICK_MSG + k, SUBTLE).tag("label-pick-" + String(k + 1)).tooltip("Write " + self.picks[k] + " in the selected row, then go down one"))
            var line = List[View]()
            for i in range(len(chips)):  # (three to a line)
                line.append(chips[i].copy())
                if len(line) == 3 or i == len(chips) - 1:
                    parts.append(HStack(line^, spacing=6).align(START))
                    line = List[View]()
            parts.append(TextField(self.new_text, "A new label (Return writes it)", on_change=b + LP_NEW, on_submit=b + LP_NEW_SUBMIT).fill()
                         .tag("label-new").label("New label"))
            parts.append(HStack(Spacer(), Button("Learn" if not self.learned_once else "Learn again", b + LP_LEARN_MSG, PROMINENT, icon="sparkles")
                                .tag("learn").tooltip("A decision tree learns from the labelled rows and fills the rest"), spacing=8).fill())
            if self.learned_once:
                parts.append(Text("It learned", HEADLINE))
                var lines = List[View]()
                for line in self.rule_lines:
                    lines.append(Text(line).max_width(300))
                parts.append(VStack(lines^, spacing=4).fill().align(START).tag("learn-rule").label(self.rule))
                var pct = Int(self.held.share() * 100.0 + 0.5)
                parts.append(Text("Right on " + String(self.held.right) + " of " + String(self.held.tried) + " labelled rows it never saw (" + String(pct) + "%)", CAPTION)
                             .tone(TONE_ACCENT if pct >= 80 else TONE_WARN).tag("learn-held"))
                parts.append(Text("Filled " + _grouped(self.filled) + " rows in " + _ms(self.ms) + " · " + learned_name(self.label) + " and " + sure_name(self.label)
                                  + " · it learns again when you change a label", CAPTION).max_width(300).tag("learn-filled"))
                if len(self.used) > 0:
                    parts.append(Text("Read " + ", ".join(self.used), CAPTION).max_width(300))
        if self.said != "":
            parts.append(Text(self.said, CAPTION).tone(TONE_WARN).max_width(300).tag("learn-said"))
        if self.label != "":
            parts.append(VStack(Text("Or label rows by number (an agent's way): 12 person ahead, 40 waiting", CAPTION).max_width(300),
                                TextField(self.rows_text, "12 person ahead, 40 waiting", on_change=b + LP_ROWS_TEXT, on_submit=b + LP_ROWS_MSG).fill()
                                .tag("label-rows").label("Label rows"),
                                spacing=4).fill().align(START))
        var out = List[View]()
        out.append(VStack(parts^, spacing=12).fill().align(START).tag("learn-panel"))
        return out^


def _ms(ms: Float64) -> String:
    if ms < 10.0:
        return String(Int(ms * 10.0 + 0.5) // 10) + "." + String(Int(ms * 10.0 + 0.5) % 10) + " ms"
    if ms < 1000.0:
        return String(Int(ms + 0.5)) + " ms"
    return String(Int(ms / 100.0 + 0.5) // 10) + "." + String(Int(ms / 100.0 + 0.5) % 10) + " s"
