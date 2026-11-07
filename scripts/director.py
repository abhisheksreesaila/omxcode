"""The director (goal 61): what every omxplorer clip is made of, drawn with PIL from a raw take (scripts/covers.Rec) and
encoded by ffmpeg. Scenes take their rectangles from the app at record time (bounds, regions), never fixed screen
coordinates, so a clip follows the layout.

    from director import *                 # configure(win) first: the take's pixel size
    still(card("Title", sub="…"), 2.4)      # title / end cards
    Canvas(frame, cam, stage)               # a camera on a raw frame; any shape fitted into `stage` (a lifted card)
    caption(im, "One idea per scene.")      # the lower third, first
    write(frames, path, check_dir)          # 1920×1080, 30 fps, H.264, a PNG for each named check frame

Used by scripts/robotclip.py (the robot story) and scripts/clipshots.py (the island, the sentence, your own model).
"""
import json
import math
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = (1920, 1080)
FPS = 30
FONT = ROOT / "mojoui/hosts/static/fonts/Geist-Variable.ttf"
# Liquid dark (themes/liquid.mojo, liquid_dark_palette): page, card, hairline, ink, ink2, accent, warn (the link colour)
PAGE, CARD, LINE, INK, INK2 = (18, 21, 27), (27, 31, 39), (50, 57, 70), (241, 244, 249), (196, 202, 214)
ACCENT, WARN, GOOD = (60, 196, 207), (251, 191, 36), (126, 210, 176)  # (GOOD: the grid cursor's outline as drawn on a dark card)
WIN = (3840, 2160)  # the take's pixels (configure)


def configure(win):
    """The raw take's size in pixels, for raw_frames, fit169 and grown."""
    global WIN
    WIN = tuple(win)


def font(size, weight=600):
    f = ImageFont.truetype(str(FONT), size)
    try:
        f.set_variation_by_axes([weight])
    except Exception:
        pass
    return f


def ease(u):
    u = min(max(u, 0.0), 1.0)
    return u * u * (3 - 2 * u)


def fit169(rect, pad=0.06, win=None):
    """A rectangle grown to 16:9 around its centre (plus a margin), kept inside the window."""
    win = win or WIN
    x, y, w, h = rect
    w, h = w * (1 + 2 * pad), h * (1 + 2 * pad)
    if w / h > 16 / 9:
        h = w * 9 / 16
    else:
        w = h * 16 / 9
    w, h = min(w, win[0]), min(h, win[1])
    cx, cy = rect[0] + rect[2] / 2, rect[1] + rect[3] / 2
    x0 = min(max(cx - w / 2, 0), win[0] - w)
    y0 = min(max(cy - h / 2, 0), win[1] - h)
    return [x0, y0, w, h]


def grown(rect, px):
    """rect with a margin of px window pixels round it, kept inside the window (a lifted card keeps its own edge)."""
    x0, y0 = max(rect[0] - px, 0), max(rect[1] - px, 0)
    x1, y1 = min(rect[0] + rect[2] + px, WIN[0]), min(rect[1] + rect[3] + px, WIN[1])
    return [x0, y0, x1 - x0, y1 - y0]


def union(*rs):
    x0 = min(r[0] for r in rs)
    y0 = min(r[1] for r in rs)
    x1 = max(r[0] + r[2] for r in rs)
    y1 = max(r[1] + r[3] for r in rs)
    return [x0, y0, x1 - x0, y1 - y0]


def lerp_rect(a, b, u):
    return [a[k] + (b[k] - a[k]) * u for k in range(4)]


def raw_frames(raw, t0, t1):
    """The raw take's frames from t0 to t1 (seconds), as RGB arrays."""
    w, h = WIN
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", f"{max(t0, 0):.3f}", "-i", str(raw), "-t", f"{max(t1 - t0, 0.04):.3f}", "-vf", f"fps={FPS}",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    n = w * h * 3
    while True:
        b = p.stdout.read(n)
        if len(b) < n:
            break
        yield np.frombuffer(b, np.uint8).reshape(h, w, 3)
    p.wait()


