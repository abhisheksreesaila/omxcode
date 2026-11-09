# mojoui.hf: the Hugging Face Hub for any app (goal 55: omxconsole finds and downloads models; any app that ships
# models can too). Search models, read a repo's files (sizes, LFS sha256, the revision's commit), download files with
# progress, resume and cancel. Public repos need no token; HF_TOKEN, when set, is sent (gated or private repos).
# HTTPS through Flare (mojoui.http_flare): build with scripts/mojo_flare.sh.
#
#   var found = hub_search("qwen2.5 instruct", limit=10)       # newest-popular first, with parameter counts and sizes
#   var repo = hub_repo("Qwen/Qwen2.5-0.5B-Instruct")           # files, sizes, sha256, the commit `main` points at
#   var t = Transfer()
#   var r = hub_download(repo, repo.files[0], "/tmp/qwen", t)   # t.done() / t.total() from any thread; t.cancel()

from std.os import makedirs, getenv
from mojoui.http import Request, Response, uri_component
from mojoui.http_flare import FlareTransport, Transfer, fetch_to_file
from mojoui.json import Json, J_STRING

comptime HUB = "https://huggingface.co"
comptime HUB_TIMEOUT_MS = 30_000


def hub_base() -> String:
    """The Hub, or the stand-in a check puts in its place (MOJOUI_HF_BASE; goal 64's fake-port harness, as the
    Python version injected its own hub in tests). Only a check sets it: whoever can set this process's
    environment can already do anything it can."""
    return getenv("MOJOUI_HF_BASE", HUB)


@fieldwise_init
struct HubModel(Copyable, Movable):
    var id: String
    var task: String  # pipeline_tag ("text-generation", "feature-extraction"…; "" when the Hub has none)
    var downloads: Int
    var likes: Int
    var params: Int  # from its safetensors index (0: not known)
    var bytes: Int  # its weights' size from the same index, by dtype (0: not known)
    var gated: Bool


@fieldwise_init
struct HubFile(Copyable, Movable):
    var name: String  # its path in the repo ("config.json", "onnx/model.onnx")
    var size: Int
    var sha256: String  # LFS files' sha256 ("" for small files kept in git)


@fieldwise_init
struct HubRepo(Copyable, Movable):
    var id: String
    var sha: String  # the commit the revision pointed at when read: downloads use it, so a push mid-pull can't mix files
    var gated: Bool
    var files: List[HubFile]

    def bytes(self) -> Int:
        var n = 0
        for f in self.files:
            n += f.size
        return n


def _get(path: String) raises -> Json:
    var r = FlareTransport.send(_auth(Request.get(0, hub_base() + path).timeout(HUB_TIMEOUT_MS)))
    if r.error != "":
        raise Error("Hugging Face: " + r.error)
    if r.status == 401 or r.status == 403:
        raise Error("Hugging Face: " + hub_base() + path + " needs access (a gated or private repo: accept its terms on the Hub, set HF_TOKEN)")
    if r.status == 404:
        raise Error("Hugging Face: no such repo or revision (" + path + ")")
    if r.status != 200:
        raise Error("Hugging Face: " + String(r.status) + " for " + path)
    return Json.parse(r.text())


def _auth(var req: Request) -> Request:
    """HF_TOKEN as a bearer token, when set."""
    var token = getenv("HF_TOKEN")
    if token == "":
        return req^
    return req^.header("Authorization", "Bearer " + token)


def _gated(j: Json, node: Int) -> Bool:
    """The Hub's gated: false, or "auto" / "manual" (a form to accept)."""
    return node >= 0 and (j.kind(node) == J_STRING or j.flag(node))


def _path(s: String) -> String:
    """A repo id or file path for a URL: each part encoded, the slashes kept."""
    var out = String("")
    var parts = s.split("/")
    for i in range(len(parts)):
        out += ("/" if i > 0 else "") + uri_component(String(parts[i]))
    return out^


def dtype_bytes(dtype: String) -> Int:
    """Bytes per parameter of a safetensors dtype (F32 4, BF16 2, I8 1…; 2 when unknown)."""
    var d = dtype.upper()
    if d == "F64" or d == "I64" or d == "U64":
        return 8
    if d == "F32" or d == "I32" or d == "U32":
        return 4
    if d.startswith("F8") or d == "I8" or d == "U8" or d == "BOOL":
        return 1
    return 2


def hub_search(query: String, limit: Int = 20, task: String = "text-generation") raises -> List[HubModel]:
    """Models whose name matches `query`, most downloaded first; `task` filters by pipeline tag ("": any)."""
    var path = "/api/models?search=" + uri_component(query) + "&limit=" + String(limit) + "&sort=downloads&direction=-1"
    if task != "":
        path += "&filter=" + uri_component(task)
    for e in ["safetensors", "downloads", "likes", "pipeline_tag", "gated"]:
        path += "&" + uri_component("expand[]") + "=" + e
    var j = _get(path)
    var out = List[HubModel]()
    for i in range(j.size(0)):
        var m = j.at(0, i)
        var params = 0
        var bytes = 0
        var st = j.get(m, "safetensors")
        if st >= 0:
            params = j.number(j.get(st, "total"))
            var by = j.get(st, "parameters")
            if by >= 0:
                for k in range(j.size(by)):
                    var n = j.at(by, k)
                    bytes += j.number(n) * dtype_bytes(j.key(by, k))
        var gated = j.get(m, "gated")
        out.append(HubModel(j.text(j.get(m, "id")), j.text(j.get(m, "pipeline_tag")), j.number(j.get(m, "downloads")),
                            j.number(j.get(m, "likes")), params, bytes, _gated(j, gated)))
    return out^


