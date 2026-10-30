# mojoui.visionmodel_jobs: the learned model's slow work as jobs (goal 41 M3): loading a model (seconds: weights, CUDA)
# and a find-more-like-this scan over a whole video run on a job's thread (mojoui.jobs.start_ui_job), so the UI thread
# only starts them and takes their rows when the end wakes it. Separate from mojoui.visionmodel, which stays a plain
# module (no omxcore) its own test runs with `mojo run`.
#
#   var job = find_like_job(path, "google/owlv2-base-patch16-ensemble", examples, "like")   # returns at once
#   on App.jobs_message: if job.poll() != JOB_RUNNING: var found = job.result()             # LikeResult: .table rows
#
# The model is loaded inside the job and dropped with it; a model kept between scans is a later step (a model service).
# UNVERIFIED (goal 41): built, not run. Whether Mojo's Python interop takes CPython's lock on a thread Python didn't make
# must be checked in the models env (tests/test_findlike.mojo through this job) before an app relies on it.

from omxcore import Job, JobBody, JobCtl
from mojoui.jobs import start_ui_job
from mojoui.video import VideoSource
from mojoui.visionmodel import VisionModel, Example, LikeResult, find_like, DETECT


struct FindLikeJob(JobBody):
    comptime Out = LikeResult
    var path: String
    var model: String
    var examples: List[Example]
    var kind: String
    var stride: Int
    var device: String

    def __init__(out self, path: String, model: String, var examples: List[Example], kind: String, stride: Int, device: String):
        self.path = path
        self.model = model
        self.examples = examples^
        self.kind = kind
        self.stride = stride
        self.device = device

    def run(mut self, ctl: JobCtl) raises -> LikeResult:
        var video = VideoSource(self.path)
        var det = VisionModel(self.model, DETECT, self.device)
        return find_like(video, det^, self.examples, self.kind, self.stride)


def find_like_job(path: String, model: String, examples: List[Example], kind: String, stride: Int = 5, device: String = "cuda") -> Job[LikeResult]:
    """mojoui.visionmodel.find_like over the video at `path` with the detection model `model`, loaded and run in a job."""
    return start_ui_job(FindLikeJob(path, model, examples.copy(), kind, stride, device))
