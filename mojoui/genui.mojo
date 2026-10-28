# mojoui.genui: UI from data (goal 35 M2, D-709). An agent describes a screen as JSON built only from catalogued mojoui
# components; the app validates it against one catalog (the same one that prints the JSON Schema agents are given) and
# renders it with native components. Nothing in it is code: text is shown as text, actions are words reported back,
# inputs edit the shared state at a JSON pointer.
#
#   {"ui": {"component": "Card", "title": "Signup", "children": [
#       {"component": "TextField", "placeholder": "Your name", "bind": "/form/name"},
#       {"component": "Button", "label": "Submit", "action": "submit"}]}}
#
#   schema()                                 the render_ui tool's parameters (docs/genui.schema.json)
#   var ui = GenUi.parse(args, base=10_000, canvas_base=100)
#   if ui.problem != "": … tell the agent (a tool result) …
#   ui.view(state, version)                  native Views (state: the shared state, a mojoui.jsonpatch.JDoc)
#   var act = ui.handle(event, state)        an input edited the state, or a button/choice reported an action
#   ui.draw(canvas, surface, palette, state) its sparklines
#
# Limits beyond the schema (a schema can't count): at most 8 levels deep, 200 components, 32 KB of JSON.

from mojoui.json import Json, json_string, J_NULL, J_BOOL, J_NUMBER, J_STRING, J_ARRAY, J_OBJECT
from mojoui.jsonpatch import JDoc
from mojoui.view import (
    View, Text, Button, TextField, Toggle, Segmented, VStack, HStack, Card, Divider,
    BODY, TITLE, HEADLINE, CAPTION, PLAIN, PROMINENT, SPACE_S, SPACE_M, START,
)
from mojoui.paragraph import Paragraph, Plain
from mojoui.table import Table
from mojoui.meter import Meter
from mojoui.sparkline import Sparkline, SparklineView
from mojoui.canvas import Surface
from mojoui.theme import Palette
from mojoui.app import Event

comptime MAX_DEPTH = 8
comptime MAX_NODES = 200
comptime MAX_BYTES = 32_768
comptime MAX_CONTROLS = 1000  # a GenUi's messages: base … base + 999

# prop kinds
comptime P_TEXT = 0
comptime P_ENUM = 1
comptime P_NUMBER = 2
comptime P_TEXTS = 3
comptime P_NUMBERS = 4
comptime P_ROWS = 5
comptime P_POINTER = 6
comptime P_WORD = 7
comptime P_CHILDREN = 8

comptime POINTER_PATTERN = "^(/[A-Za-z0-9_][A-Za-z0-9_-]{0,39}){1,6}$"  # (no "-": a bind never appends)
comptime NUMBER_LIMIT = 1_000_000_000_000_000  # numbers an agent sends: within ±1e15 (finite, drawable)
comptime WORD_PATTERN = "^[a-z][a-z0-9_]{0,39}$"


@fieldwise_init
struct Prop(Copyable, Movable):
    var name: String
    var kind: Int
    var required: Bool
    var limit: Int  # P_TEXT: longest; P_TEXTS / P_NUMBERS / P_ROWS / P_CHILDREN: most items; P_NUMBER: the maximum
    var low: Int  # P_NUMBER: the minimum; P_TEXTS: fewest items
    var choices: List[String]  # P_ENUM
    var about: String


@fieldwise_init
struct Spec(Copyable, Movable):
    var name: String  # the mojoui component it renders (docs/components.md)
    var about: String
    var props: List[Prop]


def text(name: String, limit: Int, required: Bool = False, about: String = "") -> Prop:
    return Prop(name, P_TEXT, required, limit, 0, List[String](), about)


def choice(name: String, var choices: List[String], about: String = "") -> Prop:
    return Prop(name, P_ENUM, False, 0, 0, choices^, about)


def kids() -> Prop:
    return Prop("children", P_CHILDREN, False, 50, 0, List[String](), "the components inside, in order")


def bind(required: Bool) -> Prop:
    return Prop("bind", P_POINTER, required, 0, 0, List[String](), "a JSON pointer into the shared state (\"/form/name\"): the value shown, and where edits go")


def action(required: Bool) -> Prop:
    return Prop("action", P_WORD, required, 0, 0, List[String](), "a word reported back to the agent (the render_ui tool's result) when used")


