"""Shared build-side helpers for scripts/packs/*.py (Python on our side only; apps load the packs from Mojo)."""
import json
import struct

import numpy as np

_ST_DTYPES = {np.dtype("float32"): "F32", np.dtype("int64"): "I64", np.dtype("int32"): "I32", np.dtype("uint8"): "U8"}


def write_safetensors(path, tensors):
    """A .safetensors file from {name: numpy array} (the format's header written by hand: numpy only)."""
    hdr, off, blobs = {}, 0, []
    for k, v in tensors.items():
        v = np.ascontiguousarray(v)
        b = v.tobytes()
        hdr[k] = {"dtype": _ST_DTYPES[v.dtype], "shape": list(v.shape), "data_offsets": [off, off + len(b)]}
        off += len(b)
        blobs.append(b)
    h = json.dumps(hdr).encode()
    h += b" " * ((8 - len(h) % 8) % 8)
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(h)) + h + b"".join(blobs))


def omx_cache():
    """Where the pack builders keep what they download: $OMX_CACHE, else ~/.cache/omxcode (goal 59)."""
    import os
    import pathlib
    return pathlib.Path(os.environ.get("OMX_CACHE", pathlib.Path.home() / ".cache/omxcode"))


def hf_hub():
    """The Hugging Face cache's hub folder ($HF_HOME/hub, else ~/.cache/huggingface/hub), as huggingface_hub finds it."""
    import os
    import pathlib
    return pathlib.Path(os.environ.get("HF_HOME", pathlib.Path.home() / ".cache/huggingface")) / "hub"


def fleet_csv(root):
    """A fleet.csv to take reference texts from: the demo's (scripts/setup), else goal 47's full set."""
    for p in (root / "build/demo/fleet.csv", root / "build/g47/full/fleet.csv"):
        if p.exists():
            return p
    raise SystemExit("no fleet.csv: run scripts/setup (or scripts/fetch_demo.py build/demo) first")


def fetch_pinned(url, dst, sha256):
    """url into dst once, checked against its SHA-256 (a mismatch is an error, and nothing is left behind)."""
    import hashlib
    import urllib.request
    if dst.exists():
        return dst
    dst.parent.mkdir(parents=True, exist_ok=True)
    part = dst.with_name(dst.name + ".part")
    urllib.request.urlretrieve(url, part)
    got = hashlib.sha256(part.read_bytes()).hexdigest()
    if got != sha256:
        part.unlink()
        raise SystemExit(f"{url}: SHA-256 {got}, expected {sha256}")
    part.rename(dst)
    return dst
