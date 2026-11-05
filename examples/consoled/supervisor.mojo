# consoled's supervisor: one `max serve` per loaded model, started on demand, unloaded when idle, as the Python daemon
# does it (mxconsole/supervisor.py): the same flags, a free port on 127.0.0.1, the GPU with the most room, the log in
# MXC_HOME/logs/<name>.log, ready when GET /health answers 200. Built on mojoui.process.

from std.os import getenv, makedirs
from std.os.path import exists, isdir, join, getsize
from std.os import listdir
from mojoui.process import Process, healthy, file_tail, output
from mojoui.clock import now_ns
from mojoui.json import json_string
from flare.tcp import TcpListener
from flare.net import SocketAddr

comptime DEFAULT_FRACTION = 0.35
comptime MAX_FRACTION = 0.9
comptime KV_HEADROOM = 4 * 1024 * 1024 * 1024
comptime MIN_FREE_GPU_MB = 4096
comptime LOG_TAIL_BYTES = 2000


@fieldwise_init
struct Gpu(Copyable, Movable):
    var index: Int
    var name: String
    var used_mb: Int
    var total_mb: Int
    var util: Int


def gpus() -> List[Gpu]:
    """nvidia-smi's GPUs (none when it isn't there)."""
    var out = List[Gpu]()
    var text = output(["nvidia-smi", "--query-gpu=index,name,memory.used,memory.total,utilization.gpu", "--format=csv,noheader,nounits"], 3000)
    for line in text.split("\n"):
        var f = String(line).split(",")
        if len(f) < 5:
            continue
        try:
            out.append(Gpu(atol(String(f[0]).strip()), String(String(f[1]).strip()), atol(String(f[2]).strip()), atol(String(f[3]).strip()), atol(String(f[4]).strip())))
        except:
            pass
    return out^


def gpus_json(list: List[Gpu]) -> String:
    var s = String("[")
    for i in range(len(list)):
        ref g = list[i]
        s += (", " if i > 0 else "") + '{"index": ' + String(g.index) + ', "name": ' + json_string(g.name) + ', "used_mb": ' + String(g.used_mb) + ', "total_mb": ' + String(g.total_mb) + ', "util": ' + String(g.util) + "}"
    return s + "]"


def weights_bytes(path: String) -> Int:
    """A snapshot's weight files (.safetensors, .bin, .gguf; links followed)."""
    var total = 0
    try:
        if not isdir(path):
            return 0
        for name in listdir(path):
            if name.endswith(".safetensors") or name.endswith(".bin") or name.endswith(".gguf"):
                total += getsize(join(path, name))
    except:
        pass
    return total


def memory_fraction(weights: Int, total_mb: Int) -> String:
    """supervisor.py memory_fraction: 0.35 of a GPU, or the weights + 4 GB headroom when that's more (≤ 0.9)."""
    if weights <= 0 or total_mb <= 0:
        return String(DEFAULT_FRACTION)
    var need = (Float64(weights) * 1.1 + Float64(KV_HEADROOM)) / (Float64(total_mb) * 1024 * 1024)
    if need <= DEFAULT_FRACTION:
        return String(DEFAULT_FRACTION)
    var r = Float64(Int(min(MAX_FRACTION, need) * 100 + 0.5)) / 100
    return String(r)


def free_port() raises -> Int:
    var l = TcpListener.bind(SocketAddr.localhost(0))
    var p = Int(l.local_addr().port)
    l.close()
    return p


@fieldwise_init
struct ModelRef(Copyable, Movable):
    var name: String
    var repo_id: String
    var revision: String
    var weights_path: String
    var custom_arch_path: String
    var keep_alive: Int


struct Child(Movable):
    var name: String
    var proc: Process
    var port: Int
    var gpu: Int
    var ready: Bool
    var started_ns: Int
    var ready_ns: Int
    var in_flight: Int
    var keep_alive: Int

    def __init__(out self, name: String, var proc: Process, port: Int, gpu: Int, keep_alive: Int):
        self.name = name
        self.proc = proc^
        self.port = port
        self.gpu = gpu
        self.ready = False
        self.started_ns = now_ns()
        self.ready_ns = 0
        self.in_flight = 0
        self.keep_alive = keep_alive

    def base(self) -> String:
        return "http://127.0.0.1:" + String(self.port)


