# mojoui.pluginrun: running a model plugin (mojoui.plugins) on an app's data (goal 68 M0, M2). Decision models
# (runner tree) are evaluated here in Mojo (mojoui.treefile); torch, ONNX and skops plugins run in this process through
# mojoui/plugin_py.py (loaded from its file, every call inside python_enter/python_exit so a job thread or a lent lock
# is safe). Long work (a download, loading, every row or frame) runs on Python threads: py_job(key) says how far.
#
#   var m = match_columns(plugin, sheet)          # a tabular model's inputs ↔ the sheet's columns, by name and type
#   if m.ok(): var a = tabular_rows(plugin, sheet, m, rows)   # TabularAnswer: per row its label (or value) and score
#   var pf = py_preflight("hustvl/yolos-tiny")     # Preflight: the one line said before any download, can_run, why
#   py_download(pf, folder, allow_code); py_job("dl:" + folder)   # PyJob: state, done, total, error
#   py_load(folder); py_classify(folder, px, w, h); py_detect(…); py_embed(folder, texts)

from std.python import Python, PythonObject
from std.os import getenv
from std.reflection import source_location
from std.memory import Pointer
from std.ffi import external_call
from mojoui.pygil import python_enter as _pygil_enter, python_exit, python_start
from mojoui.json import Json, J_ARRAY, J_STRING, json_string
from mojoui.plugins import Plugin, PluginIO
from mojoui.treefile import Forest
from mojoui.sheet import Sheet, TEXT as SHEET_TEXT, DECIMAL as SHEET_DECIMAL


# ------------------------------------------------------------------------------------------------- Python's side


def python_enter() raises -> Int:
    """The Python lock on this thread, CPython started first when it isn't running yet (the first call, on the UI thread)."""
    var n = String("Py_IsInitialized")
    var f = external_call["dlsym", Int](0, n.as_c_string_span())
    var up = False
    if f != 0:
        var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=f)
        up = Pointer(to=raw).unsafe_bitcast[def() thin abi("C") -> Int32]()[]() != 0
    if not up:
        python_start()
    return _pygil_enter()


def _py() raises -> PythonObject:
    """mojoui/plugin_py.py, loaded from its file once (never through sys.path): $MOJOUI_PY's folder, else this source's."""
    var sys = Python.import_module("sys")
    if Bool(py=sys.modules.__contains__("mojoui_plugin_py")):
        return sys.modules["mojoui_plugin_py"]
    var os = Python.import_module("os")
    var folder = getenv("MOJOUI_PY", "")
    if folder.byte_length() == 0:
        folder = String(py=os.path.dirname(os.path.abspath(source_location().file_name())))
    var path = os.path.join(folder, "plugin_py.py")
    if not Bool(py=os.path.isfile(path)):
        raise Error("plugins: no plugin_py.py at " + String(py=path) + " (set MOJOUI_PY to its folder)")
    var util = Python.import_module("importlib.util")
    var spec = util.spec_from_file_location("mojoui_plugin_py", path)
    var mod = util.module_from_spec(spec)
    sys.modules["mojoui_plugin_py"] = mod
    spec.loader.exec_module(mod)
    return mod


@fieldwise_init
struct PyJob(Copyable, Movable):
    var state: String  # none, running, done, failed, cancelled
    var done: Int
    var total: Int
    var error: String

    def share(self) -> Float64:
        return Float64(self.done) / Float64(self.total) if self.total > 0 else 0.0


def py_job(key: String) -> PyJob:
    try:
        var g = python_enter()
        var text = String(py=_py().job(key))
        python_exit(g)
        var j = Json.parse(text)
        return PyJob(j.text(j.get(0, "state"), "none"), j.number(j.get(0, "done")), j.number(j.get(0, "total")), j.text(j.get(0, "error")))
    except e:
        return PyJob("failed", 0, 0, String(e))


def py_cancel(key: String):
    try:
        var g = python_enter()
        _ = _py().cancel(key)
        python_exit(g)
    except:
        pass


struct Preflight(Copyable, Movable):
    var json: String  # all of it (handed back to download and write_plugin)
    var repo: String
    var line: String
    var why: String
    var kind: String
    var licence: String
    var can_run: Bool
    var remote_code: Bool
    var bytes: Int
    var files: String  # JSON list
    var sizes: String  # JSON object
    var shas: String  # JSON object: an LFS file's sha256
    var sha: String

    def __init__(out self):
        self.json = "{}"
        self.repo = ""
        self.line = ""
        self.why = ""
        self.kind = ""
        self.licence = ""
        self.can_run = False
        self.remote_code = False
        self.bytes = 0
        self.files = "[]"
        self.sizes = "{}"
        self.shas = "{}"
        self.sha = ""


