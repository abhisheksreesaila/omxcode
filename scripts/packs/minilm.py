#!/usr/bin/env python3
"""MiniLM-L6 (sentence-transformers/all-MiniLM-L6-v2, Apache-2.0) as a pack, for mojoui.embed (goal 51 M1). Build side.

    pixi run python scripts/packs/minilm.py build/packs/minilm

Writes minilm.mef (MAX's BERT graph, GPU, float32; input0 token ids int64 [batch, seq], input1 mask float32
[batch, seq] → output0 the mean-pooled embedding [batch, 384]), minilm.safetensors (its weights, by the graph's
names), vocab.txt; and the references the Mojo test compares with: texts.txt (200 distinct task texts of the robot
fleet), ref_ids.txt (Hugging Face's own tokenizer's ids, one line each, from the `models` environment) and
ref_vectors.f32 (this pack's embeddings of those ids in Python, L2-normalised, 200 × 384).
The model comes from the Hugging Face cache (~/.cache/huggingface/hub) or is downloaded there.
"""
import csv
import glob
import json
import os
import pathlib
import shutil
import subprocess
import sys
import types
import urllib.request

import numpy as np
from max import driver
from max.dtype import DType
from max.engine import InferenceSession
from max.graph import DeviceRef
from max.graph.weights import load_weights

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from bert_graph import build_graph  # noqa: E402
from packlib import write_safetensors  # noqa: E402

REPO = "sentence-transformers/all-MiniLM-L6-v2"
FILES = ("config.json", "model.safetensors", "vocab.txt", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json")
ROOT = HERE.parents[1]


def clean_env():
    """This environment's variables without the default pixi environment's own (CONDA_*, PIXI_*, PYTHON*), so a nested
    `pixi run -e models` activates its own."""
    return {k: v for k, v in os.environ.items() if not k.startswith(("CONDA", "PIXI", "PYTHON", "_CE_", "_CONDA"))}


def snapshot():
    found = glob.glob(os.path.expanduser("~/.cache/huggingface/hub/models--sentence-transformers--all-MiniLM-L6-v2/snapshots/*/"))
    if found:
        return pathlib.Path(found[0])
    d = pathlib.Path(os.path.expanduser("~/.cache/omxcode/minilm"))
    d.mkdir(parents=True, exist_ok=True)
    for f in FILES:
        if not (d / f).exists():
            urllib.request.urlretrieve(f"https://huggingface.co/{REPO}/resolve/main/{f}", d / f)
    return d


def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "build/packs/minilm")
    out.mkdir(parents=True, exist_ok=True)
    snap = snapshot()
    hf = types.SimpleNamespace(**json.load(open(snap / "config.json")))
    cfg = types.SimpleNamespace(dtype=DType.float32, device=DeviceRef.GPU(0), pool_embeddings=True, huggingface_config=hf, max_seq_len=512)
    w = load_weights([snap / "model.safetensors"])
    sd = {k.replace(".LayerNorm.", ".layer_norm."): v.data() for k, v in w.items() if ".position_ids" not in k and not k.startswith("pooler.")}
    arrays = {k: np.from_dlpack(v) if not isinstance(v, np.ndarray) else v for k, v in sd.items()}
    write_safetensors(out / "minilm.safetensors", {k: np.asarray(v, dtype=np.float32) for k, v in arrays.items()})
    shutil.copyfile(snap / "vocab.txt", out / "vocab.txt")
    gpu = driver.Accelerator(0)
    sess = InferenceSession(devices=[gpu])
    graph = build_graph(cfg, sd)
    compiled = sess.compile(graph)
    compiled.export_mef(str(out / "minilm.mef"))
    model = sess.init(compiled, weights_registry=sd)

    # references: 200 distinct task texts, HF's tokenizer's ids, this pack's vectors
    texts = []
    for r in csv.DictReader(open(ROOT / "build/g47/full/fleet.csv")):
        t = r["task"].strip()
        if t and t not in texts:
            texts.append(t)
        if len(texts) == 200:
            break
    (out / "texts.txt").write_text("\n".join(texts) + "\n")
    tok = subprocess.run(["pixi", "run", "-e", "models", "python", "-c",
                          "import sys; from transformers import AutoTokenizer; t = AutoTokenizer.from_pretrained(sys.argv[1]);"
                          "[print(' '.join(map(str, t(l.rstrip(chr(10)))['input_ids']))) for l in open(sys.argv[2])]",
                          str(snap), str((out / "texts.txt").resolve())], cwd=ROOT, capture_output=True, text=True, env=clean_env())
    if tok.returncode:
        raise SystemExit("the reference tokenizer (pixi -e models) failed: " + tok.stderr[-1500:])
    ids = [list(map(int, l.split())) for l in tok.stdout.strip().splitlines()]
    assert len(ids) == len(texts), (len(ids), len(texts))
    (out / "ref_ids.txt").write_text("\n".join(" ".join(map(str, x)) for x in ids) + "\n")
    L = max(map(len, ids))
    a = np.zeros((len(ids), L), np.int64)
    m = np.zeros((len(ids), L), np.float32)
    for i, x in enumerate(ids):
        a[i, : len(x)] = x
        m[i, : len(x)] = 1
    e = model.execute(driver.Buffer.from_numpy(a).to(gpu), driver.Buffer.from_numpy(m).to(gpu))[0].to(driver.CPU()).to_numpy()
    e = (e / np.linalg.norm(e, axis=1, keepdims=True)).astype(np.float32)
    e.tofile(out / "ref_vectors.f32")
    print(f"minilm pack: {out}; {len(texts)} references, longest {L} tokens, vectors {e.shape}")


if __name__ == "__main__":
    main()
