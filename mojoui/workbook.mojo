# mojoui.workbook: a workbook on disk, a folder `name.mxwb/`:
#   workbook.json    the tables (their source or Parquet file, formulas, the session's edits), the objects, the layout
#   table-<k>.parquet  a table's stored columns (only when it has no reproducible source)
# Parquet is written and read by the MX frame package (no Python, goal 20): each stored column is a plain integer
# column, as the pyarrow code before it wrote them, so older workbooks open. The JSON is read by mojoui.json and is
# plain enough for an agent to write.

from std.os import makedirs
from omxcore import Table as MxTable, read_parquet, write_parquet, UNCOMPRESSED, INT as MX_INT
from mojoui.json import json_string, Json
from mojoui.frame import Column, Columns, Frame, Row, Edit, share, base_at, INT, DECIMAL, TEXT, DATE, MAX_COLS


def write_text(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def read_text(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


@fieldwise_init
struct ObjectSpec(Copyable, Movable):
    """One object on the page, as the file holds it."""

    var kind: Int
    var title: String
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var a: Int
    var b: Int
    var c: Int
    var text: String
    var selected: Int

    def to_json(self) -> String:
        return ('{"kind": ' + String(self.kind) + ', "title": ' + json_string(self.title) + ', "x": ' + String(self.x) + ', "y": ' + String(self.y)
                + ', "w": ' + String(self.w) + ', "h": ' + String(self.h) + ', "a": ' + String(self.a) + ', "b": ' + String(self.b)
                + ', "c": ' + String(self.c) + ', "text": ' + json_string(self.text) + ', "selected": ' + String(self.selected) + "}")


def table_json(frame: Frame, source: String, parquet: String) raises -> String:
    """A table: where its stored columns come from, its formulas and the session's edits."""
    ref base = frame.base()[]
    var out = String('{"source": ') + json_string(source) + ', "parquet": ' + json_string(parquet) + ', "columns": ['
    for c in range(len(base.cols)):
        ref col = base.cols[c]
        out += ("," if c > 0 else "") + '{"name": ' + json_string(col.name) + ', "kind": ' + String(col.kind) + ', "scale": ' + String(col.scale)
        if col.kind == TEXT:
            out += ', "dictionary": ['
            for k in range(len(col.dictionary)):
                out += ("," if k > 0 else "") + json_string(col.dictionary[k])
            out += "]"
        out += "}"
    out += '], "formulas": ['
    for f in range(len(frame.formulas)):
        out += ("," if f > 0 else "") + json_string(frame.formulas[f].name + " = " + frame.formulas[f].formula)
    out += '], "words": ['
    var first = True
    for c in range(len(frame.words)):
        for w in frame.words[c]:
            out += ("" if first else ",") + "[" + String(c) + ", " + json_string(w) + "]"
            first = False
    out += '], "edits": ['
    first = True
    for item in frame.cells.items():
        out += ("" if first else ",") + "[" + String(item.key % MAX_COLS) + ", " + String(item.key // MAX_COLS) + ", " + String(item.value) + "]"
        first = False
    out += '], "added": ['
    for i in range(len(frame.added)):
        out += ("," if i > 0 else "") + "["
        for c in range(len(base.cols)):
            out += ("," if c > 0 else "") + String(frame.added[i][c])
        out += "]"
    out += '], "removed": ['
    first = True
    for row in frame.removed:
        out += ("" if first else ",") + String(row)
        first = False
    return out + "]}"


def save_workbook(path: String, frame: Frame, source: String, objects: List[ObjectSpec], widths: List[Int] = []) raises:
    """Writes `path` (a folder ending in .mxwb). Tables with a source name aren't copied: the JSON
    says how to rebuild them; others get a Parquet file beside the JSON."""
    var parquet = String("") if source != "" else String("table-0.parquet")
    makedirs(path, exist_ok=True)
    if parquet != "":
        ref base = frame.base()[]
        var t = MxTable.empty()
        for c in range(len(base.cols)):  # (each stored column as plain integers: kinds and dictionaries are in the JSON)
            var k = t.add_column(base.cols[c].name, MX_INT)
            t.cols[k].values = base.cols[c].values.copy()
        write_parquet(path + "/" + parquet, t, "", UNCOMPRESSED)
    var out = String('{"mojoui_workbook": 1, "tables": [') + table_json(frame, source, parquet) + '], "widths": ['
    for k in range(len(widths)):  # the grid's column widths in points (0 = the default for its type)
        out += ("," if k > 0 else "") + String(widths[k])
    out += '], "objects": ['
    for k in range(len(objects)):
        out += ("," if k > 0 else "") + objects[k].to_json()
    out += "]}\n"
    write_text(path + "/workbook.json", out)


def open_workbook(path: String, shared_source: String, shared_addr: Int, mut objects: List[ObjectSpec], mut base_addr: Int) raises -> Frame:
    """Reads `path`: returns the frame (its session edits applied), fills `objects` and sets `base_addr`.
    A table whose source matches the process's shared data reuses it; otherwise its Parquet file is
    loaded (and shared for the rest of the process)."""
    var j = Json.parse(read_text(path + "/workbook.json"))
    var t = j.at(j.get(0, "tables"), 0)
    if t < 0:
        raise Error("the workbook has no table")
    var source = j.text(j.get(t, "source"))
    var addr = shared_addr
    if source == "" or source != shared_source:
        var file = j.text(j.get(t, "parquet"))
        if file == "":
            raise Error("the workbook's table has no source and no Parquet file")
        var read = read_parquet(path + "/" + file)
        var stored = read.take_table()
        var specs = j.get(t, "columns")
        if j.size(specs) != stored.columns():
            raise Error("the workbook's table has " + String(j.size(specs)) + " columns, its Parquet file " + String(stored.columns()))
        var cols = Columns()
        for c in range(stored.columns()):
            var spec = j.at(specs, c)
            var col = Column(j.text(j.get(spec, "name")), j.number(j.get(spec, "kind")), j.number(j.get(spec, "scale")))
            col.values = List[Int64](capacity=stored.rows())
            for v in stored.values(c):
                col.values.append(v)
            if col.kind == TEXT:
                var words = j.get(spec, "dictionary")
                for k in range(j.size(words)):
                    col.dictionary.append(j.text(j.at(words, k)))
            cols.add(col^)
        addr = share(cols^)
    var frame = Frame(addr)
    var stored = frame.stored()
    var formulas = j.get(t, "formulas")
    for k in range(j.size(formulas)):
        _ = frame.formula(j.text(j.at(formulas, k)))
    var words = j.get(t, "words")
    for k in range(j.size(words)):
        var w = j.at(words, k)
        var c = j.number(j.at(w, 0))
        if c < 0 or c >= stored:
            raise Error("words: column " + String(c) + " doesn't exist")
        frame.words[c].append(j.text(j.at(w, 1)))
    var added = j.get(t, "added")
    for k in range(j.size(added)):
        var a = j.at(added, k)
        var r = Row(0)
        var width = j.size(a)
        if width > stored:
            raise Error("added row " + String(k) + " has " + String(width) + " values for " + String(stored) + " columns")
        for c in range(width):
            r[c] = Int64(j.number(j.at(a, c)))
        frame.added.append(r)
    var edits = j.get(t, "edits")
    for k in range(j.size(edits)):
        var e = j.at(edits, k)
        var c = j.number(j.at(e, 0))
        var row = j.number(j.at(e, 1))
        if c < 0 or c >= stored or row < 0 or row >= frame.rows():
            raise Error("edit " + String(k) + " names column " + String(c) + ", row " + String(row) + ": not in the table")
        frame.set(c, row, Int64(j.number(j.at(e, 2))))
    var removed = j.get(t, "removed")
    for k in range(j.size(removed)):
        var row = j.number(j.at(removed, k))
        if row < 0 or row >= frame.rows():
            raise Error("removed row " + String(row) + ": not in the table")
        frame.remove(row)
    frame.log = List[Edit]()  # what the file holds isn't undoable
    objects = List[ObjectSpec]()
    var objs = j.get(0, "objects")
    for k in range(j.size(objs)):
        var o = j.at(objs, k)
        objects.append(ObjectSpec(j.number(j.get(o, "kind")), j.text(j.get(o, "title")), j.number(j.get(o, "x")), j.number(j.get(o, "y")),
                                  j.number(j.get(o, "w")), j.number(j.get(o, "h")), j.number(j.get(o, "a")), j.number(j.get(o, "b")),
                                  j.number(j.get(o, "c")), j.text(j.get(o, "text")), j.number(j.get(o, "selected"))))
    base_addr = addr
    return frame^


def read_widths(path: String) raises -> List[Int]:
    """The grid's column widths saved with the workbook (empty if it has none: older files)."""
    var j = Json.parse(read_text(path + "/workbook.json"))
    var out = List[Int]()
    var w = j.get(0, "widths")
    for k in range(j.size(w)):
        out.append(max(0, min(j.number(j.at(w, k)), 2000)))
    return out^