def raw_at(raw, t):
    return next(raw_frames(raw, t, t + 0.1))


FULL_STAGE = [0, 0, OUT[0], OUT[1]]
STAGE = [56, 44, OUT[0] - 112, OUT[1] - 300]  # (a lifted card's room: above the caption, a margin round it)


def lerp_stage(u):
    return lerp_rect(FULL_STAGE, STAGE, u)


class Canvas:
    """One output frame: the camera's view of a raw frame, then overlays drawn in window coordinates. The view is fitted
    into `stage` (output pixels; the whole frame by default): a 16:9 camera fills it as before, any other shape (a tall
    tile, a narrow card: goal 61's tiled shell) sits centred on the page colour, so a card of any shape can fill the frame."""

    def __init__(self, frame, cam, stage=None):
        self.cam = cam
        x, y, w, h = cam
        sx, sy, sw, sh = stage or FULL_STAGE
        self.k = min(sw / w, sh / h)
        dw, dh = max(1, int(round(w * self.k))), max(1, int(round(h * self.k)))
        self.ox, self.oy = sx + (sw - dw) / 2, sy + (sh - dh) / 2
        view = Image.fromarray(frame).crop((int(x), int(y), int(x + w), int(y + h))).resize((dw, dh), Image.LANCZOS).convert("RGBA")
        if (dw, dh) == OUT:
            self.im = view
        else:
            self.im = Image.new("RGBA", OUT, PAGE + (255,))
            self.im.paste(view, (int(self.ox), int(self.oy)))

    def at(self, px, py):
        return ((px - self.cam[0]) * self.k + self.ox, (py - self.cam[1]) * self.k + self.oy)

    def box(self, rect, colour, width=6, glow=0.0, radius=12):
        x0, y0 = self.at(rect[0], rect[1])
        x1, y1 = self.at(rect[0] + rect[2], rect[1] + rect[3])
        layer = Image.new("RGBA", OUT, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        if glow > 0:
            g = Image.new("RGBA", OUT, (0, 0, 0, 0))
            ImageDraw.Draw(g).rounded_rectangle([x0, y0, x1, y1], radius, outline=colour + (int(200 * glow),), width=width * 4)
            layer = Image.alpha_composite(layer, g.filter(ImageFilter.GaussianBlur(14)))
            d = ImageDraw.Draw(layer)
        d.rounded_rectangle([x0, y0, x1, y1], radius, outline=colour + (255,), width=width)
        self.im = Image.alpha_composite(self.im, layer)
        return ((x0 + x1) / 2, y0, (x0 + x1) / 2, y1, x0, x1)

    def ring(self, cx, cy, r, colour, width=7, glow=0.0):
        x, y = self.at(cx, cy)
        rr = r * self.k
        layer = Image.new("RGBA", OUT, (0, 0, 0, 0))
        if glow > 0:
            g = Image.new("RGBA", OUT, (0, 0, 0, 0))
            ImageDraw.Draw(g).ellipse([x - rr, y - rr, x + rr, y + rr], outline=colour + (int(220 * glow),), width=width * 4)
            layer = Image.alpha_composite(layer, g.filter(ImageFilter.GaussianBlur(16)))
        ImageDraw.Draw(layer).ellipse([x - rr, y - rr, x + rr, y + rr], outline=colour + (255,), width=width)
        self.im = Image.alpha_composite(self.im, layer)
        return x, y, rr

    def line(self, a, b, colour, width=5):
        layer = Image.new("RGBA", OUT, (0, 0, 0, 0))
        ImageDraw.Draw(layer).line([a, b], fill=colour + (235,), width=width)
        self.im = Image.alpha_composite(self.im, layer)

    def label(self, text, x, y, colour):
        """A small tag (a chip) at output pixels x, y: dark, a coloured edge, white words."""
        f = font(36, 600)
        w = f.getlength(text)
        x = min(max(x, 16), OUT[0] - w - 36 - 16)  # (kept inside the frame: a mark near the edge mustn't push its tag off it)
        y = min(max(y, 16), OUT[1] - 58 - 16)
        layer = Image.new("RGBA", OUT, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        d.rounded_rectangle([x, y, x + w + 36, y + 58], 14, fill=PAGE + (225,), outline=colour + (255,), width=3)
        d.text((x + 18, y + 9), text, font=f, fill=INK)
        self.im = Image.alpha_composite(self.im, layer)


def caption(im, text, alpha=1.0, sub=None):
    """The lower third: a semi-opaque Liquid-dark bar, one line of white Geist, a teal tick; centred near the bottom."""
    if alpha <= 0:
        return im
    f = font(58, 600)
    w = f.getlength(text)
    bw, bh = w + 120, 112
    x0, y0 = (OUT[0] - bw) / 2, OUT[1] - 96 - bh
    layer = Image.new("RGBA", OUT, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    a = int(255 * alpha)
    d.rounded_rectangle([x0, y0, x0 + bw, y0 + bh], 28, fill=PAGE + (int(214 * alpha),), outline=LINE + (a,), width=2)
    d.rounded_rectangle([x0 + 34, y0 + 30, x0 + 42, y0 + bh - 30], 4, fill=ACCENT + (a,))
    d.text((x0 + 68, y0 + 22), text, font=f, fill=INK + (a,))
    return Image.alpha_composite(im, layer)


def card(title, sub=None, small=None, glow=ACCENT):
    """A full-frame Liquid-dark title card: big words, an optional line under them, a soft glow behind."""
    im = Image.new("RGBA", OUT, PAGE + (255,))
    g = Image.new("RGBA", OUT, (0, 0, 0, 0))
    ImageDraw.Draw(g).ellipse([OUT[0] * 0.2, OUT[1] * 0.05, OUT[0] * 0.8, OUT[1] * 0.95], fill=glow + (34,))
    im = Image.alpha_composite(im, g.filter(ImageFilter.GaussianBlur(160)))
    d = ImageDraw.Draw(im)
    lines = title if isinstance(title, list) else [title]
    f = font(96 if len(lines) == 1 else 70, 650)
    total = len(lines) * (f.size * 1.3) + (90 if sub else 0) + (70 if small else 0)
    y = (OUT[1] - total) / 2
    for ln in lines:
        d.text(((OUT[0] - f.getlength(ln)) / 2, y), ln, font=f, fill=INK)
        y += f.size * 1.3
    if sub:
        fs = font(46, 500)
        d.text(((OUT[0] - fs.getlength(sub)) / 2, y + 24), sub, font=fs, fill=ACCENT)
        y += 90
    if small:
        fm = font(38, 500)
        d.text(((OUT[0] - fm.getlength(small)) / 2, y + 30), small, font=fm, fill=INK2)
    return im


def spotlight(im, rect_out, alpha):
    """Everything outside rect_out (output pixels) dimmed: the eye goes to the subject."""
    if alpha <= 0:
        return im
    layer = Image.new("RGBA", OUT, PAGE + (int(150 * alpha),))
    ImageDraw.Draw(layer).rounded_rectangle([rect_out[0], rect_out[1], rect_out[2], rect_out[3]], 18, fill=(0, 0, 0, 0))
    return Image.alpha_composite(im, layer)


def write(frames, path, check_dir=None):
    p = subprocess.Popen(["ffmpeg", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{OUT[0]}x{OUT[1]}", "-r", str(FPS), "-i", "-",
                          "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(path)],
                         stdin=subprocess.PIPE)
    for im, check in frames:
        rgb = im.convert("RGB")
        p.stdin.write(rgb.tobytes())
        if check and check_dir:
            rgb.save(check_dir / f"{check}.png")
    p.stdin.close()
    p.wait()
    print(f"{path}: {len(frames) / FPS:.1f} s")


