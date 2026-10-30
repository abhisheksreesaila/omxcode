#!/usr/bin/env python3
"""Goal 39 M0: generated footage with exact truth.

    pixi run python scripts/media_data.py OUT

Writes into OUT: warehouse.mp4, drone_a.mp4, drone_b.mp4 (1280x720, 30 fps, H.264), shipments.csv, telemetry_a.csv,
telemetry_b.csv and truth.json. Everything is drawn from a scene model (fixed seeds, no analysis of the pictures), and
every fact in truth.json is read from that model: where each pallet is on each frame, where each worker's face is, where
each insulator is. CSV and JSON are byte-equal between runs (the videos are too, on one machine, x264 on one thread).

--- truth.json "warehouse" -------------------------------------------------------------------------------------------
  frame numbers are 0-based indices into warehouse.mp4 (30 fps; t = frame / 30).
  pallets          pallets whose label can be read: {code, first, last, damaged, code_visible: true}.
                   first/last = first/last frame on which the pallet's whole body (body_w x body_h box) lies inside the
                   picture (a pallet that is only part-way in or out of view is not counted).
  hidden_pallets   pallets whose label faces away from the camera: same fields, code_visible: false (code = what the
                   shipment list says; no picture shows it). Kept apart so a detector that reads codes is scored on
                   the pallets it can read (check.py m4 divides by len(pallets)).
  damaged_intervals  [[start_s, end_s], ...] time-ordered, non-overlapping, merged: seconds during which any damaged
                   pallet is fully in view; start_s = first/30, end_s = (last+1)/30 (frame ranges [first, last+1)).
                   damaged_frames is the same as integer frame ranges [start, end).
  face_checks      [{src_frame, reel_frame, box:[x,y,w,h]}]: a worker's face (a skin-tone disk, box = its bounding box)
                   on a frame inside a damaged interval, with no other worker overlapping it. The reel is the damaged
                   intervals concatenated in order at 30 fps, so reel_frame = src_frame - start + frames before it.
  id_band          {src_frame, reel_frame, box:[40,630,520,60]}: where an exported reel burns the shipment ID, on every
                   frame (lower left, plain floor on every frame of the source). src_frame is the reel's first frame.
  missing_shipments  delivered shipments whose label never appears on camera (pallet absent, or its label faces away).
  code_spec        the printed stripe code: 19 cells of 6 px (start 1,0,1 | 12 id bits MSB first | even-parity bit over
                   the 12 | stop 1,0,1), 1 = dark bar, 0 = blank; cells sit on a white label with the decimal digits
                   (4 digits) under the bars. label_box is relative to the pallet body's top-left corner.
--- truth.json "drone" -----------------------------------------------------------------------------------------------
  assets           poles: {asset, lat, lon}.
  defects_a / _b   {asset, lat, lon, severity 1..5}: a dark scorch with an orange-red rim on an insulator; lat/lon is the
                   insulator. worse = assets whose defect is new or more severe in flight b.
  camera           nadir pinhole, constant image size; for a frame at time t (telemetry gives lat, lon, alt_m,
                   heading_deg), pixel (px, py) (integer pixel index, origin top-left) is on the ground at
                       gsd   = alt_m * gsd_per_m_alt
                       right = (px + 0.5 - 640) * gsd         (metres to the right of the image centre)
                       fwd   = (360 - py - 0.5) * gsd         (metres ahead of the image centre)
                       east  = right * cos(h) + fwd * sin(h) ; north = -right * sin(h) + fwd * cos(h)   (h = heading)
                       lat = lat + north / m_per_deg_lat ; lon = lon + east / m_per_deg_lon
                   Telemetry is at 10 Hz and its t is the video's t (frame k is at t = k / 30); interpolate linearly.
"""

import csv
import json
import math
import multiprocessing as mp
import random
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

W, H, FPS = 1280, 720, 30
S = 2  # supersampling for sprites


def font(size):
    return ImageFont.load_default(size=size)


