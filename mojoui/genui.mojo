# mojoui.genui: UI from data (goal 35 M2, D-709; every general component, goal 48 M0). An agent describes a screen as
# JSON built only from catalogued mojoui components; the app validates it against one catalog (the same one that prints
# the JSON Schema agents are given) and renders it with native components. Nothing in it is code: text is shown as
# text, actions are words reported back, inputs edit the shared state at a JSON pointer.
#
#   {"ui": {"component": "Card", "title": "Signup", "children": [
#       {"component": "TextField", "placeholder": "Your name", "bind": "/form/name"},
#       {"component": "Button", "label": "Submit", "action": "submit"}]}}
#
#   schema()                                 the render_ui tool's parameters (docs/genui.schema.json)
#   var ui = GenUi(args, base=10_000, canvas_base=100)
#   if ui.problem != "": … tell the agent (a tool result) …
#   ui.view(state, version)                  native Views (state: the shared state, a mojoui.jsonpatch.JDoc)
#   var act = ui.handle(event, state)        an input edited the state, or a button/choice reported an action
#   ui.draw(canvas, surface, palette, state) its canvases: charts, grids, maps, sparklines, KPI lines
#
# Limits beyond the schema (a schema can't count): at most 8 levels deep, 200 components, 32 KB of JSON.

from std.collections import Dict
from mojoui.json import Json, json_string, J_NULL, J_BOOL, J_NUMBER, J_STRING, J_ARRAY, J_OBJECT
from mojoui.jsonpatch import JDoc
from mojoui.view import (
    View, Text, Button, TextField, TextArea, Toggle, Segmented, Dropdown, Slider, Radio, DatePicker, Tabs, Grid,
    ProgressBar, Icon, VStack, HStack, Card, Divider, Spacer, Canvas,
    BODY, TITLE, HEADLINE, CAPTION, PLAIN, PROMINENT, DESTRUCTIVE, SPACE_XS, SPACE_S, SPACE_M, SPACE_L, START, CENTER,
    TONE_NONE, TONE_WARN, TONE_GOOD, TONE_STRONG, TONE_ACCENT, CARD_WARN, CARD_GOOD,
)
from mojoui.overlays import Checkbox
from mojoui.paragraph import Paragraph, Plain
from mojoui.table import Table
from mojoui.meter import Meter
from mojoui.sparkline import Sparkline, SparklineView
from mojoui.markdown import Markdown
from mojoui.codeblock import CodeBlock
from mojoui.chip import Chip
from mojoui.skeleton import Skeleton
from mojoui.feedback import Note, Warning
from mojoui.timeline import Timeline, Stage, STAGE_PENDING, STAGE_RUNNING, STAGE_DONE, STAGE_FAILED, STAGE_CANCELLED
from mojoui.breadcrumbs import Breadcrumbs
from mojoui.kpi import KpiView
from mojoui.chartview import ChartView
from mojoui.mapview import MapView, MARK_PLACE, MARK_FINDING
from mojoui.datagrid import DataGrid
from mojoui.rowsource import Rows
from mojoui.canvas import Surface
from mojoui.text import Font
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
comptime P_BOOL = 9
comptime P_POINTS = 10  # [[lat, lon], …]
comptime P_ITEMS = 11  # a list of small objects, each with the prop's fields

comptime POINTER_PATTERN = "^(/[A-Za-z0-9_][A-Za-z0-9_-]{0,39}){1,6}$"  # (no "-": a bind never appends)
comptime NUMBER_LIMIT = 1_000_000_000_000_000  # numbers an agent sends: within ±1e15 (finite, drawable)
comptime WORD_PATTERN = "^[a-z][a-z0-9_]{0,39}$"


@fieldwise_init
struct Field(Copyable, Movable):
    """One field of a P_ITEMS prop's objects: text, a choice or a number."""
    var name: String
    var kind: Int  # P_TEXT, P_ENUM or P_NUMBER
    var required: Bool
    var limit: Int
    var low: Int
    var choices: List[String]


@fieldwise_init
struct Prop(Copyable, Movable):
    var name: String
    var kind: Int
    var required: Bool
    var limit: Int  # P_TEXT: longest; P_TEXTS / P_NUMBERS / P_ROWS / P_CHILDREN / P_POINTS / P_ITEMS: most items; P_NUMBER: the maximum
    var low: Int  # P_NUMBER: the minimum; P_TEXTS / P_ITEMS: fewest items; P_ROWS: most cells in a row
    var choices: List[String]  # P_ENUM
    var about: String
    var fields: List[Field]  # P_ITEMS


@fieldwise_init
struct Spec(Copyable, Movable):
    var name: String  # the mojoui component it renders (docs/components.md)
    var about: String
    var props: List[Prop]


def text(name: String, limit: Int, required: Bool = False, about: String = "") -> Prop:
    return Prop(name, P_TEXT, required, limit, 0, List[String](), about, List[Field]())


def choice(name: String, var choices: List[String], about: String = "") -> Prop:
    return Prop(name, P_ENUM, False, 0, 0, choices^, about, List[Field]())


def number(name: String, low: Int, high: Int, required: Bool = False, about: String = "") -> Prop:
    return Prop(name, P_NUMBER, required, high, low, List[String](), about, List[Field]())


def flag(name: String, about: String = "") -> Prop:
    return Prop(name, P_BOOL, False, 0, 0, List[String](), about, List[Field]())


def texts(name: String, low: Int, high: Int, required: Bool = False, about: String = "") -> Prop:
    return Prop(name, P_TEXTS, required, high, low, List[String](), about, List[Field]())


def numbers(name: String, high: Int, required: Bool = False, about: String = "") -> Prop:
    return Prop(name, P_NUMBERS, required, high, 0, List[String](), about, List[Field]())


