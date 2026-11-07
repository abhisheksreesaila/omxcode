"""The GPU a proof may use on this shared machine (goal 59; goal 55's wait_gpu_room is the same rule): another project's
model server comes and goes and can fill both cards, and MAX then fails deep inside ("CUDA_ERROR_OUT_OF_MEMORY", "don't
leave room for KV cache"). A check that needs the GPU waits for room first, so it measures our code, not the neighbours.

    from gpuroom import roomiest_gpu
    env["CUDA_VISIBLE_DEVICES"] = roomiest_gpu(free_mb=8000)   # waits (≤ limit_s) for a card with that much free
"""
import subprocess
import time


def free_by_card():
    """[(free MB, index)] for each card, most free first."""
    rows = subprocess.run(["nvidia-smi", "--query-gpu=index,memory.free", "--format=csv,noheader,nounits"], capture_output=True, text=True).stdout
    return sorted(((int(f), i.strip()) for i, f in (l.split(",") for l in rows.strip().splitlines())), reverse=True)


def roomiest_gpu(free_mb=8000, limit_s=2700, every_s=20):
    """The index of the card with the most free memory, once one has free_mb; RuntimeError naming who holds them after limit_s."""
    t0 = time.time()
    while time.time() - t0 < limit_s:
        cards = free_by_card()
        if cards and cards[0][0] >= free_mb:
            return cards[0][1]
        time.sleep(every_s)
    who = subprocess.run(["nvidia-smi", "--query-compute-apps=pid,used_memory,process_name", "--format=csv,noheader"],
                         capture_output=True, text=True).stdout.strip().replace("\n", "; ")
    raise RuntimeError(f"no GPU had {free_mb} MB free for {limit_s // 60} min ({who[:200]})")
