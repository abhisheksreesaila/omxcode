"""Render talk decks in headless Chromium: screenshots, console errors, and content that spills off a slide.

    pixi run python docs/launch/kit/talks/shoot.py                     # every deck: slides 1, the middle, the last
    pixi run python docs/launch/kit/talks/shoot.py omxcore/part1 --all # every slide of one deck

Screenshots go to build/talks/<deck>-<slide>.png (deck with / as -). Fragments are shown (the slide's end state).
Exits 1 on a console error, a failed request or a slide whose content spills past its 1280×720 frame.
"""
import sys
from pathlib import Path
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
OUT = HERE.parents[3] / "build/talks"
OUT.mkdir(parents=True, exist_ok=True)
args = [a for a in sys.argv[1:] if not a.startswith("--")]
every = "--all" in sys.argv
decks = [HERE / a / "index.html" for a in args] or sorted(p for p in HERE.glob("**/index.html") if "_src" not in p.parts)

SPILL = """() => {
  const sec = Reveal.getCurrentSlide(), r = sec.getBoundingClientRect(), out = [];
  for (const el of sec.querySelectorAll('*')) {
    if (el.closest('aside.notes')) continue;
    const b = el.getBoundingClientRect();
    if (!b.width || !b.height) continue;
    if (b.bottom > r.bottom + 2 || b.right > r.right + 2)
      out.push(el.tagName.toLowerCase() + '.' + el.className + ' ' + Math.round(b.bottom - r.bottom) + 'px below, ' + Math.round(b.right - r.right) + 'px right');
  }
  return out.slice(0, 3);
}"""

problems = 0
with sync_playwright() as p:
    browser = p.chromium.launch(executable_path="/usr/bin/chromium", headless=True)  # as scripts/drive.py
    for deck in decks:
        name = str(deck.parent.relative_to(HERE)).replace("/", "-")
        page = browser.new_page(viewport={"width": 1280, "height": 720})
        errors = []
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(str(e)))
        # (Chromium aborts a video's range request once it has the metadata: ERR_ABORTED on media isn't a failure)
        page.on("requestfailed", lambda r: None if r.resource_type == "media" and "ERR_ABORTED" in (r.failure or "") else errors.append("failed: " + r.url))
        page.goto(deck.as_uri())
        page.wait_for_function("window.Reveal && Reveal.isReady()")
        n = page.evaluate("Reveal.getTotalSlides()")
        notes = page.evaluate("[...document.querySelectorAll('.slides > section')].filter(s => !s.querySelector('aside.notes')).length")
        pick = range(n) if every else sorted({0, n // 2, n - 1})
        for i in range(n):
            page.evaluate(f"Reveal.slide({i}, 0, 100)")
            page.wait_for_timeout(700 if i in pick else 60)
            spill = page.evaluate(SPILL)
            if spill:
                problems += 1
                print(f"  SPILL {name} slide {i + 1}: {spill}")
            if i in pick:
                page.screenshot(path=str(OUT / f"{name}-{i + 1:02d}.png"))
        if errors or notes:
            problems += 1
        print(f"{name:<22} {n:>3} slides  {notes} without notes  {len(errors)} console errors {errors[:3] if errors else ''}")
        page.close()
    browser.close()
sys.exit(1 if problems else 0)
