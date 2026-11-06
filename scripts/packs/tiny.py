#!/usr/bin/env python3
"""The smallest packs, for tests/test_maxrt.mojo (goal 51 M0). Build side only.

    pixi run python scripts/packs/tiny.py build/packs/tiny

tiny_cpu.mef: y = relu(x @ W + b), x float32 [2, 4], W and b baked in (CPU).
tiny_gpu.mef: a 3×3 stride-2 conv with external weights (tiny_gpu.safetensors: conv.weight, conv.bias), SiLU, the
channel mean; x float32 [1, 64, 64, 3] → [1, 32, 32] (GPU). Its input is tiny_gpu_x.f32.
reference.json: Python's answers for both (the Mojo test must give the same numbers).
"""
import json
import sys
from pathlib import Path

import numpy as np
from max import driver
from max.dtype import DType
from max.engine import InferenceSession
from max.graph import DeviceRef, Graph, TensorType, Weight, ops

sys.path.insert(0, str(Path(__file__).parent))
from packlib import write_safetensors  # noqa: E402

out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/packs/tiny")
out.mkdir(parents=True, exist_ok=True)
ref = {}

# CPU: relu(x @ W + b)
W = np.arange(12, dtype=np.float32).reshape(4, 3) / 10
b = np.array([1, -100, 0.5], dtype=np.float32)
with Graph("tiny_cpu", input_types=[TensorType(DType.float32, [2, 4], device=DeviceRef.CPU())]) as g:
    y = ops.relu(g.inputs[0] @ ops.constant(W, DType.float32, device=DeviceRef.CPU()) + ops.constant(b, DType.float32, device=DeviceRef.CPU()))
    g.output(y)
cpu = driver.CPU()
sess = InferenceSession(devices=[cpu])
c = sess.compile(g)
c.export_mef(str(out / "tiny_cpu.mef"))
m = sess.init(c)
x = np.array([[1, 2, 3, 4], [0, 0, 0, 0]], dtype=np.float32)
ref["cpu"] = m.execute(driver.Buffer.from_numpy(x))[0].to_numpy().ravel().tolist()

# GPU: conv with external weights
gpu = driver.Accelerator(0)
rng = np.random.default_rng(0)
Wc = (rng.standard_normal((3, 3, 3, 16)) * 0.1).astype(np.float32)  # RSCF
bc = (rng.standard_normal(16) * 0.1).astype(np.float32)
write_safetensors(out / "tiny_gpu.safetensors", {"conv.weight": Wc, "conv.bias": bc})
dref = DeviceRef.GPU(0)
with Graph("tiny_gpu", input_types=[TensorType(DType.float32, [1, 64, 64, 3], device=dref)]) as g:
    w = Weight("conv.weight", DType.float32, [3, 3, 3, 16], device=dref)
    bb = Weight("conv.bias", DType.float32, [16], device=dref)
    y = ops.conv2d(g.inputs[0], w, stride=(2, 2), padding=(1, 1, 1, 1), bias=bb)
    y = y * ops.sigmoid(y)
    g.output(ops.reshape(ops.mean(y, axis=-1), [1, 32, 32]))
sess = InferenceSession(devices=[gpu])
c = sess.compile(g)
c.export_mef(str(out / "tiny_gpu.mef"))
m = sess.init(c, weights_registry={"conv.weight": Wc, "conv.bias": bc})
x = np.linspace(-1, 1, 64 * 64 * 3, dtype=np.float32).reshape(1, 64, 64, 3)
x.tofile(out / "tiny_gpu_x.f32")
o = m.execute(driver.Buffer.from_numpy(x).to(gpu))[0].to(driver.CPU()).to_numpy().ravel()
ref["gpu_sum"] = float(o.sum())
ref["gpu_first"] = o[:4].tolist()
ref["gpu_n"] = int(o.size)
(out / "reference.json").write_text(json.dumps(ref, indent=1))
print(json.dumps(ref))
