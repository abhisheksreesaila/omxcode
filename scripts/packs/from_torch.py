#!/usr/bin/env python3
"""A PyTorch image network as a pack, with no per-model code (goal 59): its layers traced by torch.fx, rebuilt as a
MAX graph, checked against torch on the test pictures, then written with the model.json that makes it a script
function (mojoui.models finds it; docs/models.html walks through it).

    pixi run python scripts/packs/from_torch.py MODEL OUT --function NAME [--labels FILE|imagenet] [--size 224]
                                                 [--mean 0.485,0.456,0.406] [--std 0.229,0.224,0.225] [--about TEXT]

MODEL is `torchvision:<name>` (its default weights, e.g. torchvision:resnet18) or `<file.py>:<factory>`, a function in
that file returning the torch module (eval mode is set here). OUT gets <name>.mef, <name>.safetensors, labels.txt,
model.json and check.json (how close MAX came to torch). Build side only: the app loads the pack from Mojo.

Two halves, one file: the tracing half runs in the `models` environment (torch), the building half here (MAX); the
first starts the second's input with `pixi run -e models … --trace`. Layers it converts: Conv2d (groups 1), BatchNorm2d
(folded into the conv before it), Linear, ReLU/ReLU6/SiLU/GELU/Sigmoid/Tanh/Hardswish, MaxPool2d, AvgPool2d,
AdaptiveAvgPool2d to 1×1, Dropout and Identity (no-ops when evaluating), add, mul, cat on channels, flatten. Anything
else stops the conversion with its name: write that part's graph by hand (scripts/packs/yolox.py, bert_graph.py).

The picture a pack gets (mojoui.imagemodel, in Mojo): the centre square of the frame, resized to size × size
(bilinear, pixel centres), RGB 0–255, NHWC float32; the graph's first step is (x / 255 − mean) / std.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PICTURES = sorted((ROOT / "tests/fixtures/vision").glob("*.jpg"))
ACTS = {"ReLU": "relu", "ReLU6": "relu6", "SiLU": "silu", "GELU": "gelu", "Sigmoid": "sigmoid", "Tanh": "tanh", "Hardswish": "hardswish"}
SAME = ("Dropout", "Identity", "Dropout2d")


def centre_square(rgb: np.ndarray, size: int) -> np.ndarray:
    """The picture's centre square resized to size × size, bilinear at pixel centres: what mojoui.imagemodel does."""
    h, w, _ = rgb.shape
    s = min(w, h)
    x0, y0 = (w - s) // 2, (h - s) // 2
    src = rgb[y0:y0 + s, x0:x0 + s].astype(np.float64)
    c = (np.arange(size) + 0.5) * s / size - 0.5
    c = np.clip(c, 0, s - 1)
    i0 = np.floor(c).astype(int)
    i1 = np.minimum(i0 + 1, s - 1)
    f = c - i0
    rows = src[i0] * (1 - f)[:, None, None] + src[i1] * f[:, None, None]
    out = rows[:, i0] * (1 - f)[None, :, None] + rows[:, i1] * f[None, :, None]
    return out.astype(np.float32)


# ---------------------------------------------------------------- the tracing half (torch, the `models` environment)

def load_module(spec):
    import importlib.util
    import torch
    kind, name = spec.split(":", 1)
    if kind == "torchvision":
        import torchvision
        return getattr(torchvision.models, name)(weights="DEFAULT"), torchvision.models.get_model_weights(name).DEFAULT.meta.get("categories")
    sp = importlib.util.spec_from_file_location("user_model", kind)
    m = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(m)
    torch.manual_seed(0)
    return getattr(m, name)(), getattr(m, "LABELS", None)