def rows(name: String, most_rows: Int, most_cells: Int, about: String) -> Prop:
    return Prop(name, P_ROWS, True, most_rows, most_cells, List[String](), about, List[Field]())


def items(name: String, low: Int, high: Int, var fields: List[Field], required: Bool = False, about: String = "") -> Prop:
    return Prop(name, P_ITEMS, required, high, low, List[String](), about, fields^)


def kids() -> Prop:
    return Prop("children", P_CHILDREN, False, 50, 0, List[String](), "the components inside, in order", List[Field]())


def bind(required: Bool) -> Prop:
    return Prop("bind", P_POINTER, required, 0, 0, List[String](), "a JSON pointer into the shared state (\"/form/name\"): the value shown, and where edits go", List[Field]())


def action(required: Bool) -> Prop:
    return Prop("action", P_WORD, required, 0, 0, List[String](), "a word reported back to the agent (the render_ui tool's result) when used", List[Field]())


def label(required: Bool = False) -> Prop:
    return text("label", 200, required, "shown above the control")


def catalog() -> List[Spec]:
    """What an agent may build: catalogued mojoui components and the props each takes (one place: the schema, the
    validator and the renderer all read it). Grouped as docs/agui.md lists them: layout, words, data, inputs."""
    var out = List[Spec]()
    # layout
    out.append(Spec("Card", "a surface holding components, with an optional title and subtitle", [
        text("title", 200), text("subtitle", 300), choice("tone", ["plain", "good", "warn"], "warn asks for attention, good confirms"), kids()]))
    out.append(Spec("VStack", "components in a column", [choice("gap", ["xs", "s", "m", "l"]), kids()]))
    out.append(Spec("HStack", "components in a row", [choice("gap", ["xs", "s", "m", "l"]), kids()]))
    out.append(Spec("Grid", "components in rows of equal columns (tiles, KPI rows, galleries)", [number("columns", 1, 6, True), kids()]))
    out.append(Spec("Tabs", "sections the user switches between: one child per tab, in order", [texts("tabs", 2, 8, True, "the tab titles"), kids()]))
    out.append(Spec("Divider", "a rule between components", List[Prop]()))
    out.append(Spec("Spacer", "empty room that pushes its neighbours apart in a row", List[Prop]()))
    # words
    out.append(Spec("Text", "a line of text (shown as text, never markup)", [
        text("text", 2000, True), choice("style", ["body", "title", "headline", "caption"]), choice("tone", ["plain", "accent", "good", "warn", "strong"])]))
    out.append(Spec("Paragraph", "wrapping text", [text("text", 4000, True)]))
    out.append(Spec("Markdown", "formatted text: headings, lists, bold, italics, code, links (http/https only; never HTML)", [text("text", 8000, True)]))
    out.append(Spec("CodeBlock", "code in a monospaced block with a Copy button", [text("code", 8000, True), text("language", 30)]))
    out.append(Spec("Chip", "a small pill: a tag, a status", [text("text", 60, True), number("hue", 0, 6, False, "0 quiet, 1–6 the data colours")]))
    out.append(Spec("Alert", "an inline note or warning", [text("title", 200), text("text", 1000, True), choice("tone", ["info", "warn"])]))
    out.append(Spec("Skeleton", "placeholder lines for something still loading", [number("lines", 1, 12)]))
    # data
    out.append(Spec("Table", "rows of cells under column titles", [
        texts("columns", 1, 10, True, "the column titles"), rows("rows", 100, 10, "each row: a list of strings or numbers")]))
    out.append(Spec("DataGrid", "a scrolling grid for many rows (up to 1,000 sent inline)", [
        texts("columns", 1, 20, True, "the column titles"), rows("rows", 1000, 20, "each row: a list of strings or numbers"),
        number("height", 120, 800, False, "points")]))
    out.append(Spec("ChartView", "a chart of values by label: bars or a line", [
        choice("kind", ["bar", "line"]), text("title", 200), texts("labels", 1, 60, True, "one per value"),
        numbers("values", 60, True, "the numbers, one per label"), text("value_name", 60, False, "what the numbers are"),
        flag("money", "values are amounts of money (cents)"), number("height", 140, 600, False, "points")]))
    out.append(Spec("Sparkline", "a small line chart of numbers", [
        numbers("values", 500, False, "the numbers (or bind them to the state)"), bind(False), text("label", 200)]))
    out.append(Spec("KpiView", "a headline number with its label, a note and a small trend line", [
        text("label", 80, True), text("value", 40, True), text("note", 80), choice("tone", ["plain", "good", "warn"], "the note's"),
        numbers("spark", 200, False, "the trend"), flag("accent", "the focal number")]))
    out.append(Spec("Meter", "how full something is", [text("label", 200, True), number("value", 0, 100, True, "0 to 100"), text("figure", 100)]))
    out.append(Spec("ProgressBar", "how far along something is", [number("value", 0, 100, True, "0 to 100"), label()]))
    out.append(Spec("Timeline", "steps top to bottom, each with its status", [
        items("steps", 1, 20, [Field("label", P_TEXT, True, 200, 0, List[String]()),
                               Field("status", P_ENUM, False, 0, 0, ["pending", "running", "done", "failed", "cancelled"]),
                               Field("detail", P_TEXT, False, 300, 0, List[String]())], True)]))
    out.append(Spec("MapView", "a small offline map: a route and named places, north up, metres to scale", [
        Prop("route", P_POINTS, False, 2000, 0, List[String](), "the route as [latitude, longitude] pairs", List[Field]()),
        items("places", 0, 50, [Field("lat", P_NUMBER, True, 90, -90, List[String]()),
                                Field("lon", P_NUMBER, True, 180, -180, List[String]()),
                                Field("label", P_TEXT, False, 100, 0, List[String]()),
                                Field("kind", P_ENUM, False, 0, 0, ["place", "finding"])]),
        number("height", 160, 600, False, "points")]))
    out.append(Spec("Breadcrumbs", "where you are, as a trail", [texts("items", 1, 8, True), action(False)]))
    out.append(Spec("Icon", "a Lucide icon by name (\"map-pin\", \"calendar\", \"check\")", [text("name", 40, True), number("size", 12, 64)]))
    # inputs
    out.append(Spec("Button", "a button that reports its action", [
        text("label", 100, True), action(True), choice("style", ["plain", "prominent", "destructive"]), text("icon", 40)]))
    out.append(Spec("TextField", "a text input that edits the state at bind", [text("placeholder", 200), label(), bind(True)]))
    out.append(Spec("TextArea", "a multi-line text input that edits the state at bind", [text("placeholder", 200), label(), bind(True), number("height", 60, 400)]))
    out.append(Spec("Toggle", "an on/off switch that edits the state at bind", [text("label", 200, True), bind(True)]))
    out.append(Spec("Checkbox", "a tick box that edits the state at bind", [text("label", 200, True), bind(True)]))
    out.append(Spec("Dropdown", "one choice from a list, editing the state at bind", [texts("options", 2, 30, True), label(), bind(True), action(False)]))
    out.append(Spec("Slider", "a number from min to max, editing the state at bind", [
        label(), bind(True), number("min", -1_000_000, 1_000_000), number("max", -1_000_000, 1_000_000), number("step", 1, 1_000_000)]))
    out.append(Spec("Segmented", "one choice of a few, editing the state at bind", [texts("options", 2, 8, True, "2 to 8 choices"), label(), bind(True), action(False)]))
    out.append(Spec("Radio", "one choice of a few, as a list, editing the state at bind", [texts("options", 2, 8, True), label(), bind(True), action(False)]))
    out.append(Spec("DatePicker", "a date (YYYY-MM-DD), editing the state at bind", [label(), bind(True)]))
    out.append(Spec("Confirm", "asks the user to approve or reject something; reports approve or reject", [
        text("title", 200, True), text("text", 1000), text("approve", 40, False, "the approve button's label"),
        text("reject", 40, False, "the reject button's label"), flag("danger", "approving can't be undone")]))
    return out^