def py_preflight(text: String) raises -> Preflight:
    var g = python_enter()
    var s = String(py=_py().preflight(text))
    python_exit(g)
    var j = Json.parse(s)
    var p = Preflight()
    p.json = s
    p.repo = j.text(j.get(0, "repo"))
    p.line = j.text(j.get(0, "line"))
    p.why = j.text(j.get(0, "why"))
    p.kind = j.text(j.get(0, "kind"))
    p.licence = j.text(j.get(0, "licence"))
    p.can_run = j.flag(j.get(0, "can_run"))
    p.remote_code = j.flag(j.get(0, "remote_code"))
    p.bytes = j.number(j.get(0, "bytes"))
    p.files = j.dump(j.get(0, "files")) if j.get(0, "files") >= 0 else "[]"
    p.sizes = j.dump(j.get(0, "sizes")) if j.get(0, "sizes") >= 0 else "{}"
    p.shas = j.dump(j.get(0, "shas")) if j.get(0, "shas") >= 0 else "{}"
    p.sha = j.text(j.get(0, "sha"))
    return p^


def py_plugin_name(repo: String) raises -> String:
    var g = python_enter()
    var s = String(py=_py().plugin_name(repo))
    python_exit(g)
    return s


def py_download(pf: Preflight, folder: String, allow_code: Bool) raises:
    var g = python_enter()
    _ = _py().download(pf.repo, folder, pf.files, pf.sha, allow_code, pf.sizes, pf.shas)
    python_exit(g)


def py_write_plugin(folder: String, pf: Preflight, allow_code: Bool) raises -> String:
    var g = python_enter()
    var s = String(py=_py().write_plugin(folder, pf.json, allow_code))
    python_exit(g)
    return s


def py_load(folder: String) raises:
    var g = python_enter()
    _ = _py().load(folder)
    python_exit(g)


def py_loaded(folder: String) -> Bool:
    try:
        var g = python_enter()
        var b = Bool(py=_py().loaded(folder))
        python_exit(g)
        return b
    except:
        return False


@fieldwise_init
struct Seen(Copyable, Movable):
    """One thing a picture model said: a label (and a box for a detector), how sure."""
    var label: String
    var score: Float64
    var x: Float64
    var y: Float64
    var w: Float64
    var h: Float64


def _seen(text: String) raises -> List[Seen]:
    var j = Json.parse(text)
    var out = List[Seen]()
    for i in range(j.size(0)):
        var r = j.at(0, i)
        var n = j.size(r)
        out.append(Seen(j.text(j.at(r, 0)), j.real(j.at(r, 1)), j.real(j.at(r, 2)) if n > 2 else 0.0, j.real(j.at(r, 3)) if n > 3 else 0.0,
                        j.real(j.at(r, 4)) if n > 4 else 0.0, j.real(j.at(r, 5)) if n > 5 else 0.0))
    return out^


def py_classify(folder: String, px: List[UInt32], w: Int, h: Int, top: Int = 3) raises -> List[Seen]:
    var g = python_enter()
    var s = String(py=_py().classify_image(folder, Int(px.unsafe_ptr()), w, h, top))
    python_exit(g)
    _ = len(px)
    return _seen(s)


def py_detect(folder: String, px: List[UInt32], w: Int, h: Int, queries: String = "", threshold: Float64 = 0.5) raises -> List[Seen]:
    var g = python_enter()
    var s = String(py=_py().detect(folder, Int(px.unsafe_ptr()), w, h, queries, threshold))
    python_exit(g)
    _ = len(px)
    return _seen(s)


def _floats(lst: PythonObject) raises -> List[Float64]:
    var array = Python.import_module("array")
    var a = array.array("d", lst)
    var n = Int(py=Python.import_module("builtins").len(a))
    var out = List[Float64](capacity=n)
    if n == 0:
        return out^
    var p = Pointer[Float64, MutUntrackedOrigin](unsafe_from_address=Int(py=a.buffer_info()[0]))
    for i in range(n):
        out.append(p.unsafe_offset(i)[])
    return out^


