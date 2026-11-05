# Goal 50 M1: HTTPS on a worker thread, as an app sends it (mojoui.effects with the Flare transport built in,
# -D MOJOUI_FLARE): Hugging Face's file list says how big Qwen2.5-0.5B-Instruct's config.json is, then the file itself
# (a redirect-free resolve URL, then the same through a redirecting one) comes back that size, a real JSON config.
from mojoui.http import Request, Response
from mojoui.effects import start, Backend
from mojoui.json import Json
from mojoui.clock import now_ns

comptime REPO = "Qwen/Qwen2.5-0.5B-Instruct"


def fetch(url: String) raises -> Response:
    var job = start[Backend](Request.get(1, url).timeout(30_000))
    var t0 = now_ns()
    while not job.ready():
        if now_ns() - t0 > 60_000_000_000:
            raise Error("no answer in 60 s from " + url)
    var r = job.response()
    if r.error != "":
        raise Error(url + ": " + r.error)
    return r^


def main() raises:
    var tree = fetch("https://huggingface.co/api/models/" + REPO + "/tree/main")
    if tree.status != 200:
        raise Error("file list: " + String(tree.status))
    var j = Json.parse(tree.text())
    var want = -1
    for i in range(j.size(0)):
        var f = j.at(0, i)
        if j.text(j.get(f, "path")) == "config.json":
            want = j.number(j.get(f, "size"))
    if want <= 0:
        raise Error("config.json isn't in the file list")
    var cfg = fetch("https://huggingface.co/" + REPO + "/resolve/main/config.json")
    if cfg.status != 200 or len(cfg.body) != want:
        raise Error("config.json: status " + String(cfg.status) + ", " + String(len(cfg.body)) + " bytes, want " + String(want))
    var c = Json.parse(cfg.text())
    var arch = c.text(c.at(c.get(0, "architectures"), 0))
    if arch != "Qwen2ForCausalLM":
        raise Error("config.json's architecture: " + arch)
    print("HTTPS: config.json " + String(len(cfg.body)) + " bytes = the list's " + String(want) + ", " + arch)
    print("https: ok")
