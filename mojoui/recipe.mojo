# mojoui.recipe: a script's run, kept to share (goal 49 M3/M4). A recipe is a folder: script.sql (the script as written,
# its ${questions} left in, so a colleague reruns it on their own data), each result as <name>.csv, and the section of
# video the script applied a function to, cut as <video>-<from>-<to>.mp4. Written as a job (a cut takes a while).
#
#   var job = start_ui_job(RecipeJob(folder, text, names^, sheets^, clip_path, from_s, to_s))   # Out = Recipe
#   var text = read_recipe(folder)            # Open recipe: script.sql's text (a folder, or the file itself)

from std.os import makedirs
from omxcore import JobBody, JobCtl
from mojoui.clock import now_ns
from mojoui.files import file_stem
from mojoui.imageops import ImageOps
from mojoui.sheet import Sheet
from mojoui.video import VideoSource, file_exists
from mojoui.videoexport import NoEdits, cut


struct Recipe(Movable):
    """What a recipe export wrote: its folder, its files, the clip's frames (0: no clip)."""

    var folder: String
    var files: List[String]
    var clip_frames: Int
    var milliseconds: Float64

    def __init__(out self, folder: String, var files: List[String], clip_frames: Int, milliseconds: Float64):
        self.folder = folder
        self.files = files^
        self.clip_frames = clip_frames
        self.milliseconds = milliseconds


def _secs(x: Float64) -> String:
    var tenths = Int(x * 10.0 + 0.5)
    return String(tenths // 10) + "." + String(tenths % 10)


struct RecipeJob(JobBody):
    comptime Out = Recipe
    var folder: String
    var text: String
    var names: List[String]
    var sheets: List[Sheet]
    var video: String  # the applied section's video ("": none, no clip)
    var from_s: Float64
    var to_s: Float64

    def __init__(out self, folder: String, text: String, var names: List[String], var sheets: List[Sheet], video: String, from_s: Float64, to_s: Float64):
        self.folder = folder
        self.text = text
        self.names = names^
        self.sheets = sheets^
        self.video = video
        self.from_s = from_s
        self.to_s = to_s

    def run(mut self, ctl: JobCtl) raises -> Recipe:
        var t0 = now_ns()
        makedirs(self.folder, exist_ok=True)
        var files = List[String]()
        var script = self.folder + "/script.sql"
        with open(script, "w") as f:
            f.write(self.text if self.text.endswith("\n") else self.text + "\n")
        files.append(script)
        for i in range(len(self.sheets)):
            var p = self.folder + "/" + self.names[i] + ".csv"
            self.sheets[i].write_csv(p)
            files.append(p)
        var frames = 0
        if self.video != "" and self.to_s > self.from_s:
            var src = VideoSource(self.video)
            var segments = List[Tuple[Float64, Float64]]()
            segments.append((self.from_s, self.to_s))
            var clip = self.folder + "/" + file_stem(self.video) + "-" + _secs(self.from_s) + "-" + _secs(self.to_s) + ".mp4"
            var plan = NoEdits()
            var ops = ImageOps()
            frames = cut(src, segments, plan, clip, ops)
            files.append(clip)
        return Recipe(self.folder, files^, frames, Float64(now_ns() - t0) / 1e6)


def read_recipe(path: String) raises -> String:
    """A recipe's script: <path>/script.sql, or `path` itself when it is the file."""
    var p = path if path.endswith(".sql") else path + "/script.sql"
    if not file_exists(p):
        raise Error("No recipe at " + path + ": a recipe is a folder with a script.sql")
    with open(p, "r") as f:
        return f.read()
