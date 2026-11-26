#!/usr/bin/env python3
"""Build a lightweight transparent PNG sprite-strip Companion pack for mojoui.mascot.

Supports two workflows:
  1. From key pose PNGs (RGBA): synthesizes smooth looping sprite strips (rest, listen,
     think, speak, hype, nap) with consistent foot anchoring and clean alpha.
  2. From pre-rendered video clips or PNG frame sequences (Blender / Masko / WebM / MOV):
     resizes, foot-anchors, and packs each state or hub-and-spoke transition into a
     horizontal RGBA PNG strip + manifest.json readable directly by mojoui.pngread.

Usage (default Omx Spirit sample pack):
  .pixi/envs/default/bin/python scripts/build_mascot_pack.py \\
      --poses-dir <dir_with_mascot_*.png> \\
      --out examples/stage/mascots/omx

Usage (from video clips directory containing rest.webm, listen.webm, rest_to_hype.webm, ...):
  .pixi/envs/default/bin/python scripts/build_mascot_pack.py \\
      --clips-dir <dir_with_videos> \\
      --out examples/stage/mascots/custom
"""

import argparse
import json
import math
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter


FRAME_SIZE = 192
# Where the default pack's art comes from (written into manifest.json; see examples/stage/mascots/omx/README.md). Pass --source
# for a pack made from other art: say what it was made from and under which terms.
OMX_SOURCE = ("AI-generated with Google Gemini (image model) via the Antigravity agent, 2026-11-25, from a text prompt: an original "
              "character (a dark-blue round creature). One 1024x1024 pose sheet (rest, listen, think, hype), cut into four transparent "
              "poses, animated into six strips by scripts/build_mascot_pack.py. No third-party artwork; the Masko 'Momo' video was only a "
              "reference for the hub-and-spoke clip pattern. See README.md.")
ANCHOR_Y = 178  # feet baseline inside 192x192 frame


def trim_and_clean(im: Image.Image) -> Image.Image:
    """Trim transparent margins, remove stray alpha dust, and seal any interior alpha holes so dark fur stays solid on light themes."""
    from collections import deque
    im = im.convert("RGBA")
    arr = np.array(im, dtype=np.uint8)
    h, w = arr.shape[:2]
    alpha = arr[:, :, 3]
    alpha[alpha < 10] = 0

    # Flood-fill from the 4 borders through transparent/edge pixels (alpha < 210) to identify true exterior background
    ext = np.zeros((h, w), dtype=bool)
    q = deque()
    for x in range(w):
        if alpha[0, x] < 210:
            ext[0, x] = True; q.append((0, x))
        if alpha[h - 1, x] < 210:
            ext[h - 1, x] = True; q.append((h - 1, x))
    for y in range(h):
        if alpha[y, 0] < 210 and not ext[y, 0]:
            ext[y, 0] = True; q.append((y, 0))
        if alpha[y, w - 1] < 210 and not ext[y, w - 1]:
            ext[y, w - 1] = True; q.append((y, w - 1))

    while q:
        cy, cx = q.popleft()
        for ny, nx in ((cy - 1, cx), (cy + 1, cx), (cy, cx - 1), (cy, cx + 1)):
            if 0 <= ny < h and 0 <= nx < w and not ext[ny, nx] and alpha[ny, nx] < 210:
                ext[ny, nx] = True
                q.append((ny, nx))

    # Any non-exterior pixel is strictly inside the character silhouette -> make fully opaque!
    interior_holes = (~ext) & (alpha < 255)
    arr[interior_holes, 3] = 255
    # Gently suppress bright halo on semi-transparent exterior edge pixels for clean dark+light compositing
    arr[:, :, 3] = alpha
    arr[interior_holes, 3] = 255

    im = Image.fromarray(arr, "RGBA")
    bbox = im.getbbox()
    if bbox:
        im = im.crop(bbox)
    return im


