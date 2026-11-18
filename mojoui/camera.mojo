# mojoui.camera: a camera an app can look through (goal 77 M6, D-7765..D-7769). The same calls on every host that has one:
#
#   var cam = Camera()
#   cam.start()                    # the camera is wanted: a browser page opens its rear camera (the first time the browser asks
#                                  # the person); on a desktop the camera starts
#   cam.snapshot()                 # a fresh still, asked for now; returns at once
#   # from update(), on a tick:  if cam.tick(): cam.jpeg, cam.width, cam.height, cam.seq   (a new frame has landed)
#   cam.stop()                     # the camera is let go (the page closes it; its light goes out)
#
# Which camera: when the app runs on the web host (mojoui.webcamera has a hub) the browser's: the page captures a JPEG only
# when snapshot() asks, over the audio socket's tag 3 (one still, not a stream; docs/web-audio.md). Anywhere else a camera of
# this machine: ffmpeg reads Video4Linux ($MOJOUI_CAMERA, default /dev/video0; $MOJOUI_CAMERA_SIZE, default 1280x720) at 5
# frames a second into one file that is replaced atomically, and the Camera takes the newest frame that appeared after
# snapshot(). The first 1.3 seconds after the start are skipped (auto exposure). Linux; Mac/iPhone/Android: not built. Frames stay
# in this process's memory and, for a desktop camera, one file in the user's runtime folder that is deleted at stop(): they are
# never sent anywhere (the model that looks at one is in the same process).
#
# problem says why there is no frame (no camera, refused, an ended ffmpeg); state() is CAM_OFF, CAM_STARTING, CAM_READY (has
# delivered a frame) or CAM_FAILED.

from std.os import getenv, remove, makedirs
from std.os.path import exists
from mojoui.process import Process
from mojoui.clock import now_ns
from mojoui.watch import file_stamp
from mojoui.grounding import image_size
from mojoui.webcamera import camera_hub, camera_want, camera_snap, camera_got, camera_error, camera_take, camera_arrived_ns

comptime CAM_OFF = 0
comptime CAM_STARTING = 1
comptime CAM_READY = 2
comptime CAM_FAILED = 3
comptime WARMUP_MS = 1300  # a desktop camera's first frames are dark while it settles


struct Camera(Movable):
    var jpeg: List[UInt8]  # the newest frame (a JPEG)
    var width: Int
    var height: Int
    var seq: Int  # counts frames taken (tick() returned True)
    var arrived_ns: Int  # when the newest frame arrived
    var problem: String
    var wanted: Bool
    var asked: Int  # the web request's id, until its frame lands
    var asked_ns: Int
    var proc: Optional[Process]
    var path: String
    var started_ns: Int
    var since: Int  # a desktop frame counts when its file was written after this (the request's moment, by the file's own clock)
    var web: Bool

    def __init__(out self):
        self.jpeg = List[UInt8]()
        self.width = 0
        self.height = 0
        self.seq = 0
        self.arrived_ns = 0
        self.problem = String("")
        self.wanted = False
        self.asked = 0
        self.asked_ns = 0
        self.proc = None
        self.path = String("")
        self.started_ns = 0
        self.since = 0
        self.web = camera_hub() != 0

    def source(self) -> String:
        return "browser" if self.web else "desktop"

    def state(self) -> Int:
        if not self.wanted:
            return CAM_OFF
        if self.problem != "":
            return CAM_FAILED
        return CAM_READY if self.seq > 0 else CAM_STARTING

    def start(mut self):
        """The camera is wanted. On a desktop it starts now (a missing camera is the problem, not an error); in a page it opens
        when the page next looks (a moment)."""
        if self.wanted:
            return
        self.wanted = True
        self.problem = ""
        self.started_ns = now_ns()
        if self.web:
            camera_want(True)
            return
        var dev = getenv("MOJOUI_CAMERA", "/dev/video0")
        if not exists(dev):
            self.problem = "no camera found (" + dev + ")"
            return
        var dir = getenv("XDG_RUNTIME_DIR", getenv("TMPDIR", "/tmp")) + "/mojoui-camera-" + String(Int(now_ns() // 1000) % 1_000_000_000)
        try:
            makedirs(dir, exist_ok=True)
            self.path = dir + "/frame.jpg"
            var argv = List[String]()
            argv.append("ffmpeg")
            argv.append("-loglevel")
            argv.append("error")
            argv.append("-f")
            argv.append("v4l2")
            argv.append("-video_size")
            argv.append(getenv("MOJOUI_CAMERA_SIZE", "1280x720"))
            argv.append("-i")
            argv.append(dev)
            argv.append("-vf")
            argv.append("fps=5")
            argv.append("-q:v")
            argv.append("4")
            argv.append("-f")
            argv.append("image2")
            argv.append("-update")
            argv.append("1")
            argv.append("-atomic_writing")
            argv.append("1")
            argv.append("-y")
            argv.append(self.path)
            self.proc = Process.start(argv, dir + "/ffmpeg.log")
        except e:
            self.problem = "the camera couldn't start: " + String(e)

    def stop(mut self):
        """The camera is let go: the page closes it, ffmpeg ends, its file is deleted."""
        if not self.wanted:
            return
        self.wanted = False
        if self.web:
            camera_want(False)
            return
        if self.proc:
            _ = self.proc.value().stop(1500)
            self.proc = None
        if self.path != "" and exists(self.path):
            try:
                remove(self.path)
            except:
                pass

    def snapshot(mut self):
        """Asks for a fresh still (starts the camera if it isn't). Returns at once: tick() says when it has landed."""
        if not self.wanted:
            self.start()
        self.asked_ns = now_ns()
        if self.web:
            self.asked = camera_snap()
        elif self.path != "":
            self.since = file_stamp(self.path)[0]

    def waiting(self) -> Bool:
        """A snapshot was asked for and hasn't landed."""
        return self.asked_ns > 0 and (self.arrived_ns < self.asked_ns) and self.problem == ""

    def tick(mut self) -> Bool:
        """Takes a landed frame: True when `jpeg` is a new one. Call it from the app's tick while a snapshot is waited for."""
        if not self.wanted or self.problem != "":
            return False
        if self.web:
            var err = camera_error()
            if err != 0 and camera_got() < self.asked:
                self.problem = "the browser's camera isn't available" + (" (refused)" if err == 101 else (" (none found)" if err == 102 else " (this page may not use it)"))
                return False
            if self.asked == 0 or camera_got() < self.asked:
                return False
            var got = camera_take(self.jpeg)
            if got[0] == 0:
                return False
            self.width = got[1]
            self.height = got[2]
            self.arrived_ns = camera_arrived_ns()
            self.asked = 0
            self.seq += 1
            return True
        if self.proc and not self.proc.value().running():
            self.problem = "the camera stopped: " + self.proc.value().log_tail(300)
            return False
        if self.asked_ns == 0 or now_ns() - self.started_ns < WARMUP_MS * 1_000_000:
            return False
        var st = file_stamp(self.path)
        if st[1] < 1000 or st[0] <= self.since:  # (no frame yet, or none written after the request)
            return False
        try:
            var f = open(self.path, "r")
            var bytes = f.read_bytes()
            f.close()
            var size = image_size(bytes)
            if size[0] <= 0:
                return False
            self.since = st[0]
            self.width = size[0]
            self.height = size[1]
            self.jpeg = bytes^
            self.arrived_ns = now_ns()
            self.seq += 1
            return True
        except:
            return False