def mix(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def shade(c, k):
    return tuple(max(0, min(255, int(round(v * k)))) for v in c)


def start_ffmpeg(path):
    ff = shutil.which("ffmpeg") or "/usr/bin/ffmpeg"
    cmd = [ff, "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
           "-c:v", "libx264", "-preset", "medium", "-crf", "19", "-pix_fmt", "yuv420p", "-g", "30", "-bf", "2",
           "-threads", "1", "-fflags", "+bitexact", "-flags:v", "+bitexact", "-movflags", "+faststart", str(path)]
    return subprocess.Popen(cmd, stdin=subprocess.PIPE)


def vignette(strength=0.22):
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    d = np.sqrt(((xx - W / 2) / (W / 2)) ** 2 + ((yy - H / 2) / (H / 2)) ** 2) / 1.41
    k = 1.0 - strength * np.clip(d, 0, 1) ** 2
    return Image.fromarray((k[..., None].repeat(3, 2) * 255).astype(np.uint8))


# =====================================================================================================================
# Warehouse
# =====================================================================================================================

WH_SECONDS = 38
BELT_V = 220.0           # px/s, belt and pallets
PALLET_GAP_S = 2.0
FIRST_ENTRY_S = 0.4
BELT_Y0, BELT_Y1 = 244, 444
ROLLER = 40
ID_BAND = [40, 630, 520, 60]
CELL, LABEL_W, LABEL_H = 6, 132, 74
CARD = (206, 165, 115)
TEAR = (232, 72, 28)

# index in belt order -> kind. D = damaged (label readable), H = label faces away, . = sound
PLAN = "..D.H.D..H.DD.D."
SPECS = [  # shipments with no pallet in the footage: (status)
    "delivered", "delivered", "delivered", "in_transit", "pending", "delivered", "returned"]
CUSTOMERS = ["Northwind", "Contoso Retail", "Fabrikam", "Tailspin Toys", "Adventure Works", "Litware", "Proseware",
             "Wingtip", "Lucerne Foods", "Alpine Ski House", "Coho Vineyard", "Blue Yonder", "Margie's Travel"]


def code_bits(code):
    bits = [(code >> i) & 1 for i in range(11, -1, -1)]
    parity = sum(bits) % 2
    return [1, 0, 1] + bits + [parity] + [1, 0, 1]


def wh_background():
    base = np.zeros((H, W, 3), np.float32)
    yy = np.linspace(0, 1, H, dtype=np.float32)[:, None, None]
    top, bot = np.array([222, 228, 236], np.float32), np.array([196, 205, 218], np.float32)
    base[:] = top * (1 - yy) + bot * yy
    img = Image.fromarray(base.astype(np.uint8))
    d = ImageDraw.Draw(img)
    for x in range(0, W, 160):  # floor slabs
        d.line([(x, 0), (x, H)], fill=(188, 197, 210), width=2)
    for y in range(40, H, 160):
        d.line([(0, y), (W, y)], fill=(188, 197, 210), width=2)
    # yellow safety lines
    for y in (196, 500):
        d.rectangle([0, y, W, y + 8], fill=(238, 200, 58))
        for x in range(-20, W, 48):
            d.polygon([(x, y), (x + 22, y), (x + 10, y + 8), (x - 12, y + 8)], fill=(58, 62, 72))
    # painted dock number, top left
    d.text((60, 70), "DOCK 3", font=font(60), fill=(176, 186, 202))
    # shelves / crates, bottom right (outside the walking lanes and the ID band)
    for i, (x, y, w, h, c) in enumerate([(700, 646, 150, 74, (150, 168, 196)), (860, 654, 120, 66, (176, 190, 212)),
                                          (990, 640, 170, 80, (140, 158, 188)), (1170, 660, 110, 60, (164, 180, 206))]):
        d.rounded_rectangle([x + 6, y + 10, x + w + 6, y + h + 10], 10, fill=(160, 170, 188))
        d.rounded_rectangle([x, y, x + w, y + h], 10, fill=c)
        d.rectangle([x + 10, y + h // 2 - 2, x + w - 10, y + h // 2 + 2], fill=shade(c, 0.86))
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    return img


def wh_belt():
    pw = W + ROLLER
    h = BELT_Y1 - BELT_Y0
    belt = Image.new("RGB", (pw, h), (52, 58, 70))
    d = ImageDraw.Draw(belt)
    for y in range(h):  # soft vertical lighting on the belt
        k = 0.86 + 0.28 * (y / h) * (1 - y / h) * 2
        d.line([(0, y), (pw, y)], fill=shade((60, 67, 80), k))
    for x in range(0, pw, ROLLER):
        d.rectangle([x, 0, x + 5, h], fill=(80, 88, 104))
        d.rectangle([x + 5, 0, x + 8, h], fill=(40, 45, 55))
    return belt


def tear_patch(rng, cx, cy, rx, ry, S):
    """Polygon of a torn, dented patch (orange-red) with a darker core and radiating crack lines."""
    n = 14
    pts, inner = [], []
    for i in range(n):
        a = 2 * math.pi * i / n
        k = 1.0 if i % 2 == 0 else rng.uniform(0.55, 0.8)
        pts.append((cx + math.cos(a) * rx * k * rng.uniform(0.9, 1.1), cy + math.sin(a) * ry * k * rng.uniform(0.9, 1.1)))
        inner.append((cx + math.cos(a) * rx * 0.5 * k, cy + math.sin(a) * ry * 0.5 * k))
    cracks = []
    for i in range(0, n, 2):
        a = 2 * math.pi * i / n + rng.uniform(-0.2, 0.2)
        cracks.append(((cx + math.cos(a) * rx * 0.9, cy + math.sin(a) * ry * 0.9),
                       (cx + math.cos(a) * rx * 1.35, cy + math.sin(a) * ry * 1.35)))
    return pts, inner, cracks


def pallet_sprite(rng, code, kind, pw, ph):
    """RGBA sprite of a wrapped pallet seen from above; returns (image, margin)."""
    M = 30
    cw, ch = (pw + 2 * M) * S, (ph + 2 * M) * S
    shadow = Image.new("L", (cw, ch), 0)
    ImageDraw.Draw(shadow).rounded_rectangle([(M + 4) * S, (M + 16) * S, (M + pw + 4) * S, (M + ph + 16) * S], 18 * S, fill=110)
    shadow = shadow.filter(ImageFilter.GaussianBlur(9 * S))
    sp = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    sp.paste(Image.new("RGBA", (cw, ch), (14, 18, 28, 255)), (0, 0), shadow)
    d = ImageDraw.Draw(sp)
    card = mix(CARD, (190 + rng.randint(-8, 8), 150 + rng.randint(-8, 8), 100 + rng.randint(-8, 8)), 0.6)
    # front face (thickness) and top face
    d.rounded_rectangle([M * S, (M + 10) * S, (M + pw) * S, (M + ph + 10) * S], 16 * S, fill=shade(card, 0.70))
    mask = Image.new("L", (cw, ch), 0)
    ImageDraw.Draw(mask).rounded_rectangle([M * S, M * S, (M + pw) * S, (M + ph) * S], 16 * S, fill=255)
    gy = np.linspace(1.10, 0.90, ph * S, dtype=np.float32)[:, None, None]
    top = np.clip(np.array(card, np.float32)[None, None, :] * gy, 0, 255).repeat(pw * S, 1).astype(np.uint8)
    sp.paste(Image.fromarray(top), (M * S, M * S), mask.crop((M * S, M * S, (M + pw) * S, (M + ph) * S)))
    # stretch wrap: soft translucent diagonal bands, then strapping
    wrap = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    wd = ImageDraw.Draw(wrap)
    for i in range(5):
        x0 = (M + 10 + i * 42) * S
        wd.polygon([(x0, M * S), (x0 + 22 * S, M * S), (x0 + 22 * S - 40 * S, (M + ph) * S), (x0 - 40 * S, (M + ph) * S)], fill=(255, 255, 255, 34))
    wrap = wrap.filter(ImageFilter.GaussianBlur(2 * S))
    wrap.putalpha(ImageChops.multiply(wrap.getchannel("A"), mask))
    sp.alpha_composite(wrap)
    d = ImageDraw.Draw(sp)
    for fx in (0.16, 0.86):
        x = int((M + pw * fx) * S)
        d.rectangle([x, M * S, x + 5 * S, (M + ph) * S], fill=shade(card, 0.62))
    d.rounded_rectangle([M * S, M * S, (M + pw) * S, (M + ph) * S], 16 * S, outline=shade(card, 1.18), width=2 * S)
    if kind == "H":  # label faces away: plain tape, a faint arrow on the carton
        d.rectangle([(M + 40) * S, (M + ph // 2 - 7) * S, (M + pw - 30) * S, (M + ph // 2 + 7) * S], fill=shade(card, 1.12))
    else:  # printed label: stripe code + digits
        lx, ly = M + 26, M + 25
        d.rounded_rectangle([(lx + 2) * S, (ly + 3) * S, (lx + LABEL_W + 2) * S, (ly + LABEL_H + 3) * S], 6 * S, fill=shade(card, 0.62))
        d.rounded_rectangle([lx * S, ly * S, (lx + LABEL_W) * S, (ly + LABEL_H) * S], 6 * S, fill=(250, 250, 248))
        bx, by = lx + (LABEL_W - 19 * CELL) // 2, ly + 8
        for i, b in enumerate(code_bits(code)):
            if b:
                d.rectangle([(bx + i * CELL) * S, by * S, (bx + (i + 1) * CELL) * S - 1, (by + 34) * S - 1], fill=(14, 16, 22))
        txt = f"{code:04d}"
        f = font(22 * S)
        tw = d.textlength(txt, font=f)
        d.text(((lx + LABEL_W / 2) * S - tw / 2, (ly + 44) * S), txt, font=f, fill=(24, 26, 34))
    if kind == "D":  # torn, dented patch, bottom right, clear of the label
        cx, cy = M + pw - rng.randint(36, 40), M + ph - rng.randint(34, 38)
        pts, inner, cracks = tear_patch(rng, cx, cy, rng.randint(31, 35), rng.randint(22, 26), S)
        d.polygon([(x * S, y * S) for x, y in pts], fill=TEAR)
        d.polygon([(x * S, y * S) for x, y in inner], fill=(122, 30, 12))
        for a, b in cracks:
            d.line([(a[0] * S, a[1] * S), (b[0] * S, b[1] * S)], fill=(150, 44, 18), width=2 * S)
    return sp.resize((cw // S, ch // S), Image.LANCZOS), M


SKINS = [(236, 190, 156), (214, 160, 120), (170, 116, 82), (120, 80, 56)]
HAIRS = [(48, 36, 30), (30, 24, 24), (150, 100, 56), (200, 170, 110)]
VESTS = [(34, 160, 172), (58, 96, 206), (148, 200, 62), (150, 96, 196)]


def worker_sprites(i):
    """4 walking poses, facing right, as RGBA at 1x. Head centre at (HX, HY); face box = disk bounding box."""
    skin, hair, vest = SKINS[i % 4], HAIRS[(i * 3 + 1) % 4], VESTS[i % 4]
    R, SW, SH = 26, 90, 182
    HX, HY = 45, 34
    out = []
    for pose in range(4):
        im = Image.new("RGBA", (SW * S, SH * S), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        sw = [(-10, 10), (0, 0), (10, -10), (0, 0)][pose]
        # shadow
        d.ellipse([(HX - 32) * S, (SH - 16) * S, (HX + 32) * S, (SH - 2) * S], fill=(20, 26, 40, 70))
        # legs and shoes
        for dx, off in ((-12, sw[0]), (12, sw[1])):
            x = HX + dx
            d.rounded_rectangle([(x - 8) * S, (HY + 88) * S, (x + 8) * S, (HY + 128 + off * 0.5) * S], 6 * S, fill=(52, 60, 82))
            d.rounded_rectangle([(x - 10) * S, (HY + 124 + off * 0.5) * S, (x + 12) * S, (HY + 134 + off * 0.5) * S], 5 * S, fill=(30, 34, 46))
        # arms swing opposite
        for dx, off in ((-34, -sw[0]), (34, -sw[1])):
            x = HX + dx
            d.rounded_rectangle([(x - 8) * S, (HY + 28) * S, (x + 8) * S, (HY + 72 + off * 0.4) * S], 8 * S, fill=shade(vest, 0.9))
            d.ellipse([(x - 7) * S, (HY + 68 + off * 0.4) * S, (x + 7) * S, (HY + 82 + off * 0.4) * S], fill=skin)
        # torso with reflective stripes
        d.rounded_rectangle([(HX - 30) * S, (HY + 22) * S, (HX + 30) * S, (HY + 94) * S], 16 * S, fill=vest)
        d.rectangle([(HX - 30) * S, (HY + 58) * S, (HX + 30) * S, (HY + 64) * S], fill=(236, 240, 244))
        # neck + head (face)
        d.rectangle([(HX - 7) * S, (HY + 16) * S, (HX + 7) * S, (HY + 28) * S], fill=shade(skin, 0.88))
        d.ellipse([(HX - R) * S, (HY - R) * S, (HX + R) * S, (HY + R) * S], fill=skin)
        d.pieslice([(HX - R) * S, (HY - R - 2) * S, (HX + R) * S, (HY + R - 2) * S], 180, 360, fill=hair)
        d.ellipse([(HX - R + 1) * S, (HY - R + 12) * S, (HX + R - 1) * S, (HY + R) * S], fill=skin)
        d.chord([(HX - R) * S, (HY - R - 2) * S, (HX + R) * S, (HY + R - 2) * S], 180, 360, fill=hair)
        d.ellipse([(HX - R) * S, (HY - R) * S, (HX + R) * S, (HY + R) * S], outline=shade(skin, 0.72), width=1 * S)
        for ex in (6, 17):  # eyes, shifted to the facing side
            d.ellipse([(HX + ex - 3.4) * S, (HY - 2 - 3.4) * S, (HX + ex + 3.4) * S, (HY - 2 + 3.4) * S], fill=(250, 250, 250))
            d.ellipse([(HX + ex - 1.8 + 1) * S, (HY - 2 - 1.8) * S, (HX + ex + 1.8 + 1) * S, (HY - 2 + 1.8) * S], fill=(24, 24, 32))
        d.arc([(HX + 3) * S, (HY + 4) * S, (HX + 21) * S, (HY + 18) * S], 20, 160, fill=(120, 40, 40), width=2 * S)
        d.ellipse([(HX + 22) * S, (HY + 1) * S, (HX + 27) * S, (HY + 6) * S], fill=shade(skin, 0.86))  # nose
        out.append(im.resize((SW, SH), Image.LANCZOS))
    return out, (HX, HY, R, SW, SH)


def tri(x, lo, hi):
    """Triangle wave through [lo, hi]: returns (pos, direction +1/-1)."""
    L = hi - lo
    m = x % (2 * L)
    return (lo + m, 1) if m < L else (lo + 2 * L - m, -1)


WORKERS = [  # lane head y, range, speed px/s, start offset px
    dict(y=488, lo=110, hi=1170, v=88, off=0),
    dict(y=514, lo=150, hi=1130, v=64, off=700),
    dict(y=62, lo=120, hi=1160, v=76, off=380),
    dict(y=84, lo=200, hi=1080, v=102, off=40),
]


def worker_state(i, n):
    w = WORKERS[i]
    d = w["off"] + w["v"] * (n / FPS)
    x, dr = tri(d, w["lo"], w["hi"])
    pose = int(d / 20) % 4
    y = w["y"] + (2 if pose in (0, 2) else 0)
    return x, y, dr, pose


def worker_box(i, n, geom):
    x, y, dr, pose = worker_state(i, n)
    _, _, R, _, _ = geom
    return [int(round(x)) - R, y - R, 2 * R, 2 * R]


def build_warehouse(out):
    rng = random.Random(3901)
    nrng = random.Random(77)
    codes = rng.sample(range(1000, 4000), len(PLAN))
    bg = wh_background()
    belt = wh_belt()
    vig = vignette(0.18)
    kinds = list(PLAN)
    pallets = []
    for i, k in enumerate(kinds):
        pw, ph = rng.randint(188, 206), rng.randint(144, 156)
        sp, M = pallet_sprite(random.Random(1000 + i), codes[i], k, pw, ph)
        pallets.append(dict(i=i, kind=k, code=codes[i], pw=pw, ph=ph, sprite=sp, M=M,
                            t0=FIRST_ENTRY_S + i * PALLET_GAP_S, y=BELT_Y0 + (BELT_Y1 - BELT_Y0 - ph) // 2 + rng.randint(-8, 8)))
    wsprites = [worker_sprites(i) for i in range(len(WORKERS))]
    geom = wsprites[0][1]
    nframes = WH_SECONDS * FPS

    def px(p, n):
        return int(round(-p["pw"] + BELT_V * (n / FPS - p["t0"])))

    first, last = {}, {}
    ff = start_ffmpeg(out / "warehouse.mp4")
    for n in range(nframes):
        img = bg.copy()
        off = int(round(BELT_V * n / FPS)) % ROLLER
        img.paste(belt.crop((ROLLER - off, 0, ROLLER - off + W, belt.height)), (0, BELT_Y0))
        d = ImageDraw.Draw(img)
        d.rectangle([0, BELT_Y0 - 14, W, BELT_Y0 - 2], fill=(150, 160, 178))  # steel rails
        d.rectangle([0, BELT_Y0 - 2, W, BELT_Y0], fill=(70, 78, 94))
        d.rectangle([0, BELT_Y1, W, BELT_Y1 + 2], fill=(70, 78, 94))
        d.rectangle([0, BELT_Y1 + 2, W, BELT_Y1 + 14], fill=(150, 160, 178))
        for p in pallets:
            x = px(p, n)
            if x + p["pw"] > 0 and x < W:
                img.paste(p["sprite"], (x - p["M"], p["y"] - p["M"]), p["sprite"])
            if 0 <= x and x + p["pw"] <= W:
                first.setdefault(p["i"], n)
                last[p["i"]] = n
        order = sorted(range(len(WORKERS)), key=lambda i: WORKERS[i]["y"])
        for i in order:
            x, y, dr, pose = worker_state(i, n)
            sp = wsprites[i][0][pose]
            if dr < 0:
                sp = sp.transpose(Image.FLIP_LEFT_RIGHT)
            img.paste(sp, (int(round(x)) - geom[0], y - geom[1]), sp)
        img = ImageChops.multiply(img, vig)
        ff.stdin.write(np.asarray(img).tobytes())
    ff.stdin.close()
    if ff.wait():
        raise RuntimeError("ffmpeg failed (warehouse)")

    recs = []
    for p in pallets:
        recs.append(dict(code=p["code"], first=first[p["i"]], last=last[p["i"]], damaged=p["kind"] == "D",
                         code_visible=p["kind"] != "H"))
    frames = sorted((r["first"], r["last"] + 1) for r in recs if r["damaged"])
    merged = []
    for a, b in frames:
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    # faces inside damaged intervals: a few per interval, never overlapped by another worker
    checks, before = [], 0
    for a, b in merged:
        picked = 0
        for n in range(a + 10, b - 10, 17):
            i = (n // 17) % len(WORKERS)
            fb = worker_box(i, n, geom)
            ok = 0 <= fb[0] and fb[0] + fb[2] <= W and 0 <= fb[1] and fb[1] + fb[3] <= H
            for j in range(len(WORKERS)):
                if j != i:
                    ob = worker_box(j, n, geom)
                    if abs(ob[0] - fb[0]) < 100 and abs(ob[1] - fb[1]) < 190:
                        ok = False
            if ok:
                checks.append(dict(src_frame=n, reel_frame=before + n - a, box=fb))
                picked += 1
        before += b - a
    return pallets, recs, merged, checks, geom


def write_shipments(out, recs):
    """shipments.csv + the missing set, from the pallet list and the plan."""
    rng = random.Random(555)
    rows = []
    n = 5000
    statuses = ["delivered", "delivered", "delivered", "in_transit", "delivered", "returned", "delivered", "pending"]
    for r in recs:
        n += 1
        st = "delivered" if not r["code_visible"] else statuses[rng.randrange(len(statuses))]
        rows.append(dict(shipment=f"S-{n}", pallet_code=r["code"], status=st, code_visible=r["code_visible"], seen=True))
    used = {r["code"] for r in recs}
    for st in SPECS:  # their pallets never reach this camera
        n += 1
        c = rng.choice([c for c in range(1000, 4000) if c not in used])
        used.add(c)
        rows.append(dict(shipment=f"S-{n}", pallet_code=c, status=st, code_visible=False, seen=False))
    rng.shuffle(rows)
    rows.sort(key=lambda r: r["shipment"])
    missing = []
    with open(out / "shipments.csv", "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["shipment", "pallet_code", "customer", "status", "value"])
        for r in rows:
            val = rng.randint(180, 9800) + rng.randint(0, 99) / 100
            w.writerow([r["shipment"], r["pallet_code"], CUSTOMERS[rng.randrange(len(CUSTOMERS))], r["status"], f"{val:.2f}"])
            if r["status"] == "delivered" and not (r["seen"] and r["code_visible"]):
                missing.append(r["shipment"])
    return sorted(missing)


# =====================================================================================================================
# Drone
# =====================================================================================================================

LAT0, LON0 = 52.0100, 5.1200
M_LAT = 111320.0
M_LON = M_LAT * math.cos(math.radians(LAT0))
LINE_H = 38.0                  # compass heading of the power line, degrees
GSD_PER_M = 0.001              # gsd = alt_m * GSD_PER_M
RES = 0.06                     # world raster, metres per pixel
V0, V1 = -70.0, 70.0           # across the line (to the right of the flight direction)
U0, U1 = -50.0, 262.0          # along the line
POLE_U = [20.0 + 30.0 * i for i in range(7)]
PHASE_V = [-2.0, 0.0, 2.0]
SUN = (-0.7, -0.7)             # shadow offset direction in raster pixel space (right, down) = (x, y)

FLIGHTS = {
    "a": dict(seed=11, seconds=29, speed=7.0, wob=0.12, lat_amp=2.4, lat_ph=0.4, alt=60.0, alt_ph=0.3, batt0=97.0,
              palette="summer", sun=1.0,
              defects={"P02": 2, "P03": 3, "P04": 1, "P06": 2, "P07": 1}),
    "b": dict(seed=11, seconds=27, speed=7.6, wob=0.10, lat_amp=3.0, lat_ph=1.9, alt=61.5, alt_ph=1.2, batt0=95.0,
              palette="autumn", sun=0.8,
              defects={"P01": 2, "P02": 4, "P03": 3, "P04": 1, "P05": 1, "P06": 2, "P07": 3}),
}
DEFECT_PHASE = {"P01": 1, "P02": 0, "P03": 2, "P04": 1, "P05": 2, "P06": 0, "P07": 1}


def u_v_to_enu(u, v):
    h = math.radians(LINE_H)
    return u * math.sin(h) + v * math.cos(h), u * math.cos(h) - v * math.sin(h)


def enu_to_latlon(e, n):
    return LAT0 + n / M_LAT, LON0 + e / M_LON


def uv_latlon(u, v):
    return enu_to_latlon(*u_v_to_enu(u, v))


def pose(fl, t):
    """Camera pose at time t: (u, v, delta_deg, alt). delta = image-up direction relative to the line, clockwise."""
    sp, wob = fl["speed"], fl["wob"]
    u = sp * (t - wob * 9.0 / (2 * math.pi) * math.sin(2 * math.pi * t / 9.0))
    v = fl["lat_amp"] * math.sin(2 * math.pi * t / 17.0 + fl["lat_ph"])
    dv = fl["lat_amp"] * 2 * math.pi / 17.0 * math.cos(2 * math.pi * t / 17.0 + fl["lat_ph"])
    du = sp * (1 - wob * math.cos(2 * math.pi * t / 9.0))
    delta = math.degrees(math.atan2(dv, du)) + 3.0 * math.sin(2 * math.pi * t / 11.0 + fl["lat_ph"])
    alt = fl["alt"] + 1.4 * math.sin(2 * math.pi * t / 13.0 + fl["alt_ph"])
    return u, v, delta, alt


def noise(rng, h, w, cells):
    g = rng.random((cells[0] + 1, cells[1] + 1)).astype(np.float32)
    im = Image.fromarray((g * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC)
    return np.asarray(im, np.float32) / 255.0


def world_ground(fl):
    rng = np.random.default_rng(fl["seed"])
    pr = random.Random(fl["seed"])
    cols, rows = int(round((V1 - V0) / RES)), int(round((U1 - U0) / RES))
    if fl["palette"] == "summer":
        pal = [(104, 156, 72), (128, 172, 78), (92, 140, 70), (170, 176, 84), (206, 188, 92), (118, 160, 96), (140, 124, 78)]
    else:
        pal = [(196, 168, 88), (174, 138, 80), (150, 112, 74), (206, 186, 110), (118, 140, 76), (168, 120, 78), (132, 100, 70)]
    img = Image.new("RGB", (cols, rows), pal[0])
    d = ImageDraw.Draw(img)
    arr_ops = []
    # parcels: split the raster into rectangles
    def split(x0, y0, x1, y1, depth):
        if depth == 0 or (x1 - x0) < 500 or (y1 - y0) < 500:
            c = pr.choice(pal)
            d.rectangle([x0, y0, x1, y1], fill=shade(c, pr.uniform(0.94, 1.06)))
            arr_ops.append((x0, y0, x1, y1, pr.choice((0, 1)), pr.uniform(3.0, 5.5) / RES, pr.uniform(0.03, 0.06)))
            return
        if pr.random() < 0.5:
            c = int(pr.uniform(0.35, 0.65) * (x1 - x0)) + x0
            split(x0, y0, c - 3, y1, depth - 1)
            split(c + 3, y0, x1, y1, depth - 1)
        else:
            c = int(pr.uniform(0.35, 0.65) * (y1 - y0)) + y0
            split(x0, y0, x1, c - 3, depth - 1)
            split(x0, c + 3, x1, y1, depth - 1)
    split(0, 0, cols - 1, rows - 1, 5)
    a = np.asarray(img, np.float32)
    for x0, y0, x1, y1, ori, period, amp in arr_ops:  # crop rows
        sl = a[y0:y1 + 1, x0:x1 + 1]
        coord = np.arange(sl.shape[1 if ori == 0 else 0], dtype=np.float32)
        wave = 1 + amp * np.sin(2 * np.pi * coord / period)
        sl *= (wave[None, :, None] if ori == 0 else wave[:, None, None])
    n1 = noise(rng, rows, cols, (40, 20)) - 0.5
    n2 = noise(rng, rows, cols, (200, 100)) - 0.5
    a *= (1 + 0.20 * n1 + 0.06 * n2)[..., None]
    img = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    del a
    d = ImageDraw.Draw(img)

    def X(v):
        return (v - V0) / RES

    def Y(u):
        return (U1 - u) / RES

    # a gravel service track beside the line and a tarmac road across it
    d.rectangle([X(17.5), 0, X(19.7), rows], fill=(176, 160, 128))
    ru = 126.0
    d.rectangle([0, Y(ru + 3.2), cols, Y(ru - 3.2)], fill=(74, 78, 86))
    d.rectangle([0, Y(ru + 3.2), cols, Y(ru + 3.0)], fill=(206, 208, 210))
    d.rectangle([0, Y(ru - 3.0), cols, Y(ru - 3.2)], fill=(206, 208, 210))
    for x in range(0, cols, 220):
        d.rectangle([x, Y(ru + 0.12), x + 110, Y(ru - 0.12)], fill=(232, 220, 120))
    # pond
    d.ellipse([X(-52), Y(70), X(-30), Y(46)], fill=(84, 130, 160))
    d.ellipse([X(-51), Y(69), X(-31), Y(47)], outline=(60, 108, 138), width=6)
    # farm: two roofs, a yard
    d.rectangle([X(24), Y(94), X(46), Y(66)], fill=(190, 184, 170))
    for (a0, b0, a1, b1, c) in [(26, 92, 38, 72, (86, 104, 132)), (38, 92, 44, 82, (108, 122, 148)), (39, 80, 45, 68, (130, 142, 160))]:
        d.rectangle([X(a0) + 8, Y(b0) + 8, X(a1) + 8, Y(b1) + 8], fill=(60, 70, 60))
        d.rectangle([X(a0), Y(b0), X(a1), Y(b1)], fill=c)
        d.line([(X(a0), (Y(b0) + Y(b1)) / 2), (X(a1), (Y(b0) + Y(b1)) / 2)], fill=shade(c, 0.78), width=4)
    # trees, drawn as supersampled sprites with a soft shadow
    base_tree = Image.new("RGBA", (96, 96), (0, 0, 0, 0))
    for k in range(70):
        u, v = pr.uniform(U0 + 5, U1 - 5), pr.choice([pr.uniform(-66, -8), pr.uniform(8, 66)])
        if abs(v) < 6 or abs(u - ru) < 6 or (22 < v < 48 and 62 < u < 98) or (-54 < v < -28 and 44 < u < 72):
            continue
        r = pr.uniform(0.9, 2.1) / RES
        sz = int(r * 2 + 40)
        t = Image.new("RGBA", (sz * S, sz * S), (0, 0, 0, 0))
        td = ImageDraw.Draw(t)
        c0 = pr.choice([(52, 104, 62), (64, 116, 66), (44, 92, 60)])
        sh = Image.new("L", (sz * S, sz * S), 0)
        ImageDraw.Draw(sh).ellipse([(sz / 2 - r + 12) * S, (sz / 2 - r + 14) * S, (sz / 2 + r + 12) * S, (sz / 2 + r + 14) * S], fill=120)
        sh = sh.filter(ImageFilter.GaussianBlur(5 * S))
        t.paste(Image.new("RGBA", t.size, (14, 24, 20, 255)), (0, 0), sh)
        td.ellipse([(sz / 2 - r) * S, (sz / 2 - r) * S, (sz / 2 + r) * S, (sz / 2 + r) * S], fill=c0)
        td.ellipse([(sz / 2 - r * 0.8) * S, (sz / 2 - r * 0.85) * S, (sz / 2 + r * 0.4) * S, (sz / 2 + r * 0.3) * S], fill=shade(c0, 1.25))
        t = t.resize((sz, sz), Image.LANCZOS)
        img.paste(t, (int(X(v) - sz / 2), int(Y(u) - sz / 2)), t)
    return img, X, Y


def draw_line(img, X, Y, defects, fl):
    """Poles, crossarms, insulator strings, wires and the scorch marks."""
    d = ImageDraw.Draw(img)
    # wires + shadows
    for vv in PHASE_V:
        x = X(vv)
        d.line([(x + 14, 0), (x + 14, img.height)], fill=(88, 112, 78), width=2)  # soft shadow (drawn first, thin)
    for vv in PHASE_V:
        x = X(vv)
        d.line([(x, 0), (x, img.height)], fill=(34, 36, 42), width=2)
    for i, u in enumerate(POLE_U):
        cy = Y(u)
        cx = X(0.0)
        # long soft pole shadow and a crossarm shadow
        d.line([(cx, cy), (cx + 40, cy + 40)], fill=(70, 92, 62), width=7)
        d.rounded_rectangle([cx - 2.5 / RES + 14, cy - 8 + 14, cx + 2.5 / RES + 14, cy + 8 + 14], 5, fill=(78, 98, 70))
        d.rounded_rectangle([cx - 2.5 / RES, cy - 8, cx + 2.5 / RES, cy + 8], 5, fill=(112, 84, 58))
        for k, vv in enumerate(PHASE_V):
            ix = X(vv)
            for s in range(6):  # insulator string: alternating discs, hanging toward the camera's bottom
                y0 = cy + 9 + s * 0.42 / RES
                c = (220, 230, 238) if s % 2 == 0 else (150, 168, 184)
                d.ellipse([ix - 0.34 / RES, y0, ix + 0.34 / RES, y0 + 0.42 / RES + 2], fill=c, outline=(104, 120, 136))
        d.ellipse([cx - 10, cy - 10, cx + 10, cy + 10], fill=(58, 48, 42))
        d.ellipse([cx - 6, cy - 6, cx + 6, cy + 6], fill=(96, 82, 70))
    # defects: scorch (dark core, orange-red rim) on an insulator
    out = []
    for asset, sev in defects.items():
        i = int(asset[1:]) - 1
        ph = DEFECT_PHASE[asset]
        u, v = POLE_U[i], PHASE_V[ph]
        cx, cy = X(v), Y(u) + 9 + 2.5 * 0.42 / RES
        r = (0.22 + 0.17 * sev) / RES
        rng = random.Random(900 + i * 7 + sev)
        pts_o = [(cx + math.cos(a) * r * rng.uniform(0.85, 1.15), cy + math.sin(a) * r * rng.uniform(0.85, 1.15))
                 for a in [2 * math.pi * j / 16 for j in range(16)]]
        pts_i = [(cx + (x - cx) * 0.62, cy + (y - cy) * 0.62) for x, y in pts_o]
        d.polygon(pts_o, fill=(238, 84, 24))
        d.polygon(pts_i, fill=(28, 14, 10))
        out.append((asset, cx, cy, sev, u, v + 0.0))
    return out


def build_drone(out, key):
    fl = FLIGHTS[key]
    img, X, Y = world_ground(fl)
    marks = draw_line(img, X, Y, fl["defects"], fl)
    vig = vignette(0.20)
    ff = start_ffmpeg(out / f"drone_{key}.mp4")
    nframes = fl["seconds"] * FPS
    for n in range(nframes):
        u, v, dl, alt = pose(fl, n / FPS)
        gsd = alt * GSD_PER_M
        c, s = math.cos(math.radians(dl)), math.sin(math.radians(dl))

        def uv(Xo, Yo):
            r, f = (Xo - W / 2) * gsd, (H / 2 - Yo) * gsd
            return u + f * c - r * s, v + f * s + r * c

        (u00, v00), (u10, v10), (u01, v01) = uv(0, 0), uv(1, 0), uv(0, 1)
        col = lambda vv: (vv - V0) / RES
        row = lambda uu: (U1 - uu) / RES
        coef = (col(v10) - col(v00), col(v01) - col(v00), col(v00), row(u10) - row(u00), row(u01) - row(u00), row(u00))
        frame = img.transform((W, H), Image.AFFINE, coef, Image.BILINEAR)
        frame = ImageChops.multiply(frame, vig)
        ff.stdin.write(np.asarray(frame).tobytes())
    ff.stdin.close()
    if ff.wait():
        raise RuntimeError(f"ffmpeg failed (drone {key})")
    # telemetry at 10 Hz
    with open(out / f"telemetry_{key}.csv", "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["t", "lat", "lon", "alt_m", "heading_deg", "speed_ms", "battery_pct"])
        for k in range(fl["seconds"] * 10 + 1):
            t = k / 10
            u, v, dl, alt = pose(fl, t)
            u2, v2, _, _ = pose(fl, t + 0.01)
            speed = math.hypot(u2 - u, v2 - v) / 0.01
            lat, lon = uv_latlon(u, v)
            batt = fl["batt0"] - 0.0825 * t - 0.4 * (1 - math.exp(-t / 3))
            w.writerow([f"{t:.1f}", f"{lat:.7f}", f"{lon:.7f}", f"{alt:.2f}", f"{(LINE_H + dl) % 360:.2f}", f"{speed:.2f}", f"{batt:.2f}"])
    res = []
    for asset, cx, cy, sev, _, _ in marks:
        u = U1 - cy * RES
        v = V0 + cx * RES
        lat, lon = uv_latlon(u, v)
        res.append(dict(asset=asset, lat=round(lat, 7), lon=round(lon, 7), severity=sev))
    return res


# =====================================================================================================================

def job(args):
    kind, out = args
    out = Path(out)
    if kind == "warehouse":
        pallets, recs, merged, checks, geom = build_warehouse(out)
        return kind, dict(recs=recs, merged=merged, checks=checks)
    return kind, build_drone(out, kind[-1])


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: media_data.py OUT")
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    with mp.get_context("fork").Pool(3) as pool:
        res = dict(pool.map(job, [("warehouse", out), ("drone_a", out), ("drone_b", out)], chunksize=1))
    wh = res["warehouse"]
    recs = wh["recs"]
    missing = write_shipments(out, recs)
    pallets = [r for r in recs if r["code_visible"]]
    hidden = [r for r in recs if not r["code_visible"]]
    merged = wh["merged"]
    a, b = res["drone_a"], res["drone_b"]
    da = {x["asset"]: x["severity"] for x in a}
    worse = sorted(x["asset"] for x in b if x["asset"] not in da or x["severity"] > da[x["asset"]])
    assets = []
    for i, u in enumerate(POLE_U):
        lat, lon = uv_latlon(u, 0.0)
        assets.append(dict(asset=f"P{i + 1:02d}", lat=round(lat, 7), lon=round(lon, 7)))
    truth = dict(
        warehouse=dict(
            video="warehouse.mp4", size=[W, H], fps=FPS, frames=WH_SECONDS * FPS,
            pallets=pallets, hidden_pallets=hidden,
            body_h="per pallet 144..156 px, body_w 188..206 px",
            damaged_intervals=[[round(s / FPS, 6), round(e / FPS, 6)] for s, e in merged],
            damaged_frames=merged,
            face_checks=wh["checks"],
            id_band=dict(src_frame=merged[0][0], reel_frame=0, box=ID_BAND),
            missing_shipments=missing,
            code_spec=dict(cell_px=CELL, cells=19, start=[1, 0, 1], id_bits=12, parity="even over the 12 id bits",
                           stop=[1, 0, 1], label_size=[LABEL_W, LABEL_H], bars_height=34, digits=4,
                           damage_colour_rgb=list(TEAR)),
        ),
        drone=dict(
            assets=assets, defects_a=a, defects_b=b, worse=worse,
            camera=dict(model="nadir pinhole", size=[W, H], gsd_per_m_alt=GSD_PER_M, origin_lat=LAT0, origin_lon=LON0,
                        m_per_deg_lat=M_LAT, m_per_deg_lon=round(M_LON, 4), line_heading_deg=LINE_H,
                        telemetry_hz=10, mark_colour_rgb=[238, 84, 24],
                        note="see scripts/media_data.py header for the pixel to lat/lon formulas"),
        ),
    )
    (out / "truth.json").write_text(json.dumps(truth, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
