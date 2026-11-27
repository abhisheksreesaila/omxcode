"""tests/test_pdfwriter.mojo's PDF: valid (qpdf --check), two pages of 645x810 pt, its words found by pdftotext (as text, not pixels:
the file holds no picture of them), and drawn: the page rasterized has dark glyph pixels where the words are."""
import subprocess
import sys
from pathlib import Path
import numpy as np
from PIL import Image
pdf = Path(sys.argv[1]) / "test.pdf"
bad = []
q = subprocess.run(["qpdf", "--check", str(pdf)], capture_output=True, text=True)
if q.returncode != 0:
    bad.append("qpdf: " + (q.stdout + q.stderr)[-300:])
info = subprocess.run(["pdfinfo", str(pdf)], capture_output=True, text=True).stdout
import re
if not re.search(r"^Pages:\s+2$", info, re.M) or "645 x 810 pts" not in info:
    bad.append("pdfinfo: " + info.replace("\n", " | ")[:300])
p1 = subprocess.run(["pdftotext", "-f", "1", "-l", "1", str(pdf), "-"], capture_output=True, text=True).stdout
p2 = subprocess.run(["pdftotext", "-f", "2", "-l", "2", str(pdf), "-"], capture_output=True, text=True).stdout
for words in ["Garden plan: beds by the south wall", "Tomatoes, Basil and Marigolds", "漢字", "नमस्ते"]:
    if "नमस्तेते" in p1:
        bad.append("a cluster's letters repeated (नमस्तेते)")
    if words not in p1:
        bad.append(f"page 1 lacks {words!r}: {p1!r}")
if "Second page words" not in p2:
    bad.append(f"page 2 lacks its words: {p2!r}")
subprocess.run(["pdftoppm", "-r", "96", "-png", "-f", "1", "-l", "1", str(pdf), str(pdf.with_suffix(""))], check=True)
img = np.asarray(Image.open(str(pdf.with_suffix("")) + "-1.png").convert("L"), dtype=np.float64)
band = img[95:125, 80:500]  # (the first line of words, 96 dpi = layout px)
if (band < 100).sum() < 300:
    bad.append(f"the words aren't drawn (dark pixels {(band < 100).sum()})")
print("\n".join(bad) if bad else "test_pdfwriter.py: valid, 2 pages 645x810, words found and drawn")
sys.exit(1 if bad else 0)
