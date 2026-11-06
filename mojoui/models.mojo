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
#   labels = scene(episode, 3.0, 8.0);
#       any pack whose model.json says kind "image-labels" (scripts/packs/from_torch.py writes it; ResNet-18 is
#       `scene`): its function by the name model.json gives, on every frame from 3.0 to 8.0 s: a row per frame: frame,
#       t, label (its best), score (how sure, 0–1). No Mojo edit adds one: a pack in the packs folder is found
#       (pack_functions), shown in a video's Apply menu (frame_models) and called (mojoui.imagemodel).
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
from mojoui.imagemodel import ImageModel
from mojoui.json import Json

comptime MODEL_FUNCTIONS: List[String] = ["classify", "detect"]
comptime FRAME_MODELS: List[String] = ["detect"]  # the models Apply offers on a video's section (beside mojoui.videoscript's)
comptime CLASSIFY_PACK = "e5small"  # classify()'s model: e5-small-v2 (MIT; scripts/packs/e5small.py), D-4919


def packs_dir() -> String:
    return getenv("OMX_PACKS", "build/packs")


@fieldwise_init
struct PackFunction(Copyable, Movable):
    """A pack that says what it is (its model.json): the function a script calls, its kind, its folder, one line about it."""
    var function: String
    var kind: String
    var dir: String
    var about: String


def pack_functions(packs: String = "") -> List[PackFunction]:
    """Every pack in `packs` (packs_dir() when empty) with a model.json naming a function, in name order. A folder without
    one (classify's and detect's packs: their Mojo is built in) or with one that doesn't read is skipped."""
    from std.os import listdir
    from std.os.path import isdir, exists
    var dir = packs if packs != "" else packs_dir()
    var out = List[PackFunction]()
    if not isdir(dir):
        return out^
    var names = List[String]()
    try:
        for n in listdir(dir):
            names.append(String(n))
    except:
        return out^
    sort(names)
    for n in names:
        var d = dir + "/" + n
        if not exists(d + "/model.json"):
            continue
        try:
            var j = Json.parse(open(d + "/model.json", "r").read())
            var f = j.text(j.get(0, "function"))
            if f != "" and not f in materialize[MODEL_FUNCTIONS]():
                out.append(PackFunction(f, j.text(j.get(0, "kind")), d, j.text(j.get(0, "about"))))
        except:
            pass
    return out^


def frame_models() -> List[String]:
    """The models Apply offers on a video's section: detect, then every image-labels pack found."""
    var out = materialize[FRAME_MODELS]()
    for p in pack_functions():
        if p.kind == "image-labels":
            out.append(p.function)
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
    var packs: List[PackFunction]  # the packs that describe themselves, read once (pack_functions)

    def __init__(out self, var videos: VideoFunctions):
        self.videos = videos^
        self.packs = pack_functions()

    def _pack(self, name: String) -> Int:
        for i in range(len(self.packs)):
            if self.packs[i].function == name:
                return i
        return -1

    def has(self, name: String) -> Bool:
        return name in materialize[MODEL_FUNCTIONS]() or self._pack(name) >= 0 or self.videos.has(name)

    def call(mut self, name: String, args: List[String], mut catalog: Catalog) raises -> Table:
        if name == "classify":
            return self.classify(args, catalog)
        if name == "detect":
            return self.detect(args)
        var k = self._pack(name)
        if k >= 0:
            if self.packs[k].kind == "image-labels":
                return self.image_labels(self.packs[k].copy(), args)
            raise Error(name + ": a pack of kind '" + self.packs[k].kind + "', which this version can't run (" + self.packs[k].dir + "/model.json)")
        return self.videos.call(name, args, catalog)

    def image_labels(mut self, pack: PackFunction, args: List[String]) raises -> Table:
        """pack's network on every frame of a video's section: frame, t, label, score."""
        var name = pack.function
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
        var m = ImageModel(pack.dir)
        var t = Table.empty()
        var c_frame = t.add_column("frame", MX_INT)
        var c_t = t.add_column("t", MX_DECIMAL, 3)
        var c_label = t.add_column("label", MX_TEXT)
        var c_score = t.add_column("score", MX_DECIMAL, 3)
        video.seek_frame(span[0])
        var px = List[UInt32]()
        for f in range(span[0], span[1]):
            if not video.next_into(px):
                break
            var g = m.top_rgba(px, video.width, video.height)
            t.append(c_frame, Int64(f))
            t.append(c_t, Int64(Int(Float64(f) * 1000.0 / video.fps + 0.5)))
            t.append_text(c_label, m.labels[g.label])
            t.append(c_score, Int64(Int(g.score * 1000.0 + 0.5)))
        t.check()
        return t^

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
