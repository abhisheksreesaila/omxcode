"""The same screens on GTK, the web and the Mac, side by side (owner, 2026-10-23: "if I show them the Linux app and the
Mac app next to each other and they can't tell the difference, that's the big win"; docs/plans/mac-feel.md M0).

  pixi run python scripts/side.py            GTK and the web shot here, the Mac from the newest scripts/mac-ci run
  pixi run python scripts/side.py --mac RUN  the Mac pictures of build/mac-ci/RUN
  pixi run python scripts/side.py --stamp    the sources' stamp (scripts/mac-ci records it with each run)

The screens are ci/mac/side.txt's lines (app|screen|settings|steps), one launch each at 1440x640 (GitHub's Mac screen
is 1024x768 points: a taller window is cut to its height); the Mac runs them on GitHub's macOS 26 (ci/mac/run.sh →
out/side/). Writes build/side/<app>-<screen>.png (GTK | web | Mac in one picture), the web's tagged views' rects
(<app>-<screen>-web-rects.txt, for scripts/parity.py) and build/side/index.html. A Mac run counts only if it was built
from these sources (its SOURCE file holds stamp()).
"""

import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import drive  # noqa: E402

SIZE = (1440, 640)
OUT = ROOT / "build" / "side"
HOSTS = ["gtk", "web", "mac"]


def screens():
    for line in (ROOT / "ci" / "mac" / "side.txt").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            app, screen, settings, steps = line.split("|", 3)
            yield app, screen, [s for s in settings.split(",") if s], steps.replace("{ci}", str(ROOT / "ci" / "mac"))


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
    (OUT / f"{app}-{screen}-gtk.txt").write_text(r.stdout + r.stderr)
    return None if r.returncode == 0 else f"{app} {screen} gtk exit {r.returncode}: {(r.stdout + r.stderr)[-300:]}"


def shoot_web(app, screen, settings, steps):
    e = env_for(settings)
    saved = {k: os.environ.get(k) for k in e}
    os.environ.update(e)
    try:
        try:
            r, log = drive.web_run(ROOT / "build" / app / "web", steps, shot=str(OUT / f"{app}-{screen}-web.png"), viewport=SIZE,
                                   rects=str(OUT / f"{app}-{screen}-web-rects.txt"))
        except Exception as e:  # (a step that finds nothing times out: that screen fails, the rest still shoot)
            return f"{app} {screen} web: {e!r}"[:400]
    finally:
        for k, v in saved.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
    return None if r.returncode == 0 else f"{app} {screen} web: {log[-300:]}"


SOURCES = ["mojoui", "themes", "hosts", "examples/omxplorer", "examples/maccheck", "ci/mac", "apple"]


def stamp():
    """A hash of every file the Mac builds and runs read: a Mac run built from other sources doesn't count."""
    import hashlib
    h = hashlib.sha256()
    for top in SOURCES:
        for f in sorted((ROOT / top).rglob("*")):
            if f.is_file() and "__pycache__" not in f.parts:
                h.update(str(f.relative_to(ROOT)).encode() + b"\0" + f.read_bytes())
    return h.hexdigest()[:16]


def newest_mac_run():
    runs = sorted((p for p in (ROOT / "build" / "mac-ci").glob("[0-9]*") if (p / "report-macos-26" / "side").is_dir()),
                  key=lambda p: int(p.name))
    return runs[-1] if runs else None


def mac_dir(run=None):
    """The newest Mac run's side pictures (or RUN's)."""
    run = run or newest_mac_run()
    return (ROOT / "build" / "mac-ci" / run.name / "report-macos-26" / "side") if run else None


def mac_fresh(run=None):
    """(fresh, why): the Mac run was built from these sources."""
    run = run or newest_mac_run()
    if not run:
        return False, "no Mac run with side pictures (scripts/mac-ci)"
    f = run / "SOURCE"
    had = f.read_text().strip() if f.exists() else "(none)"
    return had == stamp(), f"Mac run {run.name} built from {had}, these sources are {stamp()}"


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


def shoot_all(only=(), mac=None):
    """GTK and the web shot for every side.txt screen (of the apps in `only`, if any), each composed with the Mac's."""
    import headless
    headless.ensure()
    OUT.mkdir(parents=True, exist_ok=True)
    mdir = mac_dir(mac)
    rows, problems = [], []
    for app, screen, settings, steps in screens():
        if only and app not in only and f"{app}:{screen}" not in only:
            continue
        for shoot in (shoot_gtk, shoot_web):
            p = shoot(app, screen, settings, steps)
            if p:
                problems.append(p)
        compose(app, screen, mdir)
        rows.append((app, screen))
    page(rows)
    return problems


if __name__ == "__main__":
    if "--stamp" in sys.argv:
        print(stamp())
        sys.exit(0)
    mac = (ROOT / "build" / "mac-ci" / sys.argv[sys.argv.index("--mac") + 1]) if "--mac" in sys.argv else None
    only = [a for a in sys.argv[1:] if not a.startswith("--") and a != (mac.name if mac else "")]
    problems = shoot_all(only, mac)
    print(f"mac: {mac_dir(mac)} ({mac_fresh(mac)[1]})")
    print("\n".join(problems) or "all shot")
    print(OUT / "index.html")
