"""Goal 39 M12 spike: Python-only baseline for mojoui/visionmodel_torch.py (OWLv2 detect, SAM 2.1 track).

    CUDA_VISIBLE_DEVICES=1 pixi run -e models python scripts/vision_spike.py owl    # annotated PNGs + ms per frame
    CUDA_VISIBLE_DEVICES=1 pixi run -e models python scripts/vision_spike.py sam    # track a box over 60 frames

Writes build/g39e/out/*.png and prints timings. Media: $G39_MEDIA (default ../mojo-ui-g39/build/g39/media).
"""

import os
import subprocess
import sys
import time

import numpy as np
import torch
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "mojoui"))
import visionmodel_torch as vm  # noqa: E402

MEDIA = os.environ.get("G39_MEDIA", os.path.expanduser("~/Projects/mxapp/mojo-ui-g39/build/g39/media"))
OUT = os.path.join(os.path.dirname(__file__), "..", "build", "g39e", "out")
COLOURS = [(230, 25, 75), (60, 180, 75), (0, 130, 200), (245, 130, 48), (145, 30, 180), (70, 240, 240)]


def frames(video, first, count, w=1280, h=720):
    """`count` RGBA frames from `first` (ffmpeg pipe), as (count, h, w, 4) uint8."""
    cmd = ["ffmpeg", "-v", "error", "-i", os.path.join(MEDIA, video), "-vf", f"select=gte(n\\,{first})",
           "-frames:v", str(count), "-f", "rawvideo", "-pix_fmt", "rgba", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(-1, h, w, 4)


def draw(rgba, rows, prompts, path, masks=None):
    img = Image.fromarray(rgba[..., :3].copy())
    if masks is not None:
        over = np.array(img)
        for i, m in enumerate(masks):
            c = np.array(COLOURS[i % len(COLOURS)])
            over[m] = (over[m] * 0.5 + c * 0.5).astype(np.uint8)
        img = Image.fromarray(over)
    d = ImageDraw.Draw(img)
    for x, y, w, h, s, lab in rows:
        c = COLOURS[int(lab) % len(COLOURS)]
        d.rectangle([x, y, x + w, y + h], outline=c, width=3)
        d.text((x + 4, y + 2), f"{prompts[int(lab)]} {s:.2f}", fill=c)
    img.save(path)


def owl():
    det = vm.Detector("google/owlv2-base-patch16-ensemble", device="cuda", half=True)
    print(f"owlv2 load: {det.load_ms:.0f} ms, {torch.cuda.max_memory_allocated() / 2**20:.0f} MiB")
    cases = [
        ("warehouse.mp4", [200, 420, 800], ["a cardboard box", "a torn package", "a person's face", "a barcode label"], 0.2),
        ("drone_a.mp4", [100, 300], ["an electrical insulator", "a burn mark"], 0.1),
    ]
    for video, idx, prompts, thr in cases:
        for n in idx:
            f = frames(video, n, 1)
            g = torch.from_numpy(f).cuda()
            det.detect_frames(g, prompts, thr)  # warm (and text cache)
            rows = det.detect_frames(g, prompts, thr)[0]
            path = os.path.join(OUT, f"owl_{video.split('.')[0]}_{n}.png")
            draw(f[0], rows.tolist(), prompts, path)
            summary = {}
            for r in rows.tolist():
                summary.setdefault(prompts[int(r[5])], []).append(round(r[4], 2))
            print(f"{video} f{n}: {det.model_ms:.1f} ms, {len(rows)} boxes {summary} -> {path}")
    # throughput: batch sizes, fp16, prompts as the warehouse
    prompts = cases[0][2]
    f = torch.from_numpy(frames("warehouse.mp4", 160, 16)).cuda()
    for b in (1, 4, 8, 16):
        det.detect_frames(f[:b], prompts)
        t0 = time.perf_counter()
        reps = max(1, 32 // b)
        for _ in range(reps):
            det.detect_frames(f[:b], prompts)
        ms = (time.perf_counter() - t0) * 1000 / (reps * b)
        print(f"owlv2 fp16 batch {b}: {ms:.1f} ms/frame ({1000 / ms:.0f} fps)")
    # the hand-off: an RGBA frame at a host address -> GPU tensor
    host = np.ascontiguousarray(frames("warehouse.mp4", 200, 1)[0])
    up = vm._Upload("cuda")
    for _ in range(3):
        up(host.ctypes.data, 1280, 720)
    ts = []
    for _ in range(20):
        up(host.ctypes.data, 1280, 720)
        ts.append(up.last_ms)
    print(f"hand-off (address -> numpy view -> pinned -> GPU), 1280x720 RGBA: median {sorted(ts)[10]:.2f} ms")
    print(f"peak GPU memory: {torch.cuda.max_memory_allocated() / 2**20:.0f} MiB")


def sam(name="facebook/sam2.1-hiera-tiny", first=200, count=60):
    det = vm.Detector("google/owlv2-base-patch16-ensemble", device="cuda", half=True)
    seg = vm.Segmenter(name, device="cuda", half=True)
    print(f"{name} load: {seg.load_ms:.0f} ms")
    fr = frames("warehouse.mp4", first, count)
    g = torch.from_numpy(fr).cuda()
    prompts = ["a box on a conveyor belt", "a red splat"]
    rows = det.detect_frames(g[:1], prompts, 0.1)[0]
    boxes = sorted([r for r in rows.tolist() if int(r[5]) == 0 and r[2] < 400], key=lambda r: -r[4])  # a pallet, not the belt
    if not boxes:
        print("sam: OWLv2 found no box to track")
        return
    seg.start(1280, 720)
    picked = boxes[:3]
    seg.add_boxes(0, list(range(1, len(picked) + 1)), [v for r in picked for v in r[:4]])
    print(f"tracking {len(picked)} boxes from OWLv2 on frame {first}: " + ", ".join(f"({x:.0f},{y:.0f},{w:.0f},{h:.0f})" for x, y, w, h, _, _ in picked))
    ts = []
    trail = []
    for k in range(count):
        ids, masks = seg.step_frame(g[k])
        ts.append(seg.model_ms)
        rows6 = vm._mask_rows(ids, masks)
        trail.append(rows6)
        if k in (0, 20, 40, count - 1):
            mr = [(rows6[j + 1], rows6[j + 2], rows6[j + 3], rows6[j + 4], 1.0, 0) for j in range(0, len(rows6), 6)]
            path = os.path.join(OUT, f"sam_track_{first + k}.png")
            draw(fr[k], mr, ["tracked"], path, masks=masks.cpu().numpy())
            print(f"frame {first + k}: " + ", ".join(f"id{int(rows6[j])} x={rows6[j+1]:.0f} w={rows6[j+3]:.0f} area={rows6[j+5]:.0f}" for j in range(0, len(rows6), 6)) + f" -> {path}")
    print(f"sam2.1 track: first frame {ts[0]:.0f} ms, then median {sorted(ts[1:])[len(ts) // 2]:.1f} ms/frame for {len(picked)} objects")
    print(f"peak GPU memory: {torch.cuda.max_memory_allocated() / 2**20:.0f} MiB")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    {"owl": owl, "sam": sam}[sys.argv[1]](*sys.argv[2:])
