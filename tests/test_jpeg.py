"""mojoui.jpeg's pictures decoded by Pillow (libjpeg): the right size, and as close to the picture as libjpeg's own encoder at the
same settings (quality 85, 4:2:0): PSNR no more than 0.5 dB under it."""
import io
import sys
from pathlib import Path
import numpy as np
from PIL import Image
out = Path(sys.argv[1])
bad = 0
psnr = lambda x, o: 99.0 if ((x - o) ** 2).mean() == 0 else 10 * np.log10(255 ** 2 / ((x - o) ** 2).mean())
for j in sorted(out.glob("jpeg-*.jpg")):
    ours = np.asarray(Image.open(j).convert("RGB"), dtype=np.float64)
    src = Image.open(j.with_suffix(".png")).convert("RGB")
    o = np.asarray(src, dtype=np.float64)
    b = io.BytesIO()
    src.save(b, "JPEG", quality=85, subsampling=2)
    lib = np.asarray(Image.open(io.BytesIO(b.getvalue())).convert("RGB"), dtype=np.float64)
    ok = ours.shape == o.shape and psnr(ours, o) >= psnr(lib, o) - 0.5
    bad += not ok
    print(f"{'ok ' if ok else 'FAIL'} {j.name} {ours.shape} PSNR {psnr(ours, o):.1f} dB (libjpeg {psnr(lib, o):.1f}), {j.stat().st_size} bytes (libjpeg {len(b.getvalue())})")
sys.exit(1 if bad else 0)