def place_anchored(
    sprite: Image.Image,
    size: int = FRAME_SIZE,
    target_h: float = 148.0,
    anchor_y: float = ANCHOR_Y,
    scale_x: float = 1.0,
    scale_y: float = 1.0,
    dx: float = 0.0,
    dy: float = 0.0,
    rot_deg: float = 0.0,
) -> Image.Image:
    """Scale `sprite` proportionally to `target_h`, apply squash/stretch & rotation around feet, place in `size`x`size`."""
    w, h = sprite.size
    if w == 0 or h == 0:
        return Image.new("RGBA", (size, size), (0, 0, 0, 0))
    base_s = min(target_h / float(h), (size * 0.80) / float(w))
    nw = max(1, int(round(w * base_s * scale_x)))
    nh = max(1, int(round(h * base_s * scale_y)))
    scaled = sprite.resize((nw, nh), Image.Resampling.LANCZOS)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = int(round((size - nw) / 2.0 + dx))
    py = int(round(anchor_y - nh + dy))
    canvas.alpha_composite(scaled, (px, py))

    if abs(rot_deg) > 0.05:
        canvas = canvas.rotate(
            rot_deg,
            resample=Image.Resampling.BICUBIC,
            center=(size / 2.0 + dx, anchor_y + dy),
        )
    return canvas


def add_glow_orb(img: Image.Image, cx: float, cy: float, r: float, color: tuple, alpha: int):
    """Paint a soft glowing mote on top of an RGBA frame."""
    if alpha <= 0 or r <= 0.5:
        return
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    x0, y0, x1, y1 = cx - r, cy - r, cx + r, cy + r
    d.ellipse([x0, y0, x1, y1], fill=(color[0], color[1], color[2], min(255, max(0, alpha))))
    blurred = overlay.filter(ImageFilter.GaussianBlur(radius=max(1.2, r * 0.7)))
    img.alpha_composite(blurred)
    # bright core
    core = Image.new("RGBA", img.size, (0, 0, 0, 0))
    dc = ImageDraw.Draw(core)
    cr = max(1.0, r * 0.42)
    dc.ellipse([cx - cr, cy - cr, cx + cr, cy + cr], fill=(255, 255, 255, min(255, int(alpha * 0.85))))
    img.alpha_composite(core)


def add_sparkle(img: Image.Image, cx: float, cy: float, r: float, color: tuple, alpha: int):
    """Paint a crisp 4-point Pixar-like twinkle star."""
    if alpha <= 0 or r <= 1.0:
        return
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    pts = [
        (cx, cy - r),
        (cx + r * 0.28, cy - r * 0.28),
        (cx + r, cy),
        (cx + r * 0.28, cy + r * 0.28),
        (cx, cy + r),
        (cx - r * 0.28, cy + r * 0.28),
        (cx - r, cy),
        (cx - r * 0.28, cy - r * 0.28),
    ]
    d.polygon(pts, fill=(color[0], color[1], color[2], min(255, max(0, alpha))))
    img.alpha_composite(overlay)


def pack_strip(frames: list[Image.Image], out_path: Path):
    """Pack a list of equal-sized RGBA frames into a horizontal PNG strip."""
    if not frames:
        raise ValueError("no frames")
    w, h = frames[0].size
    strip = Image.new("RGBA", (w * len(frames), h), (0, 0, 0, 0))
    for i, f in enumerate(frames):
        strip.paste(f, (i * w, 0))
    out_path.parent.mkdir(parents=True, exist_ok=True)
    # Use RGBA PNG (lossless alpha, clean with mojoui.pngread, optimize=True for compact size)
    strip.save(out_path, format="PNG", optimize=True, compress_level=9)


