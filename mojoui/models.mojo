# mojoui.models: models as functions a script calls (goal 51), every one of them a model plugin (goal 68 M0,
# mojoui.plugins): the registry a script runs with (mojoui.script's ScriptFunctions) is the video functions
# (mojoui.videoscript: regions, …) and one function per plugin found in mojoui.plugins.plugin_dirs() (no Mojo per
# model: what a function does follows its plugin's kind and runner; a folder dropped in is a function, no rebuild).
#
#   classified = classify(fleet, task, verbs, verb);
#       each distinct value of fleet.task once, embedded by the text embedder plugin (e5small: e5-small-v2, a MAX pack
#       from scripts/packs/e5small.py; else the first embed-text plugin) with every verbs.verb; the nearest label by
#       cosine: columns label, score (its cosine), margin (how far ahead of the runner-up), value
#
#   boxes = detect(episode, 3.0, 8.0);         (any detect plugin, by its name: YOLOX-Tiny's pack is called detect)
#       on every frame of the video from 3.0 to 8.0 s: a row per box: frame, t, kind, score, x, y, w, h (the video's pixels)
#
#   labels = scene(episode, 3.0, 8.0);         (any classify-image plugin: ResNet-18's pack is scene)
#       on every frame from 3.0 to 8.0 s: a row per frame: label (its best), score (how sure, 0–1), frame, t
#
#   stops = stops_xgb(moments);                (any tabular plugin: a decision model on a table's rows)
#       a row per row of the table: row, label (or value), score; its inputs matched to the table's columns by name
#
# Runners: max (mojoui.maxrt: mojoui.detect's YOLOX decode, mojoui.textembed, mojoui.imagemodel), tree (mojoui.treefile),
# torch / onnx / skops (mojoui.pluginrun, in this process). Video functions' names and a plugin found earlier win.
#
#   var fns = ModelFunctions(videos^)        # (the app's videos, as mojoui.videoscript has them)
#   var run = run_script(text, catalog, fns)

from std.os import getenv
from std.os.path import exists
from omxcore import Catalog, Table, sql, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL, INT as MX_INT
from mojoui.script import ScriptFunctions
from mojoui.sheet import Sheet
from mojoui.videoscript import VideoFunctions, VIDEO_FUNCTIONS
from mojoui.textembed import Embedder
from mojoui.detect import Detector, coco_name, max_detector
from mojoui.video import VideoSource
from mojoui.videoscript import frame_span
from mojoui.imagemodel import ImageModel
from mojoui.json import Json
from mojoui.plugins import Plugin, find_plugins
from mojoui.pluginrun import py_load, py_job, py_loaded, py_classify, py_detect, py_embed, match_columns, tabular_rows, Seen

comptime MODEL_FUNCTIONS: List[String] = ["classify"]  # (classify(): a function over the text embedder plugin)
comptime CLASSIFY_PLUGIN = "e5small"  # classify()'s embedder when there is one: e5-small-v2 (MIT; scripts/packs/e5small.py), D-4919


def packs_dir() -> String:
    return getenv("OMX_PACKS", "build/packs")


@fieldwise_init
struct PackFunction(Copyable, Movable):
    """A plugin a script calls (goal 59's name for a pack that says what it is): its function, kind, folder, one line."""
    var function: String
    var kind: String  # (a MAX classify-image plugin says "image-labels", goal 59's word)
    var dir: String
    var about: String


def _usable() -> List[Plugin]:
    """The plugins a script can call: readable, with a name no video function has; a MAX one only with its compiled
    graph (a failed build has none)."""
    var out = List[Plugin]()
    for p in find_plugins():
        if not p.ok() or p.name in materialize[VIDEO_FUNCTIONS]() or p.name in materialize[MODEL_FUNCTIONS]():
            continue
        if p.runner == "max" and not exists(p.file("graph")):
            continue
        out.append(p.copy())
    return out^


def pack_functions(packs: String = "") -> List[PackFunction]:
    """Every picture-labelling MAX plugin, in name order (what goal 59's Apply offered; `packs` is unused: plugins
    are found in mojoui.plugins.plugin_dirs(), which includes $OMX_PACKS)."""
    _ = packs
    var out = List[PackFunction]()
    for p in _usable():
        if p.kind == "classify-image" and p.runner == "max":
            out.append(PackFunction(p.name, "image-labels", p.dir, p.about))
    return out^


def box_models() -> List[String]:
    """The detect plugins' names (their rows are boxes on frames: marks on a video)."""
    var out = List[String]()
    for p in _usable():
        if p.kind == "detect":
            out.append(p.name)
    return out^


