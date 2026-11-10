# Run in Jupyter (the Python daemon's jupyter.py, in Mojo; D-6501): POST /admin/learn/{name}/open writes the model's
# notebook to MXC_HOME/notebooks/<name>.ipynb if it isn't there yet and starts one Jupyter Lab on that folder (127.0.0.1,
# a random token), which later opens reuse while it runs. The console shows Jupyter's single-notebook view.
#
# Jupyter isn't ours to bundle. It is found as $MXC_JUPYTER, else `jupyter` on PATH, else run through `pixi exec` (a
# throwaway environment with jupyterlab, openai and httpx: the notebook's cells need the last two). The first pixi start
# downloads, so the open's reply waits on a server worker and tick answers it once Jupyter answers (the load pattern).
# Unlike jupyter.py's detached server, this one is the daemon's child: it stops when the daemon stops, as Caddy does
# (D-6409), so no notebook server outlives the app that opened it.
#
# The kernels get MXC_BASE_URL and MXC_API_KEY (the daemon's in-memory "_notebook" key, never stored), so the "Try it"
# cells run against this daemon; MXC_ADMIN_KEY is removed from Jupyter's environment.

from std.os import getenv, makedirs
from mojoui.serve import Pipe
from mojoui.process import Process, file_tail, healthy
from mojoui.clock import now_ns
from mojoui.http import uri_component
from mojoui.json import json_string
from mojoui import libc
from flare.crypto.random import random_bytes
from flare.crypto.hmac import base64url_encode
from sandbox import which
from supervisor import free_port

comptime JUPYTER_WAIT_MS = 240_000  # (a first `pixi exec` downloads jupyterlab: about a minute here, slower lines longer)
comptime NO_JUPYTER = ("Jupyter was not found, and neither was pixi to run it without installing. Install JupyterLab "
                       + "(`pixi global install jupyterlab`, or `pip install jupyterlab openai httpx`), or set MXC_JUPYTER "
                       + "to your jupyter command, then try again.")


def frame_ancestors(console_port: Int) -> String:
    """jupyter.py's frame_ancestors: the console's own origins may frame it, nothing else (Jupyter refuses all framing
    by default, and the web console shows it in an iframe)."""
    var p = String(console_port)
    return "frame-ancestors 'self' http://127.0.0.1:" + p + " http://localhost:" + p


def jupyter_argv(root: String, port: Int, console_port: Int) -> List[String]:
    """The command that serves `root` on `port`, or an empty list when there is no way to run Jupyter."""
    var lab: List[String] = ["lab", "--no-browser", "--ServerApp.ip=127.0.0.1", "--ServerApp.port=" + String(port),
                             "--ServerApp.port_retries=0", "--ServerApp.root_dir=" + root,
                             '--ServerApp.tornado_settings={"headers": {"Content-Security-Policy": "' + frame_ancestors(console_port) + '"}}']
    var asked = getenv("MXC_JUPYTER")
    var out = List[String]()
    if asked != "":
        out.append(asked)
    elif which("jupyter") != "":
        out.append("jupyter")
    elif which("pixi") != "":
        out += ["pixi", "exec", "--spec", "jupyterlab", "--spec", "openai", "--spec", "httpx", "jupyter"]
    else:
        return out^
    out += lab^
    return out^


@fieldwise_init
struct Opening(Copyable, Movable):
    """A POST …/open still waiting for Jupyter to answer: tick answers it."""
    var pipe: Int
    var notebook: String  # the file's name in the notebooks folder


