"""examples/agentchat/pictures/tagus.jpg: an illustration (drawn here, no photo, no licence to track) of the Tagus at
sunset from a viewpoint: sky, sun, the river, a suspension bridge, roofs. The agent chat's album holds it (mojoui.album).

  pixi run python scripts/make_tagus.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

W, H = 1200, 640
OUT = Path(__file__).resolve().parent.parent / "examples" / "agentchat" / "pictures" / "tagus.jpg"


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


img = Image.new("RGB", (W, H))
d = ImageDraw.Draw(img)
horizon = int(H * 0.56)
for y in range(horizon):  # sky: dusk blue down to apricot
    t = y / horizon
    d.line([(0, y), (W, y)], fill=lerp((58, 74, 128), (246, 178, 122), t ** 1.4))
glow = Image.new("L", (W, H), 0)
ImageDraw.Draw(glow).ellipse([W * 0.62 - 180, horizon - 230, W * 0.62 + 180, horizon + 130], fill=150)
img.paste((255, 214, 150), mask=glow.filter(ImageFilter.GaussianBlur(70)))
d = ImageDraw.Draw(img)
d.ellipse([W * 0.62 - 46, horizon - 98, W * 0.62 + 46, horizon - 6], fill=(255, 236, 196))
for y in range(horizon, H):  # the river, darker toward us, the sun's path on it
    t = (y - horizon) / (H - horizon)
    d.line([(0, y), (W, y)], fill=lerp((214, 146, 112), (44, 58, 96), t ** 0.7))
for k in range(26):
    y = horizon + 6 + k * 7
    half = 60 - k * 2
    d.line([(W * 0.62 - half, y), (W * 0.62 + half, y)], fill=(255, 220, 170), width=2)
far = (92, 70, 92)
d.polygon([(0, horizon), (0, horizon - 26), (260, horizon - 40), (560, horizon - 18), (W, horizon - 30), (W, horizon)], fill=far)
deck = horizon - 34
d.line([(80, deck), (W - 60, deck)], fill=(120, 52, 48), width=6)  # the bridge
for tx in (330, 830):
    d.rectangle([tx - 7, deck - 150, tx + 7, deck + 40], fill=(132, 50, 44))
    d.rectangle([tx - 15, deck - 110, tx + 15, deck - 102], fill=(132, 50, 44))
tops = deck - 150
for a, b in ((80, 330), (330, 830), (830, W - 60)):  # its cables: up to the towers at the ends, a sag between them
    pts = []
    for i in range(41):
        t = i / 40
        y = tops + 110 * 4 * t * (1 - t) if a == 330 else (tops + 150 * (1 - t) if a == 80 else tops + 150 * t)
        pts.append((a + (b - a) * t, y))
    d.line(pts, fill=(132, 50, 44), width=3)
roofs = [(0, 60), (90, 40), (170, 70), (260, 50), (340, 85), (430, 55), (520, 75), (610, 45), (700, 80), (800, 60), (900, 90), (1010, 55), (1100, 75), (1200, 60)]
base = H
for (x0, h0), (x1, h1) in zip(roofs, roofs[1:]):  # roofs in the foreground: terracotta and lime-wash
    top = base - 120 - h0
    d.rectangle([x0, top + 22, x1, base], fill=(70, 46, 52))
    d.polygon([(x0 - 6, top + 24), ((x0 + x1) / 2, top), (x1 + 6, top + 24)], fill=(176, 84, 58))
    for wx in range(int(x0) + 14, int(x1) - 10, 26):
        d.rectangle([wx, top + 44, wx + 9, top + 58], fill=(255, 204, 140))
img = img.filter(ImageFilter.SMOOTH)
OUT.parent.mkdir(parents=True, exist_ok=True)
img.save(OUT, quality=86)
print(OUT, img.size, OUT.stat().st_size)
