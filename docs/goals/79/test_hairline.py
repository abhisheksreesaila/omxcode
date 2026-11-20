"""D-7920's hairline rule (79-check.hairline_color) on synthetic pictures at the Linux test screen's 1.6×: a 1 CSS px line
drawn at its exact fractional coverage, the same ink spread over four rows (Chromium's resampled layer), no line at all,
and a line twice as thick as its box. The first two must read the line's colour (within 2 levels); the last two must not
(more than 4 levels off: the fill bar), so a missing or doubled divider can't pass.
    pixi run python docs/goals/79/test_hairline.py        → "hairline: ok"
"""
import importlib.util
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("check79", ROOT / "docs/goals/79-check.py")
check = importlib.util.module_from_spec(spec)
sys.argv = [sys.argv[0]]
spec.loader.exec_module(check)

DPR = 1.6
BG = np.array([236.0, 231.0, 221.0])
LINE = np.array([226.0, 219.0, 205.0])
BOX = (20.0, 10.25, 100.0, 1.0)  # x, y, w, h in logical px: a 1 px horizontal divider


def picture(coverages, start=16):
    """A 40 × 260 device-px picture with rows from `start` covered by the line at these coverages."""
    img = np.tile(BG, (40, 260, 1))
    for i, c in enumerate(coverages):
        img[start + i] = BG * (1 - c) + LINE * c
    return np.clip(np.round(img), 0, 255).astype(np.uint8)


def off(c):
    return max(abs(a - b) for a, b in zip(c, LINE))


def main():
    # the box's device rows: 10.25 × 1.6 = 16.4 → 18.0 (1.6 rows)
    exact = check.hairline_color(picture([0.6, 1.0]), BOX, DPR)
    spread = check.hairline_color(picture([0.14, 0.66, 0.6, 0.2], 15), BOX, DPR)  # (as measured: rows 706–709 for a box at 707.2)
    missing = check.hairline_color(picture([]), BOX, DPR)
    double = check.hairline_color(picture([1.0, 1.0, 1.0, 0.2], 15), BOX, DPR)
    print(f"  exact 1 px: {exact} (off {off(exact):.0f}); spread over 4 rows: {spread} (off {off(spread):.0f}); "
          f"missing: {missing} (off {off(missing):.0f}); twice as thick: {double} (off {off(double):.0f})")
    assert off(exact) <= 2, "a 1 px line at its exact coverage must read its colour"
    assert off(spread) <= 2, "the same ink spread over four rows must read the same colour"
    assert off(missing) > 4, "a missing line must not pass the 4-level fill bar"
    assert off(double) > 4, "a line twice its box's thickness must not pass the 4-level fill bar"
    print("hairline: ok")


if __name__ == "__main__":
    main()
