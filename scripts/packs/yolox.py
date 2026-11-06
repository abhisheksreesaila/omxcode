#!/usr/bin/env python3
"""YOLOX-Tiny (Megvii, Apache-2.0) as a pack, for mojoui.detect (goal 51 M3). Build side.

    pixi run python scripts/packs/yolox.py build/packs/yolox

1. scripts/packs/yolox_ref.py (torch environment): Megvii's model and weights, BatchNorm folded, references.
2. Here (MAX): the same network as a MAX graph, NHWC, every conv as im2col patches @ a weight matrix (MAX's own 3×3
   conv kernel is ~100× slower on sm_86: docs/research/goal50-models.md), SiLU, max pools, nearest 2× upsampling;
   input0 float32 [1, 416, 416, 3] (letterboxed BGR, 0–255, as Megvii's preproc) → output0 [3549, 85] (box offsets,
   objectness and the 80 classes after sigmoid; decoding and NMS are the app's, in Mojo). Weights in
   yolox.safetensors, by module path. Checked against torch's raw outputs on the test images before it's written.
"""
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
from max import driver
from max.dtype import DType
from max.engine import InferenceSession
from max.graph import DeviceRef, Graph, TensorType, Weight, ops

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from packlib import fetch_pinned, omx_cache, write_safetensors  # noqa: E402

SIZE = 416
DEV = DeviceRef.GPU(0)


