"""The same screens on GTK, the web and the Mac, side by side (owner, 2026-10-23: "if I show them the Linux app and the
Mac app next to each other and they can't tell the difference, that's the big win"; docs/plans/mac-feel.md M0).

  pixi run python scripts/side.py            GTK and the web shot here, the Mac from the newest scripts/mac-ci run
  pixi run python scripts/side.py --mac RUN  the Mac pictures of build/mac-ci/RUN

The screens are ci/mac/side.txt's lines (app|screen|settings|steps), one launch each at 1440x900; the Mac runs them on
GitHub's macOS 26 (ci/mac/run.sh → out/side/). Writes build/side/<app>-<screen>.png (GTK | web | Mac in one picture)
and build/side/index.html.
"""

import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import drive  # noqa: E402

SIZE = (1440, 900)
OUT = ROOT / "build" / "side"
HOSTS = ["gtk", "web", "mac"]


def screens():
    for line in (ROOT / "ci" / "mac" / "side.txt").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            app, screen, settings, steps = line.split("|", 3)
            yield app, screen, [s for s in settings.split(",") if s], steps


def env_for(settings):
    config = Path(tempfile.mkdtemp(prefix="side-config-"))
    (config / "settings.txt").write_text("".join(s + "\n" for s in settings))
    docs = Path(tempfile.mkdtemp(prefix="side-docs-"))
    return {"OMX_CONFIG": str(config), "OMX_DOCUMENTS": str(docs)}


def shoot_gtk(app, screen, settings, steps):
    import subprocess
    e = dict(os.environ, **env_for(settings), MOJOUI_TEST=steps, MOJOUI_WINDOW=f"{SIZE[0]}x{SIZE[1]}",
             MOJOUI_SHOT=str(OUT / f"{app}-{screen}-gtk.png"))
    r = subprocess.run([str(ROOT / "build" / app / "linux" / app)], env=e, capture_output=True, text=True, timeout=600)
    return None if r.returncode == 0 else f"{app} {screen} gtk exit {r.returncode}: {(r.stdout + r.stderr)[-300:]}"


def shoot_web(app, screen, settings, steps):
    e = env_for(settings)
    saved = {k: os.environ.get(k) for k in e}
    os.environ.update(e)
    try:
        r, log = drive.web_run(ROOT / "build" / app / "web", steps, shot=str(OUT / f"{app}-{screen}-web.png"), viewport=SIZE)
    finally:
        for k, v in saved.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
    return None if r.returncode == 0 else f"{app} {screen} web: {log[-300:]}"


def newest_mac_run():
    runs = sorted((p for p in (ROOT / "build" / "mac-ci").glob("[0-9]*") if (p / "report-macos-26" / "side").is_dir()),
                  key=lambda p: int(p.name))
    return runs[-1] if runs else None


def compose(app, screen, mac_dir):
    """GTK | web | Mac in one picture, each scaled to 720 wide, labelled."""
    from PIL import Image, ImageDraw
    w, h = SIZE[0] // 2, SIZE[1] // 2
    out = Image.new("RGB", (w * 3 + 40, h + 28), "white")
    d = ImageDraw.Draw(out)
    for i, host in enumerate(HOSTS):
        src = (mac_dir / f"{app}-{screen}.png") if host == "mac" and mac_dir else OUT / f"{app}-{screen}-{host}.png"
        x = i * (w + 20)
        d.text((x + 4, 6), f"{host}  {app} · {screen}", fill="black")
        if src.exists():
            im = Image.open(src).convert("RGB")
            im.thumbnail((w, h))
            out.paste(im, (x, 28))
        else:
            d.text((x + 4, 40), "(no picture)", fill="red")
    out.save(OUT / f"{app}-{screen}.png")


def page(rows):
    cells = "\n".join(f'<h2>{a} · {s}</h2><img src="{a}-{s}.png">' for a, s in rows)
    (OUT / "index.html").write_text("<!doctype html><meta charset=utf-8><title>side by side</title>"
                                    "<style>body{font:14px Inter,sans-serif;margin:16px}img{max-width:100%;border:1px solid #ddd}</style>"
                                    "<h1>GTK · web · Mac</h1>" + cells)


if __name__ == "__main__":
    import headless
    headless.ensure()
    OUT.mkdir(parents=True, exist_ok=True)
    mac = Path(sys.argv[sys.argv.index("--mac") + 1]) if "--mac" in sys.argv else newest_mac_run()
    mac_dir = (ROOT / "build" / "mac-ci" / mac.name / "report-macos-26" / "side") if mac else None
    only = [a for a in sys.argv[1:] if not a.startswith("--") and a != (mac.name if mac else "")]
    rows, problems = [], []
    for app, screen, settings, steps in screens():
        if only and app not in only:
            continue
        for shoot in (shoot_gtk, shoot_web):
            p = shoot(app, screen, settings, steps)
            if p:
                problems.append(p)
        compose(app, screen, mac_dir)
        rows.append((app, screen))
    page(rows)
    print(f"mac: {mac_dir}")
    print("\n".join(problems) or "all shot")
    print(OUT / "index.html")