def catalog() -> List[Spec]:
    """What an agent may build: catalogued mojoui components and the props each takes (one place: the schema, the
    validator and the renderer all read it)."""
    var out = List[Spec]()
    out.append(Spec("Card", "a surface holding components, with an optional title", [text("title", 200), kids()]))
    out.append(Spec("VStack", "components in a column", [kids()]))
    out.append(Spec("HStack", "components in a row", [kids()]))
    out.append(Spec("Text", "a line of text (shown as text, never markup)", [text("text", 2000, True), choice("style", ["body", "title", "headline", "caption"])]))
    out.append(Spec("Paragraph", "wrapping text", [text("text", 4000, True)]))
    out.append(Spec("Divider", "a rule between components", List[Prop]()))
    out.append(Spec("Table", "rows of cells under column titles", [
        Prop("columns", P_TEXTS, True, 10, 1, List[String](), "the column titles"),
        Prop("rows", P_ROWS, True, 100, 0, List[String](), "each row: a list of strings or numbers"),
    ]))
    out.append(Spec("Sparkline", "a small line chart of numbers", [
        Prop("values", P_NUMBERS, False, 500, 0, List[String](), "the numbers (or bind them to the state)"),
        bind(False), text("label", 200),
    ]))
    out.append(Spec("Meter", "how full something is", [
        text("label", 200, True), Prop("value", P_NUMBER, True, 100, 0, List[String](), "0 to 100"), text("figure", 100),
    ]))
    out.append(Spec("Button", "a button that reports its action", [text("label", 100, True), action(True), choice("style", ["plain", "prominent"])]))
    out.append(Spec("TextField", "a text input that edits the state at bind", [text("placeholder", 200), bind(True)]))
    out.append(Spec("Toggle", "an on/off switch that edits the state at bind", [text("label", 200, True), bind(True)]))
    out.append(Spec("Segmented", "one choice of a few, editing the state at bind", [
        Prop("options", P_TEXTS, True, 8, 2, List[String](), "2 to 8 choices"), bind(True), action(False),
    ]))
    return out^


# ---------------------------------------------------------------------------------------------------------------------
# the JSON Schema (the render_ui tool's parameters)
# ---------------------------------------------------------------------------------------------------------------------

def prop_schema(p: Prop) -> String:
    var about = (',"description":' + json_string(p.about)) if p.about.byte_length() > 0 else String("")
    if p.kind == P_TEXT:
        return '{"type":"string","maxLength":' + String(p.limit) + about + "}"
    if p.kind == P_ENUM:
        var vals = String("[")
        for i in range(len(p.choices)):
            vals += ("," if i > 0 else "") + json_string(p.choices[i])
        return '{"enum":' + vals + "]" + about + "}"
    if p.kind == P_NUMBER:
        return '{"type":"number","minimum":' + String(p.low) + ',"maximum":' + String(p.limit) + about + "}"
    if p.kind == P_TEXTS:
        return '{"type":"array","minItems":' + String(p.low) + ',"maxItems":' + String(p.limit) + ',"items":{"type":"string","maxLength":100}' + about + "}"
    if p.kind == P_NUMBERS:
        return '{"type":"array","maxItems":' + String(p.limit) + ',"items":{"type":"number","minimum":-' + String(NUMBER_LIMIT) + ',"maximum":' + String(NUMBER_LIMIT) + "}" + about + "}"
    if p.kind == P_ROWS:
        return ('{"type":"array","maxItems":' + String(p.limit) + ',"items":{"type":"array","maxItems":10,"items":{"type":["string","number"],"maxLength":200,"minimum":-' + String(NUMBER_LIMIT) + ',"maximum":' + String(NUMBER_LIMIT) + "}}" + about + "}")
    if p.kind == P_POINTER:
        return '{"type":"string","pattern":' + json_string(POINTER_PATTERN) + about + "}"
    if p.kind == P_WORD:
        return '{"type":"string","pattern":' + json_string(WORD_PATTERN) + about + "}"
    return '{"type":"array","maxItems":' + String(p.limit) + ',"items":{"$ref":"#/$defs/node"}' + about + "}"


