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