struct Jupyter(Movable):
    var child: List[Process]  # at most one
    var dying: List[Process]  # stopped by a tick: SIGTERM sent, reaped by later ticks (never a wait under the lock)
    var port: Int
    var token: String
    var root: String
    var since_ns: Int
    var ready: Bool
    var waiting: List[Opening]

    def __init__(out self):
        self.child = List[Process]()
        self.dying = List[Process]()
        self.port = 0
        self.token = ""
        self.root = ""
        self.since_ns = 0
        self.ready = False
        self.waiting = List[Opening]()

    def running(mut self) -> Bool:
        return len(self.child) > 0 and self.child[0].running()

    def url(self, notebook: String) -> String:
        return "http://127.0.0.1:" + String(self.port) + "/lab/tree/" + uri_component(notebook) + "?token=" + self.token

    def reply(self, notebook: String, path: String) -> String:
        """jupyter.py's answer: the lab view for the browser, the single-notebook view for the console's frame."""
        var url = self.url(notebook)
        var embed = url.replace("/lab/tree/", "/doc/tree/")
        return '{"url": ' + json_string(url) + ', "embed_url": ' + json_string(embed) + ', "path": ' + json_string(path) + "}"

    def start(mut self, root: String, home: String, console_port: Int, api_key: String) raises -> String:
        """Start Jupyter on `root` unless it already serves it. Returns "" when it is starting (or up), else why not."""
        if self.running() and self.root == root:
            return ""
        self.stop()
        var port = free_port()
        var argv = jupyter_argv(root, port, console_port)
        if len(argv) == 0:
            return NO_JUPYTER
        makedirs(home + "/run", exist_ok=True)
        var token = String(base64url_encode(random_bytes(24)).rstrip("="))
        var env: List[String] = ["JUPYTER_TOKEN=" + token, "MXC_BASE_URL=http://127.0.0.1:" + String(console_port) + "/v1",
                                 "MXC_API_KEY=" + api_key, "MXC_ADMIN_KEY=", "PIXI_PROJECT_ROOT=", "PIXI_PROJECT_MANIFEST=",
                                 "PIXI_ENVIRONMENT_NAME=", "PIXI_IN_SHELL=", "PIXI_PROJECT_NAME="]
        var log = home + "/run/jupyter.log"
        with open(log, "w") as f:  # (a fresh log per start; Jupyter prints its link with the token: the owner's only)
            f.write("")
        _ = libc.chmod(log, 0o600)
        var p = Process.start(argv, log, env, root)
        self.child.append(p^)
        self.port = port
        self.token = token
        self.root = root
        self.since_ns = Int(now_ns())
        self.ready = False
        return ""

    def wait(mut self, notebook: String) -> Pipe:
        var pipe = Pipe()
        self.waiting.append(Opening(pipe.share().addr, notebook))
        return pipe^

    def check(mut self) -> Bool:
        if not self.ready and self.running():
            self.ready = healthy("http://127.0.0.1:" + String(self.port) + "/api", 500)
        return self.ready

    def answer(mut self):
        """Every tick: the waiting opens once Jupyter answers (200), exits (503, with its log's end) or is too slow."""
        var i = 0
        while i < len(self.dying):
            if self.dying[i].finish_stop(5000):
                _ = self.dying.pop(i)
            else:
                i += 1
        if len(self.waiting) == 0:
            return
        var up = self.check()
        var gone = not self.running()
        var late = Int(now_ns()) - self.since_ns > JUPYTER_WAIT_MS * 1_000_000
        if not (up or gone or late):
            return
        self.settle(up, "")

    def shutdown(mut self):
        self.settle(False, "consoled is stopping, so Jupyter was not started.")
        self.stop()

    def settle(mut self, up: Bool, reason: String):
        """Answer every waiting open: Jupyter's links, or why not (`reason`, else what its exit or its log says)."""
        var why = reason
        if not up and why == "":
            var gone = not self.running()
            var log = self.child[0].log if len(self.child) > 0 else String("jupyter.log")
            why = ("Jupyter exited while starting" if gone else "Jupyter did not answer within " + String(JUPYTER_WAIT_MS // 1000) + " s")
            var tail = String(file_tail(log, 600).strip())
            if self.token != "":
                tail = tail.replace(self.token, "…")  # (Jupyter's own lines show its link with the token)
            why += ". Last log lines (" + log + "):\n" + tail
            if len(self.child) > 0:
                self.child[0].begin_stop()
                self.dying.append(self.child.pop(0))
            self.ready = False
        for k in range(len(self.waiting)):
            var pipe = Pipe.at(self.waiting[k].pipe)
            if not pipe.gone():
                if up:
                    pipe.set_head(200, "application/json")
                    pipe.write(self.reply(self.waiting[k].notebook, self.root + "/" + self.waiting[k].notebook))
                else:
                    pipe.set_head(503, "application/json")
                    pipe.write('{"error": {"message": ' + json_string(why) + ', "type": "server_error", "param": null, "code": "jupyter_failed"}}')
            pipe.close()
            pipe.release()
        self.waiting = List[Opening]()

    def stop(mut self):
        if len(self.child) > 0:
            self.dying.append(self.child.pop(0))
        for k in range(len(self.dying)):
            _ = self.dying[k].stop(5000)
        self.dying = List[Process]()
        self.ready = False
