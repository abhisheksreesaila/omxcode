"""Build small forum GIFs from real app recordings/screenshots already in docs/.

    python scripts/forum_media.py

Needs ffmpeg. Clips keep their recorded speed; console scenes are still screenshots.
The AG-UI recording uses a scripted agent and is labelled as such. Sources are listed
in docs/launch/forum/README.md. No fake screens or invented performance numbers.
"""
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs/img/forum"
WORK = ROOT / "build/forum/media"
OUT.mkdir(parents=True, exist_ok=True)
WORK.mkdir(parents=True, exist_ok=True)


def run(args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], cwd=ROOT, check=True)


def scene(name, source, title, duration=3, start=None, still=False, height=508):
    title_file = WORK / f"{name}.txt"
    title_file.write_text(title)
    args = ["-loop", "1", "-framerate", "8"] if still else []
    if start is not None:
        args += ["-ss", str(start)]
    args += ["-i", str(ROOT / source), "-t", str(duration)]
    area = height - 58
    filters = (
        f"setpts=PTS-STARTPTS,fps=8,scale=800:{area}:force_original_aspect_ratio=decrease:flags=lanczos:out_color_matrix=bt709:out_range=tv,"
        f"pad=800:{area}:(ow-iw)/2:(oh-ih)/2:color=0x0b0b0d,setsar=1,"
        f"pad=800:{height}:0:58:color=0x0b0b0d,"
        f"drawtext=fontfile=/usr/share/fonts/TTF/DejaVuSans.ttf:"
        f"textfile='{title_file}':fontcolor=0xededef:fontsize=20:x=22:y=18,"
        "setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709"
    )
    target = WORK / f"{name}.mp4"
    run([*args, "-vf", filters, "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(target)])
    return target


def assemble(name, scenes):
    listing = WORK / f"{name}.txt"
    listing.write_text("\n".join(f"file '{p}'" for p in scenes) + "\n")
    movie = WORK / f"{name}.mp4"
    run(["-f", "concat", "-safe", "0", "-i", str(listing), "-c", "copy", str(movie)])
    run(["-i", str(movie), "-filter_complex",
         "[0:v]split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
         "-loop", "0", str(OUT / f"{name}.gif")])
    run(["-ss", "1", "-i", str(movie), "-frames:v", "1", "-q:v", "2", str(OUT / f"{name}-poster.jpg")])
    return {"file": f"{name}.gif", "bytes": (OUT / f"{name}.gif").stat().st_size,
            "scenes": [p.name for p in scenes]}


code = assemble("omxcode", [
    scene("data", "docs/img/clip-robots-15s.mp4", "Explore robot video and telemetry together", start=8, duration=5),
    scene("agents", "docs/launch/series/omxcode-agui.gif", "Agents build screens · scripted AG-UI demo", start=5, duration=5),
    scene("console", "docs/img/forum/console-find.png", "A native console around Modular’s MAX", still=True, duration=3),
])
console = assemble("omxconsole", [
    scene("find", "docs/img/forum/console-find.png", "Find a model that fits your GPU", still=True, height=558),
    scene("library", "docs/img/forum/console-models.png", "Manage your models in one native app", still=True, height=558),
    scene("keys", "docs/img/forum/console-keys.png", "One endpoint · a key for each app", still=True, height=558),
])
(WORK / "manifest.json").write_text(json.dumps([code, console], indent=2))
print(json.dumps([code, console], indent=2))
