"""Build the talk decks: talks/_src/<product>[-partN].html -> talks/<product>[/partN]/index.html.

Each source starts with `<!-- title: …; accent: --core -->` and holds only <section>s. The head (Liquid dark, the
kit deck's look) and foot (Reveal.js from a CDN, notes plugin) are shared, so every built index.html is self-contained.
Pictures and clips referenced as img/<name> are copied from the repo's and omxlabs' image folders into the deck's own
img/, so each folder stands alone. Prints each deck's spoken length (notes at 150 words a minute). Fails if a slide has no speaker notes or a picture can't be found.

    pixi run python docs/launch/kit/talks/build.py
"""
import re, shutil, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
PICS = [REPO / "docs/img", REPO / "docs/gallery/img", Path.home() / "Projects/omxlabs/assets/img"]

head = (HERE / "_src/head.html").read_text()
foot = (HERE / "_src/foot.html").read_text()
bad = []
rows = []
for src in sorted((HERE / "_src").glob("*.html")):
    if src.name in ("head.html", "foot.html"):
        continue
    text = src.read_text()
    meta = re.match(r"<!--\s*title:\s*(.*?);\s*accent:\s*(--[a-z]+)\s*-->", text)
    if not meta:
        bad.append(f"{src.name}: no title/accent comment")
        continue
    product, _, part = src.stem.partition("-")
    out = HERE / product / part if part else HERE / product
    out.mkdir(parents=True, exist_ok=True)
    sections = re.findall(r"<section\b.*?</section>", text, flags=re.S)
    for i, s in enumerate(sections, 1):
        if '<aside class="notes">' not in s:
            bad.append(f"{src.name}: slide {i} has no notes")
    names = sorted(set(re.findall(r'(?:src|poster)="img/([^"]+)"', text)))
    (out / "img").mkdir(exist_ok=True)
    for n in names:
        found = next((d / n for d in PICS if (d / n).exists()), None)
        if found is None:
            bad.append(f"{src.name}: img/{n} not found")
        else:
            shutil.copy2(found, out / "img" / n)
    for stale in (out / "img").iterdir():
        if stale.name not in names:
            stale.unlink()
    html = head.replace("{TITLE}", meta.group(1)).replace("{ACCENT}", meta.group(2)) + text[meta.end():].strip() + "\n\n" + foot
    (out / "index.html").write_text(html)
    words = sum(len(re.sub(r"<[^>]+>", " ", n).split()) for n in re.findall(r'<aside class="notes">(.*?)</aside>', text, flags=re.S))
    rows.append((str(out.relative_to(HERE)), len(sections), len(names), words))

for r in rows:
    print(f"{r[0]:<22} {r[1]:>3} slides  {r[2]:>2} pictures  {r[3]:>4} words of notes ≈ {r[3] / 150:.1f} min at 150 wpm")
if bad:
    print("\n".join(bad))
    sys.exit(1)
