"""mojoui.ocr_torch: backend of mojoui/ocrmodel.mojo, docTR (Apache-2.0, PyTorch) in the same process (goal 41 M7,
D-1102). Mojo calls it through `std.python`; nothing here knows about any app or document.

    ocr = Reader("db_resnet50+crnn_vgg16_bn", device="cuda")
    words = ocr.read_address(addr, width, height)
    # one flat list of floats, 5 per word: x, y, w, h (pixels of the picture), confidence; ocr.texts: the words' text

Pictures arrive as an address of RGBA bytes (row by row, R first, as mojoui.pdfsource and mojoui.video give them);
numpy wraps them without a copy and docTR gets the RGB channels. Weights come from docTR's cache (~/.cache/doctr).
"""

import ctypes
import time

import numpy as np
import torch


def from_address(addr, width, height):
    """A (height, width, 4) uint8 numpy view of `addr` (no copy). The caller keeps the memory alive."""
    buf = (ctypes.c_uint8 * (width * height * 4)).from_address(int(addr))
    return np.frombuffer(buf, dtype=np.uint8).reshape(height, width, 4)


class Reader:
    """Text detection + recognition: words with boxes and confidences. `name`: "<detector>+<recognizer>" (docTR
    architecture names)."""

    def __init__(self, name="db_resnet50+crnn_vgg16_bn", device="cuda"):
        from doctr.models import ocr_predictor

        t0 = time.perf_counter()
        det, _, reco = name.partition("+")
        self.device = torch.device(device if (device == "cpu" or torch.cuda.is_available()) else "cpu")
        self.model = ocr_predictor(det_arch=det, reco_arch=reco or "crnn_vgg16_bn", pretrained=True,
                                   assume_straight_pages=True).to(self.device).eval()
        self.load_ms = (time.perf_counter() - t0) * 1000
        self.model_ms = 0.0
        self.texts = []

    @torch.inference_mode()
    def read_address(self, addr, width, height):
        img = np.ascontiguousarray(from_address(addr, width, height)[..., :3])
        t0 = time.perf_counter()
        doc = self.model([img])
        if self.device.type == "cuda":
            torch.cuda.synchronize()
        self.model_ms = (time.perf_counter() - t0) * 1000
        out, texts = [], []
        page = doc.pages[0]
        for block in page.blocks:
            for line in block.lines:
                for w in line.words:
                    (x0, y0), (x1, y1) = w.geometry
                    out += [x0 * width, y0 * height, (x1 - x0) * width, (y1 - y0) * height, float(w.confidence)]
                    texts.append(w.value)
        self.texts = texts
        return out

    def vram_mb(self):
        return torch.cuda.max_memory_allocated() / 1e6 if self.device.type == "cuda" else 0.0
