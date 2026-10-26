"""Where each tagged view sits on the web and on the Mac, and how far apart (goal 32: "nobody can tell them apart").

  pixi run python scripts/parity.py              every screen scripts/side.py shot, as a table
  parity.compare(web_rects_text, mac_views_text) → rows (key, web rect, mac rect, ok) for a check

The web's rects come from scripts/drive.py's RECTS (every [data-tag] view, and each button whose nearest tagged view is
it); the Mac's from the AppKit host's view dump (each line's #tag). A key is a tag (its second use "#tag 2"), or a
tagged view's button by its title ("toolbar/Add row"). Close enough: within 4 pt, or 3 % of the size.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOL_PT, TOL_PCT = 4, 0.03
RECT = re.compile(r"@ (-?\d+),(-?\d+) (\d+)x(\d+)")


def _key(seen, k):
    seen[k] = seen.get(k, 0) + 1
    return k if seen[k] == 1 else f"{k} {seen[k]}"


def web_rects(text):
    out, seen, owner = {}, {}, None
    for line in text.splitlines():
        m = RECT.search(line)
        if not m:
            continue
        r = tuple(int(v) for v in m.groups())
        if line.startswith("  button "):
            name = json.loads(line[len("  button "):m.start()].strip())
            out[_key(seen, f"{owner}/{name}")] = r
        else:
            tag = line.split(" #", 1)[1].split(" @", 1)[0]
            owner = _key(seen, tag)
            out[owner] = r
    return out


def mac_rects(text):
    """The view dump's tree: a tagged line is a key; a Button under a tagged view (its nearest) is "tag/title"."""
    out, seen, tagged = {}, {}, []  # tagged: (depth, key) of the open tagged views
    for line in text.splitlines():
        m = RECT.search(line)
        depth = (len(line) - len(line.lstrip(" "))) // 2
        while tagged and tagged[-1][0] >= depth:
            tagged.pop()
        if not m or " hidden" in line:
            continue
        r = tuple(int(v) for v in m.groups())
        body = line.strip()
        tag = re.search(r" #(\S+)", body)  # (a tag is everything to the space, as web_rects reads it: a model's name has dots, D-501)
        if tag:
            key = _key(seen, tag.group(1))
            out[key] = r
            tagged.append((depth, key))
        elif body.startswith("Button ") and tagged:
            name = re.match(r"Button '(.*)'", body)
            if name:
                out[_key(seen, f"{tagged[-1][1]}/{name.group(1)}")] = r
    return out


def close(a, b):
    return all(abs(x - y) <= max(TOL_PT, TOL_PCT * max(abs(x), abs(y))) for x, y in zip(a, b))


def compare(web_text, mac_text):
    """[(key, web rect or None, mac rect or None, ok)] for every key either side has."""
    web, mac = web_rects(web_text), mac_rects(mac_text)
    rows = []
    for k in list(web) + [k for k in mac if k not in web]:
        w, m = web.get(k), mac.get(k)
        rows.append((k, w, m, w is not None and m is not None and close(w, m)))
    return rows


def fmt(r):
    return "—" if r is None else f"{r[0]},{r[1]} {r[2]}x{r[3]}"


def table(rows):
    return "\n".join(f"{'ok ' if ok else 'OFF'}  {k:<40} web {fmt(w):<22} mac {fmt(m)}" for k, w, m, ok in rows)


if __name__ == "__main__":
    sys.path.insert(0, str(ROOT / "scripts"))
    import side
    mac_dir = side.mac_dir()
    for app, screen, _, _ in side.screens():
        web = side.OUT / f"{app}-{screen}-web-rects.txt"
        mac = mac_dir / f"{app}-{screen}-views.txt" if mac_dir else None
        if not web.exists() or not mac or not mac.exists():
            print(f"== {app} · {screen}: no {'web rects' if not web.exists() else 'Mac dump'}")
            continue
        rows = compare(web.read_text(), mac.read_text())
        print(f"== {app} · {screen}: {sum(r[3] for r in rows)} of {len(rows)} close")
        print(table(rows))