def _texts_json(texts: List[String]) -> String:
    var s = String("[")
    for i in range(len(texts)):
        s += ("," if i > 0 else "") + json_string(texts[i])
    return s + "]"


def py_embed(folder: String, texts: List[String]) raises -> Tuple[List[Float64], Int]:
    """Each text's vector, flat (texts × dim), and dim."""
    var g = python_enter()
    var flat = _floats(_py().embed_text(folder, _texts_json(texts)))
    python_exit(g)
    var dim = Int(flat.pop())
    return (flat^, dim)


def py_run_video(folder: String, path: String, every: Int, queries: String = "", threshold: Float64 = 0.5) raises:
    var g = python_enter()
    _ = _py().run_video(folder, path, every, queries, threshold)
    python_exit(g)


def py_run_texts(folder: String, texts: List[String]) raises:
    var g = python_enter()
    _ = _py().run_texts(folder, _texts_json(texts))
    python_exit(g)


def py_result_rows(key: String) raises -> String:
    var g = python_enter()
    var s = String(py=_py().result_rows(key))
    python_exit(g)
    return s


def py_similar(key: String, row: Int) raises -> List[Float64]:
    var g = python_enter()
    var out = _floats(_py().similar(key, row))
    python_exit(g)
    return out^


def py_stats(folder: String) -> String:
    try:
        var g = python_enter()
        var s = String(py=_py().model_stats(folder))
        python_exit(g)
        return s
    except:
        return "{}"


# ----------------------------------------------------------------------------------------------------- tables


struct Match(Copyable, Movable):
    """A tabular model's inputs and the sheet's columns: each input's column (-1: none), and what doesn't match."""
    var inputs: List[String]
    var types: List[String]
    var cols: List[Int]
    var problems: List[String]

    def __init__(out self):
        self.inputs = List[String]()
        self.types = List[String]()
        self.cols = List[Int]()
        self.problems = List[String]()

    def ok(self) -> Bool:
        return len(self.problems) == 0 and len(self.inputs) > 0

    def said(self) -> String:
        if self.ok():
            return "reads " + ", ".join(self.inputs)
        return "; ".join(self.problems)


def model_inputs(p: Plugin) raises -> List[PluginIO]:
    """The inputs plugin.json names; for a tree file that names none, the file's own feature names (as numbers)."""
    if len(p.inputs) > 0 or p.runner != "tree":
        return p.inputs.copy()
    var f = Forest.load(p.file("model"))
    var out = List[PluginIO]()
    for name in f.features:
        out.append(PluginIO(name, "number"))
    return out^


def match_columns(p: Plugin, sheet: Sheet) -> Match:
    """Each input to the column with its name (any case) and a kind it takes: a number input ↔ a number, date or
    true/false column, a text input ↔ a text column. Never by position or a near name: a mismatch is said."""
    var m = Match()
    var ins: List[PluginIO]
    try:
        ins = model_inputs(p)
    except e:
        m.problems.append(String(e))
        return m^
    if len(ins) == 0:
        m.problems.append(p.name + " doesn't say which columns it reads (inputs in plugin.json)")
    for io in ins:
        m.inputs.append(io.name)
        m.types.append(io.type)
        var found = sheet.index(io.name)  # (its exact name first, then any case: the first such column)
        if found < 0:
            for c in range(sheet.columns()):
                if found < 0 and sheet.name(c).lower() == io.name.lower():
                    found = c
        if io.type == "text" and p.kind == "tabular":
            m.problems.append("needs " + io.name + " as text: this version's decision models read number columns only")
            found = -1
        elif found < 0:
            m.problems.append("needs " + io.name + " (" + io.type + "): no column called " + io.name)
        elif (io.type == "text") != (sheet.kind(found) == SHEET_TEXT):
            m.problems.append("needs " + io.name + " as " + io.type + ": the sheet's " + sheet.name(found) + " is " + ("text" if sheet.kind(found) == SHEET_TEXT else "a number"))
            found = -1
        m.cols.append(found)
    return m^


struct TabularAnswer(Movable):
    var labels: List[String]  # the classes ("" for a regressor)
    var best: List[Int]  # per row: the class (-1 for a regressor)
    var score: List[Float64]  # per row: how sure (the class's probability), or the value (a regressor)
    var regression: Bool

    def __init__(out self):
        self.labels = List[String]()
        self.best = List[Int]()
        self.score = List[Float64]()
        self.regression = False

    def said(self, i: Int) -> String:
        if self.regression:
            return String(Int(self.score[i] * 1000.0 + (0.5 if self.score[i] >= 0 else -0.5)) / 1000)
        return self.labels[self.best[i]] + " (" + String(Int(self.score[i] * 100.0 + 0.5)) + "%)"