def build_from_poses(poses_dir: Path, out_dir: Path, name: str = "Omx Spirit", source: str = OMX_SOURCE):
    rest_src = trim_and_clean(Image.open(poses_dir / "mascot_rest.png"))
    listen_src = trim_and_clean(Image.open(poses_dir / "mascot_listen.png"))
    think_src = trim_and_clean(Image.open(poses_dir / "mascot_think.png"))
    hype_src = trim_and_clean(Image.open(poses_dir / "mascot_hype.png"))

    out_dir.mkdir(parents=True, exist_ok=True)

    # 1. REST: 16 frames @ 12 fps — gentle alive breath + subtle sway
    rest_frames = []
    n_rest = 16
    for i in range(n_rest):
        t = 2.0 * math.pi * i / n_rest
        sy = 1.0 + 0.022 * math.sin(t)
        sx = 1.0 - 0.015 * math.sin(t)
        rot = 1.1 * math.sin(t - 0.5)
        dy = -1.6 * (0.5 - 0.5 * math.cos(t))
        fr = place_anchored(rest_src, target_h=148.0, scale_x=sx, scale_y=sy, dy=dy, rot_deg=rot)
        # subtle warm lantern firefly shimmer
        mote_a = int(55 + 45 * (0.5 + 0.5 * math.sin(t + 1.0)))
        add_glow_orb(fr, 142 + 4 * math.sin(t), 126 - 6 * math.cos(t), 3.2, (255, 214, 130), mote_a)
        rest_frames.append(fr)
    pack_strip(rest_frames, out_dir / "rest.png")

    # 2. LISTEN: 12 frames @ 12 fps — eager forward tilt + attentive bounce
    listen_frames = []
    n_listen = 12
    for i in range(n_listen):
        t = 2.0 * math.pi * i / n_listen
        pulse = 0.5 - 0.5 * math.cos(t)
        sy = 1.0 + 0.032 * pulse
        sx = 1.0 - 0.020 * pulse
        rot = -2.2 + 2.4 * math.sin(t)
        dy = -3.2 * pulse
        fr = place_anchored(listen_src, target_h=150.0, scale_x=sx, scale_y=sy, dy=dy, rot_deg=rot)
        # soft blue acoustic mote near ear
        add_glow_orb(fr, 34 + 3 * math.cos(t), 62 - 4 * math.sin(t), 3.8, (118, 196, 255), int(90 + 60 * pulse))
        listen_frames.append(fr)
    pack_strip(listen_frames, out_dir / "listen.png")

    # 3. THINK: 16 frames @ 12 fps — gentle sway + 3 orbiting soft glowing orbs
    think_frames = []
    n_think = 16
    for i in range(n_think):
        t = 2.0 * math.pi * i / n_think
        sy = 1.0 + 0.018 * math.sin(t)
        sx = 1.0 - 0.012 * math.sin(t)
        rot = 2.6 * math.sin(t)
        fr = place_anchored(think_src, target_h=152.0, scale_x=sx, scale_y=sy, rot_deg=rot)
        for k in range(3):
            a = t + k * (2.0 * math.pi / 3.0)
            ox = 96.0 + 54.0 * math.cos(a)
            oy = 42.0 + 11.0 * math.sin(a)
            depth = 0.5 + 0.5 * math.sin(a)
            col = (130, 190, 255) if k != 1 else (196, 168, 255)
            add_glow_orb(fr, ox, oy, 2.8 + 1.8 * depth, col, int(95 + 110 * depth))
        think_frames.append(fr)
    pack_strip(think_frames, out_dir / "think.png")

    # 4. SPEAK: 12 frames @ 16 fps — rhythmic expressive bobbing with warm glow
    speak_frames = []
    n_speak = 12
    for i in range(n_speak):
        t = 2.0 * math.pi * i / n_speak
        beat = abs(math.sin(t))
        sy = 0.985 + 0.050 * beat
        sx = 1.015 - 0.032 * beat
        dy = -4.5 * beat
        rot = 2.2 * math.sin(t)
        src = listen_src if (i % 6) < 3 else rest_src
        # smoothly blend between listen & rest silhouettes on boundary frames
        fr_a = place_anchored(listen_src, target_h=150.0, scale_x=sx, scale_y=sy, dy=dy, rot_deg=rot)
        fr_b = place_anchored(rest_src, target_h=148.0, scale_x=sx, scale_y=sy, dy=dy, rot_deg=rot)
        mix = 0.5 - 0.5 * math.cos(t)
        fr = Image.blend(fr_b, fr_a, mix * 0.65)
        add_glow_orb(fr, 148, 72 - 5 * beat, 3.6, (255, 210, 130), int(75 + 95 * beat))
        add_glow_orb(fr, 44, 84 - 4 * (1.0 - beat), 2.8, (130, 200, 255), int(65 + 75 * (1.0 - beat)))
        speak_frames.append(fr)
    pack_strip(speak_frames, out_dir / "speak.png")

    # 5. HYPE: 14 frames @ 18 fps (one-shot -> rest) — joyful squash-jump-sparkle-land!
    hype_frames = []
    n_hype = 14
    for i in range(n_hype):
        u = i / float(n_hype - 1)  # 0..1
        if u < 0.18:  # anticipation crouch
            p = u / 0.18
            sx = 1.0 + 0.11 * math.sin(p * math.pi * 0.5)
            sy = 1.0 - 0.12 * math.sin(p * math.pi * 0.5)
            dy = 2.0 * p
            rot = -3.0 * p
            src = rest_src
        elif u < 0.72:  # joyful airborne arc
            p = (u - 0.18) / 0.54
            arc = math.sin(p * math.pi)
            dy = -26.0 * arc
            stretch = math.sin(p * math.pi) * 0.08
            sx = 1.0 - stretch * 0.6
            sy = 1.0 + stretch
            rot = 5.5 * math.sin(p * math.pi * 2.0)
            src = hype_src
        else:  # cushioned landing settle
            p = (u - 0.72) / 0.28
            damp = math.sin(p * math.pi)
            sx = 1.0 + 0.09 * damp
            sy = 1.0 - 0.09 * damp
            dy = 1.5 * damp
            rot = 0.0
            src = hype_src if p < 0.45 else rest_src
        fr = place_anchored(src, target_h=146.0, scale_x=sx, scale_y=sy, dy=dy, rot_deg=rot)
        if 0.22 <= u <= 0.78:
            sp = math.sin(((u - 0.22) / 0.56) * math.pi)
            a = int(235 * sp)
            add_sparkle(fr, 34, 40 - 10 * sp, 9.0 * sp, (255, 224, 120), a)
            add_sparkle(fr, 158, 36 - 12 * sp, 10.5 * sp, (140, 214, 255), a)
            add_sparkle(fr, 166, 92 - 6 * sp, 6.5 * sp, (255, 180, 120), int(a * 0.85))
            add_sparkle(fr, 28, 96 - 4 * sp, 6.0 * sp, (210, 175, 255), int(a * 0.8))
        hype_frames.append(fr)
    pack_strip(hype_frames, out_dir / "hype.png")

    # 6. NAP: 12 frames @ 8 fps — cozy dimmed resting pose + slow deep sleep breath + floating dusk sparks
    nap_base = rest_src.copy()
    rgb = nap_base.convert("RGB")
    rgb = ImageEnhance.Brightness(rgb).enhance(0.84)
    rgb = ImageEnhance.Color(rgb).enhance(0.82)
    nap_src = Image.merge("RGBA", (*rgb.split(), nap_base.getchannel("A")))
    nap_frames = []
    n_nap = 12
    for i in range(n_nap):
        t = 2.0 * math.pi * i / n_nap
        breath = 0.5 - 0.5 * math.cos(t)
        sy = 0.94 + 0.032 * breath
        sx = 1.05 - 0.022 * breath
        dy = 3.0 - 1.5 * breath
        fr = place_anchored(nap_src, target_h=144.0, scale_x=sx, scale_y=sy, dy=dy, rot_deg=-1.8)
        # gently rising tiny star/dream mote
        u = i / float(n_nap)
        rise_a = int(145 * math.sin(u * math.pi))
        add_glow_orb(fr, 134 + 6 * math.sin(t), 58 - 22 * u, 3.0, (175, 198, 255), rise_a)
        nap_frames.append(fr)
    pack_strip(nap_frames, out_dir / "nap.png")

    manifest = {
        "name": name,
        "version": 1,
        "source": source,
        "frame_width": FRAME_SIZE,
        "frame_height": FRAME_SIZE,
        "anchor_y": round(ANCHOR_Y / float(FRAME_SIZE), 3),
        "states": {
            "rest": {"file": "rest.png", "frames": n_rest, "fps": 12, "loop": True},
            "listen": {"file": "listen.png", "frames": n_listen, "fps": 12, "loop": True},
            "think": {"file": "think.png", "frames": n_think, "fps": 12, "loop": True},
            "speak": {"file": "speak.png", "frames": n_speak, "fps": 16, "loop": True},
            "hype": {"file": "hype.png", "frames": n_hype, "fps": 18, "loop": False, "next": "rest"},
            "nap": {"file": "nap.png", "frames": n_nap, "fps": 8, "loop": True},
        },
        "transitions": {},
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    total = sum(p.stat().st_size for p in out_dir.glob("*.png"))
    print(f"Built pack '{name}' in {out_dir}:")
    for p in sorted(out_dir.glob("*.png")):
        im = Image.open(p)
        print(f"  {p.name:12s}  {im.size[0]:4d}x{im.size[1]:3d}  {p.stat().st_size / 1024:6.1f} KB")
    print(f"  Total PNGs: {total / 1024:.1f} KB")


def build_from_clips(clips_dir: Path, out_dir: Path, name: str = "Custom Mascot", fps: int = 16, size: int = FRAME_SIZE,
                     source: str = "not recorded: pass --source with where the clips come from and under which terms"):
    """Compile transparent video clips (.webm/.mov/.mp4) into an omxome companion pack via ffmpeg."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg not found in PATH")
    out_dir.mkdir(parents=True, exist_ok=True)
    known_states = ["rest", "listen", "think", "speak", "hype", "nap"]
    states_meta = {}
    trans_meta = {}

    for p in sorted(clips_dir.iterdir()):
        if p.suffix.lower() not in (".webm", ".mov", ".mp4", ".gif", ".apng"):
            continue
        stem = p.stem.lower()
        with tempfile.TemporaryDirectory() as tmp:
            pattern = os.path.join(tmp, "f_%04d.png")
            cmd = [
                ffmpeg, "-y", "-i", str(p),
                "-vf", f"fps={fps},scale={size}:{size}:force_original_aspect_ratio=decrease,pad={size}:{size}:(ow-iw)/2:oh-ih:color=0x00000000",
                "-pix_fmt", "rgba", pattern,
            ]
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            frame_paths = sorted(Path(tmp).glob("f_*.png"))
            frames = [Image.open(fp).convert("RGBA") for fp in frame_paths]
            if not frames:
                continue
            out_png = out_dir / f"{stem}.png"
            pack_strip(frames, out_png)
            if "_to_" in stem:
                a, b = stem.split("_to_", 1)
                trans_meta[f"{a}->{b}"] = {"file": out_png.name, "frames": len(frames), "fps": fps}
            elif stem in known_states:
                entry = {"file": out_png.name, "frames": len(frames), "fps": fps, "loop": stem != "hype"}
                if stem == "hype":
                    entry["next"] = "rest"
                states_meta[stem] = entry

    manifest = {
        "name": name,
        "source": source,
        "version": 1,
        "frame_width": size,
        "frame_height": size,
        "anchor_y": 0.94,
        "states": states_meta,
        "transitions": trans_meta,
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Built pack '{name}' from clips in {out_dir}: {len(states_meta)} states, {len(trans_meta)} transitions")


def main():
    ap = argparse.ArgumentParser(description="Build a mojoui.mascot sprite-strip pack.")
    ap.add_argument("--poses-dir", type=Path, help="Directory with mascot_rest/listen/think/hype.png")
    ap.add_argument("--clips-dir", type=Path, help="Directory with transparent video clips (rest.webm, ...)")
    ap.add_argument("--out", type=Path, required=True, help="Output pack directory")
    ap.add_argument("--name", default="Omx Spirit", help="Pack display name")
    ap.add_argument("--fps", type=int, default=16, help="Extraction FPS for --clips-dir")
    ap.add_argument("--source", default=None, help="Where the art comes from and under which terms (manifest.json's source)")
    args = ap.parse_args()

    if args.poses_dir:
        build_from_poses(args.poses_dir, args.out, args.name, args.source or OMX_SOURCE)
    elif args.clips_dir:
        build_from_clips(args.clips_dir, args.out, args.name, fps=args.fps, source=args.source or "not recorded: pass --source with where the clips come from and under which terms")
    else:
        ap.error("Specify either --poses-dir or --clips-dir")


if __name__ == "__main__":
    main()