def hub_repo(repo: String, revision: String = "main") raises -> HubRepo:
    """`repo`'s files at `revision` with their sizes and LFS sha256, and the commit the revision points at."""
    var j = _get("/api/models/" + _path(repo) + "/revision/" + uri_component(revision) + "?blobs=true")
    var files = List[HubFile]()
    var sib = j.get(0, "siblings")
    if sib >= 0:
        for i in range(j.size(sib)):
            var f = j.at(sib, i)
            var lfs = j.get(f, "lfs")
            files.append(HubFile(j.text(j.get(f, "rfilename")), j.number(j.get(f, "size")), j.text(j.get(lfs, "sha256")) if lfs >= 0 else String("")))
    var gated = j.get(0, "gated")
    return HubRepo(j.text(j.get(0, "id"), repo), j.text(j.get(0, "sha")), _gated(j, gated), files^)


comptime HUB_HOSTS = ["huggingface.co", "www.huggingface.co"]
# First path parts on huggingface.co that are not a model's owner (a dataset, a Space, the site's own pages).
comptime NOT_OWNERS = ["datasets", "spaces", "models", "docs", "api", "collections", "papers", "blog", "organizations",
                       "settings", "login", "join", "new", "tasks", "learn", "posts", "pricing", "enterprise", "chat"]


def hub_ref(text: String) -> String:
    """A model reference as someone pasted it. A Hub model URL (https://huggingface.co/owner/name, http://, no scheme,
    www.; a trailing /, /tree/<rev>, /blob/…, ?query and #fragment are ignored) becomes "owner/name"; text that isn't
    a URL comes back stripped and otherwise unchanged (a curated name, owner/name). "" for a URL that names no model
    on the Hub: another host, a user or port in it, a dataset or Space, no owner/name. The caller still checks the
    characters of what comes back."""
    var s = String(text.strip())
    var low = s.lower()
    var rest: String
    if low.startswith("https://"):
        rest = String(s[byte = 8 :])
    elif low.startswith("http://"):
        rest = String(s[byte = 7 :])
    elif low.find("://") >= 0:
        return ""
    else:
        var looks_hosted = False
        for h in materialize[HUB_HOSTS]():
            if low.startswith(String(h) + "/") or low == String(h):
                looks_hosted = True
        if not looks_hosted:
            return s
        rest = s
    for mark in ["#", "?"]:
        var at = rest.find(String(mark))
        if at >= 0:
            var cut = String(rest[byte = : at])
            rest = cut
    var slash = rest.find("/")
    var host = (String(rest[byte = : slash]) if slash >= 0 else rest).lower()
    var known = False
    for h in materialize[HUB_HOSTS]():
        if host == String(h):
            known = True
    if not known or slash < 0:
        return ""
    var parts = String(rest[byte = slash + 1 :]).split("/")
    if len(parts) < 2:
        return ""
    var owner = String(parts[0])
    var name = String(parts[1])
    if owner == "" or name == "":
        return ""
    for n in materialize[NOT_OWNERS]():
        if owner.lower() == String(n):
            return ""
    return owner + "/" + name


def safe_name(name: String) -> Bool:
    """A repo file's path that stays inside the folder it's downloaded to: relative, no "." or ".." parts, no empty ones."""
    if name == "" or name.startswith("/") or name.find("\\") >= 0:
        return False
    for part in name.split("/"):
        if String(part) == "" or String(part) == "." or String(part) == "..":
            return False
    return True


def hub_file_url(repo: HubRepo, file: HubFile) -> String:
    return hub_base() + "/" + _path(repo.id) + "/resolve/" + repo.sha + "/" + _path(file.name)


def hub_download(repo: HubRepo, file: HubFile, folder: String, t: Transfer, timeout_ms: Int = 60_000, tries: Int = 6) -> Response:
    """`file` of `repo` (at the commit read) into `folder`/<its path>, on the calling thread (fetch_to_file: a part
    resumes, a cancel keeps it, a dropped connection is picked up again up to `tries` - 1 times)."""
    if not safe_name(file.name):
        return Response.failed("refusing the file name " + file.name + " (it would land outside " + folder + ")")
    var dest = folder + "/" + file.name
    var cut = dest.rfind("/")
    try:
        makedirs(String(dest[byte=:cut]), exist_ok=True)
    except e:
        return Response.failed("couldn't make " + String(dest[byte=:cut]) + ": " + String(e))
    var req = _auth(Request.get(0, hub_file_url(repo, file)).timeout(timeout_ms))
    return fetch_to_file(req, dest, t, tries=tries)