def sample(name: String) -> String:
    """A small valid node of each catalogued component (tests, docs): {"ui": node}."""
    var n: String
    if name == "Card":
        n = '{"component":"Card","title":"Trip","subtitle":"Lisbon","children":[{"component":"Text","text":"Hello"}]}'
    elif name == "VStack" or name == "HStack":
        n = '{"component":"' + name + '","gap":"m","children":[{"component":"Text","text":"a"},{"component":"Text","text":"b"}]}'
    elif name == "Grid":
        n = '{"component":"Grid","columns":2,"children":[{"component":"Text","text":"a"},{"component":"Text","text":"b"}]}'
    elif name == "Tabs":
        n = '{"component":"Tabs","tabs":["One","Two"],"children":[{"component":"Text","text":"first"},{"component":"Text","text":"second"}]}'
    elif name == "Divider" or name == "Spacer":
        n = '{"component":"' + name + '"}'
    elif name == "Text":
        n = '{"component":"Text","text":"Revenue","style":"headline","tone":"accent"}'
    elif name == "Paragraph":
        n = '{"component":"Paragraph","text":"Words that wrap."}'
    elif name == "Markdown":
        n = '{"component":"Markdown","text":"# Title\\n\\n- one\\n- **two**"}'
    elif name == "CodeBlock":
        n = '{"component":"CodeBlock","code":"pixi run hello","language":"bash"}'
    elif name == "Chip":
        n = '{"component":"Chip","text":"new","hue":2}'
    elif name == "Alert":
        n = '{"component":"Alert","title":"Heads up","text":"It may rain.","tone":"warn"}'
    elif name == "Skeleton":
        n = '{"component":"Skeleton","lines":3}'
    elif name == "Table":
        n = '{"component":"Table","columns":["city","trips"],"rows":[["Lisbon",12],["Porto",7]]}'
    elif name == "DataGrid":
        n = '{"component":"DataGrid","columns":["city","trips"],"rows":[["Lisbon",12],["Porto",7]],"height":200}'
    elif name == "ChartView":
        n = '{"component":"ChartView","kind":"bar","title":"Sales","labels":["Q1","Q2"],"values":[3,5],"value_name":"sales"}'
    elif name == "Sparkline":
        n = '{"component":"Sparkline","values":[1,3,2,5],"label":"trend"}'
    elif name == "KpiView":
        n = '{"component":"KpiView","label":"Revenue","value":"$1.2M","note":"+4%","tone":"good","spark":[1,2,3]}'
    elif name == "Meter":
        n = '{"component":"Meter","label":"Disk","value":40,"figure":"40 GB"}'
    elif name == "ProgressBar":
        n = '{"component":"ProgressBar","value":60,"label":"Uploading"}'
    elif name == "Timeline":
        n = '{"component":"Timeline","steps":[{"label":"Plan","status":"done"},{"label":"Build","status":"running","detail":"2 of 5"}]}'
    elif name == "MapView":
        n = '{"component":"MapView","route":[[38.70,-9.14],[38.69,-9.20]],"places":[{"lat":38.70,"lon":-9.14,"label":"Baixa"}]}'
    elif name == "Breadcrumbs":
        n = '{"component":"Breadcrumbs","items":["Home","Trips","Lisbon"],"action":"crumb"}'
    elif name == "Icon":
        n = '{"component":"Icon","name":"map-pin","size":24}'
    elif name == "Button":
        n = '{"component":"Button","label":"Go","action":"go","style":"prominent"}'
    elif name == "TextField":
        n = '{"component":"TextField","placeholder":"Name","label":"Your name","bind":"/form/name"}'
    elif name == "TextArea":
        n = '{"component":"TextArea","placeholder":"Notes","bind":"/form/notes"}'
    elif name == "Toggle" or name == "Checkbox":
        n = '{"component":"' + name + '","label":"Subscribe","bind":"/form/on"}'
    elif name == "Dropdown" or name == "Segmented" or name == "Radio":
        n = '{"component":"' + name + '","options":["a","b","c"],"label":"Pick","bind":"/form/pick"}'
    elif name == "Slider":
        n = '{"component":"Slider","label":"Party size","bind":"/form/party","min":1,"max":10}'
    elif name == "DatePicker":
        n = '{"component":"DatePicker","label":"Date","bind":"/form/date"}'
    elif name == "Confirm":
        n = '{"component":"Confirm","title":"Refund order 1042?","text":"$42.00 back to the card.","danger":true}'
    else:
        n = '{"component":"' + name + '"}'
    return '{"ui":' + n + "}"


