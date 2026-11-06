# Goal 55 review round 2: what consoled may delete. DELETE /admin/models removes a folder only when it is exactly one
# part under MXC_HOME/models/ (owned_folder); a cancelled re-pull of a registered model removes only its unfinished
# .part files (remove_parts). Offline.
#   scripts/mojo_flare.sh build -I examples/consoled tests/test_consoled_paths.mojo -o build/test_consoled_paths
from std.os import makedirs
from std.os.path import exists
from daemon import owned_folder
from pulls import remove_parts
from mojoui.files import remove_tree

comptime DIR = "build/g55/test_consoled_paths"


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def main() raises:
    var home = String("/tmp/mxc")
    check(owned_folder(home + "/models/Qwen--Qwen2.5-0.5B-Instruct", home), "a pull's folder")
    for bad in ["/models/..", "/models/.", "/models/", "/models/a/b", "/models/a/", "/models/../x", "/other/a", "/models"]:
        check(not owned_folder(home + String(bad), home), "accepted " + String(bad))
    check(not owned_folder("/tmp/other/models/a", home), "a folder under another home")
    check(not owned_folder("/tmp/./mxc/models/a", "/tmp/./mxc"), "a home with a . part")
    # remove_parts: the .part files go, everything else stays, in subfolders too
    remove_tree(DIR)
    makedirs(DIR + "/sub", exist_ok=True)
    for name in ["model.safetensors", "model.safetensors.part", "sub/a.json", "sub/b.bin.part"]:
        with open(DIR + "/" + String(name), "w") as f:
            f.write("x")
    remove_parts(DIR)
    check(exists(DIR + "/model.safetensors") and exists(DIR + "/sub/a.json"), "remove_parts removed a whole file")
    check(not exists(DIR + "/model.safetensors.part") and not exists(DIR + "/sub/b.bin.part"), "remove_parts left a .part")
    remove_tree(DIR)
    print("consoled paths: ok (owned_folder, remove_parts)")