def frame_models() -> List[String]:
    """The models Apply offers on a video's section: every detect and classify-image plugin, in name order."""
    var out = List[String]()
    for p in _usable():
        if p.kind == "detect" or p.kind == "classify-image":
            out.append(p.name)
    sort(out)
    return out^


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
    var plugins: List[Plugin]  # the plugins scripts can call, read once (_usable)

    def __init__(out self, var videos: VideoFunctions):
        self.videos = videos^
        self.plugins = _usable()

    def _plugin(self, name: String) -> Int:
        for i in range(len(self.plugins)):
            if self.plugins[i].name == name:
                return i
        return -1

    def has(self, name: String) -> Bool:
        return name in materialize[MODEL_FUNCTIONS]() or self._plugin(name) >= 0 or self.videos.has(name)

    def call(mut self, name: String, args: List[String], mut catalog: Catalog) raises -> Table:
        if name == "classify":
            return self.classify(args, catalog)
        var k = self._plugin(name)
        if k >= 0:
            var p = self.plugins[k].copy()
            if p.kind == "classify-image" or p.kind == "detect":
                return self.on_frames(p, args)
            if p.kind == "tabular":
                return self.tabular(p, args, catalog)
            raise Error(name + ": a " + p.kind + " plugin isn't a script function yet (" + p.dir + "/plugin.json)")
        return self.videos.call(name, args, catalog)

    def _ready(self, p: Plugin) raises:
        """A Python-run plugin loaded (on this thread: a script runs in a job)."""
        if p.runner == "max" or p.runner == "tree" or py_loaded(p.dir):
            return
        py_load(p.dir)
        while py_job("load:" + p.dir).state == "running":
            pass
        var j = py_job("load:" + p.dir)
        if j.state != "done":
            raise Error(p.name + " didn't load: " + j.error)

    def on_frames(mut self, p: Plugin, args: List[String]) raises -> Table:
        """A picture model on every frame of a video's section: a row per frame (a classifier: label, score, frame, t)
        or per box (a detector: frame, t, kind, score, x, y, w, h)."""
        var name = p.name
        if len(args) < 1 or len(args) > 3:
            raise Error(name + "(video, from_s, to_s): a video's name, then seconds")
        var k = self.videos.find(args[0])
        if k < 0:
            raise Error("no video " + args[0] + (": the videos are " + ", ".join(self.videos.names) if len(self.videos) > 0 else ": open one first"))
        var from_s = Float64(args[1]) if len(args) > 1 else 0.0
        var to_s = Float64(args[2]) if len(args) > 2 else -1.0
        var video = VideoSource(self.videos.paths[k])
        var span = frame_span(video.fps, video.frames, from_s, to_s)
        if span[1] <= span[0]:
            raise Error(name + ": no frames in that section")
        self._ready(p)
        var t = Table.empty()
        var detector = p.kind == "detect"
        var c_label = -1
        var c_score = -1
        var c_frame: Int
        var c_t: Int
        var c_x = -1
        var c_y = -1
        var c_w = -1
        var c_h = -1
        if detector:
            c_frame = t.add_column("frame", MX_INT)
            c_t = t.add_column("t", MX_DECIMAL, 3)
            c_label = t.add_column("kind", MX_TEXT)
            c_score = t.add_column("score", MX_DECIMAL, 3)
            c_x = t.add_column("x", MX_INT)
            c_y = t.add_column("y", MX_INT)
            c_w = t.add_column("w", MX_INT)
            c_h = t.add_column("h", MX_INT)
        else:
            c_label = t.add_column("label", MX_TEXT)  # (the answer first: a narrow card shows it, as classify's)
            c_score = t.add_column("score", MX_DECIMAL, 3)
            c_frame = t.add_column("frame", MX_INT)
            c_t = t.add_column("t", MX_DECIMAL, 3)
        var image: Optional[ImageModel] = None
        var boxes: Optional[Detector] = None  # (a MAX detect plugin)
        if p.runner == "max":
            if detector:
                boxes = max_detector(p)
            else:
                image = ImageModel(p.dir)
        var queries = p.param("queries")
        video.seek_frame(span[0])
        var px = List[UInt32]()
        for f in range(span[0], span[1]):
            if not video.next_into(px):
                break
            var seen = List[Seen]()
            if image:
                var g = image.value().top_rgba(px, video.width, video.height)
                seen.append(Seen(image.value().labels[g.label], g.score, 0.0, 0.0, 0.0, 0.0))
            elif boxes:
                for b in boxes.value().detect_rgba(px, video.width, video.height):
                    seen.append(Seen(coco_name(b.cls), b.score, b.x, b.y, b.w, b.h))
            elif detector:
                seen = py_detect(p.dir, px, video.width, video.height, queries)
            else:
                seen = py_classify(p.dir, px, video.width, video.height, 1)
            var ms = Int64(Int(Float64(f) * 1000.0 / video.fps + 0.5))
            for s in seen:
                t.append(c_frame, Int64(f))
                t.append(c_t, ms)
                t.append_text(c_label, s.label)
                t.append(c_score, Int64(Int(s.score * 1000.0 + 0.5)))
                if detector:
                    t.append(c_x, Int64(Int(s.x + 0.5)))
                    t.append(c_y, Int64(Int(s.y + 0.5)))
                    t.append(c_w, Int64(Int(s.w + 0.5)))
                    t.append(c_h, Int64(Int(s.h + 0.5)))
                if not detector:
                    break
        t.check()
        return t^

    def tabular(mut self, p: Plugin, args: List[String], mut catalog: Catalog) raises -> Table:
        """A decision model on a table's rows: row, label (or value), score."""
        if len(args) != 1:
            raise Error(p.name + "(table): the table whose rows it answers")
        var answer = sql(catalog, "SELECT * FROM " + _quoted(args[0]))
        var sheet = Sheet(answer.take_table().share(), False)
        var m = match_columns(p, sheet)
        if not m.ok():
            raise Error(p.name + " on " + args[0] + ": " + m.said())
        self._ready(p)
        var rows = List[Int]()
        for r in range(sheet.rows()):
            rows.append(r)
        var a = tabular_rows(p, sheet, m, rows)
        var t = Table.empty()
        var c_row = t.add_column("row", MX_INT)
        var c_label = t.add_column("value" if a.regression else "label", MX_DECIMAL if a.regression else MX_TEXT, 4 if a.regression else 0)
        var c_score = t.add_column("score", MX_DECIMAL, 3)
        for i in range(len(rows)):
            t.append(c_row, Int64(rows[i] + 1))
            if a.regression:
                t.append(c_label, Int64(Int(a.score[i] * 10000.0 + (0.5 if a.score[i] >= 0 else -0.5))))
                t.append(c_score, 0)
            else:
                t.append_text(c_label, a.labels[a.best[i]])
                t.append(c_score, Int64(Int(a.score[i] * 1000.0 + 0.5)))
        t.check()
        return t^

    def classify(mut self, args: List[String], mut catalog: Catalog) raises -> Table:
        if len(args) != 4:
            raise Error("classify(table, column, labels_table, label_column): what to label, then the labels")
        var values = _texts(catalog, args[0], args[1])
        var labels = _texts(catalog, args[2], args[3])
        if len(labels) < 2:
            raise Error("classify needs at least two labels in " + args[2] + "." + args[3])
        var k = self._plugin(CLASSIFY_PLUGIN)
        if k < 0 or self.plugins[k].kind != "embed-text":
            k = -1
            for i in range(len(self.plugins)):
                if self.plugins[i].kind == "embed-text" and k < 0:
                    k = i
        if k < 0:
            raise Error("classify needs a text embedder plugin (scripts/packs/e5small.py, or Add a model: a feature-extraction model)")
        var p = self.plugins[k].copy()
        var lv: List[Float32]
        var vv: List[Float32]
        var d: Int
        if p.runner == "max":
            var e = Embedder(p.dir)
            lv = e.embed(labels)
            vv = e.embed(values, 1024)
            d = e.dim
        else:
            self._ready(p)
            var a = py_embed(p.dir, labels)
            var b = py_embed(p.dir, values)
            d = a[1]
            lv = List[Float32](capacity=len(a[0]))
            for x in a[0]:
                lv.append(Float32(x))
            vv = List[Float32](capacity=len(b[0]))
            for x in b[0]:
                vv.append(Float32(x))
        var t = Table.empty()
        var c_label = t.add_column("label", MX_TEXT)  # (the short columns first: a card shows them beside the long text)
        var c_score = t.add_column("score", MX_DECIMAL, 3)
        var c_margin = t.add_column("margin", MX_DECIMAL, 3)
        var c_value = t.add_column("value", MX_TEXT)
        for i in range(len(values)):
            var best = -1
            var top = -2.0
            var second = -2.0
            for j in range(len(labels)):
                var c = 0.0
                for q in range(d):
                    c += Float64(vv[i * d + q]) * Float64(lv[j * d + q])
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
