"""The gallery's "Works when closed" race table, drawn from docs/goals/45/web.json (goal 45), so every web number on the
page is one web.json holds. Native's column takes the numbers the final checker run printed (passed on the command line).

    pixi run python scripts/keeper_gallery.py --scan-s 1.9 --watch-p95 0.01 --index-p95 0.7
"""

import argparse
import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "docs" / "goals" / "45" / "web.json"
PAGE = ROOT / "docs" / "gallery" / "index.html"


def esc(s):
    return html.escape(str(s), quote=False)  # (apostrophes kept as typed: the checker finds web.json's text on the page)


def evidence(thing, e):
    """A short line of what was observed, from web.json's own fields."""
    if thing == "read_folder":
        ev = e["tries"]["cdp_granted"]["evidence"]
        reads = e.get("race", {}).get("tries", [])
        each = "; ".join(f"{r['how']} {r['ms'] / 1000:.1f} s" for r in reads)
        return (f"no gesture: {e['tries']['no_gesture']['evidence'].split(': ', 1)[1]} With a DevTools gesture the picker opens and can't be "
                f"answered headless ({ev['picker_intercepted']['promise'].split(':')[0]}); a dropped folder gives a handle. Every read of the "
                f"100,000 files: {each}")
    if thing == "notice_change":
        fso = e["tries"]["FileSystemObserver"]["evidence"]
        polls = e["tries"]["polling"]["evidence"].get("every_try", [])
        bits = [f"FileSystemObserver p95 {fso['p95_ms']} ms over {fso['seen']} of {fso['of']} (missed {', '.join(fso['missed']) or 'none'})"]
        bits += [f"polling every {p['every_ms']} ms p95 {p['p95_ms']} ms ({p['seen']}/{p['of']})" for p in polls]
        return "; ".join(bits)
    if thing == "run_closed":
        t = e["tries"]
        return (f"Background Sync registered ({t['background_sync']['evidence']['registered']}): events after a file change "
                f"{len(t['background_sync']['evidence']['events_after_a_file_change'])}, in the 75 s after close "
                f"{len(t['background_sync']['evidence']['events_in_the_75_s_after_close'])}; ran when the network came back: "
                f"{t['background_sync']['evidence']['ran_when_the_network_came_back']}. Periodic Sync: permission "
                f"{t['periodic_sync']['evidence']['permission']}, {t['periodic_sync']['evidence']['register']}, no event "
                f"({t['periodic_sync']['evidence']['by_design']}). Web Push: subscribe gave {t['web_push']['evidence']['subscribe']}")
    if thing == "notify_closed":
        woken = e["evidence"]["what_a_worker_could_do_when_woken"]
        return (f"{e['evidence']['why']}; when the network woke the held sync: "
                + (woken[0].split("notify=[", 1)[1].rstrip("]") if woken else "nothing"))
    return f"tray-like names in window/navigator: {e['evidence']['tray_like_names_in_window_and_navigator']}; {e['evidence']['note']}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scan-s", required=True)
    ap.add_argument("--watch-p95", required=True)
    ap.add_argument("--index-p95", required=True)
    a = ap.parse_args()
    w = json.loads(WEB.read_text())
    native = {
        "read_folder": f"reads and indexes all 100,000 files in {a.scan_s} s, no click (KEEPER_DIR)",
        "notice_change": (f"inotify on its own thread, p95 {a.watch_p95} ms as the consumer's thread receives it (the later of the reader's "
                          f"and the consumer's stamps; M0's 1,000 mixed changes 2 ms apart, the web's 200 creates 20 ms apart: different "
                          f"workloads), window open or closed"),
        "run_closed": f"keeps indexing with the window closed: 200 files searchable p95 {a.index_p95} ms",
        "notify_closed": "one notification per burst of alert files, window closed (seen on the bus)",
        "tray": "a StatusNotifierItem with a menu (Open, Quit); Activate opens the window",
    }
    rows = ["<tr><th></th><th>omxcode (Keeper)</th><th>The web's best, with evidence</th></tr>"]
    for thing, e in w["entries"].items():
        rows.append(f"<tr><th>{esc(e['label'])}</th><td>{esc(native[thing])}</td><td><b>{'Yes' if e['can'] else 'No'}</b>: "
                    f"{esc(e['summary'])}<br><small>{esc(evidence(thing, e))}</small></td></tr>")
    table = '<table class="race">' + "".join(rows) + "</table>"
    page = PAGE.read_text()
    start = page.index('id="works-when-closed"')
    t0 = page.index('<table class="race">', start)
    t1 = page.index("</table>", t0) + len("</table>")
    page = page[:t0] + table + page[t1:]
    m = re.search(r"headless Chromium [\d.]+", page[start:])
    if m:
        page = page[:start] + page[start:].replace(m.group(0), "headless Chromium " + w["chromium"], 1)
    PAGE.write_text(page)
    print("wrote the Works when closed table from", WEB.relative_to(ROOT))


if __name__ == "__main__":
    main()