def trace(args):
    """MODEL → work/graph.json (the layers, in order), weights.npz (BatchNorm folded), refs.npz (inputs, torch's outputs)."""
    import torch
    import torch.fx as fx
    from PIL import Image
    work = Path(args.work)
    module, labels = load_module(args.model)
    module.eval()
    g = fx.symbolic_trace(module)
    mods = dict(g.named_modules())
    users = {n.name: len(n.users) for n in g.graph.nodes}
    nodes, weights = [], {}
    folded = {}  # a BatchNorm's name → the conv it went into

    def arg(a):
        if isinstance(a, fx.Node):
            return folded.get(a.name, a.name)
        if isinstance(a, (list, tuple)):
            return [arg(x) for x in a]
        return a

    def stop(n, what):
        raise SystemExit(f"from_torch: can't convert {what} (node {n.name}). It converts: Conv2d (groups 1), BatchNorm2d, Linear, "
                         f"{', '.join(ACTS)}, MaxPool2d, AvgPool2d, AdaptiveAvgPool2d(1), Dropout, Identity, add, mul, cat, flatten. "
                         "Write that part's MAX graph by hand (scripts/packs/yolox.py shows how).")

    for n in g.graph.nodes:
        if n.op == "placeholder":
            nodes.append({"name": n.name, "op": "input"})
        elif n.op == "output":
            nodes.append({"name": n.name, "op": "output", "args": [arg(n.args[0])]})
        elif n.op == "call_module":
            m = mods[n.target]
            t = type(m).__name__
            src = arg(n.args[0])
            if t == "Conv2d":
                if m.groups != 1 or m.dilation != (1, 1) or m.padding_mode != "zeros" or isinstance(m.padding, str):
                    stop(n, f"Conv2d with groups={m.groups}, dilation={m.dilation}, padding={m.padding!r}")
                weights[n.name + ".w"] = m.weight.detach().double().numpy()
                weights[n.name + ".b"] = (m.bias.detach().double().numpy() if m.bias is not None else np.zeros(m.out_channels))
                nodes.append({"name": n.name, "op": "conv", "args": [src], "k": list(m.kernel_size), "stride": list(m.stride), "pad": list(m.padding)})
            elif t == "BatchNorm2d":
                if not m.track_running_stats or m.running_mean is None:
                    stop(n, "BatchNorm2d without running statistics (track_running_stats=False)")
                if not m.affine:  # (no learned scale and shift: 1 and 0)
                    m.weight, m.bias = torch.nn.Parameter(torch.ones(m.num_features)), torch.nn.Parameter(torch.zeros(m.num_features))
                scale = (m.weight.detach().double() / torch.sqrt(m.running_var.double() + m.eps)).numpy()
                shift = (m.bias.detach().double() - m.running_mean.double() * torch.from_numpy(scale)).numpy()
                prev = next((x for x in nodes if x["name"] == src), None)
                if prev is not None and prev["op"] == "conv" and users.get(n.args[0].name) == 1:
                    weights[src + ".w"] = weights[src + ".w"] * scale[:, None, None, None]
                    weights[src + ".b"] = weights[src + ".b"] * scale + shift
                    folded[n.name] = src
                else:
                    weights[n.name + ".scale"], weights[n.name + ".shift"] = scale, shift
                    nodes.append({"name": n.name, "op": "affine", "args": [src]})
            elif t == "Linear":
                weights[n.name + ".w"] = m.weight.detach().double().numpy().T
                weights[n.name + ".b"] = m.bias.detach().double().numpy() if m.bias is not None else np.zeros(m.out_features)
                nodes.append({"name": n.name, "op": "linear", "args": [src]})
            elif t in ACTS:
                nodes.append({"name": n.name, "op": ACTS[t], "args": [src]})
            elif t in SAME:
                folded[n.name] = src
            elif t == "MaxPool2d" or t == "AvgPool2d":
                k, s, p = (v if isinstance(v, (tuple, list)) else (v, v) for v in (m.kernel_size, m.stride or m.kernel_size, m.padding))
                if getattr(m, "ceil_mode", False) or getattr(m, "dilation", 1) not in (1, (1, 1)):
                    stop(n, f"{t} with ceil_mode or dilation")
                if t == "AvgPool2d" and (not m.count_include_pad or m.divisor_override) and p != (0, 0):
                    stop(n, "AvgPool2d with padding that isn't counted (count_include_pad=False) or a divisor_override")
                nodes.append({"name": n.name, "op": "maxpool" if t == "MaxPool2d" else "avgpool", "args": [src], "k": list(k), "stride": list(s), "pad": list(p)})
            elif t == "AdaptiveAvgPool2d":
                if m.output_size not in (1, (1, 1)):
                    stop(n, f"AdaptiveAvgPool2d({m.output_size})")
                nodes.append({"name": n.name, "op": "gap", "args": [src]})
            elif t == "Flatten":
                if m.start_dim != 1 or m.end_dim != -1:
                    stop(n, f"Flatten(start_dim={m.start_dim}, end_dim={m.end_dim})")
                nodes.append({"name": n.name, "op": "flatten", "args": [src]})
            else:
                stop(n, t)
        elif n.op in ("call_function", "call_method"):
            f = n.target if isinstance(n.target, str) else getattr(n.target, "__name__", str(n.target))
            a = [arg(x) for x in n.args]
            if f in ("add", "iadd", "__add__") and len(a) == 2:
                nodes.append({"name": n.name, "op": "add", "args": a})
            elif f in ("mul", "imul", "__mul__") and len(a) == 2:
                nodes.append({"name": n.name, "op": "mul", "args": a})
            elif f in ("relu", "relu_", "sigmoid", "tanh", "silu", "gelu", "hardswish"):
                nodes.append({"name": n.name, "op": f.rstrip("_"), "args": a[:1]})
            elif f == "flatten":
                if (a[1] if len(a) > 1 else n.kwargs.get("start_dim", 0)) != 1 or (a[2] if len(a) > 2 else n.kwargs.get("end_dim", -1)) != -1:
                    stop(n, f"flatten{tuple(a)} (only from dimension 1 on converts)")
                nodes.append({"name": n.name, "op": "flatten", "args": a[:1]})
            elif f == "cat" and n.kwargs.get("dim", a[1] if len(a) > 1 else 0) == 1:
                nodes.append({"name": n.name, "op": "cat", "args": list(a[0])})
            elif f == "adaptive_avg_pool2d" and a[1] in (1, (1, 1)):
                nodes.append({"name": n.name, "op": "gap", "args": a[:1]})
            else:
                stop(n, f"{f}{tuple(a)}")
        else:
            stop(n, f"{n.op} {n.target}")
    # references: the test pictures as the app will see them, and torch's outputs
    if not PICTURES:
        raise SystemExit("from_torch: no test pictures in tests/fixtures/vision (*.jpg): the check needs them")
    size, mean, std = args.size, np.array(args.mean), np.array(args.std)
    ins = np.stack([centre_square(np.asarray(Image.open(p).convert("RGB")), size) for p in PICTURES])
    x = torch.from_numpy(((ins / 255.0 - mean) / std).transpose(0, 3, 1, 2).astype(np.float32))
    with torch.no_grad():
        outs = module(x).numpy()
    work.mkdir(parents=True, exist_ok=True)
    (work / "graph.json").write_text(json.dumps({"nodes": nodes, "labels": labels}, indent=1))
    np.savez(work / "weights.npz", **{k: v.astype(np.float32) for k, v in weights.items()})
    np.savez(work / "refs.npz", inputs=ins, outputs=outs)
    print(f"traced {args.model}: {len(nodes)} steps, {len(weights)} weight arrays, {len(PICTURES)} reference pictures")