def _value(sheet: Sheet, c: Int, r: Int) -> Float64:
    if sheet.is_null(c, r):
        return Float64(0) / Float64(0)
    var div = 1.0
    if sheet.kind(c) == SHEET_DECIMAL:
        for _ in range(sheet.scale(c)):
            div *= 10.0
    return Float64(sheet.value(c, r)) / div


def _classes(p: Plugin, n: Int, file_names: List[String]) -> List[String]:
    var out = List[String]()
    try:
        var j = Json.parse(p.params)
        var cs = j.get(0, "classes")
        if cs >= 0 and j.kind(cs) == J_ARRAY:
            for i in range(j.size(cs)):
                out.append(j.text(j.at(cs, i)) if j.kind(j.at(cs, i)) == J_STRING else j.dump(j.at(cs, i)))
    except:
        pass
    if len(out) == 0:
        for name in file_names:
            out.append(name)
    while len(out) < n:
        out.append(String(len(out)))
    return out^


def tabular_rows(p: Plugin, sheet: Sheet, m: Match, rows: List[Int]) raises -> TabularAnswer:
    """The model on those rows of the sheet (columns as matched)."""
    if not m.ok():
        raise Error(m.said())
    var a = TabularAnswer()
    if p.runner == "tree":
        var f = Forest.load(p.file("model"))
        if (len(f.features) > 0 and len(m.cols) != len(f.features)) or f.widest() > len(m.cols):
            raise Error(p.name + " reads " + String(f.widest()) + " columns; its plugin.json names " + String(len(m.cols)))
        var k = max(f.classes, 2) if f.kind != "regression" else 1
        a.regression = f.kind == "regression"
        if not a.regression:
            a.labels = _classes(p, k, f.class_names)
        var row = List[Float64](length=len(m.cols), fill=0.0)
        for r in rows:
            for i in range(len(m.cols)):
                row[i] = _value(sheet, m.cols[i], r)
            var out = f.predict(row)
            if a.regression:
                a.best.append(-1)
                a.score.append(out[0])
            elif f.kind == "binary":
                var p1 = out[0]
                a.best.append(1 if p1 >= 0.5 else 0)
                a.score.append(p1 if p1 >= 0.5 else 1.0 - p1)
            else:
                var b = 0
                for i in range(len(out)):
                    if out[i] > out[b]:
                        b = i
                a.best.append(b)
                a.score.append(out[b])
        return a^
    if p.runner == "onnx" or p.runner == "skops":
        var cols = String("[")
        for i in range(len(m.cols)):
            cols += ("," if i > 0 else "") + "["
            for k in range(len(rows)):
                var v = _value(sheet, m.cols[i], rows[k])
                cols += ("," if k > 0 else "") + ("null" if v != v else String(v))
            cols += "]"
        cols += "]"
        var g = python_enter()
        var s = String(py=_py().tabular(p.dir, cols))
        python_exit(g)
        var j = Json.parse(s)
        var vals = j.get(0, "values")
        var labs = j.get(0, "labels")
        if labs >= 0 and j.kind(labs) == J_ARRAY:
            for i in range(j.size(labs)):
                a.labels.append(j.text(j.at(labs, i)) if j.kind(j.at(labs, i)) == J_STRING else j.dump(j.at(labs, i)))
        for i in range(j.size(vals)):
            var r = j.at(vals, i)
            if j.size(r) == 1 and len(a.labels) == 0:
                a.regression = True
                a.best.append(-1)
                a.score.append(j.real(j.at(r, 0)))
            else:
                var b = 0
                for q in range(j.size(r)):
                    if j.real(j.at(r, q)) > j.real(j.at(r, b)):
                        b = q
                a.best.append(b)
                a.score.append(j.real(j.at(r, b)))
        while len(a.labels) < 1 and not a.regression:
            a.labels.append("0")
        if not a.regression:
            var n = 0
            for b in a.best:
                n = max(n, b + 1)
            while len(a.labels) < n:
                a.labels.append(String(len(a.labels)))
        return a^
    raise Error(p.name + ": a " + p.runner + " plugin isn't a tabular one")
