# mojoui.models: models as functions a script calls (goal 51). The registry a script runs with (mojoui.script's
# ScriptFunctions): the video functions (mojoui.videoscript: regions, …) and the models, each loaded from its pack the
# first time a script calls it (mojoui.maxrt; packs in $OMX_PACKS, else build/packs).
#
#   classified = classify(fleet, task, verbs, verb);
#       each distinct value of fleet.task once, embedded (e5-small-v2, mojoui.textembed) with every verbs.verb; the
#       nearest label by cosine: columns label, score (its cosine), margin (how far ahead of the runner-up: a
#       small margin is a row a person, or a bigger model, should look at), value
#
#   boxes = detect(episode, 3.0, 8.0);
#       YOLOX-Tiny (mojoui.detect) on every frame of the video from 3.0 to 8.0 s: a row per box: frame (the video's own
#       number), t, kind (its COCO class), score, x, y, w, h (the video's pixels)
#
#   var fns = ModelFunctions(videos^)        # (the app's videos, as mojoui.videoscript has them)
#   var run = run_script(text, catalog, fns)

from std.os import getenv
from omxcore import Catalog, Table, sql, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL, INT as MX_INT
from mojoui.script import ScriptFunctions
from mojoui.sheet import Sheet
from mojoui.videoscript import VideoFunctions
from mojoui.textembed import Embedder
from mojoui.detect import Detector, coco_name
from mojoui.video import VideoSource
from mojoui.videoscript import frame_span

comptime MODEL_FUNCTIONS: List[String] = ["classify", "detect"]
comptime FRAME_MODELS: List[String] = ["detect"]  # the models Apply offers on a video's section (beside mojoui.videoscript's)
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
        if name == "detect":
            return self.detect(args)
        return self.videos.call(name, args, catalog)

    def classify(mut self, args: List[String], mut catalog: Catalog) raises -> Table:
        if len(args) != 4:
            raise Error("classify(table, column, labels_table, label_column): what to label, then the labels")
        var values = _texts(catalog, args[0], args[1])
        var labels = _texts(catalog, args[2], args[3])
        if len(labels) < 2:
            raise Error("classify needs at least two labels in " + args[2] + "." + args[3])
        var e = Embedder(packs_dir() + "/" + CLASSIFY_PACK)
        var lv = e.embed(labels)
        var vv = e.embed(values, 1024)
        var d = e.dim
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

    def detect(mut self, args: List[String]) raises -> Table:
        if len(args) < 1 or len(args) > 3:
            raise Error("detect(video, from_s, to_s): a video's name, then seconds")
        var k = self.videos.find(args[0])
        if k < 0:
            raise Error("no video " + args[0] + (": the videos are " + ", ".join(self.videos.names) if len(self.videos) > 0 else ": open one first"))
        var from_s = Float64(args[1]) if len(args) > 1 else 0.0
        var to_s = Float64(args[2]) if len(args) > 2 else -1.0
        var video = VideoSource(self.videos.paths[k])
        var span = frame_span(video.fps, video.frames, from_s, to_s)
        if span[1] <= span[0]:
            raise Error("detect: no frames in that section")
        var d = Detector(packs_dir() + "/yolox")
        var t = Table.empty()
        var c_frame = t.add_column("frame", MX_INT)
        var c_t = t.add_column("t", MX_DECIMAL, 3)
        var c_kind = t.add_column("kind", MX_TEXT)
        var c_score = t.add_column("score", MX_DECIMAL, 3)
        var c_x = t.add_column("x", MX_INT)
        var c_y = t.add_column("y", MX_INT)
        var c_w = t.add_column("w", MX_INT)
        var c_h = t.add_column("h", MX_INT)
        video.seek_frame(span[0])
        var px = List[UInt32]()
        for f in range(span[0], span[1]):
            if not video.next_into(px):
                break
            for b in d.detect_rgba(px, video.width, video.height):
                t.append(c_frame, Int64(f))
                t.append(c_t, Int64(Int(Float64(f) * 1000.0 / video.fps + 0.5)))
                t.append_text(c_kind, coco_name(b.cls))
                t.append(c_score, Int64(Int(b.score * 1000.0 + 0.5)))
                t.append(c_x, Int64(Int(b.x + 0.5)))
                t.append(c_y, Int64(Int(b.y + 0.5)))
                t.append(c_w, Int64(Int(b.w + 0.5)))
                t.append(c_h, Int64(Int(b.h + 0.5)))
        t.check()
        return t^
