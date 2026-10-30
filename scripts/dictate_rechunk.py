"""Goal 43 review (D-1416): onnx-community's fp32 Whisper encoder keeps its 2.55 GB of weights in ONE external-data
file, and Chromium can't allocate one ArrayBuffer that big (`RangeError: Array buffer allocation failed`, measured by the
race page's fetchtest), so transformers.js can never load it in a browser as published. transformers.js does load
external data split into numbered files (encoder_model.onnx_data, encoder_model.onnx_data_1, ...: its
use_external_data_format = N), so this rewrites the same tensors, byte for byte, into files under 1.9 GB each, next to
a copy of the graph whose tensors point at them. Nothing about the weights changes (each tensor's bytes are checked).

    pixi exec --spec onnx --spec python=3.12 python scripts/dictate_rechunk.py SRC_DIR DST_DIR

SRC_DIR: the downloaded model's onnx/ folder; DST_DIR gets encoder_model.onnx + encoder_model.onnx_data[_N].
"""

import hashlib
import sys
from pathlib import Path

import onnx

LIMIT = 1_900_000_000
NAME = "encoder_model.onnx"


def main(src, dst):
    src, dst = Path(src), Path(dst)
    dst.mkdir(parents=True, exist_ok=True)
    model = onnx.load(str(src / NAME), load_external_data=False)
    files, used, out = [], LIMIT, None
    handles = {}
    moved = 0
    for t in model.graph.initializer:
        if t.data_location != onnx.TensorProto.EXTERNAL:
            continue
        info = {e.key: e.value for e in t.external_data}
        fsrc = handles.setdefault(info["location"], open(src / info["location"], "rb"))
        fsrc.seek(int(info.get("offset", 0)))
        data = fsrc.read(int(info["length"]))
        assert len(data) == int(info["length"])
        if used + len(data) > LIMIT:
            name = NAME + "_data" + ("" if not files else f"_{len(files)}")
            out = open(dst / name, "wb")
            files.append(name)
            used = 0
        pad = (-used) % 64  # (aligned as onnx writes it)
        out.write(b"\0" * pad)
        used += pad
        offset = used
        out.write(data)
        used += len(data)
        del t.external_data[:]
        for k, v in (("location", files[-1]), ("offset", str(offset)), ("length", str(len(data)))):
            e = t.external_data.add()
            e.key, e.value = k, v
        moved += len(data)
        # check: the bytes just written are the source's
        out.flush()
        with open(dst / files[-1], "rb") as chk:
            chk.seek(offset)
            assert hashlib.sha256(chk.read(len(data))).digest() == hashlib.sha256(data).digest()
    if out:
        out.close()
    onnx.save(model, str(dst / NAME))
    for f in handles.values():
        f.close()
    print(f"{moved} bytes of tensors into {len(files)} files: " + ", ".join(f"{n} {(dst / n).stat().st_size}" for n in files))


if __name__ == "__main__":
    main(*sys.argv[1:3])
