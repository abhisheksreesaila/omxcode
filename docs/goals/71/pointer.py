"""The cold open's pointer: an arrow drawn over a take recorded without X's own (live.py's recordbare).

The headless display has no window manager, so over plain widgets X shows its bare black "x"; zoomed scenes made it huge.
The take is recorded with draw_mouse off and this draws a clean arrow (white, dark outline, soft shadow) at the pointer
positions live.py logged (LIVE-PTR), held between moves, with a brief press ring at each button press (LIVE-BTN). It runs
on the 1440x810 take before any zoom or crop, so the arrow scales with the picture.

    pixi run python docs/goals/71/pointer.py <take.mp4> <live output.txt> <out.mp4>     (also: arrow <out.png>)
"""
import re
import subprocess
import sys
from bisect import bisect_right

from PIL import Image, ImageDraw, ImageFilter

S = 4                                    # drawn at 4x, then reduced: smooth edges
HEIGHT = 24                              # the arrow's height in take pixels (1440x810)
PAD = 6                                  # room for the outline and the shadow
# a classic pointer: tip at (0, 0), in units of ~1.2 px
SHAPE = [(0, 0), (0, 16.5), (4.0, 12.8), (6.8, 19.2), (9.4, 18.1), (6.7, 11.9), (12.0, 11.9)]


def arrow():
    """The arrow as an RGBA image and its hotspot (the tip) inside it."""
    k = HEIGHT / 19.2
    size = (int(13 * k) + 2 * PAD, HEIGHT + 2 * PAD)
    big = (size[0] * S, size[1] * S)
    pts = [((PAD + x * k) * S, (PAD + y * k) * S) for x, y in SHAPE]
    shadow = Image.new("L", big, 0)
    ImageDraw.Draw(shadow).polygon([(x + 1.2 * S, y + 1.8 * S) for x, y in pts], fill=110)
    shadow = shadow.filter(ImageFilter.GaussianBlur(1.6 * S))
    img = Image.new("RGBA", big, (0, 0, 0, 0))
    img.paste((10, 12, 16, 255), (0, 0), shadow)
    dr = ImageDraw.Draw(img)
    dr.polygon(pts, fill=(255, 255, 255, 255), outline=(20, 22, 28, 255), width=int(1.3 * S))
    return img.resize(size, Image.LANCZOS), (PAD, PAD)


def track(text):
    """(times, points) of the pointer and the press times from live.py's LIVE-PTR and LIVE-BTN lines."""
    ptr = [(float(t), int(x), int(y)) for t, x, y in re.findall(r"^LIVE-PTR: ([\d.]+) (-?\d+) (-?\d+)$", text, re.M)]
    ptr.sort()
    presses = [float(t) for t in re.findall(r"^LIVE-BTN: ([\d.]+) down$", text, re.M)]
    return [p[0] for p in ptr], [(p[1], p[2]) for p in ptr], presses


def at(times, pts, t):
    """The pointer at time t: live.py's moves are its steps (a glide is 12 of them over ~200 ms), so between two logged
    points ~16 ms apart it slides linearly, and after the last one it rests there."""
    i = bisect_right(times, t) - 1
    if i < 0:
        return pts[0]
    if i + 1 < len(times) and times[i + 1] - times[i] < 0.05:
        f = (t - times[i]) / (times[i + 1] - times[i])
        return (pts[i][0] + (pts[i + 1][0] - pts[i][0]) * f, pts[i][1] + (pts[i + 1][1] - pts[i][1]) * f)
    return pts[i]


def ring(r, alpha):
    """A press ring: a soft white circle with a thin dark edge, radius r, opacity alpha (0..1)."""
    n = int(r + 4) * 2 * S
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    dr = ImageDraw.Draw(img)
    c = n / 2
    rr = r * S
    dr.ellipse((c - rr, c - rr, c + rr, c + rr), fill=(255, 255, 255, int(70 * alpha)), outline=(20, 22, 28, int(150 * alpha)), width=int(1.4 * S))
    return img.resize((n // S, n // S), Image.LANCZOS)


def composite(take, text, out, fps=30):
    times, pts, presses = track(text)
    if not times:
        sys.exit("pointer: no LIVE-PTR lines (record the take with recordbare:)")
    pr = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", take],
                        capture_output=True, text=True, check=True)
    w, h = (int(n) for n in pr.stdout.strip().split(","))
    img, (hx, hy) = arrow()
    dec = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-i", take, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    enc = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-r", str(fps), "-i", "-",
                            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "16", "-preset", "medium", out], stdin=subprocess.PIPE)
    n, frame = 0, w * h * 3
    while True:
        buf = dec.stdout.read(frame)
        if len(buf) < frame:
            break
        t = n / fps
        im = Image.frombytes("RGB", (w, h), buf).convert("RGBA")
        x, y = at(times, pts, t)
        for p in presses:  # a ring grows and fades over 0.4 s from each press
            if 0 <= t - p < 0.4:
                f = (t - p) / 0.4
                rg = ring(7 + 13 * f, 1 - f)
                im.alpha_composite(rg, (int(x - rg.width / 2), int(y - rg.height / 2)))
        if -img.width < x < w and -img.height < y < h:
            layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
            layer.paste(img, (int(round(x)) - hx, int(round(y)) - hy))
            im.alpha_composite(layer)
        enc.stdin.write(im.convert("RGB").tobytes())
        n += 1
    enc.stdin.close()
    dec.wait()
    if enc.wait() or n == 0:
        sys.exit("pointer: encoding failed")
    return n


if __name__ == "__main__":
    if sys.argv[1] == "arrow":
        arrow()[0].save(sys.argv[2])
    else:
        print(composite(sys.argv[1], open(sys.argv[2]).read(), sys.argv[3]), "frames")
