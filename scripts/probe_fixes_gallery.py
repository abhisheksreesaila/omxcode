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
    if step == "jot_flake":
        return (f"Goal 30's 100M-row check failed now and then, and every time with half the CPU busy. Two causes, both in "
                f"the test host, neither in the app: a fixed 3.5 s pause raced the open job (the host now waits for the import "
                f"sheet, <code>waitfor:</code>), and its <code>pause:</code> slept 10 ms after every main-loop turn, which "
                f"skipped frames (the cancel's gap was 50–67 ms in 6 of 6 runs, 16.7–50 ms after). {r['runs']} of {r['runs']} "
                f"runs pass now.")
    if step == "jot_queue":
        return ("A field change that arrives during a rebuild waits in a queue (D-1321); a newer change of the same field "
                "that reached the app directly left the older one waiting, and the next rebuild wrote it back over the "
                "newer text. A direct change now clears the field's queue (<code>tests/test_field_queue.py</code>, red "
                "before: the app ended with the older text).")
    if step == "jot_drop":
        return ("On the web: an upload that finished after its tab was evicted crashed the whole server (it reached the "
                "closed app) and a drop left its files; both now clean up after themselves. A starting server sweeps "
                "the folders a crashed one left, and a file over the upload limit shows a notice instead of vanishing "
                "(<code>tests/test_web_files.py</code>, and in Chromium: <code>docs/goals/probe-fixes/web-notice.png</code>).")
    if step == "keeper_stamp":
        return ("<code>file_stamp</code> (what a rescan compares) read x86-64's <code>struct stat</code> at fixed offsets, and "
                "its test found a worse bug: a short path was freed before <code>stat</code> read it, so the file looked "
                "unreadable. It now reads <code>statx</code>, which has one layout on every Linux, keeps the path alive, "
                "and compiles for aarch64 (not run there: no such machine here) (<code>tests/test_file_stamp.py</code>).")
    if step == "keeper_handover":
        return ("Launching Keeper again used to build a whole second app (open the index, start a watcher) before it "
                "handed over to the running one. Apps now name themselves with <code>App.one_instance()</code>, a static "
                "method the host asks first, so a second launch opens the running window and exits having built nothing "
                "(goal 45 M1, with a new check).")
    if step == "sketch_erase":
        runs = ", ".join(f"{v:g}" for v in r["runs_p95_ms"])
        return (f"Erasing took {r['before_p95_ms']:g} ms p95 here: every erased stroke rebuilt the whole page's render node "
                f"(6.1 ms) and the mend walked all 1,000 strokes to redraw one small box (11.1 ms). The framework now keeps "
                f"the other strokes' nodes (<code>Scene.removed_ops</code>) and mends with only the nodes near the box: "
                f"{r['after_p95_ms']:g} ms p95 (six runs on a shared machine: {runs} ms), pixel for pixel the CPU's picture.")
    return escape(r.get("summary", ""))


def main():
    results = json.loads(RESULTS.read_text()) if RESULTS.exists() else {}
    page = PAGE.read_text()
    for section, steps in SECTIONS.items():
        items = [line(s, results[s]) for s in steps if s in results]
        start = page.index(f'id="{section}"')
        end = page.index("</article>", start)
        art = page[start:end]
        if "<article" in art:  # (the Database section once lacked its closing tags: a note landed in the next section)
            raise SystemExit(f"gallery: section {section} doesn't close before the next one starts")
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
