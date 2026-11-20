"""The ring's own measure (goal 77, owner OK 2026-11-20): how much of the band round the rect the app says it drew the ring round
(OMX POINT/RING ring=x,y,w,h) is ring-teal, against the same screen once the ring has faded.

mojoui.pointer draws the ring RING_GAP (5) points outside the part, RING_WIDTH (2.4) wide, with a soft glow; the band read here runs
from INNER to OUTER points outside the rect (rounded as the pointer rounds it), so the part's own fill and anything beyond the glow never count. Two numbers:
  share:   band pixels teal in the frame and not teal in the faded frame, over the band's pixels (size-free: a small diagram's
           small ring reads the same as a big one's);
  control: band pixels already teal in the faded frame (a teal tile, a route line): the negative control, which must read near
           zero for the share to mean the ring.
"""

TEAL = {False: (14, 124, 134), True: (60, 196, 207)}  # the Counter family's accent, light and dark (the ring's colour)
INNER, OUTER = 2, 9  # points outside the rect: the ring line sits at 5 +- 1.2, its glow either side
FLOOR = 0.13  # the least share that counts as the ring: about half the lowest stored passing share (docs/goals/77-ring-calibration.json)
CONTROL_MAX = 0.04  # the faded frame's own teal share in the band above which the measure can't see the ring


def near_teal(c, dark):
    return sum(abs(a - b) for a, b in zip(c[:3], TEAL[dark])) < 90


def round_box(px, py, cx, cy, hw, hh, r):
    """Signed distance from (px, py) to the rounded box (mojoui.pointer._round_box): < 0 inside."""
    qx, qy = abs(px - cx) - (hw - r), abs(py - cy) - (hh - r)
    return (max(qx, 0.0) ** 2 + max(qy, 0.0) ** 2) ** 0.5 + min(max(qx, qy), 0.0) - r


def band(rect, width, height, scale=1.0):
    """The pixels INNER..OUTER points outside the rect, measured as the pointer draws its ring: from the rect rounded by
    min(half its width, half its height, 14 points), so a round marker's band is a ring, not a square with empty corners."""
    x, y, w, h = [v * scale for v in rect]
    i, o = INNER * scale, OUTER * scale
    cx, cy, hw, hh = x + w / 2, y + h / 2, max(w / 2, 4 * scale), max(h / 2, 4 * scale)
    r = min(hw, hh, 14 * scale)
    for yy in range(max(int(y - o), 0), min(int(y + h + o) + 1, height)):
        for xx in range(max(int(x - o), 0), min(int(x + w + o) + 1, width)):
            if i <= round_box(xx + 0.5, yy + 0.5, cx, cy, hw, hh, r) <= o:
                yield xx, yy


def ring_share(png, after, rect, dark, scale=1.0, offset=(0, 0)):
    """(share, control) for the ring round `rect` (in points from the ring layer's corner; `offset` is that corner in the picture,
    `scale` the picture's pixels per point)."""
    from PIL import Image
    im = Image.open(png).convert("RGB")
    ref = Image.open(after).convert("RGB")
    if ref.size != im.size:
        return 0.0, 1.0
    px, rp = im.load(), ref.load()
    r = (rect[0] + offset[0], rect[1] + offset[1], rect[2], rect[3])
    n = hits = ctrl = 0
    for xx, yy in band(r, im.width, im.height, scale):
        n += 1
        was = near_teal(rp[xx, yy], dark)
        ctrl += was
        hits += near_teal(px[xx, yy], dark) and not was
    return round(hits / max(n, 1), 3), round(ctrl / max(n, 1), 3)


def parse_rect(text):
    import re
    m = re.search(r"ring=(-?\d+),(-?\d+),(\d+),(\d+)", str(text))
    return tuple(int(v) for v in m.groups()) if m else None
