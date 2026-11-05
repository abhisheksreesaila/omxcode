# mojoui.videoscript: videos in a script (goal 49 M2). Every video an app holds is a table a script reads by name, one row
# per frame (frame, t), made from what the video says about itself (no decode, no analysis: cheap for any length); and
# the functions a script calls on a video's frames (mojoui.script's ScriptFunctions) live here too.
#
#   var videos = VideoFunctions()
#   videos.add("episode", "clips/F00118.mp4", 15.0, 244)     # its SQL name, file, rate and frame count (VideoInfo)
#   videos.add_to(catalog)                                   # `episode` is a table: frame 0…243, t in seconds (3 places)
#   var run = run_script("frames = SELECT * FROM episode;", catalog, videos)
#
# A video's rows join anything with a time or a frame: `ON round(tl.t * 15) = f.frame` for a 15 Hz log.

from omxcore import Catalog, Table, Frame as MxFrame, INT as MX_INT, DECIMAL as MX_DECIMAL
from mojoui.script import ScriptFunctions


def frames_table(fps: Float64, frames: Int) raises -> Table:
    """A video's frames as rows: frame (0-based) and t (its time in seconds, 3 places: frame / fps)."""
    var t = Table.empty()
    var frame = t.add_column("frame", MX_INT)
    var secs = t.add_column("t", MX_DECIMAL, 3)
    for i in range(frames):
        t.append(frame, Int64(i))
        t.append(secs, Int64(Int(Float64(i) * 1000.0 / fps + 0.5)) if fps > 0 else Int64(0))
    t.check()
    return t^


struct VideoFunctions(ScriptFunctions, Copyable, Movable, Sized):
    """The videos a script can read (each a table by its SQL name) and the functions it can call on their frames."""

    var names: List[String]
    var paths: List[String]
    var fps: List[Float64]
    var frames: List[Int]

    def __init__(out self):
        self.names = List[String]()
        self.paths = List[String]()
        self.fps = List[Float64]()
        self.frames = List[Int]()

    def __len__(self) -> Int:
        return len(self.names)

    def add(mut self, name: String, path: String, fps: Float64, frames: Int):
        """A video by its SQL name (a later one with the same name replaces it)."""
        var k = self.find(name)
        if k >= 0:
            self.paths[k] = path
            self.fps[k] = fps
            self.frames[k] = frames
            return
        self.names.append(name)
        self.paths.append(path)
        self.fps.append(fps)
        self.frames.append(frames)

    def find(self, name: String) -> Int:
        for k in range(len(self.names)):
            if self.names[k] == name:
                return k
        return -1

    def add_to(self, mut catalog: Catalog) raises:
        """Every video as a table of its frames, by its name."""
        for k in range(len(self.names)):
            catalog.add_frame(self.names[k], MxFrame(frames_table(self.fps[k], self.frames[k]).share()))

    def has(self, name: String) -> Bool:
        return False

    def call(mut self, name: String, args: List[String], mut catalog: Catalog) raises -> Table:
        raise Error("no function " + name)
