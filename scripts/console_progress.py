"""Side-by-side progress images for goal 33 M7: the original (left) beside ours (right), one per screen and size.

    pixi run python scripts/console_progress.py [out_dir]      # default /tmp/g33-progress

Reads docs/goals/33/orig/a/<screen>-<w>x<h>.png and docs/goals/33/ours/<screen>-<w>x<h>.png (M7's shots, or any newer
ones written there), writes <out_dir>/<screen>-<w>.png with a dark strip on top naming the screen and size and the share
of pixels equal (console_side.differing, M0's tolerance). 1440 images are halved.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import console_side  # noqa: E402


def make(orig, ours, out, label):
    from PIL import Image, ImageDraw, ImageFont
    a, b = Image.open(orig).convert("RGB"), Image.open(ours).convert("RGB")
    share = 1 - console_side.differing(orig, ours)
    if a.width > 1000:
        a = a.resize((a.width // 2, a.height // 2), Image.LANCZOS)
        b = b.resize((b.width // 2, b.height // 2), Image.LANCZOS)
    strip, gap = 34, 8
    img = Image.new("RGB", (a.width + b.width + gap, max(a.height, b.height) + strip), (24, 24, 28))
    img.paste(a, (0, strip))
    img.paste(b, (a.width + gap, strip))
    try:
        font = ImageFont.truetype(str(ROOT / "mojoui/hosts/static/fonts/Geist-Variable.ttf"), 15)
    except OSError:
        font = ImageFont.load_default()
    ImageDraw.Draw(img).text((10, 8), f"{label}  left: original (JS)  right: omxcode (Mojo)  {share * 100:.1f}% pixels equal", fill=(235, 235, 240), font=font)
    img.save(out)
    return share


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/g33-progress")
    out.mkdir(parents=True, exist_ok=True)
    for name, _ in console_side.SCREENS:
        for w, h in console_side.SIZES:
            orig = console_side.OUT / "orig" / "a" / f"{name}-{w}x{h}.png"
            ours = console_side.OUT / "ours" / f"{name}-{w}x{h}.png"
            if orig.exists() and ours.exists():
                share = make(orig, ours, out / f"{name}-{w}.png", f"{name} {w}×{h}")
                print(f"{name} {w}: {share:.1%}")


if __name__ == "__main__":
    main()
