# mojoui.fleetjobs: opening a folder of bags off the UI thread (goal 68 M4): mojoui.fleet reads every bag and writes
# the fleet (runs, moments, stops, story.json) into <folder>/fleet; every camera topic becomes a video there
# (mojoui.bag.camera_video: JPEGs into an AVI, H.264 into an MP4, nothing re-encoded). Progress: a step a bag, then a
# step a camera.
#
#   var job = fleet_job("~/bags")            # Job[FleetOpened]; poll it each frame
#   var f = job.result(); f.out (the story's folder), f.cameras (run, topic, path, first_s), f.problems

from omxcore import Job, JobBody, JobCtl
from mojoui.uijobs import start_ui_job
from mojoui.fleet import read_fleet
from mojoui.bag import Bag, camera_video
from mojoui.clock import now_ns
from std.os import makedirs
from std.os.path import exists


@fieldwise_init
struct FleetCamera(Copyable, Movable):
    var run: String
    var topic: String
    var path: String  # the video
    var first_s: Float64  # its first picture's time on the bag's clock (seconds): a time link's offset


struct FleetOpened(Movable):
    var out: String
    var runs: Int
    var hero: String
    var cameras: List[FleetCamera]
    var problems: List[String]
    var ms: Float64

    def __init__(out self, out_dir: String):
        self.out = out_dir
        self.runs = 0
        self.hero = ""
        self.cameras = List[FleetCamera]()
        self.problems = List[String]()
        self.ms = 0.0


def camera_file(run: String, topic: String) -> String:
    """A camera's video file name: run__topic (slashes as _)."""
    return run + "__" + String(topic.lstrip("/")).replace("/", "_")


struct FleetJob(JobBody):
    comptime Out = FleetOpened
    var folder: String

    def __init__(out self, var folder: String):
        self.folder = folder^

    def run(mut self, ctl: JobCtl) raises -> FleetOpened:
        var t0 = now_ns()
        var f = read_fleet(self.folder, ctl)
        var out = FleetOpened(f.folder + "/fleet")
        out.runs = len(f.runs)
        out.hero = f.hero()
        out.problems = f.problems.copy()
        var vids = out.out + "/videos"
        makedirs(vids, exist_ok=True)
        var n = 0
        for r in f.runs:
            n += len(r.cameras)
        ctl.add_total(n)
        for r in f.runs:
            if len(r.cameras) == 0:
                continue
            var bag = Bag.open(r.path)
            for topic in r.cameras:
                ctl.check()
                try:
                    var k = bag.find(topic)
                    if bag.topics[k].count > 0:  # (camera_video names it .avi (JPEGs) or .mp4 (H.264) by what it holds)
                        var v = camera_video(bag, k, vids + "/" + camera_file(r.name, topic) + ".avi")
                        out.cameras.append(FleetCamera(r.name, topic, v.path, Float64(v.times_ns[0]) / 1e9))
                except e:
                    out.problems.append(r.name + " " + topic + ": " + String(e))
                ctl.advance(1)
        var videos = List[String]()
        var firsts = List[Float64]()
        for c in out.cameras:
            if c.run == out.hero:
                videos.append("videos/" + String(c.path[byte = c.path.rfind("/") + 1 :]))
                firsts.append(c.first_s)
        f.write(out.out, videos, firsts)
        out.ms = Float64(now_ns() - t0) / 1e6
        return out^


def fleet_job(folder: String) -> Job[FleetOpened]:
    return start_ui_job(FleetJob(folder))
