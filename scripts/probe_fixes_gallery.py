"""The gallery's "Hardened since" notes: one line per fixed probe item, in that probe's section, drawn from
docs/goals/probe-fixes/results.json (written by scripts/probe_fixes.py, so every number cites a run). Rewrites each
<p class="hardened"> in place, or adds it at the end of the section's text. Run: pixi run python scripts/probe_fixes_gallery.py
"""

import json
import re
from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAGE = ROOT / "docs" / "gallery" / "index.html"
RESULTS = ROOT / "docs" / "goals" / "probe-fixes" / "results.json"

# probe section in the gallery -> (steps in results.json, how each reads)
SECTIONS = {
    "dictation": ["dictate"],
    "database": ["jot_flake", "jot_queue", "jot_drop"],
    "works-when-closed": ["keeper_handover", "keeper_stamp"],
    "drawing": ["sketch_erase"],
}


def line(step, r):
    if step == "dictate":
        return (f"<code>Microphone.captured_ns</code> no longer retries without a bound: a capture thread stuck mid-update "
                f"made it spin forever; it now gives up after {r['after_ms']:.1f} ms with a time never later than now "
                f"(<code>{escape(r['test'])}</code>).")
    return escape(r.get("summary", ""))


def main():
    results = json.loads(RESULTS.read_text()) if RESULTS.exists() else {}
    page = PAGE.read_text()
    for section, steps in SECTIONS.items():
        items = [line(s, results[s]) for s in steps if s in results]
        start = page.index(f'id="{section}"')
        end = page.index("</article>", start)
        art = page[start:end]
        art = re.sub(r'\n *<p class="hardened">.*?</p>', "", art, flags=re.S)
        if items:
            note = ('\n        <p class="hardened"><b>Hardened since</b> (<code>scripts/probe_fixes.py</code>): '
                    + " ".join(items) + "</p>")
            cut = art.rindex("</div>\n    </div>") if "</div>\n    </div>" in art else art.rindex("</div></div>")
            art = art[:cut].rstrip() + note + "\n      " + art[cut:]
        page = page[:start] + art + page[end:]
    PAGE.write_text(page)
    print("gallery: hardened notes for", ", ".join(s for s, st in SECTIONS.items() if any(x in results for x in st)) or "none")


if __name__ == "__main__":
    main()
