# My models (blade-home.js, library.js, library-logic.js): the page header, a search with List | Cards, the groups
# column (Show · Kind · Your labels) and the models as a table you can tick and label, or as cards. Drag a model (with
# every ticked one, if it's ticked) onto a label to label it; tick models and tap a label in the bar to label them all.

from mojoui.view import View, Text, Button, Icon, TextField, VStack, HStack, Grid, Spacer, Divider, Card, PROMINENT, SUBTLE, PLAIN, ICON_ONLY, CENTER, START, END
from mojoui.table import Table
from mojoui.chip import Chip
from mojoui.overlays import Checkbox
from mojoui.dragdrop import Draggable, DropTarget
from mojoui.pagekit import PageHeader, GroupHead, GroupItem, HueDot, StatTile, SourceLine, MonoLine, SegButtons, StateWord, Panel, FlatButton, NameButton, HashMark, QuietAction, Strong, QuietText, SearchField
from mojoui.json import json_string
from data import Store, Model, Row, row_of, sorted_models, kind_name, kind_hue, hardware, fmt, short_endpoint, KINDS, KIND_NAMES, KIND_HUES
from msgs import ADD, SEARCH, VIEW, GROUP, LABEL_GROUP, DROP_LABEL, TICK, TICK_ALL, OPEN, TAP_LABEL, CLEAR, REMOVE_TICKED, EDIT_LABELS


struct Library(Copyable, Movable):
    """library.js's state: the search, the group ("all", "running", "kind:<k>", "label:<l>"), the ticked names (in the
    order they were ticked), List or Cards."""

    var q: String
    var group: String
    var ticked: List[String]
    var cards: Bool

    def __init__(out self):
        self.q = ""
        self.group = "all"
        self.ticked = List[String]()
        self.cards = False

    def is_ticked(self, name: String) -> Bool:
        for t in self.ticked:
            if t == name:
                return True
        return False

    def tick(mut self, name: String, on: Bool):
        var keep = List[String]()
        for t in self.ticked:
            if t != name:
                keep.append(t)
        if on:
            keep.append(name)
        self.ticked = keep^

    def forget_gone(mut self, st: Store):
        var keep = List[String]()
        for t in self.ticked:
            if st.model(t) >= 0:
                keep.append(t)
        self.ticked = keep^


def in_group(m: Model, group: String) -> Bool:
    if group == "all" or group == "":
        return True
    if group == "running":
        return m.state == "ready"
    if group.startswith("kind:"):
        return m.kind == String(group[byte=5:])
    if group.startswith("label:"):
        var l = String(group[byte=6:])
        for x in m.labels:
            if x == l:
                return True
    return False


def matches(m: Model, q: String) -> Bool:
    """Every word must match: plain words the name (or repo) or the start of the kind; #word the start of a label."""
    var name = (m.name + " " + m.repo).lower()
    for w in q.lower().split(" "):
        var word = String(w)
        if word == "":
            continue
        if word.startswith("#"):
            var ok = False
            for l in m.labels:
                if l.startswith(String(word[byte=1:])):
                    ok = True
            if not ok:
                return False
        elif not (word in name or m.kind.startswith(word)):
            return False
    return True


def visible(st: Store, lib: Library) -> List[Model]:
    var out = List[Model]()
    for m in sorted_models(st):
        if in_group(m, lib.group) and matches(m, lib.q):
            out.append(m.copy())
    return out^


def group_name(g: String) -> String:
    if g == "all":
        return "All models"
    if g == "running":
        return "Running"
    if g.startswith("kind:"):
        return kind_name(String(g[byte=5:]))
    return "#" + String(g[byte=6:])


def bulk_state(st: Store, names: List[String], label: String) -> String:
    """Does this label sit on all, some or none of the ticked models?"""
    var on = 0
    for n in names:
        var k = st.model(n)
        if k >= 0:
            for l in st.models[k].labels:
                if l == label:
                    on += 1
    return "none" if on == 0 else ("all" if on == len(names) else "some")


def label_models(mut st: Store, names: List[String], label: String, add: Bool):
    """added / removed (library-logic.js), shown at once: the poll after the write brings the daemon's truth."""
    for ref m in st.models:
        var hit = False
        for n in names:
            if n == m.name:
                hit = True
        if not hit:
            continue
        var has = False
        var keep = List[String]()
        for l in m.labels:
            if l == label:
                has = True
            else:
                keep.append(l)
        if add and not has:
            m.labels.append(label)
        elif not add and has:
            m.labels = keep^