# ---------------------------------------------------------------------------------------------------------------------
# the JSON Schema (the render_ui tool's parameters)
# ---------------------------------------------------------------------------------------------------------------------

def field_schema(f: Field) -> String:
    if f.kind == P_TEXT:
        return '{"type":"string","maxLength":' + String(f.limit) + "}"
    if f.kind == P_ENUM:
        var vals = String("[")
        for i in range(len(f.choices)):
            vals += ("," if i > 0 else "") + json_string(f.choices[i])
        return '{"enum":' + vals + "]}"
    return '{"type":"number","minimum":' + String(f.low) + ',"maximum":' + String(f.limit) + "}"


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
    if p.kind == P_BOOL:
        return '{"type":"boolean"' + about + "}"
    if p.kind == P_TEXTS:
        return '{"type":"array","minItems":' + String(p.low) + ',"maxItems":' + String(p.limit) + ',"items":{"type":"string","maxLength":100}' + about + "}"
    if p.kind == P_NUMBERS:
        return '{"type":"array","maxItems":' + String(p.limit) + ',"items":{"type":"number","minimum":-' + String(NUMBER_LIMIT) + ',"maximum":' + String(NUMBER_LIMIT) + "}" + about + "}"
    if p.kind == P_ROWS:
        return ('{"type":"array","maxItems":' + String(p.limit) + ',"items":{"type":"array","maxItems":' + String(p.low) + ',"items":{"type":["string","number"],"maxLength":200,"minimum":-' + String(NUMBER_LIMIT) + ',"maximum":' + String(NUMBER_LIMIT) + "}}" + about + "}")
    if p.kind == P_POINTS:
        return ('{"type":"array","maxItems":' + String(p.limit) + ',"items":{"type":"array","minItems":2,"maxItems":2,"prefixItems":[{"type":"number","minimum":-90,"maximum":90},{"type":"number","minimum":-180,"maximum":180}]}' + about + "}")
    if p.kind == P_ITEMS:
        var props = String("{")
        var req = String("[")
        for i in range(len(p.fields)):
            props += ("," if i > 0 else "") + json_string(p.fields[i].name) + ":" + field_schema(p.fields[i])
            if p.fields[i].required:
                req += ("," if req.byte_length() > 1 else "") + json_string(p.fields[i].name)
        return ('{"type":"array","minItems":' + String(p.low) + ',"maxItems":' + String(p.limit) + ',"items":{"type":"object","properties":' + props
                + '},"required":' + req + '],"additionalProperties":false}' + about + "}")
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


def within(j: Json, v: Int, low: Float64, high: Float64) -> Bool:
    return j.kind(v) == J_NUMBER and j.real(v) >= low and j.real(v) <= high


def check_field(j: Json, v: Int, f: Field, bad: String) raises:
    var k = j.kind(v)
    if f.kind == P_TEXT:
        if k != J_STRING or chars(j.text(v)) > f.limit:
            raise Error(bad + "'s " + f.name + " must be a string of at most " + String(f.limit) + " characters")
    elif f.kind == P_ENUM:
        var ok = False
        for c in f.choices:
            if k == J_STRING and j.text(v) == c:
                ok = True
        if not ok:
            var all = String("")
            for c in f.choices:
                all += (", " if all.byte_length() > 0 else "") + c
            raise Error(bad + "'s " + f.name + " must be one of " + all)
    elif not within(j, v, Float64(f.low), Float64(f.limit)):
        raise Error(bad + "'s " + f.name + " must be a number from " + String(f.low) + " to " + String(f.limit))


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
        if not within(j, v, Float64(p.low), Float64(p.limit)):
            raise Error(bad + " must be a number from " + String(p.low) + " to " + String(p.limit))
    elif p.kind == P_BOOL:
        if k != J_BOOL:
            raise Error(bad + " must be true or false")
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
            if j.kind(row) != J_ARRAY or j.size(row) > p.low:
                raise Error(bad + ": each row must be a list of at most " + String(p.low) + " cells")
            for c in range(j.size(row)):
                var cell = j.at(row, c)
                if j.kind(cell) == J_STRING:
                    if chars(j.text(cell)) > 200:
                        raise Error(bad + ": a cell is longer than 200 characters")
                elif not bounded(j, cell):
                    raise Error(bad + ": a cell must be a string or a number within ±1e15")
    elif p.kind == P_POINTS:
        if k != J_ARRAY or j.size(v) > p.limit:
            raise Error(bad + " must be a list of at most " + String(p.limit) + " [latitude, longitude] pairs")
        for i in range(j.size(v)):
            var pt = j.at(v, i)
            if j.kind(pt) != J_ARRAY or j.size(pt) != 2 or not within(j, j.at(pt, 0), -90, 90) or not within(j, j.at(pt, 1), -180, 180):
                raise Error(bad + ": each point must be [latitude -90…90, longitude -180…180]")
    elif p.kind == P_ITEMS:
        if k != J_ARRAY or j.size(v) < p.low or j.size(v) > p.limit:
            raise Error(bad + " must be a list of " + String(p.low) + " to " + String(p.limit) + " objects")
        for i in range(j.size(v)):
            var it = j.at(v, i)
            var at = bad + "[" + String(i) + "]"
            if j.kind(it) != J_OBJECT:
                raise Error(at + " must be an object")
            for key in j.keys[it]:
                var known = False
                for ref f in p.fields:
                    if f.name == key:
                        known = True
                if not known:
                    raise Error(at + " has no field " + json_string(key))
            for ref f in p.fields:
                var fv = j.get(it, f.name)
                if fv < 0:
                    if f.required:
                        raise Error(at + " needs " + json_string(f.name))
                    continue
                check_field(j, fv, f, at)
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
comptime ACT_LOCAL = 3  # only the screen itself changed (a tab, a copy, a grid scrolled): redraw