def schema() -> String:
    """The JSON Schema (2020-12) of render_ui's arguments: {"ui": node}, a node being one catalogued component."""
    var specs = catalog()
    var refs = String("[")
    var comps = String("{")
    for i in range(len(specs)):
        ref s = specs[i]
        refs += ("," if i > 0 else "") + '{"$ref":"#/$defs/components/' + s.name + '"}'
        var props = String('{"component":{"const":') + json_string(s.name) + "}"
        var req = String('["component"')
        for ref p in s.props:
            props += "," + json_string(p.name) + ":" + prop_schema(p)
            if p.required:
                req += "," + json_string(p.name)
        comps += ("," if i > 0 else "") + json_string(s.name) + ':{"type":"object","description":' + json_string(s.about) + ',"properties":' + props + '},"required":' + req + '],"additionalProperties":false}'
    return ('{"$schema":"https://json-schema.org/draft/2020-12/schema","title":"render_ui",'
            + '"description":"A screen built only from catalogued mojoui components, drawn natively by the app. Data, never code: text is shown as text. Beyond this schema the app refuses more than '
            + String(MAX_DEPTH) + " levels, " + String(MAX_NODES) + " components or " + String(MAX_BYTES) + ' bytes.",'
            + '"type":"object","properties":{"ui":{"$ref":"#/$defs/node"}},"required":["ui"],"additionalProperties":false,'
            + '"$defs":{"node":{"oneOf":' + refs + ']},"components":' + comps + "}}}")


# ---------------------------------------------------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------------------------------------------------

def spec_index(specs: List[Spec], name: String) -> Int:
    for i in range(len(specs)):
        if specs[i].name == name:
            return i
    return -1


def is_pointer(s: String) -> Bool:
    """POINTER_PATTERN: 1–6 parts of 1–40 letters, digits, _ or -, none starting with - (so never "-", which appends)."""
    if not s.startswith("/"):
        return False
    var parts = String(s[byte = 1 :]).split("/")
    if len(parts) > 6:
        return False
    for p in parts:
        var t = String(p)
        if t.byte_length() < 1 or t.byte_length() > 40 or t.startswith("-"):
            return False
        for b in t.as_bytes():
            var c = Int(b)
            if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95 or c == 45):
                return False
    return True


