#!/usr/bin/env python3
"""YOLOX-Tiny's reference, from Megvii's own code and weights (Apache-2.0), in the torch environment (goal 51 M3).
Run by scripts/packs/yolox.py; build side only.

    pixi run -e models python scripts/packs/yolox_ref.py OUT

Writes OUT/folded.npz (every conv with its BatchNorm folded in, by the module's path: <path>.w [F, C, R, S] float64
folded to float32, <path>.b [F]), and for each test image (tests/fixtures/vision/*.jpg): <name>.rgb (its pixels,
RGB bytes) with <name>.size ("w h"), <name>.input.f32 (the letterboxed 416×416 BGR input, NHWC, as Megvii's preproc
makes it), <name>.raw.f32 (the head's outputs before decoding [3549, 85], objectness and classes after sigmoid), and
reference.json: each image's boxes after Megvii's postprocess (score ≥ 0.25, class-aware NMS 0.45) in the image's
pixels: {"cls": COCO name, "score": obj × class, "box": [x, y, w, h]}.
"""
import importlib.util
import json
import sys
import types
from pathlib import Path

import cv2
import numpy as np
import torch

SRC = Path.home() / ".cache/omxcode/yolox/src"
WEIGHTS = Path.home() / ".cache/omxcode/yolox/yolox_tiny.pth"
ROOT = Path(__file__).resolve().parents[2]
SIZE = 416
CONF, NMS = 0.25, 0.45
COCO = ["person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light", "fire hydrant",
        "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe",
        "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball", "kite", "baseball bat",
        "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl",
        "banana", "apple", "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch",
        "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave",
        "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"]


def load_megvii():
    """Megvii's model files, imported by path: their `yolox` package's __init__ pulls in training tools (loguru,
    tabulate, …) this needs none of, so `yolox` and `yolox.utils` are stand-ins holding only what the model uses."""
    sys.modules["loguru"] = types.SimpleNamespace(logger=types.SimpleNamespace(info=print, warning=print, error=print))
    pkg = types.ModuleType("yolox")
    pkg.__path__ = [str(SRC / "yolox")]
    sys.modules["yolox"] = pkg

    def load(name, path):
        spec = importlib.util.spec_from_file_location(name, path)
        m = importlib.util.module_from_spec(spec)
        sys.modules[name] = m
        spec.loader.exec_module(m)
        return m

    boxes = load("yolox.utils.boxes", SRC / "yolox/utils/boxes.py")
    compat = load("yolox.utils.compat", SRC / "yolox/utils/compat.py")
    utils = types.ModuleType("yolox.utils")
    utils.bboxes_iou, utils.meshgrid, utils.postprocess = boxes.bboxes_iou, compat.meshgrid, boxes.postprocess
    sys.modules["yolox.utils"] = utils
    models = types.ModuleType("yolox.models")
    models.__path__ = [str(SRC / "yolox/models")]
    sys.modules["yolox.models"] = models
    for n in ("network_blocks", "darknet", "losses", "yolo_pafpn", "yolo_head", "yolox"):
        load(f"yolox.models.{n}", SRC / f"yolox/models/{n}.py")
    m = sys.modules
    backbone = m["yolox.models.yolo_pafpn"].YOLOPAFPN(0.33, 0.375, act="silu")
    head = m["yolox.models.yolo_head"].YOLOXHead(80, 0.375, act="silu")
    model = m["yolox.models.yolox"].YOLOX(backbone, head)
    ckpt = torch.load(WEIGHTS, map_location="cpu", weights_only=True)
    model.load_state_dict(ckpt["model"])
    model.eval()
    return model, boxes.postprocess


def fold(model):
    """Every Conv2d with the BatchNorm after it (BaseConv's conv + bn) folded into one weight and bias (in float64)."""
    out = {}
    mods = dict(model.named_modules())
    for name, mod in mods.items():
        if isinstance(mod, torch.nn.Conv2d):
            w = mod.weight.detach().double().numpy()
            b = mod.bias.detach().double().numpy() if mod.bias is not None else np.zeros(w.shape[0])
            parent = name.rsplit(".", 1)[0] if "." in name else ""
            bn = mods.get(parent + ".bn") if name.endswith(".conv") else None
            if isinstance(bn, torch.nn.BatchNorm2d):
                g = bn.weight.detach().double().numpy() / np.sqrt(bn.running_var.detach().double().numpy() + bn.eps)
                w = w * g[:, None, None, None]
                b = (b - bn.running_mean.detach().double().numpy()) * g + bn.bias.detach().double().numpy()
            out[name + ".w"] = w.astype(np.float32)
            out[name + ".b"] = b.astype(np.float32)
    return out


def letterbox(img):
    """Megvii's preproc (legacy off): the image scaled to fit 416 × 416 (cv2 bilinear), top-left, the rest 114."""
    r = min(SIZE / img.shape[0], SIZE / img.shape[1])
    resized = cv2.resize(img, (int(img.shape[1] * r), int(img.shape[0] * r)), interpolation=cv2.INTER_LINEAR).astype(np.uint8)
    padded = np.full((SIZE, SIZE, 3), 114, dtype=np.uint8)
    padded[: resized.shape[0], : resized.shape[1]] = resized
    return padded, r


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    model, postprocess = load_megvii()
    np.savez(out / "folded.npz", **fold(model))
    model.head.decode_in_inference = False
    ref = {}
    for p in sorted((ROOT / "tests/fixtures/vision").glob("*.jpg")):
        bgr = cv2.imread(str(p), cv2.IMREAD_COLOR)  # (greyscale files come back as 3 equal channels)
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        rgb.tofile(out / f"{p.stem}.rgb")
        (out / f"{p.stem}.size").write_text(f"{rgb.shape[1]} {rgb.shape[0]}")
        x, r = letterbox(bgr)
        x.astype(np.float32).tofile(out / f"{p.stem}.input.f32")
        with torch.no_grad():
            t = torch.from_numpy(x.astype(np.float32).transpose(2, 0, 1)[None])
            raw = model(t)  # [1, 3549, 85]: reg, obj and classes after sigmoid, not decoded
            raw.numpy()[0].astype(np.float32).tofile(out / f"{p.stem}.raw.f32")
            model.head.decode_in_inference = True
            dec = model.head.decode_outputs(raw.clone(), dtype=raw.type())
            model.head.decode_in_inference = False
            det = postprocess(dec, 80, CONF, NMS, class_agnostic=False)[0]
        boxes = []
        if det is not None:
            for d in det.numpy():
                x1, y1, x2, y2 = (float(v) / r for v in d[:4])
                boxes.append({"cls": COCO[int(d[6])], "score": float(d[4] * d[5]), "box": [x1, y1, x2 - x1, y2 - y1]})
        ref[p.stem] = boxes
        print(p.stem, [(b["cls"], round(b["score"], 2)) for b in boxes])
    (out / "reference.json").write_text(json.dumps(ref, indent=1))


if __name__ == "__main__":
    main()
