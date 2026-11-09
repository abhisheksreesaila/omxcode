# CUDA_VISIBLE_DEVICES when consoled picks a GPU for `max serve`: only the listed GPUs (indices or UUIDs, CUDA's
# rules: the list stops at the first entry that names no GPU; empty, "-1" or "NoDevBackend" means none), and the
# chosen GPU passed as its number among the visible ones (MAX/CUDA renumber them from 0). None visible serves
# exactly as a machine without a GPU does (no --devices). The port sandbox keeps the variable. Offline.
#   scripts/mojo_flare.sh build -I examples/consoled tests/test_gpu_visible.mojo -o build/test_gpu_visible
from supervisor import Gpu, parse_smi, visible_gpus, device_of, Supervisor, ModelRef
from sandbox import scrub

comptime SMI = """0, GPU-950714f3-1dcb-82c4-6f0b-241024860932, NVIDIA GeForce RTX 3090, 60, 24576, 0
1, GPU-2b0cad02-4be1-3933-8210-861d920e6f28, NVIDIA GeForce RTX 3090, 2913, 24576, 6
2, GPU-77aa0000-0000-0000-0000-000000000002, NVIDIA GeForce RTX 3090, 10, 24576, 0
"""


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def indices(list: List[Gpu]) -> String:
    var s = String("")
    for g in list:
        s += String(g.index) + ">" + String(g.device) + " "
    return s


def devices_arg(cmd: List[String]) -> String:
    for i in range(len(cmd) - 1):
        if cmd[i] == "--devices":
            return cmd[i + 1]
    return "none"


def main() raises:
    var all = parse_smi(SMI)
    check(len(all) == 3 and all[1].uuid == "GPU-2b0cad02-4be1-3933-8210-861d920e6f28" and all[1].used_mb == 2913, "parse_smi")
    check(indices(all) == "0>0 1>1 2>2 ", "physical order: " + indices(all))
    # unset: every GPU, numbered as nvidia-smi does
    check(indices(visible_gpus(all, "", False)) == "0>0 1>1 2>2 ", "unset")
    # a list of indices, in CUDA's order, renumbered from 0
    check(indices(visible_gpus(all, "1", True)) == "1>0 ", "CUDA_VISIBLE_DEVICES=1: " + indices(visible_gpus(all, "1", True)))
    check(indices(visible_gpus(all, "2,0", True)) == "2>0 0>1 ", "2,0: " + indices(visible_gpus(all, "2,0", True)))
    check(indices(visible_gpus(all, " 1 , 2 ", True)) == "1>0 2>1 ", "spaces")
    # UUIDs, whole or a unique prefix, with or without GPU-
    check(indices(visible_gpus(all, "GPU-2b0cad02-4be1-3933-8210-861d920e6f28", True)) == "1>0 ", "a whole UUID")
    check(indices(visible_gpus(all, "GPU-77aa,GPU-9507", True)) == "2>0 0>1 ", "UUID prefixes")
    check(indices(visible_gpus(all, "2b0cad02", True)) == "1>0 ", "a UUID without GPU-")
    check(indices(visible_gpus(all, "GPU-", True)) == "", "an ambiguous UUID prefix names no GPU")
    # none visible
    for none in ["", "-1", "NoDevBackend", "7", "none", ","]:
        check(len(visible_gpus(all, String(none), True)) == 0, "`" + String(none) + "` must leave no GPU")
    # CUDA stops at the first entry that names no GPU, and a repeat
    check(indices(visible_gpus(all, "1,-1,0", True)) == "1>0 ", "stops at -1")
    check(indices(visible_gpus(all, "0,0,1", True)) == "0>0 ", "stops at a repeat")
    # the choice: physical GPU picked among the visible ones, its visible number on the command line
    var sup = Supervisor("/tmp/g-test-home", "max", 0)
    var m = ModelRef("tiny", "openai-community/gpt2", "", "", "", 0)
    var vis = visible_gpus(all, "1", True)
    var g = sup.pick_gpu(vis)
    check(g == 1 and device_of(vis, g) == 0, "CUDA_VISIBLE_DEVICES=1 picks physical 1 as device 0: " + String(g))
    check(devices_arg(sup.command(m, 9000, device_of(vis, g), 24576)) == "gpu:0", "--devices under CUDA_VISIBLE_DEVICES=1")
    var unset = visible_gpus(all, "", False)
    var u = sup.pick_gpu(unset)
    check(u == 2 and device_of(unset, u) == 2, "unset picks the roomiest physical GPU as itself: " + String(u))
    check(devices_arg(sup.command(m, 9000, device_of(unset, u), 24576)) == "gpu:2", "--devices unset")
    var none = visible_gpus(all, "-1", True)
    check(sup.pick_gpu(none) == -1 and device_of(none, -1) == -1, "no visible GPU picks none")
    check(devices_arg(sup.command(m, 9000, device_of(none, -1), 0)) == "none", "no visible GPU: no --devices (the CPU path)")
    # the port sandbox scrubs credentials, never CUDA_VISIBLE_DEVICES
    check(len(scrub(["CUDA_VISIBLE_DEVICES", "CUDA_DEVICE_ORDER"], False)) == 0, "the sandbox dropped CUDA_VISIBLE_DEVICES")
    print("gpu visible: ok (indices, UUIDs, none, renumbered --devices, kept by the sandbox)")