def names_json(names: List[String]) -> String:
    var out = String("{\"models\": [")
    for k in range(len(names)):
        out += (", " if k > 0 else "") + json_string(names[k])
    return out + "]}"


def drag_names(dragged: String, lib: Library) -> List[String]:
    """A row dragged from a ticked set takes the whole set; an unticked row goes alone (library-logic.js dragNames)."""
    if lib.is_ticked(dragged):
        return lib.ticked.copy()
    return [dragged]


def count_label(st: Store, label: String) -> Int:
    var n = 0
    for m in st.models:
        for l in m.labels:
            if l == label:
                n += 1
    return n


def tags_view(r: Row) -> View:
    var tags: List[View] = [Chip(kind_name(r.kind), hue=kind_hue(r.kind))]
    for l in r.labels:
        tags.append(Chip("#" + l))
    return HStack(tags^, spacing=4).align(CENTER)


def name_cell(r: Row, row: Int, hue: Int, lib: Library) -> View:
    var payload = String("")
    var names = drag_names(r.name, lib)
    for k in range(len(names)):
        payload += ("\n" if k > 0 else "") + names[k]
    var cell = VStack(HStack(HueDot(hue, 9), NameButton(r.name, OPEN + row), spacing=9).align(CENTER),
                      MonoLine(r.repo), spacing=2).align(START)
    return Draggable(cell, payload).tag("row-" + r.name)


def groups_column(st: Store, lib: Library) -> View:
    var running = 0
    for m in st.models:
        if m.state == "ready":
            running += 1
    var items: List[View] = [GroupHead("Show"),
                             GroupItem(Icon("box", 16), "All models", String(len(st.models)), GROUP + 0, lib.group == "all"),
                             GroupItem(HueDot(7), "Running", String(running), GROUP + 1, lib.group == "running"),
                             GroupHead("Kind", "· automatic")]
    var kinds = materialize[KINDS]()
    for k in range(len(kinds)):
        var n = 0
        for m in st.models:
            if m.kind == kinds[k]:
                n += 1
        items.append(GroupItem(HueDot(materialize[KIND_HUES]()[k]), materialize[KIND_NAMES]()[k], String(n), GROUP + 2 + k, lib.group == "kind:" + kinds[k]))
    items.append(HStack(GroupHead("Your labels"), Spacer(), QuietAction("Edit labels", EDIT_LABELS), spacing=6).align(CENTER).fill())
    for k in range(len(st.labels)):
        var l = st.labels[k]
        var row = GroupItem(HashMark(), l, String(count_label(st, l)), LABEL_GROUP + k, lib.group == "label:" + l)
        items.append(DropTarget(row, DROP_LABEL + k).fill().tag("label-" + l))
    items.append(GroupItem(Icon("plus", 15), "New label", "", EDIT_LABELS))
    return VStack(items^, spacing=1).align(START).width(228).padding(6, 10).tag("groups")


def card_of(r: Row, row: Int, hue: Int, lib: Library) -> View:
    var top = HStack(Checkbox("", lib.is_ticked(r.name), TICK + row).tag("tick-" + String(row)), HueDot(hue, 9),
                     NameButton(r.name, OPEN + row), Spacer(), StateWord(r.state_label, r.running), spacing=8).align(CENTER).fill()
    var k3 = HStack(StatTile("tok/s", r.tps, "", ""), StatTile("Memory", r.memory, "", ""), StatTile("Requests", r.requests, "", ""), spacing=6).fill()
    var items: List[View] = [top^, k3^, tags_view(r)]
    return Draggable(Panel(items^, spacing=10).fill(), r.name).tag("card-" + r.name)


def tick_bar(st: Store, lib: Library) -> View:
    var n = len(lib.ticked)
    var items: List[View] = [Strong(String(n) + " selected"), QuietText("Labels:")]
    for k in range(len(st.labels)):
        var state = bulk_state(st, lib.ticked, st.labels[k])
        items.append(FlatButton("#" + st.labels[k], TAP_LABEL + k, filled=state == "all"))
    if len(st.labels) == 0:
        items.append(QuietText("none yet: use New label"))
    items.append(Spacer())
    items.append(FlatButton("Clear", CLEAR))
    items.append(FlatButton("Remove " + String(n), REMOVE_TICKED, icon="trash-2", danger=True))
    return HStack(items^, spacing=6).align(CENTER).padding(10, 18).fill().tag("selbar")


