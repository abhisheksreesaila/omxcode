# mojoui.imagegen: a text-to-image model as a program the app supervises (goal 72 M6, D-7280): stable-diffusion.cpp's
# sd-server with Z-Image-Turbo, on a GPU of its own (the voice's, not the brain's), started and stopped with the app.
#
#   var server = ImageServer.zimage("sd-server", "models/card2", gpu="1", port=8190)   # (nothing runs yet)
#   server.start()                                  # the child process; returns at once
#   server.tick()                                   # from update(): health probes, never waits (STARTING -> READY / FAILED)
#   if server.ready():
#       http.send(server.draw_request(DREW, id, "a fox in a hat", seed=7, size=768))   # an HTTP request effect (mojoui.http)
#   # in update(), on DREW:  var png = png_of(e.text)    # the picture's bytes ([] when the server said no)
#   save_file("fox.png", png)
#
# The drawing itself is an ordinary request on a worker thread (mojoui.http: nothing on the UI thread waits for the
# picture); the server draws one at a time, so a caller sends the next after the last one's reply. The reply carries the
# PNG as base64 inside a JSON text; png_of() finds it without parsing a megabyte of JSON.
#
# Settings: where the program and its models are, which GPU (CUDA_VISIBLE_DEVICES of the child only: the parent keeps its own),
# the port; the app reads them from the environment and hands them over. Linux and macOS (mojoui.process).

from std.os import getenv
from std.os.path import exists
from mojoui.http import Request
from mojoui.json import json_string
from mojoui.process import Process, healthy, file_tail
from mojoui.clock import now_ns
from mojoui.text import base64_decode

comptime IMG_OFF = 0
comptime IMG_STARTING = 1
comptime IMG_READY = 2
comptime IMG_FAILED = 3


struct ImageServer(Movable):
    var binary: String
    var args: List[String]
    var gpu: String  # the child's CUDA_VISIBLE_DEVICES ("" leaves the parent's)
    var port: Int
    var log: String
    var proc: Optional[Process]
    var state: Int
    var why: String  # FAILED: what the log says
    var probed_ns: Int
    var started_ns: Int
    var ready_ms: Int  # start() to the first healthy answer

    def __init__(out self, binary: String, var args: List[String], gpu: String, port: Int, log: String = ""):
        self.binary = binary
        self.args = args^
        self.gpu = gpu
        self.port = port
        self.log = log if log != "" else getenv("TMPDIR", "/tmp") + "/mojoui-imagegen-" + String(port) + ".log"
        self.proc = None
        self.state = IMG_OFF
        self.why = ""
        self.probed_ns = 0
        self.started_ns = 0
        self.ready_ms = 0

    @staticmethod
    def zimage(binary: String, models: String, gpu: String, port: Int) -> ImageServer:
        """sd-server with Z-Image-Turbo (Q8 GGUF) + its Qwen3-4B text model + the FLUX VAE, from one models folder: 8 steps,
        guidance 1.0, flash attention. About 10.5 GB of the GPU; a 768 px picture in ~3.5 s on a 3090."""
        var args = List[String]()
        args.append(binary)
        args.append("--listen-ip")
        args.append("127.0.0.1")
        args.append("--listen-port")
        args.append(String(port))
        args.append("--model-dir")
        args.append(models)
        args.append("--diffusion-model")
        args.append(models + "/z_image_turbo-Q8_0.gguf")
        args.append("--vae")
        args.append(models + "/split_files/vae/ae.safetensors")
        args.append("--llm")
        args.append(models + "/Qwen3-4B-Instruct-2507-Q8_0.gguf")
        args.append("--cfg-scale")
        args.append("1.0")
        args.append("--steps")
        args.append("8")
        args.append("--diffusion-fa")
        return ImageServer(binary, args^, gpu, port)

    def installed(self) -> Bool:
        """The program and every file named in its arguments are there."""
        if not exists(self.binary):
            return False
        for a in self.args:
            if a.startswith("/") and not exists(a):
                return False
        return True

    def url(self) -> String:
        return "http://127.0.0.1:" + String(self.port)

    def start(mut self):
        """Starts the child (once); STARTING until tick() sees it healthy. A server that can't start says why (FAILED)."""
        if self.state == IMG_STARTING or self.state == IMG_READY:
            return
        if not self.installed():
            self.state = IMG_FAILED
            self.why = "the image model isn't installed (" + self.binary + ")"
            return
        try:
            var env = List[String]()
            if self.gpu != "":
                env.append("CUDA_VISIBLE_DEVICES=" + self.gpu)
            self.proc = Process.start(self.args, self.log, env)
            self.state = IMG_STARTING
            self.started_ns = now_ns()
            self.why = ""
        except e:
            self.state = IMG_FAILED
            self.why = String(e)

    def tick(mut self):
        """Looks at the child (at most every 400 ms): healthy -> READY; ended -> FAILED with the end of its log."""
        if self.state != IMG_STARTING and self.state != IMG_READY:
            return
        var now = now_ns()
        if now - self.probed_ns < 400_000_000:
            return
        self.probed_ns = now
        if not self.proc:
            return
        if not self.proc.value().running():
            self.state = IMG_FAILED
            self.why = "the image server stopped: " + self.proc.value().log_tail(300)
            return
        if self.state == IMG_STARTING and healthy(self.url() + "/sdapi/v1/options", 150):
            self.state = IMG_READY
            self.ready_ms = (now - self.started_ns) // 1_000_000

    def ready(self) -> Bool:
        return self.state == IMG_READY

    def stop(mut self):
        """Ends the child and its group (waits up to its grace: for the app closing, not for a frame)."""
        if self.proc:
            _ = self.proc.value().stop(3000)
            self.proc = None
        self.state = IMG_OFF

    def draw_request(self, msg: Int, id: Int, prompt: String, seed: Int, size: Int = 768) -> Request:
        """A request for one picture (size × size px), its reply to come back as `msg` tagged `id`; png_of() reads it."""
        var body = '{"prompt":' + json_string(prompt) + ',"steps":8,"cfg_scale":1.0,"width":' + String(size) + ',"height":' + String(size) + ',"seed":' + String(seed) + "}"
        return Request.post_json(msg, self.url() + "/sdapi/v1/txt2img", body).tagged(id).timeout(180_000)


def png_of(reply: String) -> List[UInt8]:
    """The picture inside a txt2img reply ({"images":["<base64 PNG>"],…}); empty when the reply holds none."""
    var key = reply.find('"images"')
    if key < 0:
        return List[UInt8]()
    var open = reply.find('"', reply.find("[", key) + 1)
    if open < 0:
        return List[UInt8]()
    var close = reply.find('"', open + 1)
    if close < 0:
        return List[UInt8]()
    var bytes = base64_decode(String(reply[byte = open + 1 : close]))
    # a PNG starts with its 8-byte signature: anything else is not a picture
    if len(bytes) < 8 or bytes[0] != 137 or bytes[1] != 80 or bytes[2] != 78 or bytes[3] != 71:
        return List[UInt8]()
    return bytes^


def save_file(path: String, bytes: List[UInt8]) raises:
    """Writes `bytes` to `path` (whole)."""
    var f = open(path, "w")
    f.write_bytes(Span(bytes))
    f.close()