# what a control's message does beyond its component (a Confirm has two)
comptime ROLE_MAIN = 0
comptime ROLE_REJECT = 1

# canvases
comptime CV_SPARK = 0
comptime CV_CHART = 1
comptime CV_KPI = 2
comptime CV_MAP = 3
comptime CV_GRID = 4


@fieldwise_init
struct UiAction(Copyable, Movable):
    var kind: Int
    var bind: String  # the state path an input edited
    var action: String  # the action's word
    var value: String  # JSON: the new value (inputs, choices)

    def report(self) -> String:
        """The tool result for an action: {"action": word, "value": …} (value only when there is one)."""
        return '{"action":' + json_string(self.action) + ((',"value":' + self.value) if self.value.byte_length() > 0 else String("")) + "}"


def is_control(comp: String) -> Bool:
    return (comp == "Button" or comp == "TextField" or comp == "TextArea" or comp == "Toggle" or comp == "Checkbox"
            or comp == "Dropdown" or comp == "Slider" or comp == "Segmented" or comp == "Radio" or comp == "DatePicker"
            or comp == "Tabs" or comp == "CodeBlock" or comp == "Breadcrumbs" or comp == "DataGrid")


def canvas_kind(comp: String) -> Int:
    if comp == "Sparkline":
        return CV_SPARK
    if comp == "ChartView":
        return CV_CHART
    if comp == "KpiView":
        return CV_KPI
    if comp == "MapView":
        return CV_MAP
    if comp == "DataGrid":
        return CV_GRID
    return -1


def gap(word: String) -> Int:
    return SPACE_XS if word == "xs" else (SPACE_M if word == "m" else (SPACE_L if word == "l" else SPACE_S))