def is_word(s: String) -> Bool:
    """WORD_PATTERN: a lower-case letter, then up to 39 lower-case letters, digits or _."""
    var n = s.byte_length()
    if n < 1 or n > 40:
        return False
    var b = s.as_bytes()
    if b[0] < 97 or b[0] > 122:
        return False
    for c in b:
        if not ((c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95):
            return False
    return True


def bounded(j: Json, n: Int) -> Bool:
    """A number within ±NUMBER_LIMIT (so never inf or nan)."""
    if j.kind(n) != J_NUMBER:
        return False
    var r = j.real(n)
    return r == r and r >= -Float64(NUMBER_LIMIT) and r <= Float64(NUMBER_LIMIT)


def chars(s: String) -> Int:
    """Characters (code points), as JSON Schema's maxLength counts."""
    var n = 0
    for _ in s.codepoint_slices():
        n += 1
    return n


def check_prop(j: Json, v: Int, p: Prop, where: String, comp: String) raises:
    var bad = "bad prop: " + where + ": " + comp + "'s " + p.name
    var k = j.kind(v)
    if p.kind == P_TEXT:
        if k != J_STRING:
            raise Error(bad + " must be a string")
        if chars(j.text(v)) > p.limit:
            raise Error(bad + " is longer than " + String(p.limit) + " characters")
    elif p.kind == P_ENUM:
        var ok = False
        for c in p.choices:
            if k == J_STRING and j.text(v) == c:
                ok = True
        if not ok:
            var all = String("")
            for c in p.choices:
                all += (", " if all.byte_length() > 0 else "") + c
            raise Error(bad + " must be one of " + all)
    elif p.kind == P_NUMBER:
        if k != J_NUMBER or j.real(v) < Float64(p.low) or j.real(v) > Float64(p.limit):
            raise Error(bad + " must be a number from " + String(p.low) + " to " + String(p.limit))
    elif p.kind == P_TEXTS:
        if k != J_ARRAY or j.size(v) < p.low or j.size(v) > p.limit:
            raise Error(bad + " must be a list of " + String(p.low) + " to " + String(p.limit) + " strings")
        for i in range(j.size(v)):
            if j.kind(j.at(v, i)) != J_STRING or chars(j.text(j.at(v, i))) > 100:
                raise Error(bad + " must hold strings of at most 100 characters")
    elif p.kind == P_NUMBERS:
        if k != J_ARRAY or j.size(v) > p.limit:
            raise Error(bad + " must be a list of at most " + String(p.limit) + " numbers")
        for i in range(j.size(v)):
            if not bounded(j, j.at(v, i)):
                raise Error(bad + " must hold numbers within ±1e15 only")
    elif p.kind == P_ROWS:
        if k != J_ARRAY or j.size(v) > p.limit:
            raise Error(bad + " must be a list of at most " + String(p.limit) + " rows")
        for r in range(j.size(v)):
            var row = j.at(v, r)
            if j.kind(row) != J_ARRAY or j.size(row) > 10:
                raise Error(bad + ": each row must be a list of at most 10 cells")
            for c in range(j.size(row)):
                var cell = j.at(row, c)
                if j.kind(cell) == J_STRING:
                    if chars(j.text(cell)) > 200:
                        raise Error(bad + ": a cell is longer than 200 characters")
                elif not bounded(j, cell):
                    raise Error(bad + ": a cell must be a string or a number within ±1e15")
    elif p.kind == P_POINTER:
        if k != J_STRING or not is_pointer(j.text(v)):
            raise Error(bad + " must be a state path like \"/form/name\"")
    elif p.kind == P_WORD:
        if k != J_STRING or not is_word(j.text(v)):
            raise Error(bad + " must be one lower-case word (letters, digits, _)")
    else:
        if k != J_ARRAY or j.size(v) > p.limit:
            raise Error(bad + " must be a list of at most " + String(p.limit) + " components")


def walk(j: Json, n: Int, depth: Int, where: String, specs: List[Spec], mut count: Int) raises:
    if depth > MAX_DEPTH:
        raise Error("too deep: " + where + " nests deeper than " + String(MAX_DEPTH) + " levels")
    count += 1
    if count > MAX_NODES:
        raise Error("too big: more than " + String(MAX_NODES) + " components")
    if j.kind(n) != J_OBJECT:
        raise Error("bad prop: " + where + " must be a component (an object)")
    var c = j.get(n, "component")
    if j.kind(c) != J_STRING:
        raise Error("bad prop: " + where + " has no component name")
    var name = j.text(c)
    var at = spec_index(specs, name)
    if at < 0:
        var all = String("")
        for s in specs:
            all += (", " if all.byte_length() > 0 else "") + s.name
        raise Error("unknown component " + json_string(name) + " at " + where + " (the catalog: " + all + ")")
    ref spec = specs[at]
    for k in range(len(j.keys[n])):
        var key = j.keys[n][k]
        if key == "component":
            continue
        var found = -1
        for i in range(len(spec.props)):
            if spec.props[i].name == key:
                found = i
        if found < 0:
            raise Error("bad prop: " + where + ": " + name + " has no prop " + json_string(key))
        for k2 in range(k + 1, len(j.keys[n])):
            if j.keys[n][k2] == key:
                raise Error("bad prop: " + where + ": " + name + "'s " + key + " is given twice")
        check_prop(j, j.kids[n][k], spec.props[found], where, name)
    for ref p in spec.props:
        if p.required and j.get(n, p.name) < 0:
            raise Error("bad prop: " + where + ": " + name + " needs " + json_string(p.name))
    var ch = j.get(n, "children")
    for i in range(j.size(ch)):
        walk(j, j.at(ch, i), depth + 1, where + "/children/" + String(i), specs, count)


def validate(args: String) -> String:
    """Why render_ui's arguments can't be shown ("" when they can): too big, not JSON, not {"ui": node}, an unknown
    component, a bad prop (unknown, wrong type, out of range, missing), too deep or too many components."""
    if args.byte_length() > MAX_BYTES:
        return "too big: the UI is " + String(args.byte_length()) + " bytes (at most " + String(MAX_BYTES) + ")"
    var j: Json
    try:
        j = Json.parse(args)
    except e:
        return "bad prop: the arguments aren't JSON (" + String(e) + ")"
    if j.kind(0) != J_OBJECT or j.get(0, "ui") < 0:
        return "bad prop: the arguments must be {\"ui\": a component}"
    for k in j.keys[0]:
        if k != "ui":
            return "bad prop: the arguments have " + json_string(k) + " besides ui"
    var count = 0
    try:
        walk(j, j.get(0, "ui"), 1, "/ui", catalog(), count)
    except e:
        return String(e)
    return ""


# ---------------------------------------------------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------------------------------------------------

comptime ACT_NONE = 0
comptime ACT_STATE = 1  # an input edited the state at `bind`
comptime ACT_ACTION = 2  # a button or a choice with an action: report it to the agent


@fieldwise_init
struct UiAction(Copyable, Movable):
    var kind: Int
    var bind: String  # the state path an input edited
    var action: String  # the action's word
    var value: String  # JSON: the new value (inputs, choices)

    def report(self) -> String:
        """The tool result for an action: {"action": word, "value": …} (value only when there is one)."""
        return '{"action":' + json_string(self.action) + ((',"value":' + self.value) if self.value.byte_length() > 0 else String("")) + "}"


struct GenUi(Movable):
    """One agent-built screen: its validated JSON and what each of its controls and canvases is."""

    var problem: String  # "" when it can be shown
    var json: Json
    var base: Int  # its controls' messages: base + k (k < MAX_CONTROLS)
    var canvas_base: Int
    var controls: List[Int]  # node of control k
    var canvases: List[Int]  # node of sparkline k (canvas canvas_base + k)

    def __init__(out self, args: String, base: Int, canvas_base: Int):
        self.problem = validate(args)
        self.base = base
        self.canvas_base = canvas_base
        self.controls = List[Int]()
        self.canvases = List[Int]()
        if self.problem != "":
            self.json = Json()
            return
        try:
            self.json = Json.parse(args)
        except:
            self.json = Json()
            self.problem = "bad prop: not JSON"
            return
        self.index(self.json.get(0, "ui"))
        if len(self.controls) > MAX_CONTROLS:
            self.problem = "too big: more than " + String(MAX_CONTROLS) + " controls"

    def owns(self, message: Int) -> Bool:
        return message >= self.base and message < self.base + MAX_CONTROLS

    def summary(self, n: Int = -1) -> String:
        """The components as a short outline: Card(Text,TextField,Button)."""
        var at = self.json.get(0, "ui") if n < 0 else n
        var out = self.json.text(self.json.get(at, "component"))
        var ch = self.json.get(at, "children")
        if self.json.size(ch) > 0:
            out += "("
            for i in range(self.json.size(ch)):
                out += ("," if i > 0 else "") + self.summary(self.json.at(ch, i))
            out += ")"
        return out

    def index(mut self, n: Int):
        """Its controls and sparklines, in the order view() draws them (each control's message: base + its place)."""
        var comp = self.str(n, "component")
        if comp == "Sparkline":
            self.canvases.append(n)
        elif comp == "Button" or comp == "TextField" or comp == "Toggle" or comp == "Segmented":
            self.controls.append(n)
        var ch = self.json.get(n, "children")
        for i in range(self.json.size(ch)):
            self.index(self.json.at(ch, i))

    def view(self, state: JDoc, version: Int = 0) -> View:
        """The screen as native components (inputs show the state's values; `version` redraws its sparklines)."""
        if self.problem != "":
            return Text("")
        var ctl = 0
        var cv = 0
        return self.node(self.json.get(0, "ui"), state, version, ctl, cv)

    def str(self, n: Int, key: String) -> String:
        return self.json.text(self.json.get(n, key))

    def children(self, n: Int, state: JDoc, version: Int, mut ctl: Int, mut cv: Int) -> List[View]:
        var out = List[View]()
        var ch = self.json.get(n, "children")
        for i in range(self.json.size(ch)):
            out.append(self.node(self.json.at(ch, i), state, version, ctl, cv))
        return out^

    def node(self, n: Int, state: JDoc, version: Int, mut ctl: Int, mut cv: Int) -> View:
        var comp = self.str(n, "component")
        if comp == "Card":
            var items = List[View]()
            if self.json.get(n, "title") >= 0:
                items.append(Text(self.str(n, "title"), style=HEADLINE))
            for v in self.children(n, state, version, ctl, cv):
                items.append(v.copy())
            return Card(items^, spacing=SPACE_M).fill()
        if comp == "VStack":
            return VStack(self.children(n, state, version, ctl, cv), spacing=SPACE_S).fill()
        if comp == "HStack":
            return HStack(self.children(n, state, version, ctl, cv), spacing=SPACE_S)
        if comp == "Text":
            var s = self.str(n, "style")
            return Text(self.str(n, "text"), style=TITLE if s == "title" else (HEADLINE if s == "headline" else (CAPTION if s == "caption" else BODY)))
        if comp == "Paragraph":
            return Paragraph([Plain(self.str(n, "text"))])
        if comp == "Divider":
            return Divider()
        if comp == "Table":
            var cols = List[String]()
            var cn = self.json.get(n, "columns")
            for i in range(self.json.size(cn)):
                cols.append(self.json.text(self.json.at(cn, i)))
            var cells = List[View]()
            var rows = self.json.get(n, "rows")
            for r in range(self.json.size(rows)):
                var row = self.json.at(rows, r)
                for c in range(len(cols)):
                    var cell = self.json.at(row, c)
                    if self.json.kind(cell) == J_NUMBER:
                        cells.append(Text(String(self.json.number(cell)) if self.json.is_whole(cell) else String(self.json.real(cell))))
                    else:
                        cells.append(Text(self.json.text(cell)))
            return Table(cols^, cells^).fill()
        if comp == "Sparkline":
            var k = cv
            cv += 1
            var parts = List[View]()
            if self.json.get(n, "label") >= 0:
                parts.append(Text(self.str(n, "label"), style=CAPTION))
            parts.append(SparklineView(self.canvas_base + k, version, 64))
            return VStack(parts^, spacing=SPACE_S).align(START).fill()
        if comp == "Meter":
            return Meter(self.str(n, "label"), Int(self.json.real(self.json.get(n, "value"))), False, self.str(n, "figure"))
        # controls
        var msg = self.base + ctl
        ctl += 1
        if comp == "Button":
            return Button(self.str(n, "label"), on_tap=msg, style=PROMINENT if self.str(n, "style") == "prominent" else PLAIN)
        if comp == "TextField":
            return TextField(state.text_at(self.str(n, "bind")), placeholder=self.str(n, "placeholder"), on_change=msg).fill()
        if comp == "Toggle":
            return Toggle(self.str(n, "label"), state.flag_at(self.str(n, "bind")), on_toggle=msg)
        # Segmented
        var opts = List[String]()
        var on = self.json.get(n, "options")
        var picked = state.text_at(self.str(n, "bind"))
        var sel = 0
        for i in range(self.json.size(on)):
            var o = self.json.text(self.json.at(on, i))
            if o == picked:
                sel = i
            opts.append(o)
        return Segmented(opts^, sel, on_select=msg)

    def handle(self, e: Event, mut state: JDoc) -> UiAction:
        """One of its controls was used: the state edited at its bind, and its action if it has one."""
        var k = e.message - self.base
        if k < 0 or k >= len(self.controls):
            return UiAction(ACT_NONE, "", "", "")
        var n = self.controls[k]
        var comp = self.str(n, "component")
        var path = self.str(n, "bind")
        var value = String("")
        if comp == "TextField":
            value = json_string(e.text)
        elif comp == "Toggle":
            value = "true" if e.number != 0 else "false"
        elif comp == "Segmented":
            var on = self.json.get(n, "options")
            if e.number < 0 or e.number >= self.json.size(on):
                return UiAction(ACT_NONE, "", "", "")
            value = json_string(self.json.text(self.json.at(on, e.number)))
        if path.byte_length() > 0:
            try:
                state.set(path, value)
            except:
                return UiAction(ACT_NONE, "", "", "")
        var act = self.str(n, "action")
        if act.byte_length() > 0:
            return UiAction(ACT_ACTION, path, act, value)
        return UiAction(ACT_STATE, path, "", value)

    def draws(self, canvas: Int) -> Bool:
        return canvas >= self.canvas_base and canvas < self.canvas_base + len(self.canvases)

    def draw(self, canvas: Int, mut surface: Surface, p: Palette, state: JDoc):
        """Paints one of its sparklines (values from bind, else its own)."""
        var k = canvas - self.canvas_base
        if k < 0 or k >= len(self.canvases):
            return
        var n = self.canvases[k]
        var values = List[Float64]()
        if self.json.get(n, "bind") >= 0:
            values = state.numbers_at(self.str(n, "bind"))
        else:
            var vn = self.json.get(n, "values")
            for i in range(self.json.size(vn)):
                values.append(self.json.real(self.json.at(vn, i)))
        surface.fill(p.card)  # (it sits on a card)
        Sparkline.themed(values, p).draw(surface)
