"""Chrome's line breaks between printable ASCII characters, measured (D-548): tests/fixtures/chrome_ascii_breaks.txt.

    pixi run python scripts/linebreak_table.py

For every pair x y of printable ASCII characters (! to ~), after a letter, a digit or a full stop (the character
before x matters only for "-" before a digit), headless Chromium lays out "pp" + x + y + "a" in a 1 px wide box (every
break it allows is taken) and notes whether y starts a line. One line per context: the context character, a tab, then
the pairs that break, two characters each. mojoui/linebreak.mojo's browser_breaks is checked against it
(tests/test_linebreak.mojo).
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
OUT = ROOT / "tests" / "fixtures" / "chrome_ascii_breaks.txt"
CONTEXTS = ["a", "1", "."]


def measure():
    import drive
    from playwright.sync_api import sync_playwright
    chars = [chr(c) for c in range(33, 127)]
    with sync_playwright() as p:
        b = p.chromium.launch(executable_path=drive.CHROMIUM, headless=True)
        page = b.new_page()
        page.set_content("<div id=c style='font: 16px monospace; width: 1px; white-space: normal'></div>")
        res = page.evaluate("""([chars, contexts]) => { const e = document.getElementById('c'); const out = {};
          const top = (n, i) => { const r = document.createRange(); r.setStart(n, i); r.setEnd(n, i + 1); return r.getClientRects()[0].top; };
          for (const pre of contexts) { out[pre] = '';
            for (const x of chars) for (const y of chars) { e.textContent = pre + pre + x + y + 'a'; const n = e.firstChild;
              if (top(n, 3) !== top(n, 2)) out[pre] += x + y; } }
          return out; }""", [chars, CONTEXTS])
        version = b.version
        b.close()
    return res, version


if __name__ == "__main__":
    res, version = measure()
    OUT.write_text("".join(f"{pre}\t{res[pre]}\n" for pre in CONTEXTS))
    print(f"Chromium {version}: " + ", ".join(f"after {pre!r} {len(res[pre]) // 2} pairs" for pre in CONTEXTS) + f" -> {OUT.relative_to(ROOT)}")
