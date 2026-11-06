# Goal 55 review: the safety rules under omxconsole's downloads and deletes, offline. A token follows a redirect only on
# the same host over HTTPS (mojoui.http_flare.redirected); remove_tree never follows a symlink out (mojoui.files); a Hub
# file name can't land outside its folder (mojoui.hf.safe_name); Companion reports a closed port as down and finds the
# program's own folder (mojoui.companion). scripts/mojo_flare.sh build tests/test_safety.mojo -o build/test_safety
from std.os import makedirs, symlink
from std.os.path import exists, isdir
from mojoui.http import Request
from mojoui.http_flare import redirected
from mojoui.files import remove_tree
from mojoui.hf import safe_name
from mojoui.companion import answers, exe_dir, exe_path

comptime DIR = "build/g55/test_safety"


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def has_auth(r: Request) -> Bool:
    for n in r.names:
        if n.lower() == "authorization":
            return True
    return False


def main() raises:
    var req = Request.get(0, "https://huggingface.co/Qwen/x/resolve/abc/config.json").header("Authorization", "Bearer secret")
    # same host, relative forms: the token stays
    var r = redirected(req, "/api/resolve-cache/models/Qwen/x/abc/config.json?etag=1")
    check(r.url == "https://huggingface.co/api/resolve-cache/models/Qwen/x/abc/config.json?etag=1" and has_auth(r), "host-relative: " + r.url)
    r = redirected(req, "other.json")
    check(r.url == "https://huggingface.co/Qwen/x/resolve/abc/other.json" and has_auth(r), "path-relative: " + r.url)
    r = redirected(req, "https://huggingface.co/elsewhere")
    check(has_auth(r), "absolute, same host: the token stays")
    # another host, a scheme-relative one, and HTTPS down to HTTP: the token goes
    r = redirected(req, "https://us.aws.cdn.hf.co/xet-bridge/blob")
    check(r.url == "https://us.aws.cdn.hf.co/xet-bridge/blob" and not has_auth(r), "another host kept the token")
    r = redirected(req, "//cdn.example.com/file")
    check(r.url == "https://cdn.example.com/file" and not has_auth(r), "scheme-relative: " + r.url)
    r = redirected(req, "http://huggingface.co/plain")
    check(not has_auth(r), "https down to http kept the token")
    check(len(r.names) == 0, "only Authorization goes; other headers stay (there were none)")
    # remove_tree: everything under the folder goes, a symlink's target stays
    makedirs(DIR + "/outside", exist_ok=True)
    with open(DIR + "/outside/keep.txt", "w") as f:
        f.write("keep")
    makedirs(DIR + "/tree/sub", exist_ok=True)
    with open(DIR + "/tree/sub/a.txt", "w") as f:
        f.write("a")
    if not exists(DIR + "/tree/link"):
        symlink("../outside", DIR + "/tree/link")
    remove_tree(DIR + "/tree")
    check(not exists(DIR + "/tree") and exists(DIR + "/outside/keep.txt"), "remove_tree followed the symlink, or left the tree")
    remove_tree(DIR + "/no-such-folder")  # (missing: no error)
    remove_tree(DIR + "/outside")
    # Hub file names
    check(safe_name("config.json") and safe_name("onnx/model.onnx") and safe_name("additional_chat_templates/tool.jinja"), "plain names")
    check(not safe_name("../x") and not safe_name("a/../../x") and not safe_name("/etc/passwd") and not safe_name("a//b")
          and not safe_name("./a") and not safe_name("") and not safe_name("a\\b"), "an escaping name passed")
    # Companion
    check(not answers("http://127.0.0.1:9/health", 300), "a closed port answered")
    check(exe_path().endswith("/test_safety") and isdir(exe_dir()), "exe_dir: " + exe_path())
    print("safety: ok (redirect tokens, remove_tree and symlinks, Hub names, companion probes)")