# ---------------------------------------------------------------- the building half (MAX)

def build(args):
    from max import driver
    from max.dtype import DType
    from max.engine import InferenceSession
    from max.graph import DeviceRef, Graph, TensorType, Weight, ops
    sys.path.insert(0, str(HERE))
    from packlib import write_safetensors

    dev = DeviceRef.GPU(0)
    work, out = Path(args.work), Path(args.out)
    spec = json.loads((work / "graph.json").read_text())
    wts = dict(np.load(work / "weights.npz"))
    refs = np.load(work / "refs.npz")
    size = args.size
    kept = {}

    def weight(name, arr):
        kept[name] = np.ascontiguousarray(arr, dtype=np.float32)
        return Weight(name, DType.float32, list(arr.shape), device=dev)

    def shape(x):
        return [int(d) for d in x.shape]

    def conv(x, node):
        """Conv2d (+ folded BatchNorm) as im2col patches @ a weight matrix, NHWC (MAX's own 3×3 conv kernel is ~100×
        slower on sm_86: docs/research/goal50-models.md, as scripts/packs/yolox.py does)."""
        w = wts[node["name"] + ".w"]
        f, c, kh, kw = w.shape
        (sh, sw), (ph, pw) = node["stride"], node["pad"]
        _, h, wd, _ = shape(x)
        ho, wo = (h + 2 * ph - kh) // sh + 1, (wd + 2 * pw - kw) // sw + 1
        if kh == kw == 1 and ph == pw == 0:
            p = x if sh == sw == 1 else x[:, ::sh, ::sw, :]
        else:
            xp = ops.pad(x, [0, 0, ph, ph, pw, pw, 0, 0]) if ph or pw else x
            views = [xp[:, i:i + sh * (ho - 1) + 1:sh, j:j + sw * (wo - 1) + 1:sw, :] for i in range(kh) for j in range(kw)]
            p = ops.concat(views, axis=-1) if len(views) > 1 else views[0]
        y = ops.reshape(p, [ho * wo, kh * kw * c]) @ weight(node["name"] + ".w", w.transpose(2, 3, 1, 0).reshape(kh * kw * c, f))
        y = y + weight(node["name"] + ".b", wts[node["name"] + ".b"])
        return ops.reshape(y, [1, ho, wo, f])

    def pool(x, node, kind):
        (kh, kw), (sh, sw), (ph, pw) = node["k"], node["stride"], node["pad"]
        if kind == "max":
            # padding reads as −∞ for a max (torch's rule): pad by hand with a very low number
            if ph or pw:
                x = ops.pad(x, [0, 0, ph, ph, pw, pw, 0, 0], value=-3.0e38)
            return ops.max_pool2d(x, (kh, kw), stride=(sh, sw))
        if ph or pw:  # torch's AvgPool2d counts the zero padding (count_include_pad=True)
            x = ops.pad(x, [0, 0, ph, ph, pw, pw, 0, 0])
        return ops.avg_pool2d(x, (kh, kw), stride=(sh, sw))

    def act(x, kind):
        if kind == "relu":
            return ops.relu(x)
        if kind == "relu6":
            return ops.min(ops.relu(x), 6.0)
        if kind == "silu":
            return x * ops.sigmoid(x)
        if kind == "sigmoid":
            return ops.sigmoid(x)
        if kind == "tanh":
            return ops.tanh(x)
        if kind == "gelu":
            return ops.gelu(x)
        if kind == "hardswish":
            return x * ops.min(ops.relu(x + 3.0), 6.0) / 6.0
        raise SystemExit(f"from_torch: no activation {kind}")

    mean = np.array(args.mean, dtype=np.float32)
    std = np.array(args.std, dtype=np.float32)
    with Graph(args.function, input_types=[TensorType(DType.float32, [1, size, size, 3], device=dev)]) as g:
        vals = {}
        for node in spec["nodes"]:
            op, a = node["op"], [vals[x] if isinstance(x, str) and x in vals else x for x in node.get("args", [])]
            if op == "input":
                vals[node["name"]] = (g.inputs[0].tensor * (1.0 / 255.0) - weight("input.mean", mean)) / weight("input.std", std)
            elif op == "conv":
                vals[node["name"]] = conv(a[0], node)
            elif op == "affine":
                vals[node["name"]] = a[0] * weight(node["name"] + ".scale", wts[node["name"] + ".scale"]) + weight(node["name"] + ".shift", wts[node["name"] + ".shift"])
            elif op == "linear":
                vals[node["name"]] = a[0] @ weight(node["name"] + ".w", wts[node["name"] + ".w"]) + weight(node["name"] + ".b", wts[node["name"] + ".b"])
            elif op in ("maxpool", "avgpool"):
                vals[node["name"]] = pool(a[0], node, op[:3])
            elif op == "gap":
                vals[node["name"]] = ops.mean(ops.mean(a[0], axis=1), axis=2)  # [1, 1, 1, C]
            elif op == "flatten":
                x = a[0]
                if len(x.shape) == 4 and (int(x.shape[1]) > 1 or int(x.shape[2]) > 1):
                    x = ops.permute(x, [0, 3, 1, 2])  # (torch flattens channels first)
                vals[node["name"]] = ops.reshape(x, [1, -1])
            elif op == "add":
                vals[node["name"]] = a[0] + a[1]
            elif op == "mul":
                vals[node["name"]] = a[0] * a[1]
            elif op == "cat":
                vals[node["name"]] = ops.concat(a, axis=-1)
            elif op == "output":
                y = a[0]
                g.output(ops.reshape(y, [1, -1]))
            else:
                vals[node["name"]] = act(a[0], op)
    out.mkdir(parents=True, exist_ok=True)
    name = out.name
    write_safetensors(out / f"{name}.safetensors", kept)
    gpu = driver.Accelerator(0)
    sess = InferenceSession(devices=[gpu])
    compiled = sess.compile(g)
    compiled.export_mef(str(out / f"{name}.mef"))
    model = sess.init(compiled, weights_registry=kept)
    # the check: MAX against torch on every reference picture
    worst, same = 0.0, 0
    for i, x in enumerate(refs["inputs"]):
        y = model.execute(driver.Buffer.from_numpy(x[None].copy()).to(gpu))[0].to_numpy()[0]
        t = refs["outputs"][i]
        worst = max(worst, float(np.abs(y - t).max()))
        same += int(np.argmax(y) == np.argmax(t))
    n = len(refs["inputs"])
    labels = load_labels(args.labels, spec.get("labels"), refs["outputs"].shape[1])
    (out / "labels.txt").write_text("\n".join(labels) + "\n")
    (out / "check.json").write_text(json.dumps({"pictures": n, "same_top1": same, "worst_logit": worst,
                                                    "largest_logit": float(np.abs(refs["outputs"]).max()),
                                                    "top1": [int(np.argmax(t)) for t in refs["outputs"]]}))
    manifest = {"function": args.function, "kind": "image-labels", "about": args.about or f"{args.model} (from_torch.py)",
                "input": {"size": size, "fit": "centre-square", "pixels": "RGB 0-255 NHWC float32"},
                "labels": "labels.txt", "model": args.model}
    (out / "model.json").write_text(json.dumps(manifest, indent=1) + "\n")
    print(f"   {name}: MAX matches torch on {same}/{n} pictures (top label), logits within {worst:.4f}; {len(labels)} labels")
    if same != n or worst > args.tolerance:
        raise SystemExit(f"from_torch: MAX's outputs differ from torch's (top label {same}/{n}, logits within {worst:.4f} > {args.tolerance})")