struct Supervisor(Movable):
    var home: String
    var max_cmd: String
    var idle_override: Int
    var children: List[Child]
    var last_error: String

    def __init__(out self, home: String, max_cmd: String, idle_override: Int):
        self.home = home
        self.max_cmd = max_cmd
        self.idle_override = idle_override
        self.children = List[Child]()
        self.last_error = ""

    def log_path(self, name: String) -> String:
        try:
            makedirs(self.home + "/logs", exist_ok=True)
        except:
            pass
        return self.home + "/logs/" + name + ".log"

    def find(self, name: String) -> Int:
        for i in range(len(self.children)):
            if self.children[i].name == name:
                return i
        return -1

    def pick_gpu(self, list: List[Gpu]) -> Int:
        """The GPU with fewest of our models, then most free memory (one nearly full is skipped when another has room)."""
        if len(list) == 0:
            return -1
        var best = -1
        var best_key = Int.MAX
        var best_free = -1
        var any_roomy = False
        for g in list:
            if g.total_mb - g.used_mb >= MIN_FREE_GPU_MB:
                any_roomy = True
        for g in list:
            var free = g.total_mb - g.used_mb
            if any_roomy and free < MIN_FREE_GPU_MB:
                continue
            var ours = 0
            for k in range(len(self.children)):
                if self.children[k].gpu == g.index:
                    ours += 1
            if ours < best_key or (ours == best_key and free > best_free):
                best = g.index
                best_key = ours
                best_free = free
        return best

    def command(self, m: ModelRef, port: Int, gpu: Int, total_mb: Int) -> List[String]:
        var cmd = List[String]()
        for part in self.max_cmd.split(" "):
            var w = String(part)
            if w != "":
                cmd.append(w)
        cmd += ["serve", "--port", String(port), "--served-model-name", m.name]
        if getenv("MXC_GRAPH_CAPTURE") != "1":
            cmd.append("--no-device-graph-capture")
        if gpu >= 0:
            cmd += ["--devices", "gpu:" + String(gpu)]
        var frac = getenv("MXC_GPU_MEMORY_FRACTION")
        cmd += ["--device-memory-utilization", frac if frac != "" else memory_fraction(weights_bytes(m.weights_path), total_mb)]
        if m.custom_arch_path != "":
            cmd += ["--custom-architectures", m.custom_arch_path]
        if m.weights_path != "" and isdir(m.weights_path):
            cmd += ["--model-path", m.weights_path]
        else:
            cmd += ["--model-path", m.repo_id]
            if m.revision != "":
                cmd += ["--huggingface-model-revision", m.revision]
        return cmd^

    def child_env(self) -> List[String]:
        """MAX_SERVE_HOST, and the environment of the install `max` runs from: when MXC_MAX is <env>/bin/max, that env is
        CONDA_PREFIX and its bin comes first on PATH; this process's own pixi/conda variables never leak into it (MAX
        finds its kernels through them: another env's MAX fails with "failed to resolve built-in kernel package paths")."""
        var env: List[String] = ["MAX_SERVE_HOST=127.0.0.1", "CONDA_DEFAULT_ENV=", "CONDA_SHLVL=", "PIXI_PROJECT_ROOT=", "PIXI_PROJECT_MANIFEST=",
                                 "PIXI_ENVIRONMENT_NAME=", "PIXI_IN_SHELL=", "PIXI_PROJECT_NAME="]
        var first = String(self.max_cmd.split(" ")[0])
        var at = first.find("/bin/max")
        if at > 0 and first.endswith("/bin/max"):
            var prefix = String(first[byte = : at])
            env.append("CONDA_PREFIX=" + prefix)
            if exists(prefix + "/share/max"):
                env.append("MODULAR_HOME=" + prefix + "/share/max")  # (what that env's activation sets; MAX's kernels)
            env.append("PATH=" + prefix + "/bin:" + getenv("PATH"))
        else:
            env.append("CONDA_PREFIX=")
        return env^

    def ensure(mut self, m: ModelRef) raises -> Int:
        """The model's child (started when it isn't running): its index. Doesn't wait for it to be ready."""
        var i = self.find(m.name)
        if i >= 0:
            if self.children[i].proc.running():
                self.children[i].proc.touch()
                return i
            _ = self.children.pop(i)
        var list = gpus()
        var gpu = self.pick_gpu(list)
        var total = 0
        for g in list:
            if g.index == gpu:
                total = g.total_mb
        var port = free_port()
        var keep = self.idle_override if self.idle_override > 0 else m.keep_alive
        var p = Process.start(self.command(m, port, gpu, total), self.log_path(m.name), self.child_env())
        self.children.append(Child(m.name, p^, port, gpu, keep))
        return len(self.children) - 1

    def check_ready(mut self, i: Int) -> Bool:
        """Ready yet? (One quick /health probe while starting.)"""
        if self.children[i].ready:
            return True
        if healthy(self.children[i].base() + "/health", 300):
            self.children[i].ready = True
            self.children[i].ready_ns = now_ns()
        return self.children[i].ready

    def stop(mut self, name: String) -> Bool:
        var i = self.find(name)
        if i < 0:
            return False
        _ = self.children[i].proc.stop(10_000)
        _ = self.children.pop(i)
        return True

    def sweep(mut self):
        """Forget children that ended; unload ready ones idle past their keep_alive (none in flight)."""
        var i = 0
        while i < len(self.children):
            if not self.children[i].ready and self.children[i].proc.running():
                _ = self.check_ready(i)  # (a start finishes between requests too)
            ref c = self.children[i]
            if not c.proc.running():
                self.last_error = c.name + " exited (" + String(c.proc.code) + "): " + file_tail(c.proc.log, LOG_TAIL_BYTES)
                _ = self.children.pop(i)
                continue
            if c.ready and c.in_flight == 0 and c.keep_alive > 0 and c.proc.idle_ms() > c.keep_alive * 1000:
                _ = c.proc.stop(10_000)
                _ = self.children.pop(i)
                continue
            i += 1

    def state(mut self, name: String) -> String:
        var i = self.find(name)
        if i < 0:
            return "cold"
        return "ready" if self.check_ready(i) else "starting"
