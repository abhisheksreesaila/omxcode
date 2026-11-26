"""A scene with objects at known places, for goal 77's camera proof (M6).

    pixi run python scripts/g77_scene.py [--out build/g77] [--gpu 1]

Draws each object once with the Z-Image sd-server (on GPU $G77_SD_GPU, default 1; cached in <out>/objects, so a second run
doesn't start the server), pastes them onto a white 1280x720 counter at fixed places, and writes
  <out>/scene.png        the picture
  <out>/scene.y4m, otter.y4m   the pictures as 5-frame videos, the files Chromium's fake camera plays
  <out>/truth.json       {"objects": [{"name", "box": [x0, y0, x1, y1]}], "width", "height"}  (pixels; the tight box of what
                         was drawn, measured from the object's own picture, not asked of any model)
"""
import argparse
import base64
import json
import os
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
HOME = Path.home()
SD_BIN = os.environ.get("OMX_SD_BIN", str(HOME / "Projects/omx-local/third_party/stable-diffusion.cpp/build/bin/sd-server"))
SD_MODELS = os.environ.get("OMX_SD_MODELS", str(HOME / "Projects/omx-local/models/card2"))
W, H, TILE = 1280, 720, 400

# name (what a person calls it), the drawing prompt, where its tile goes (x, y)
OBJECTS = [
    ("mug", "a single red ceramic coffee mug, product photo, centered, plain white background", 60, 150, 11),
    ("banana", "a single ripe yellow banana, product photo, centered, plain white background", 470, 190, 12),
    ("bottle", "a single tall green glass bottle with a label, product photo, centered, plain white background", 840, 120, 13),
]


def draw(out_dir, gpu):
    need = [o for o in OBJECTS if not (out_dir / "objects" / f"{o[0]}.png").exists()]
    if not need:
        return
    (out_dir / "objects").mkdir(parents=True, exist_ok=True)
    args = [SD_BIN, "--listen-ip", "127.0.0.1", "--listen-port", "8191", "--model-dir", SD_MODELS,
            "--diffusion-model", SD_MODELS + "/z_image_turbo-Q8_0.gguf", "--vae", SD_MODELS + "/split_files/vae/ae.safetensors",
            "--llm", SD_MODELS + "/Qwen3-4B-Instruct-2507-Q8_0.gguf", "--cfg-scale", "1.0", "--steps", "8", "--diffusion-fa"]
    log = open(out_dir / "sd.log", "w")
    srv = subprocess.Popen(args, stdout=log, stderr=log, env=dict(os.environ, CUDA_VISIBLE_DEVICES=str(gpu)), start_new_session=True)
    try:
        for _ in range(240):
            try:
                urllib.request.urlopen("http://127.0.0.1:8191/sdapi/v1/options", timeout=1)
                break
            except Exception:
                time.sleep(1)
                if srv.poll() is not None:
                    raise SystemExit("sd-server ended: " + (out_dir / "sd.log").read_text()[-300:])
        for name, prompt, _x, _y, seed in need:
            body = json.dumps({"prompt": prompt, "steps": 8, "cfg_scale": 1.0, "width": 768, "height": 768, "seed": seed}).encode()
            req = urllib.request.Request("http://127.0.0.1:8191/sdapi/v1/txt2img", body, {"Content-Type": "application/json"})
            img = json.loads(urllib.request.urlopen(req, timeout=180).read())["images"][0]
            (out_dir / "objects" / f"{name}.png").write_bytes(base64.b64decode(img))
    finally:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(srv.pid, sig)
                srv.wait(15)
                break
            except (ProcessLookupError, subprocess.TimeoutExpired):
                continue


def tight_box(img):
    """The box of the object: what differs from the backdrop (the tile's border colour) by a clear margin, so neither the
    soft shadow nor the tile's vignette counts. Stray rows and columns with a couple of pixels don't count either."""
    a = np.asarray(img.convert("RGB")).astype(np.int32)
    border = np.concatenate([a[:6].reshape(-1, 3), a[-6:].reshape(-1, 3), a[:, :6].reshape(-1, 3), a[:, -6:].reshape(-1, 3)])
    bg = np.median(border, axis=0)
    mask = np.abs(a - bg).sum(axis=2) > 90
    cols = np.where(mask.sum(axis=0) >= 3)[0]
    rows = np.where(mask.sum(axis=1) >= 3)[0]
    return int(cols.min()), int(rows.min()), int(cols.max()) + 1, int(rows.max()) + 1


def text_picture(out_dir):  # (1280x720 like the scene)
    """A picture of words, for the reading case: PURPLE OTTER 42 in big purple letters on cream."""
    from PIL import ImageDraw, ImageFont
    img = Image.new("RGB", (W, H), (250, 244, 228))
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(str(ROOT / "mojoui/hosts/static/fonts/Inter-SemiBold.ttf"), 150)
    for i, line in enumerate(("PURPLE", "OTTER 42")):
        w = d.textlength(line, font=font)
        d.text(((W - w) / 2, 150 + i * 220), line, fill=(110, 40, 160), font=font)
    img.save(out_dir / "otter.png")
    y4m(img, out_dir / "otter.y4m")


def y4m(img, path):
    """The picture as a 5-frame yuv420 video, the file Chromium's fake camera plays in a loop."""
    rgb = np.asarray(img.convert("RGB").resize((W, H))).astype(np.float32)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    yy = (0.299 * r + 0.587 * g + 0.114 * b).clip(0, 255).astype(np.uint8)
    u = ((b - yy) * 0.564 + 128).clip(0, 255)
    v = ((r - yy) * 0.713 + 128).clip(0, 255)
    u = u.reshape(H // 2, 2, W // 2, 2).mean(axis=(1, 3)).astype(np.uint8)
    v = v.reshape(H // 2, 2, W // 2, 2).mean(axis=(1, 3)).astype(np.uint8)
    frame = b"FRAME\n" + yy.tobytes() + u.tobytes() + v.tobytes()
    with open(path, "wb") as f:
        f.write(f"YUV4MPEG2 W{W} H{H} F5:1 Ip A1:1 C420jpeg\n".encode())
        for _ in range(5):
            f.write(frame)


def build(out_dir):
    canvas = Image.new("RGB", (W, H), (255, 255, 255))
    truth = []
    for name, _prompt, x, y, _seed in OBJECTS:
        img = Image.open(out_dir / "objects" / f"{name}.png").convert("RGB")
        x0, y0, x1, y1 = tight_box(img)
        s = TILE / img.width
        tile = img.resize((TILE, TILE), Image.LANCZOS)
        region = canvas.crop((x, y, x + TILE, y + TILE))
        canvas.paste(Image.fromarray(np.minimum(np.asarray(region), np.asarray(tile))), (x, y))  # (white backdrop never hides a neighbour)
        truth.append({"name": name, "box": [round(x + x0 * s), round(y + y0 * s), round(x + x1 * s), round(y + y1 * s)]})
    text_picture(out_dir)
    canvas.save(out_dir / "scene.png")
    canvas.save(out_dir / "scene.jpg", quality=88)
    (out_dir / "truth.json").write_text(json.dumps({"objects": truth, "width": W, "height": H}, indent=1))
    y4m(canvas, out_dir / "scene.y4m")
    return truth


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "build/g77"))
    ap.add_argument("--gpu", default=os.environ.get("G77_SD_GPU", "1"))
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    draw(out, a.gpu)
    print(json.dumps(build(out)))


if __name__ == "__main__":
    sys.exit(main())