def load_labels(given, traced, k):
    if given and given != "imagenet":
        labels = [x.strip() for x in open(given) if x.strip()]
    elif traced:
        labels = list(traced)
    else:
        labels = [f"class {i}" for i in range(k)]
    if len(labels) != k:
        raise SystemExit(f"from_torch: {len(labels)} labels for {k} outputs")
    return labels


def clean_env():
    return {k: v for k, v in os.environ.items() if not k.startswith(("CONDA", "PIXI", "PYTHON", "_CE_", "_CONDA"))}


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("model")
    p.add_argument("out")
    p.add_argument("--function", required=False, default="")
    p.add_argument("--labels", default="")
    p.add_argument("--size", type=int, default=224)
    p.add_argument("--mean", type=lambda s: [float(v) for v in s.split(",")], default=[0.485, 0.456, 0.406])
    p.add_argument("--std", type=lambda s: [float(v) for v in s.split(",")], default=[0.229, 0.224, 0.225])
    p.add_argument("--about", default="")
    p.add_argument("--tolerance", type=float, default=0.05)
    p.add_argument("--trace", action="store_true", help="(the tracing half, in the models environment)")
    p.add_argument("--work", default="")
    args = p.parse_args()
    if args.trace:
        return trace(args)
    if not args.function:
        p.error("--function NAME: what a script calls it")
    args.work = args.work or str(Path(args.out).resolve() / "work")
    model = args.model if args.model.startswith("torchvision:") else str(Path(args.model.split(":")[0]).resolve()) + ":" + args.model.split(":", 1)[1]
    cmd = ["pixi", "run", "-e", "models", "python", str(Path(__file__).resolve()), model, args.out, "--trace", "--work", args.work,
           "--size", str(args.size), "--mean", ",".join(map(str, args.mean)), "--std", ",".join(map(str, args.std))]
    r = subprocess.run(cmd, cwd=ROOT, env=clean_env(), capture_output=True, text=True)
    print(r.stdout[-1500:], end="")
    if r.returncode:
        raise SystemExit(r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "the tracing half failed")
    build(args)


if __name__ == "__main__":
    main()