def home_view(st: Store, lib: Library, phone: Bool) -> View:
    var all = st.models.copy()
    var rows = visible(st, lib)
    var running = 0
    for m in all:
        if m.state == "ready":
            running += 1
    var hw = hardware(st)
    var sub = String(len(all)) + " model" + ("" if len(all) == 1 else "s") + " · " + String(running) + " running" + \
        ((" · " + fmt(hw.used_gb, 1) + " of " + fmt(hw.total_gb, 1) + " GB GPU") if hw.present else String("")) + " · " + short_endpoint(st.endpoint_now())
    var tools: List[View] = []
    if phone:
        tools.append(Button("Add a model", ADD, ICON_ONLY, icon="plus"))
    else:
        tools.append(SourceLine("mxc ls"))
        tools.append(Button("Add a model", ADD, PROMINENT, icon="plus"))
    var header = PageHeader("layout-grid", "My models", String(len(all)), sub, tools^)
    var search = SearchField(lib.q, "Search " + String(len(all)) + " model" + ("" if len(all) == 1 else "s") + " by name, kind or #label", SEARCH).grow()
    var hbar = HStack(search, SegButtons(["List", "Cards"], ["list", "layout-grid"], 1 if lib.cards else 0, VIEW), spacing=10).align(CENTER).padding(12, 18).fill()
    # the results
    var shown = List[Row]()
    for m in rows:
        shown.append(row_of(st, m))
    var hues = List[Int]()  # colorOf: one colour per model, in the order they're first seen (core.js SIGNAL)
    for k in range(len(shown)):
        hues.append(k % 5 + 1)
    var results: List[View] = [HStack(MonoLine(group_name(lib.group) + " · " + String(len(shown)) + ((" matching “" + lib.q + "”") if lib.q != "" else String(""))),
                                      Spacer(), MonoLine("" if phone else "tick models to label many at once, or drag them onto a label", quiet=True),
                                      spacing=10).align(CENTER).padding(12, 18).fill()]
    if len(shown) == 0:
        results.append(QuietText("Nothing matches. Try another group or clear the search.").padding(30, 18))
    elif lib.cards:
        var cards: List[View] = []
        for k in range(len(shown)):
            cards.append(card_of(shown[k], k, hues[k], lib))
        results.append(Grid(cards^, columns=1 if phone else 4, spacing=10).padding(4, 18).fill().tag("cards"))
    else:
        var cells: List[View] = []
        var ticked = List[Bool]()
        for k in range(len(shown)):
            ref r = shown[k]
            ticked.append(lib.is_ticked(r.name))
            cells.append(name_cell(r, k, hues[k], lib))
            var state: List[View] = [StateWord(r.state_label, r.running)]
            if r.note != "":
                state.append(MonoLine(r.note))
            cells.append(VStack(state^, spacing=2).align(START))
            if phone:
                cells.append(Text(r.tps))
            else:
                cells.append(tags_view(r))
                cells.append(Text(r.size))
                cells.append(Text(r.memory))
                cells.append(Text(r.tps))
                cells.append(Text(r.ttft))
                cells.append(Text(r.requests))
                cells.append(MonoLine(r.access))
        var cols: List[String] = ["Model", "State", "tok/s"] if phone else ["Model", "State", "Kind · labels", "Size", "Memory", "tok/s", "First token", "Requests", "Access"]
        results.append(VStack(Table(cols, cells, align="LLR" if phone else "LLLRRRRRL", ticked=ticked, on_tick=TICK, on_tick_all=TICK_ALL).fill().tag("models"),
                              spacing=0).padding(0, 18 if not phone else 12).fill())
    var body: List[View] = [header^, Divider().fill(), hbar^, Divider().fill()]
    if phone:
        body.append(groups_column(st, lib))  # (on a phone the column is a row of chips: here, the same rows above the list)
        body.append(Divider().fill())
        body.append(VStack(results^, spacing=0).align(START).fill())
    else:
        body.append(HStack(groups_column(st, lib), Divider(), VStack(results^, spacing=0).align(START).grow(), spacing=0).align(START).grow().fill())
    if len(lib.ticked) > 0:
        body.append(Divider().fill())
        body.append(tick_bar(st, lib))
    return VStack(body^, spacing=0).align(START).grow().fill()
