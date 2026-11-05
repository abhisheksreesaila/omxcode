# mojoui.models: models as functions a script calls (goal 51). The registry a script runs with (mojoui.script's
# ScriptFunctions): the video functions (mojoui.videoscript: regions, …) and the models, each loaded from its pack the
# first time a script calls it (mojoui.maxrt; packs in $OMX_PACKS, else build/packs).
#
#   classified = classify(fleet, task, verbs, verb);
#       each distinct value of fleet.task once, embedded (e5-small-v2, mojoui.textembed) with every verbs.verb; the
#       nearest label by cosine: columns value, label, score (its cosine), margin (how far ahead of the runner-up: a
#       small margin is a row a person, or a bigger model, should look at)
#
#   var fns = ModelFunctions(videos^)        # (the app's videos, as mojoui.videoscript has them)
#   var run = run_script(text, catalog, fns)

from std.os import getenv
from omxcore import Catalog, Table, sql, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL
from mojoui.script import ScriptFunctions
from mojoui.sheet import Sheet
from mojoui.videoscript import VideoFunctions
from mojoui.maxrt import MaxRuntime
from mojoui.textembed import Embedder

comptime MODEL_FUNCTIONS: List[String] = ["classify"]
comptime CLASSIFY_PACK = "e5small"  # classify()'s model: e5-small-v2 (MIT; scripts/packs/e5small.py), D-4919


def packs_dir() -> String:
    return getenv("OMX_PACKS", "build/packs")


def _quoted(name: String) -> String:
    return "\"" + name.replace("\"", "\"\"") + "\""


def _texts(mut catalog: Catalog, table: String, column: String) raises -> List[String]:
    """The distinct non-empty values of table.column as text, in first-seen order."""
    var answer = sql(catalog, "SELECT DISTINCT " + _quoted(column) + " FROM " + _quoted(table) + " WHERE " + _quoted(column) + " IS NOT NULL")
    var s = Sheet(answer.take_table().share(), False)
    var out = List[String]()
    for r in range(s.rows()):
        var t = s.plain_text(0, r)
        if t != "":
            out.append(t)
    return out^


struct ModelFunctions(ScriptFunctions, Movable):
    var videos: VideoFunctions

    def __init__(out self, var videos: VideoFunctions):
        self.videos = videos^

    def has(self, name: String) -> Bool:
        return name in materialize[MODEL_FUNCTIONS]() or self.videos.has(name)

    def call(mut self, name: String, args: List[String], mut catalog: Catalog) raises -> Table:
        if name == "classify":
            return self.classify(args, catalog)
        return self.videos.call(name, args, catalog)

    def classify(mut self, args: List[String], mut catalog: Catalog) raises -> Table:
        if len(args) != 4:
            raise Error("classify(table, column, labels_table, label_column): what to label, then the labels")
        var values = _texts(catalog, args[0], args[1])
        var labels = _texts(catalog, args[2], args[3])
        if len(labels) < 2:
            raise Error("classify needs at least two labels in " + args[2] + "." + args[3])
        var rt = MaxRuntime()
        var e = Embedder(rt, packs_dir() + "/" + CLASSIFY_PACK)
        var lv = e.embed(labels)
        var vv = e.embed(values, 1024)
        var d = e.dim
        var t = Table.empty()
        var c_value = t.add_column("value", MX_TEXT)
        var c_label = t.add_column("label", MX_TEXT)
        var c_score = t.add_column("score", MX_DECIMAL, 3)
        var c_margin = t.add_column("margin", MX_DECIMAL, 3)
        for i in range(len(values)):
            var best = -1
            var top = -2.0
            var second = -2.0
            for j in range(len(labels)):
                var c = 0.0
                for k in range(d):
                    c += Float64(vv[i * d + k]) * Float64(lv[j * d + k])
                if c > top:
                    second = top
                    top = c
                    best = j
                elif c > second:
                    second = c
            t.append_text(c_value, values[i])
            t.append_text(c_label, labels[best])
            t.append(c_score, Int64(Int(top * 1000.0 + (0.5 if top >= 0 else -0.5))))
            t.append(c_margin, Int64(Int((top - second) * 1000.0 + 0.5)))
        t.check()
        return t^
