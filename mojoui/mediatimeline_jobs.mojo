# mojoui.mediatimeline_jobs: the editor's work off the UI thread (goal 39 M11). MediaTimeline's thumbnails are decoded
# and scaled (VideoSource + imageops on the GPU) in background jobs, a chunk at a time so the filmstrip fills in from
# the left; an export runs the cut in a job too. The UI thread only copies finished thumbnails into the cache.
#
#   var feed = TimelineFeed()
#   update():  if ed.update(event): feed.poll(ed)        # (also after any event: it starts the next chunk, takes what ended)
#
# Separate from mojoui.mediatimeline because it needs omxcore (jobs): the editor's model and drawing stay testable with
# a plain `mojo run`, and an app without omxcore can feed thumbnails itself (Thumbnails.put).

from omxcore import Job, JobBody, JobCtl, JOB_RUNNING
from mojoui.jobs import start_ui_job
from mojoui.imageops import ImageOps, Frame
from mojoui.mediatimeline import MediaTimeline, ReelSpec, decode_thumbnails, write_reel
from mojoui.video import VideoSource
from mojoui.videotable import VideoTable, Analyzer, ColourRange, scan

comptime CHUNK = 12  # thumbnails per job


struct ThumbJob(JobBody):
    comptime Out = List[Frame]
    var path: String
    var interval: Float64
    var first: Int
    var count: Int
    var height: Int

    def __init__(out self, path: String, interval: Float64, first: Int, count: Int, height: Int):
        self.path = path
        self.interval = interval
        self.first = first
        self.count = count
        self.height = height

    def run(mut self, ctl: JobCtl) raises -> List[Frame]:
        return decode_thumbnails(self.path, self.interval, self.first, self.count, self.height)


struct ExportJob(JobBody):
    comptime Out = Int
    var path: String
    var out: String
    var spec: ReelSpec

    def __init__(out self, path: String, out_path: String, var spec: ReelSpec):
        self.path = path
        self.out = out_path
        self.spec = spec^

    def run(mut self, ctl: JobCtl) raises -> Int:
        return write_reel(self.path, self.out, self.spec)


struct AnalyseJob[A: Analyzer](JobBody):
    """A video's analysis rows (mojoui.videotable.scan, on the GPU) off the UI thread: what the editor's lanes and its
    sentence are made from when the app has no rows yet."""
    comptime Out = VideoTable
    var path: String
    var analyzer: Self.A
    var ranges: List[ColourRange]
    var cell: Int

    def __init__(out self, path: String, var analyzer: Self.A, var ranges: List[ColourRange], cell: Int):
        self.path = path
        self.analyzer = analyzer^
        self.ranges = ranges^
        self.cell = cell

    def run(mut self, ctl: JobCtl) raises -> VideoTable:
        var video = VideoSource(self.path)
        return scan(video, self.analyzer, self.ranges, self.cell)


struct TimelineFeed(Movable):
    var thumbs: Optional[Job[List[Frame]]]
    var first: Int  # the running chunk's first thumbnail
    var export: Optional[Job[Int]]
    var exporting: String  # the path the running export writes

    def __init__(out self):
        self.thumbs = None
        self.first = 0
        self.export = None
        self.exporting = ""

    def poll(mut self, mut ed: MediaTimeline):
        """Takes finished work into the editor and starts what's next (one thumbnail job and one export at a time)."""
        if self.thumbs and self.thumbs.value().poll() != JOB_RUNNING:
            var job = self.thumbs.take()
            try:
                ed.thumbs.put(self.first, job.result())
            except:
                ed.thumbs.put(self.first, List[Frame]())  # (a failed chunk: the rest stays empty tiles)
            ed.version += 1
        if not self.thumbs and not ed.thumbs.complete():
            self.first = ed.thumbs.arrived
            var n = min(CHUNK, ed.thumbs.count() - self.first)
            self.thumbs = start_ui_job(ThumbJob(ed.path(), ed.thumbs.interval, self.first, n, ed.thumbs.height))
        if self.export and self.export.value().poll() != JOB_RUNNING:
            var job = self.export.take()
            try:
                ed.exported(job.result())
            except e:
                ed.status = "Export failed: " + String(e)
                ed.export_path = ""
            ed.version += 1
        if not self.export and ed.export_path != "" and ed.export_path != self.exporting:
            self.exporting = ed.export_path
            self.export = start_ui_job(ExportJob(ed.path(), ed.export_path, ed.reel_spec()))
        if not self.export:
            self.exporting = ""
