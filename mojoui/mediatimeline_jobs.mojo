# mojoui.mediatimeline_jobs: the editor's work off the UI thread (goal 39 M11). MediaTimeline's thumbnails are decoded
# and scaled (VideoSource + imageops on the GPU) in background jobs, a chunk at a time so the filmstrip fills in from
# the left; an export runs the cut in a job too. The viewer's preview (the reel's blur, captions and boxes on the frame
# on show) is made by a job too, newest first (goal 41 M2): its GPU context and plan travel with the job and come back
# with the picture. The UI thread only copies finished work into the editor.
#
#   var feed = TimelineFeed()
#   update():  if ed.update(event): feed.poll(ed)        # (also after any event: it starts the next chunk, takes what ended)
#
# Separate from mojoui.mediatimeline because it needs omxcore (jobs): the editor's model and drawing stay testable with
# a plain `mojo run`, and an app without omxcore can feed thumbnails itself (Thumbnails.put).

from omxcore import Job, JobBody, JobCtl, JOB_RUNNING
from mojoui.jobs import start_ui_job
from mojoui.imageops import ImageOps, Frame
from mojoui.mediatimeline import MediaTimeline, ReelSpec, decode_thumbnails, write_reel, render_preview
from mojoui.videoexport import RedactPlan
from mojoui.video import VideoSource

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


def _take_ops(mut o: Optional[ImageOps]) -> Optional[ImageOps]:
    """o's value moved out (o left empty), or None when it had none (Optional.take() aborts on an empty one)."""
    if o:
        return o.take()
    return None


def _take_plan(mut o: Optional[RedactPlan]) -> Optional[RedactPlan]:
    if o:
        return o.take()
    return None


struct Previewed(Movable):
    """A preview job's answer: the edited frame, and the GPU context and plan it used (kept for the next one)."""
    var frame: Frame
    var ops: Optional[ImageOps]
    var plan: Optional[RedactPlan]
    var key: Int
    var plan_key: Int

    def __init__(out self, var frame: Frame, var ops: Optional[ImageOps], var plan: Optional[RedactPlan], key: Int, plan_key: Int):
        self.frame = frame^
        self.ops = ops^
        self.plan = plan^
        self.key = key
        self.plan_key = plan_key


struct PreviewJob(JobBody):
    """The reel's edits on one frame for the viewer, off the UI thread: the GPU context made on first use, the plan
    built from the spec when the chips changed (`spec` set), both handed back with the picture."""
    comptime Out = Previewed
    var frame: Frame
    var ops: Optional[ImageOps]
    var plan: Optional[RedactPlan]
    var spec: Optional[ReelSpec]
    var key: Int
    var plan_key: Int

    def __init__(out self, var frame: Frame, var ops: Optional[ImageOps], var plan: Optional[RedactPlan], var spec: Optional[ReelSpec], key: Int, plan_key: Int):
        self.frame = frame^
        self.ops = ops^
        self.plan = plan^
        self.spec = spec^
        self.key = key
        self.plan_key = plan_key

    def run(mut self, ctl: JobCtl) raises -> Previewed:
        if not self.ops:
            self.ops = ImageOps()
        if self.spec:
            self.plan = self.spec.value().plan()
        var frame = self.frame.copy()
        try:
            render_preview(frame, self.plan, self.ops.value(), self.key // 8)
        except:
            pass  # (the plain frame: a preview that couldn't be made)
        return Previewed(frame^, _take_ops(self.ops), _take_plan(self.plan), self.key, self.plan_key)


struct TimelineFeed(Movable):
    var thumbs: Optional[Job[List[Frame]]]
    var first: Int  # the running chunk's first thumbnail
    var export: Optional[Job[Int]]
    var exporting: String  # the path the running export writes
    var preview: Optional[Job[Previewed]]

    def __init__(out self):
        self.thumbs = None
        self.first = 0
        self.export = None
        self.exporting = ""
        self.preview = None

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
        self.poll_preview(ed)

    def poll_preview(mut self, mut ed: MediaTimeline):
        """Takes a finished preview into the viewer and starts the next one wanted (one at a time: the newest wins)."""
        _ = ed.player.poll()
        if self.preview and self.preview.value().poll() != JOB_RUNNING:
            var job = self.preview.take()
            try:
                var got = job.result()
                ed.preview = got.frame.copy()
                ed.preview_key = got.key
                ed.ops = _take_ops(got.ops)
                ed.plan = _take_plan(got.plan)
                ed.plan_key = got.plan_key
            except:
                ed.ops = None  # (made again next time)
                ed.plan = None
                ed.plan_key = -1
            ed.preview_busy = False
            ed.version += 1
        var want = ed.preview_wanted()
        if self.preview or want < 0 or want == ed.preview_key:
            return
        if ed.player.have != want // 8 or len(ed.player.buf) != ed.player.info.width * ed.player.info.height:
            return  # (its frame hasn't landed: the next poll, at a display frame, starts it)
        var fx = want % 8
        var spec = Optional[ReelSpec](None)
        if not ed.plan or ed.plan_key != fx:
            spec = ed.preview_spec()
            ed.plan = None
        var frame = Frame(ed.player.info.width, ed.player.info.height, ed.player.buf.copy())
        self.preview = start_ui_job(PreviewJob(frame^, _take_ops(ed.ops), _take_plan(ed.plan), spec^, want, fx))
        ed.preview_busy = True
