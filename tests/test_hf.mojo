# mojoui.hf on the live Hugging Face Hub (goal 55 M1): search with sizes, a repo's files, a download, a resumed part,
# a cancel. Needs the network. scripts/mojo_flare.sh build tests/test_hf.mojo -o build/test_hf && build/test_hf
from std.os import makedirs
from std.os.path import exists, getsize
from mojoui.hf import hub_search, hub_repo, hub_download, HubFile, dtype_bytes
from mojoui.http import url_quote
from mojoui.http_flare import Transfer
from mojoui import libc

comptime REPO = "HuggingFaceTB/SmolLM2-135M-Instruct"
comptime DIR = "build/g55/test_hf_files"


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def file_named(files: List[HubFile], name: String) -> Int:
    for i in range(len(files)):
        if files[i].name == name:
            return i
    return -1


def read_bytes(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def main() raises:
    check(url_quote("a b/c?d=é") == "a%20b%2Fc%3Fd%3D%C3%A9", "url_quote: " + url_quote("a b/c?d=é"))
    check(url_quote("Qwen/Qwen2.5-0.5B", safe="/") == "Qwen/Qwen2.5-0.5B", "url_quote safe")
    check(dtype_bytes("BF16") == 2 and dtype_bytes("F32") == 4 and dtype_bytes("I8") == 1, "dtype_bytes")
    # search: the Hub's own sizes
    var found = hub_search("SmolLM2-135M-Instruct", limit=10)
    var hit = -1
    for i in range(len(found)):
        if found[i].id == REPO:
            hit = i
    check(hit >= 0, "search didn't find " + REPO + " (" + String(len(found)) + " results)")
    check(found[hit].params > 100_000_000 and found[hit].bytes > found[hit].params, "sizes: " + String(found[hit].params) + " params, " + String(found[hit].bytes) + " bytes")
    check(found[hit].task == "text-generation" and not found[hit].gated, "task/gated: " + found[hit].task)
    # a repo's files
    var repo = hub_repo(REPO)
    check(repo.sha.byte_length() == 40, "sha: " + repo.sha)
    var w = file_named(repo.files, "model.safetensors")
    var c = file_named(repo.files, "config.json")
    check(w >= 0 and repo.files[w].sha256.byte_length() == 64 and repo.files[w].size > 100_000_000, "model.safetensors: LFS size and sha256")
    check(c >= 0 and repo.files[c].sha256 == "" and repo.files[c].size > 100, "config.json: a small git file")
    # a download, then a resume from a part that holds its first bytes
    makedirs(DIR, exist_ok=True)
    var dest = DIR + "/config.json"
    _ = libc.unlink(dest)
    _ = libc.unlink(dest + ".part")
    var t = Transfer()
    var r = hub_download(repo, repo.files[c], DIR, t)
    check(r.error == "" and r.status == 200 and exists(dest), "download: " + String(r.status) + " " + r.error)
    check(getsize(dest) == repo.files[c].size and t.done() == repo.files[c].size, "size: " + String(getsize(dest)) + " vs " + String(repo.files[c].size))
    var whole = read_bytes(dest)
    var head = List[UInt8]()
    for i in range(40):
        head.append(whole[i])
    with open(dest + ".part", "w") as f:
        f.write_bytes(Span(head))
    _ = libc.unlink(dest)
    var t2 = Transfer()
    r = hub_download(repo, repo.files[c], DIR, t2)
    check(r.error == "" and exists(dest) and not exists(dest + ".part"), "resume: " + String(r.status) + " " + r.error)
    check(read_bytes(dest) == whole, "the resumed file differs from the whole one")
    # a cancel: nothing renamed into place, the part kept for later
    var t3 = Transfer()
    t3.cancel()
    var big = DIR + "/model.safetensors"
    _ = libc.unlink(big)
    r = hub_download(repo, repo.files[w], DIR, t3)
    check(r.error == "cancelled" and not exists(big), "cancel: " + r.error)
    _ = libc.unlink(big + ".part")
    t.free()
    t2.free()
    t3.free()
    print("hf: ok (" + String(len(found)) + " results; " + REPO + " " + String(found[hit].params) + " params, "
          + String(len(repo.files)) + " files at " + String(repo.sha[byte=:8]) + "; download, resume, cancel)")