class Net:
    """YOLOX-Tiny's forward pass, by Megvii's module paths (depth 0.33, width 0.375: yolox/exp/default/yolox_tiny.py)."""

    def __init__(self, folded):
        self.f = folded
        self.weights = {}

    def _w(self, name, arr):
        self.weights[name] = np.ascontiguousarray(arr, dtype=np.float32)
        return Weight(name, DType.float32, list(arr.shape), device=DEV)

    def conv(self, x, path, k, stride=1, act=True):
        """Conv2d(+ folded BN) at `path` (its weights: <path>.w [F, C, k, k], <path>.b), SiLU when act."""
        w = self.f[path + ".w"]
        f, c = w.shape[0], w.shape[1]
        mat = w.transpose(2, 3, 1, 0).reshape(k * k * c, f)  # [R·S·C, F]: im2col's order (kernel row, column, channel)
        wm = self._w(path + ".w", mat)
        b = self._w(path + ".b", self.f[path + ".b"])
        _, h, wd, _ = (int(d) for d in x.shape)
        pad = (k - 1) // 2
        ho, wo = (h + 2 * pad - k) // stride + 1, (wd + 2 * pad - k) // stride + 1
        if k == 1:
            p = x if stride == 1 else x[:, ::stride, ::stride, :]
        else:
            xp = ops.pad(x, [0, 0, pad, pad, pad, pad, 0, 0]) if pad else x
            views = [xp[:, i:i + stride * (ho - 1) + 1:stride, j:j + stride * (wo - 1) + 1:stride, :] for i in range(k) for j in range(k)]
            p = ops.concat(views, axis=-1)
        y = ops.reshape(p, [ho * wo, k * k * c]) @ wm + b
        y = ops.reshape(y, [1, ho, wo, f])
        return y * ops.sigmoid(y) if act else y

    def base(self, x, path, k, stride=1):
        return self.conv(x, path + ".conv", k, stride)

    def bottleneck(self, x, path, shortcut):
        y = self.base(self.base(x, path + ".conv1", 1), path + ".conv2", 3)
        return y + x if shortcut else y

    def csp(self, x, path, n, shortcut=True):
        x1 = self.base(x, path + ".conv1", 1)
        for i in range(n):
            x1 = self.bottleneck(x1, f"{path}.m.{i}", shortcut)
        x2 = self.base(x, path + ".conv2", 1)
        return self.base(ops.concat([x1, x2], axis=-1), path + ".conv3", 1)

    def spp(self, x, path):
        x = self.base(x, path + ".conv1", 1)
        pools = [ops.max_pool2d(x, (k, k), stride=1, padding=(k // 2, k // 2)) for k in (5, 9, 13)]
        return self.base(ops.concat([x] + pools, axis=-1), path + ".conv2", 1)

    @staticmethod
    def up(x):
        """Nearest 2× (NHWC): each pixel repeated across 2 columns, then 2 rows."""
        _, h, w, c = (int(d) for d in x.shape)
        y = ops.reshape(x, [1, h, w, 1, c])
        y = ops.reshape(ops.concat([y, y], axis=3), [1, h, 1, 2 * w, c])
        return ops.reshape(ops.concat([y, y], axis=2), [1, 2 * h, 2 * w, c])

    def forward(self, x):
        B = "backbone.backbone"
        # Focus: space to depth, torch's channel order (top-left, bottom-left, top-right, bottom-right)
        x = ops.concat([x[:, ::2, ::2, :], x[:, 1::2, ::2, :], x[:, ::2, 1::2, :], x[:, 1::2, 1::2, :]], axis=-1)
        x = self.base(x, f"{B}.stem.conv", 3)
        x = self.csp(self.base(x, f"{B}.dark2.0", 3, 2), f"{B}.dark2.1", 1)
        d3 = self.csp(self.base(x, f"{B}.dark3.0", 3, 2), f"{B}.dark3.1", 3)
        d4 = self.csp(self.base(d3, f"{B}.dark4.0", 3, 2), f"{B}.dark4.1", 3)
        d5 = self.base(d4, f"{B}.dark5.0", 3, 2)
        d5 = self.csp(self.spp(d5, f"{B}.dark5.1"), f"{B}.dark5.2", 1, shortcut=False)
        P = "backbone"
        fpn0 = self.base(d5, f"{P}.lateral_conv0", 1)
        f0 = self.csp(ops.concat([self.up(fpn0), d4], axis=-1), f"{P}.C3_p4", 1, shortcut=False)
        fpn1 = self.base(f0, f"{P}.reduce_conv1", 1)
        pan2 = self.csp(ops.concat([self.up(fpn1), d3], axis=-1), f"{P}.C3_p3", 1, shortcut=False)
        pan1 = self.csp(ops.concat([self.base(pan2, f"{P}.bu_conv2", 3, 2), fpn1], axis=-1), f"{P}.C3_n3", 1, shortcut=False)
        pan0 = self.csp(ops.concat([self.base(pan1, f"{P}.bu_conv1", 3, 2), fpn0], axis=-1), f"{P}.C3_n4", 1, shortcut=False)
        outs = []
        for i, feat in enumerate((pan2, pan1, pan0)):
            H = "head"
            s = self.base(feat, f"{H}.stems.{i}", 1)
            c = self.base(self.base(s, f"{H}.cls_convs.{i}.0", 3), f"{H}.cls_convs.{i}.1", 3)
            r = self.base(self.base(s, f"{H}.reg_convs.{i}.0", 3), f"{H}.reg_convs.{i}.1", 3)
            reg = self.conv(r, f"{H}.reg_preds.{i}", 1, act=False)
            obj = ops.sigmoid(self.conv(r, f"{H}.obj_preds.{i}", 1, act=False))
            cls = ops.sigmoid(self.conv(c, f"{H}.cls_preds.{i}", 1, act=False))
            y = ops.concat([reg, obj, cls], axis=-1)  # [1, h, w, 85], rows then columns: the head's grid order
            _, h, w, _ = (int(d) for d in y.shape)
            outs.append(ops.reshape(y, [h * w, 85]))
        return ops.concat(outs, axis=0)  # [3549, 85]


def clean_env():
    return {k: v for k, v in os.environ.items() if not k.startswith(("CONDA", "PIXI", "PYTHON", "_CE_", "_CONDA"))}


# Megvii's source and weights, from their GitHub (Apache-2.0), pinned by SHA-256 (goal 59: no hand step)
SRC_URL = ("https://github.com/Megvii-BaseDetection/YOLOX/archive/refs/tags/0.3.0.tar.gz",
           "972ddb9cb13d508fac3738e814449327cec29bc55fbd8a125c67d9080edfc02d")
WEIGHTS_URL = ("https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_tiny.pth",
               "9de513de589ac98bb92d3bca53b5af7b9acfa9b0bacb831f7999d0f7afaee8f0")


def fetch_megvii():
    """$OMX_CACHE/yolox/src (YOLOX 0.3.0's source) and yolox_tiny.pth, where yolox_ref.py reads them."""
    import tarfile
    d = omx_cache() / "yolox"
    fetch_pinned(WEIGHTS_URL[0], d / "yolox_tiny.pth", WEIGHTS_URL[1])
    if not (d / "src/yolox/__init__.py").exists():
        tgz = fetch_pinned(SRC_URL[0], d / "src.tar.gz", SRC_URL[1])
        with tarfile.open(tgz) as t:
            for m in t.getmembers():
                if m.isfile() and "/" in m.name:
                    m.name = m.name.split("/", 1)[1]  # (YOLOX-0.3.0/… → src/…)
                    t.extract(m, d / "src", filter="data")


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/packs/yolox")
    out.mkdir(parents=True, exist_ok=True)
    if not (out / "folded.npz").exists():
        fetch_megvii()
        r = subprocess.run(["pixi", "run", "-e", "models", "python", str(HERE / "yolox_ref.py"), str(out.resolve())], cwd=ROOT, env=clean_env(),
                           capture_output=True, text=True)
        print(r.stdout[-2000:])
        if r.returncode:
            raise SystemExit("yolox_ref.py failed: " + r.stderr[-2000:])
    folded = dict(np.load(out / "folded.npz"))
    net = Net(folded)
    with Graph("yolox_tiny", input_types=[TensorType(DType.float32, [1, SIZE, SIZE, 3], device=DEV)]) as g:
        g.output(net.forward(g.inputs[0]))
    write_safetensors(out / "yolox.safetensors", net.weights)
    gpu = driver.Accelerator(0)
    sess = InferenceSession(devices=[gpu])
    compiled = sess.compile(g)
    compiled.export_mef(str(out / "yolox.mef"))
    model = sess.init(compiled, weights_registry=net.weights)
    worst = 0.0
    for p in sorted(out.glob("*.input.f32")):
        x = np.fromfile(p, np.float32).reshape(1, SIZE, SIZE, 3)
        y = model.execute(driver.Buffer.from_numpy(x).to(gpu))[0].to(driver.CPU()).to_numpy()
        want = np.fromfile(str(p).replace(".input.f32", ".raw.f32"), np.float32).reshape(-1, 85)
        d = np.abs(y - want)
        print(f"{p.name.split('.')[0]}: max |MAX − torch| boxes {d[:, :4].max():.4f}, scores {d[:, 4:].max():.5f}")
        worst = max(worst, float(d[:, 4:].max()))
    if worst > 0.02:
        raise SystemExit(f"the graph differs from torch: score difference {worst}")
    print(f"yolox pack: {out} (worst score difference {worst:.5f})")


if __name__ == "__main__":
    main()