struct GenUi(Movable):
    """One agent-built screen: its validated JSON, what each of its controls and canvases is, and the little state
    that is the screen's own (the open tab, a grid's scroll, a copy count)."""

    var problem: String  # "" when it can be shown
    var json: Json
    var base: Int  # its controls' messages: base + k (k < MAX_CONTROLS)
    var canvas_base: Int
    var controls: List[Int]  # node of control k
    var roles: List[Int]  # ROLE_* of control k
    var control_of: Dict[Int, Int]  # node → its (first) control
    var canvases: List[Int]  # node of canvas k (canvas_base + k)
    var kinds: List[Int]  # CV_* of canvas k
    var canvas_of: Dict[Int, Int]  # node → its canvas
    var picks: Dict[Int, Int]  # Tabs node → the open tab
    var copies: Dict[Int, Int]  # CodeBlock node → times copied (the clipboard's version)
    var charts: List[ChartView]  # per canvas (CV_CHART; a placeholder for the others)
    var grids: List[DataGrid]  # per canvas (CV_GRID)
    var tables: List[Rows]  # per canvas (CV_GRID)
    var drawn: Int  # bumps when a canvas's own state changes (a grid scrolled): add it to the canvas versions
    var font: Font
    var palette: Optional[Palette]  # from the last draw (a grid's gestures measure with it)

    def __init__(out self, args: String, base: Int, canvas_base: Int):
        self.problem = validate(args)
        self.base = base
        self.canvas_base = canvas_base
        self.controls = List[Int]()
        self.roles = List[Int]()
        self.control_of = Dict[Int, Int]()
        self.canvases = List[Int]()
        self.kinds = List[Int]()
        self.canvas_of = Dict[Int, Int]()
        self.picks = Dict[Int, Int]()
        self.copies = Dict[Int, Int]()
        self.charts = List[ChartView]()
        self.grids = List[DataGrid]()
        self.tables = List[Rows]()
        self.drawn = 0
        self.font = Font()
        self.palette = None
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

    def str(self, n: Int, key: String) -> String:
        return self.json.text(self.json.get(n, key))

    def num(self, n: Int, key: String, default: Float64) -> Float64:
        var v = self.json.get(n, key)
        return self.json.real(v) if v >= 0 and self.json.kind(v) == J_NUMBER else default

    def texts_of(self, n: Int, key: String) -> List[String]:
        var out = List[String]()
        var a = self.json.get(n, key)
        for i in range(self.json.size(a)):
            out.append(self.json.text(self.json.at(a, i)))
        return out^

    def numbers_of(self, n: Int, key: String) -> List[Float64]:
        var out = List[Float64]()
        var a = self.json.get(n, key)
        for i in range(self.json.size(a)):
            out.append(self.json.real(self.json.at(a, i)))
        return out^

    def cell(self, c: Int) -> String:
        if self.json.kind(c) == J_NUMBER:
            return String(self.json.number(c)) if self.json.is_whole(c) else String(self.json.real(c))
        return self.json.text(c)

    def index(mut self, n: Int):
        """Its controls and canvases, each node once (messages and canvas ids follow document order, so a screen that
        grows as it streams keeps the ones it had)."""
        var comp = self.str(n, "component")
        if is_control(comp):
            self.control_of[n] = len(self.controls)
            self.controls.append(n)
            self.roles.append(ROLE_MAIN)
        if comp == "Confirm":
            self.control_of[n] = len(self.controls)
            self.controls.append(n)
            self.roles.append(ROLE_MAIN)
            self.controls.append(n)
            self.roles.append(ROLE_REJECT)
        var kind = canvas_kind(comp)
        if kind >= 0:
            self.canvas_of[n] = len(self.canvases)
            self.canvases.append(n)
            self.kinds.append(kind)
            self.charts.append(self.chart_of(n) if kind == CV_CHART else ChartView("", List[String](), List[Float64]()))
            var g = DataGrid()
            g.browse = True
            self.grids.append(g^)
            self.tables.append(self.rows_of(n) if kind == CV_GRID else Rows(List[String](), List[Bool]()))
        var ch = self.json.get(n, "children")
        for i in range(self.json.size(ch)):
            self.index(self.json.at(ch, i))

    def chart_of(self, n: Int) -> ChartView:
        var c = ChartView(self.str(n, "title"), self.texts_of(n, "labels"), self.numbers_of(n, "values"),
                          self.str(n, "value_name") if self.json.get(n, "value_name") >= 0 else String("value"),
                          money=self.json.flag(self.json.get(n, "money")))
        if self.str(n, "kind") == "line":
            c.kind = "Line Chart"
        return c^

    def rows_of(self, n: Int) -> Rows:
        var names = self.texts_of(n, "columns")
        var rs = self.json.get(n, "rows")
        var numeric = List[Bool]()
        for c in range(len(names)):
            var all_numbers = self.json.size(rs) > 0
            for r in range(self.json.size(rs)):
                var row = self.json.at(rs, r)
                if c < self.json.size(row) and self.json.kind(self.json.at(row, c)) != J_NUMBER:
                    all_numbers = False
            numeric.append(all_numbers)
        var out = Rows(names^, numeric^)
        for r in range(self.json.size(rs)):
            var row = self.json.at(rs, r)
            var cells = List[String]()
            for c in range(self.json.size(row)):
                cells.append(self.cell(self.json.at(row, c)))
            out.add(cells)
        return out^

    def map_of(self, n: Int) -> MapView:
        var lats = List[Float64]()
        var lons = List[Float64]()
        var route = self.json.get(n, "route")
        for i in range(self.json.size(route)):
            var pt = self.json.at(route, i)
            lats.append(self.json.real(self.json.at(pt, 0)))
            lons.append(self.json.real(self.json.at(pt, 1)))
        var m = MapView(lats^, lons^)
        var places = self.json.get(n, "places")
        for i in range(self.json.size(places)):
            var p = self.json.at(places, i)
            m.mark(self.num(p, "lat", 0), self.num(p, "lon", 0), self.str(p, "label"), MARK_FINDING if self.str(p, "kind") == "finding" else MARK_PLACE)
        return m^

    def kpi_of(self, n: Int) -> KpiView:
        var t = self.str(n, "tone")
        return KpiView(self.str(n, "label"), self.str(n, "value"), self.str(n, "note"), self.numbers_of(n, "spark"),
                       self.json.flag(self.json.get(n, "accent")), TONE_GOOD if t == "good" else (TONE_WARN if t == "warn" else TONE_NONE))

    def view(self, state: JDoc, version: Int = 0) -> View:
        """The screen as native components (inputs show the state's values; `version` redraws its canvases)."""
        if self.problem != "":
            return Text("")
        return self.node(self.json.get(0, "ui"), state, version)

    def children(self, n: Int, state: JDoc, version: Int) -> List[View]:
        var out = List[View]()
        var ch = self.json.get(n, "children")
        for i in range(self.json.size(ch)):
            out.append(self.node(self.json.at(ch, i), state, version))
        return out^

    def msg(self, n: Int) -> Int:
        return self.base + self.control_of.get(n, 0)

    def canvas(self, n: Int) -> Int:
        return self.canvas_base + self.canvas_of.get(n, 0)

    def labelled(self, n: Int, var control: View) -> View:
        """A control with its label above it (when it has one)."""
        if self.json.get(n, "label") < 0:
            return control^
        return VStack(Text(self.str(n, "label"), style=CAPTION), control^, spacing=SPACE_XS).align(START).fill()

    def pick(self, n: Int, state: JDoc) -> Int:
        """The option at bind's index (0 when it isn't one of them)."""
        var picked = state.text_at(self.str(n, "bind"))
        var on = self.json.get(n, "options")
        for i in range(self.json.size(on)):
            if self.json.text(self.json.at(on, i)) == picked:
                return i
        return 0

    def slider_range(self, n: Int) -> Tuple[Float64, Float64, Float64]:
        var lo = self.num(n, "min", 0)
        var hi = self.num(n, "max", 100)
        if hi <= lo:
            hi = lo + 1
        return (lo, hi, max(self.num(n, "step", 1), 1e-9))

    def node(self, n: Int, state: JDoc, version: Int) -> View:
        var comp = self.str(n, "component")
        var v = version + self.drawn
        # layout
        if comp == "Card":
            var items = List[View]()
            if self.json.get(n, "title") >= 0:
                items.append(Text(self.str(n, "title"), style=HEADLINE))
            if self.json.get(n, "subtitle") >= 0:
                items.append(Text(self.str(n, "subtitle"), style=CAPTION))
            for c in self.children(n, state, version):
                items.append(c.copy())
            var t = self.str(n, "tone")
            var card = Card(items^, spacing=SPACE_M).fill()
            return card^.tone(CARD_WARN) if t == "warn" else (card^.tone(CARD_GOOD) if t == "good" else card^)
        if comp == "VStack":
            return VStack(self.children(n, state, version), spacing=gap(self.str(n, "gap"))).align(START).fill()
        if comp == "HStack":
            return HStack(self.children(n, state, version), spacing=gap(self.str(n, "gap"))).align(CENTER)
        if comp == "Grid":
            return Grid(self.children(n, state, version), Int(self.num(n, "columns", 2))).fill()
        if comp == "Tabs":
            var titles = self.texts_of(n, "tabs")
            var at = min(self.picks.get(n, 0), len(titles) - 1)
            var parts = List[View]()
            parts.append(Tabs(titles^, at, on_select=self.msg(n)))
            var ch = self.json.get(n, "children")
            if at < self.json.size(ch):
                parts.append(self.node(self.json.at(ch, at), state, version))
            return VStack(parts^, spacing=SPACE_M).align(START).fill()
        if comp == "Divider":
            return Divider()
        if comp == "Spacer":
            return Spacer()
        # words
        if comp == "Text":
            var s = self.str(n, "style")
            var t = self.str(n, "tone")
            var tone = TONE_ACCENT if t == "accent" else (TONE_GOOD if t == "good" else (TONE_WARN if t == "warn" else (TONE_STRONG if t == "strong" else TONE_NONE)))
            return Text(self.str(n, "text"), style=TITLE if s == "title" else (HEADLINE if s == "headline" else (CAPTION if s == "caption" else BODY))).tone(tone)
        if comp == "Paragraph":
            return Paragraph([Plain(self.str(n, "text"))])
        if comp == "Markdown":
            return Markdown(self.str(n, "text"))
        if comp == "CodeBlock":
            var parts = List[View]()
            if self.json.get(n, "language") >= 0:
                parts.append(Text(self.str(n, "language"), style=CAPTION))
            parts.append(CodeBlock(self.str(n, "code"), self.msg(n), self.copies.get(n, 0), self.copies.get(n, 0) > 0))
            return VStack(parts^, spacing=SPACE_XS).align(START).fill()
        if comp == "Chip":
            return Chip(self.str(n, "text"), Int(self.num(n, "hue", 0)))
        if comp == "Alert":
            var parts = List[View]()
            if self.json.get(n, "title") >= 0:
                parts.append(Text(self.str(n, "title"), style=HEADLINE))
            parts.append(Text(self.str(n, "text")))
            return Warning(parts^) if self.str(n, "tone") == "warn" else Note(parts^)
        if comp == "Skeleton":
            var bars = List[View]()
            var lines = Int(self.num(n, "lines", 3))
            for i in range(lines):
                bars.append(Skeleton(0 if i < lines - 1 or lines == 1 else 180, 12))
            return VStack(bars^, spacing=SPACE_S).fill()
        # data
        if comp == "Table":
            var cols = self.texts_of(n, "columns")
            var cells = List[View]()
            var rs = self.json.get(n, "rows")
            for r in range(self.json.size(rs)):
                var row = self.json.at(rs, r)
                for c in range(len(cols)):
                    cells.append(Text(self.cell(self.json.at(row, c)) if c < self.json.size(row) else String("")))
            return Table(cols^, cells^).fill()
        if comp == "DataGrid":
            var k = self.canvas_of.get(n, 0)
            return Canvas(self.canvas(n), v + self.grids[k].version, on_gesture=self.msg(n)).fill().height(Int(self.num(n, "height", 260)))
        if comp == "ChartView":
            return Canvas(self.canvas(n), v).fill().height(Int(self.num(n, "height", 220)))
        if comp == "Sparkline":
            var parts = List[View]()
            if self.json.get(n, "label") >= 0:
                parts.append(Text(self.str(n, "label"), style=CAPTION))
            parts.append(SparklineView(self.canvas(n), v, 64))
            return VStack(parts^, spacing=SPACE_S).align(START).fill()
        if comp == "KpiView":
            return self.kpi_of(n).view(self.canvas(n), v)
        if comp == "MapView":
            return Canvas(self.canvas(n), v).fill().height(Int(self.num(n, "height", 260)))
        if comp == "Meter":
            return Meter(self.str(n, "label"), Int(self.num(n, "value", 0)), False, self.str(n, "figure"))
        if comp == "ProgressBar":
            return self.labelled(n, ProgressBar(Int(self.num(n, "value", 0))).fill())
        if comp == "Timeline":
            var stages = List[Stage]()
            var steps = self.json.get(n, "steps")
            for i in range(self.json.size(steps)):
                var s = self.json.at(steps, i)
                var st = self.str(s, "status")
                var status = STAGE_DONE if st == "done" else (STAGE_RUNNING if st == "running" else (STAGE_FAILED if st == "failed" else (STAGE_CANCELLED if st == "cancelled" else STAGE_PENDING)))
                stages.append(Stage(self.str(s, "label"), status, -1, self.str(s, "detail")))
            return Timeline(stages)
        if comp == "Breadcrumbs":
            return Breadcrumbs(self.texts_of(n, "items"), self.msg(n))
        if comp == "Icon":
            return Icon(self.str(n, "name"), Int(self.num(n, "size", 24)))
        # inputs
        if comp == "Button":
            var s = self.str(n, "style")
            return Button(self.str(n, "label"), on_tap=self.msg(n), style=PROMINENT if s == "prominent" else (DESTRUCTIVE if s == "destructive" else PLAIN), icon=self.str(n, "icon"))
        if comp == "TextField":
            return self.labelled(n, TextField(state.text_at(self.str(n, "bind")), placeholder=self.str(n, "placeholder"), on_change=self.msg(n)).fill())
        if comp == "TextArea":
            return self.labelled(n, TextArea(state.text_at(self.str(n, "bind")), placeholder=self.str(n, "placeholder"), on_change=self.msg(n), height=Int(self.num(n, "height", 120))).fill())
        if comp == "Toggle":
            return Toggle(self.str(n, "label"), state.flag_at(self.str(n, "bind")), on_toggle=self.msg(n))
        if comp == "Checkbox":
            return Checkbox(self.str(n, "label"), state.flag_at(self.str(n, "bind")), on_toggle=self.msg(n))
        if comp == "Dropdown":
            return self.labelled(n, Dropdown(self.texts_of(n, "options"), self.pick(n, state), on_select=self.msg(n)))
        if comp == "Segmented":
            return self.labelled(n, Segmented(self.texts_of(n, "options"), self.pick(n, state), on_select=self.msg(n)))
        if comp == "Radio":
            return self.labelled(n, Radio(self.texts_of(n, "options"), self.pick(n, state), on_select=self.msg(n)))
        if comp == "Slider":
            var r = self.slider_range(n)
            var value = r[0]
            var at = state.find(self.str(n, "bind"))
            if at >= 0 and state.kinds[at] == J_NUMBER:
                try:
                    value = atof(state.texts[at])
                except:
                    pass
            var pos = Int((value - r[0]) / (r[1] - r[0]) * 100.0 + 0.5)
            var shown = String(Int(value)) if value == Float64(Int(value)) else String(value)
            var head = HStack(Text(self.str(n, "label"), style=CAPTION), Spacer(), Text(shown, style=CAPTION).tone(TONE_STRONG), spacing=SPACE_S).fill()
            return VStack(head^, Slider(max(0, min(100, pos)), on_change=self.msg(n)).fill(), spacing=SPACE_XS).align(START).fill()
        if comp == "DatePicker":
            return self.labelled(n, DatePicker(state.text_at(self.str(n, "bind")), on_change=self.msg(n)))
        if comp == "Confirm":
            var items = List[View]()
            items.append(Text(self.str(n, "title"), style=HEADLINE))
            if self.json.get(n, "text") >= 0:
                items.append(Text(self.str(n, "text")))
            var yes = self.str(n, "approve") if self.json.get(n, "approve") >= 0 else String("Approve")
            var no = self.str(n, "reject") if self.json.get(n, "reject") >= 0 else String("Reject")
            var danger = self.json.flag(self.json.get(n, "danger"))
            items.append(HStack(Spacer(), Button(no, on_tap=self.msg(n) + 1, style=PLAIN),
                                Button(yes, on_tap=self.msg(n), style=DESTRUCTIVE if danger else PROMINENT), spacing=SPACE_S).fill())
            return Card(items^, spacing=SPACE_M).fill()
        return Text("")

    def handle(mut self, e: Event, mut state: JDoc) -> UiAction:
        """One of its controls was used: the state edited at its bind, and its action if it has one."""
        var k = e.message - self.base
        if k < 0 or k >= len(self.controls):
            return UiAction(ACT_NONE, "", "", "")
        var n = self.controls[k]
        var comp = self.str(n, "component")
        var path = self.str(n, "bind")
        var value = String("")
        if comp == "Tabs":
            self.picks[n] = max(0, min(e.number, self.json.size(self.json.get(n, "tabs")) - 1))
            return UiAction(ACT_LOCAL, "", "", "")
        if comp == "CodeBlock":
            self.copies[n] = self.copies.get(n, 0) + 1
            return UiAction(ACT_LOCAL, "", "", "")
        if comp == "DataGrid":
            var c = self.canvas_of.get(n, 0)
            if self.palette:
                _ = self.grids[c].handle(e, self.tables[c], self.font, self.palette.value())
            self.drawn += 1
            return UiAction(ACT_LOCAL, "", "", "")
        if comp == "Confirm":
            var yes = self.roles[k] == ROLE_MAIN
            return UiAction(ACT_ACTION, "", "approve" if yes else "reject", "true" if yes else "false")
        if comp == "Breadcrumbs":
            var act = self.str(n, "action")
            var items_ = self.texts_of(n, "items")
            var at = e.number if e.number >= 0 and e.number < len(items_) else 0
            if act.byte_length() == 0:
                return UiAction(ACT_NONE, "", "", "")
            return UiAction(ACT_ACTION, "", act, json_string(items_[at]))
        if comp == "TextField" or comp == "TextArea" or comp == "DatePicker":
            value = json_string(e.text)
        elif comp == "Toggle" or comp == "Checkbox":
            value = "true" if e.number != 0 else "false"
        elif comp == "Segmented" or comp == "Dropdown" or comp == "Radio":
            var on = self.json.get(n, "options")
            if e.number < 0 or e.number >= self.json.size(on):
                return UiAction(ACT_NONE, "", "", "")
            value = json_string(self.json.text(self.json.at(on, e.number)))
        elif comp == "Slider":
            var r = self.slider_range(n)
            var raw = r[0] + (r[1] - r[0]) * Float64(max(0, min(100, e.number))) / 100.0
            var snapped = r[0] + Float64(Int((raw - r[0]) / r[2] + 0.5)) * r[2]
            snapped = max(r[0], min(r[1], snapped))
            value = String(Int(snapped)) if snapped == Float64(Int(snapped)) else String(snapped)
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

    def draw(mut self, canvas: Int, mut surface: Surface, p: Palette, state: JDoc):
        """Paints one of its canvases."""
        var k = canvas - self.canvas_base
        if k < 0 or k >= len(self.canvases):
            return
        self.palette = p.copy()
        var n = self.canvases[k]
        var kind = self.kinds[k]
        if kind == CV_CHART:
            surface.fill(p.card)
            self.charts[k].draw(surface, self.font, p)
        elif kind == CV_KPI:
            self.kpi_of(n).draw(surface, p)
        elif kind == CV_MAP:
            surface.fill(p.card)
            self.map_of(n).draw(surface, self.font, p)
        elif kind == CV_GRID:
            self.grids[k].draw(surface, self.tables[k], self.font, p)
        else:
            var values = List[Float64]()
            if self.json.get(n, "bind") >= 0:
                values = state.numbers_at(self.str(n, "bind"))
            else:
                values = self.numbers_of(n, "values")
            surface.fill(p.card)  # (it sits on a card)
            Sparkline.themed(values, p).draw(surface)
