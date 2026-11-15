# Where huggingface_hub keeps a repo it has downloaded, so an app opens a dataset "where it sits" without Python and
# without downloading (goal 71). The same lookup as omxcore's `mx robot` (HF_HUB_CACHE, else HF_HOME/hub, else
# ~/.cache/huggingface/hub; refs/main's snapshot), which omxcore's Mojo package doesn't expose yet.
#   var folder = hf_snapshot("lerobot/svla_so100_sorting")        # raises when the repo isn't in the cache
from std.os import getenv
from std.os.path import isdir


def hf_hub_cache() -> String:
    """huggingface_hub's cache folder."""
    var h = getenv("HF_HUB_CACHE")
    if h.byte_length() > 0:
        return h
    var home = getenv("HF_HOME")
    if home.byte_length() > 0:
        return home + "/hub"
    return getenv("HOME") + "/.cache/huggingface/hub"


def hf_snapshot(repo: String, kind: String = "datasets") raises -> String:
    """The folder of `repo`'s refs/main snapshot ("lerobot/libero" -> .../datasets--lerobot--libero/snapshots/<sha>); a
    path that is already a folder is returned as it is."""
    if isdir(repo):
        return repo
    var base = hf_hub_cache() + "/" + kind + "--" + repo.replace("/", "--")
    var sha = String()
    try:
        with open(base + "/refs/main", "r") as f:
            sha = String(f.read().strip())
    except:
        raise Error("`" + repo + "` isn't in the Hugging Face cache (" + hf_hub_cache() + "): download it once with huggingface_hub")
    var snap = base + "/snapshots/" + sha
    if not isdir(snap):
        raise Error("`" + repo + "`: the cache names snapshot " + sha + ", which isn't there")
    return snap
