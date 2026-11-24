"""Goal 79, continuation 20: a person's first five minutes in native pnote, with real pointer and key events (xdrive.py: XTEST
on a headless Xvfb, CPU only), each step checked in the notes file or the boxes drawn and a picture kept
(build/g79/first5-*.png); then the web app's own code reads what was written (first5web.py), and this reads what it wrote.
  pixi run python docs/goals/79/first5.py [fresh|again]"""
import json
import shutil
import sqlite3
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from xdrive import App, ROOT

W = ROOT / "build/first5"
OUT = ROOT / "build/g79"
DB = W / "data/notes.db"
bad = []


def env():
    return {"OMX_DATA": str(W / "data"), "OMX_CONFIG": str(W / "cfg"), "HOME": str(W / "home"), "PNOTE_BOXES": str(W / "boxes.json")}


def rows(sql, *a):
    c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    try:
        return c.execute(sql, a).fetchall()
    finally:
        c.close()


def check(ok, what):
    print(("ok   " if ok else "BAD  ") + what, flush=True)
    if not ok:
        bad.append(what)


def note(title):
    r = rows("SELECT content FROM notes WHERE title = ?", title)
    return json.loads(r[0][0]) if r else None


def shot(a, name):
    a.shot(OUT / f"first5-{name}.png")


def wait_saved(f, t=4):
    end = time.time() + t
    while time.time() < end:
        try:
            v = f()
            if v:
                return v
        except Exception:
            pass
        time.sleep(0.1)
    return None


def fresh():
    for d in ["data", "cfg", "home"]:
        shutil.rmtree(W / d, ignore_errors=True)
        (W / d).mkdir(parents=True)
    a = App(env(), W / "log.txt")
    check(rows("SELECT COUNT(*) FROM notes")[0][0] == 1 and rows("SELECT name FROM notebooks") == [("My Notes",)], "a first start makes the file, a notebook and a canvas")
    shot(a, "01-start")
    a.tap("#toggle-sidebar")
    shot(a, "02-panel")
    # a page: made from the search, typed as a person types
    a.key("k", "Ctrl", wait=0.4)
    a.type("new page")
    shot(a, "03-search-action")
    a.key("Enter", wait=0.6)
    check(rows("SELECT COUNT(*) FROM notes WHERE note_type = 'page'")[0][0] == 1, "New page from the search")
    a.type("# Trip to Goa\n\nA **bold** plan, a *slanted* one, `code`, ~~struck~~ and [a link](https://example.org/x).\n\n- [ ] tickets\n- bags\n\n```py\nx = 1\n```\n")
    a.type("The end of it is a long line that must wrap because it goes on and on past the width of the sheet, and then some more words after that.", wait=1.2)
    md = wait_saved(lambda: (note("Untitled note") or {}).get("markdown") or [json.loads(r[0])["markdown"] for r in rows("SELECT content FROM notes WHERE note_type = 'page'")][0])
    check(md and md.startswith("# Trip to Goa\n\nA **bold** plan") and md.endswith("after that."), f"what was typed is saved: {md!r}"[:300])
    shot(a, "04-page")
    # selection, copy, paste, undo
    a.key("Home", "Ctrl")
    a.key("End", "Shift")
    a.key("c", "Ctrl", wait=0.3)
    a.key("End", "Ctrl")
    a.key("Enter")
    a.key("v", "Ctrl", wait=0.6)
    shot(a, "05-pasted")
    md = wait_saved(lambda: [x for x in [json.loads(r[0])["markdown"] for r in rows("SELECT content FROM notes WHERE note_type = 'page'")] if x.endswith("\n# Trip to Goa")])
    check(bool(md), "copied and pasted through the system clipboard")
    a.key("z", "Ctrl", wait=0.2)
    a.key("z", "Ctrl", wait=0.9)
    md = wait_saved(lambda: [x for x in [json.loads(r[0])["markdown"] for r in rows("SELECT content FROM notes WHERE note_type = 'page'")] if x.endswith("after that.")])
    check(bool(md), "undone")
    b = a.boxes()
    px, py, pw, ph = b[".page-paper"]
    a.click(px + 160, py + 115, n=2)
    shot(a, "06-word")
    a.drag(px + 130, py + 120, px + 500, py + 260)
    shot(a, "07-drag-selection")
    a.click(px + 160, py + 115)
    # its title, through the island's card
    a.tap("#share-button")
    shot(a, "08-card")
    a.tap("#note-title")
    a.key("a", "Ctrl")
    a.type("Goa é")
    a.key("Enter", wait=0.8)
    check(rows("SELECT COUNT(*) FROM notes WHERE title = 'Goa é'")[0][0] == 1, "renamed with é")
    shot(a, "09-renamed")
    # filed
    a.tap("#share-button")
    a.tap("#share-props")
    a.tap("#notebook-picker")
    shot(a, "10-props")
    a.tap("[Move to 1]", wait=0.8)
    check(rows("SELECT notebook_id FROM notes WHERE title = 'Goa é'") == [(1,)], "filed in My Notes")
    a.click(1300, 820)
    shot(a, "11-filed")
    # a long page
    a.key("k", "Ctrl", wait=0.4)
    a.type("new page")
    a.key("Enter", wait=0.6)
    for i in range(60):
        a.type(f"line {i} of a long page\n", wait=0)
    time.sleep(1.0)
    shot(a, "12-long-end")
    a.wheel(860, 500, -30)
    shot(a, "13-long-scrolled")
    a.key("Home", "Ctrl", wait=0.4)
    a.key("PageDown", wait=0.4)
    shot(a, "14-long-pagedown")
    # ink on it
    a.tap(".page-tool:Highlighter")
    b = a.boxes()
    ex, ey, ew, eh = next(v for k, v in b.items() if k.startswith(".page-editor"))
    a.drag(ex + 2, max(ey, 200) + 90, ex + 120, max(ey, 200) + 92)
    a.tap(".page-tool:Red")
    a.path([(ex + 200 + 8 * i, 400 + (12 if i % 2 else -12)) for i in range(10)])
    shot(a, "15-ink")
    a.tap(".page-tool:Eraser")
    a.drag(ex + 190, 400, ex + 290, 400)
    a.tap(".page-tool:Write")
    shot(a, "16-erased")
    marks = wait_saved(lambda: [len(json.loads(r[0])["ink"]["marks"]) for r in rows("SELECT content FROM notes WHERE content LIKE '%long page%'")][0] == 1)
    check(bool(marks), "a highlight saved, the red one erased")
    # delete it, take it back, delete it for good
    n = rows("SELECT COUNT(*) FROM notes")[0][0]
    a.tap("#share-button")
    a.tap("#share-props")
    a.tap("#delete-note")
    shot(a, "17-deleted")
    a.tap("#toast-action")
    check(rows("SELECT COUNT(*) FROM notes WHERE content LIKE '%long page%'")[0][0] == 1, "deleted and taken back")
    shot(a, "18-undone")
    # search with é, a word inside
    a.key("k", "Ctrl", wait=0.4)
    a.type("é")
    shot(a, "19-search-e")
    a.key("BackSpace", wait=0.3)
    a.type("bags")
    shot(a, "20-search-word")
    a.key("Enter", wait=0.6)
    check(any("Goa" in k for k in a.boxes() if k.startswith(".isl-face")), "a word inside a note finds it")
    # a canvas
    a.tap("#rail-new-note", wait=0.8)
    shot(a, "21-canvas")
    b = a.boxes()
    X0, Y0 = 620, 260
    a.click(X0, Y0)
    a.type("Words on the board that wrap when they reach the margin of the page, as they should do")
    a.key("Enter")
    a.type("second é line")
    shot(a, "22-words")
    # Control tapped twice: the pen; and back to the words, the caret where it was
    for _ in range(2):
        a.key("Control_L", wait=0.08)
    time.sleep(0.3)
    shot(a, "22b-pen")
    for _ in range(2):
        a.key("Control_L", wait=0.08)
    time.sleep(0.3)
    a.type(" !")
    shot(a, "22c-words-again")
    a.key("Escape", wait=0.4)
    a.tap("[Shape]")
    shot(a, "23-shape-tool")
    a.click(700, 560)
    a.tap("[Sticky note]")
    a.click(820, 420)
    a.type("sticky words")
    a.key("Escape", wait=0.4)
    shot(a, "24-shapes")
    a.tap("[Pen]")
    a.tap("#ink-options-trigger")
    shot(a, "25-colours")
    a.tap("ink-color:2")
    a.tap("ink-width:2")
    a.tap("#ink-options-trigger")
    a.path([(560 + 10 * i, 640 + (20 if i % 2 else 0)) for i in range(20)])
    a.tap("#dock-more")
    shot(a, "26-flyout")
    a.tap("[Highlighter]")
    a.drag(560, 600, 760, 605)
    a.tap("[Stroke eraser]")
    a.drag(660, 600, 665, 680)
    shot(a, "27-ink")
    a.tap("[Select]")
    a.drag(520, 230, 1000, 700)
    shot(a, "28-marquee")
    a.key("Right")
    a.key("Down", "Shift")
    a.key("Escape")
    a.click(700, 560)
    shot(a, "29-selected")
    a.click(X0 + 60, Y0 + 12, n=2, wait=0.6)
    shot(a, "30-edit-again")
    a.key("Escape", wait=1.0)
    c = rows("SELECT content FROM notes ORDER BY updated_at DESC, id DESC LIMIT 1")[0][0]
    kinds = [(n.get("pn") or {}).get("type") for n in json.loads(c)["nodes"]]
    check(sorted(set(k for k in kinds if k)) == ["ink", "shape", "sticky", "text"], f"the board's objects saved: {kinds}")
    # a mind map
    a.key("k", "Ctrl", wait=0.4)
    a.type("new mind")
    a.key("Enter", wait=0.8)
    shot(a, "31-map")
    a.key("Tab", wait=0.3)
    a.type("Places é")
    a.key("Enter", wait=0.4)
    a.key("Enter", wait=0.3)
    a.type("People")
    a.key("Enter", wait=0.4)
    shot(a, "32-map-ideas")
    b = a.boxes()
    k = next(k for k in b if k == "[People]")
    x, y, w, h = b[k]
    a.drag(x + w / 2, y + h / 2, x + w / 2 + 60, y + h / 2 + 90)
    a.key("Tab", wait=0.3)
    a.type("Ana")
    a.key("Enter", wait=0.4)
    a.key("Delete", wait=0.4)
    a.key("z", "Ctrl", wait=0.4)
    a.wheel(900, 450, -2)
    shot(a, "33-map-moved")
    a.tap("[Fit map]", wait=1.2)
    m = json.loads(rows("SELECT content FROM notes WHERE note_type = 'mindmap'")[0][0])
    check(sorted(n["text"] for n in m["nodes"]) == ["Ana", "Central idea", "People", "Places é"], f"the map saved: {[n['text'] for n in m['nodes']]}")
    shot(a, "34-map-fit")
    # its words written in the box: the centre, a long one, the caret moved, a word picked with the pointer
    x, y, w, h = a.boxes()["[Central idea]"]
    a.click(x + w / 2, y + h / 2, n=2, wait=0.6)
    shot(a, "34b-map-writing")
    a.type("A plan for the summer trip to Goa")
    a.key("Home", wait=0.1)
    a.key("Delete", wait=0.1)
    a.type("The")
    shot(a, "34c-map-caret")
    a.key("Enter", wait=1.0)
    m = json.loads(rows("SELECT content FROM notes WHERE note_type = 'mindmap'")[0][0])
    check(m["nodes"][0]["text"] == "The plan for the summer trip to Goa", f"the centre rewritten: {m['nodes'][0]['text']}")
    shot(a, "34d-map-centre")
    # a new notebook, a row dragged on it
    b = a.boxes()
    sx, sy, sw, sh = b[".sec-head@2"]
    a.move(sx + sw / 2, sy + sh / 2)
    time.sleep(0.4)
    shot(a, "35-plus")
    a.click(sx + sw - 8 - 14 - 8 - 7, sy + sh / 2)
    a.type("Travel é")
    shot(a, "36-naming")
    a.key("Enter", wait=0.6)
    check(rows("SELECT COUNT(*) FROM notebooks WHERE name = 'Travel é'")[0][0] == 1, "a new notebook")
    b = a.boxes()
    r = next(k for k in b if k.startswith("row:") and "mind map" in k.lower() or k.startswith("row:🧠"))if any(k.startswith("row:") and "Untitled" in k for k in b) and False else next(k for k in b if k.startswith("row:"))
    rx, ry, rw, rh = b[r]
    t = next(k for k in b if k.startswith(".nav-row:Travel"))
    tx, ty, tw, th = b[t]
    a.move(rx + 60, ry + 17)
    a.button(1, True)
    for i in range(1, 11):
        a.move(rx + 60 + (tx + 60 - rx - 60) * i / 10, ry + 17 + (ty + 15 - ry - 17) * i / 10)
    shot(a, "37-dragging")
    a.button(1, False)
    time.sleep(0.7)
    check(rows("SELECT COUNT(*) FROM notes WHERE notebook_id = 2")[0][0] == 1, "a row dragged onto it")
    shot(a, "38-dropped")
    code = a.close()
    check(code == 0, f"closes by its close button: {code}")


def again():
    a = App(env(), W / "log2.txt")
    shot(a, "40-restarted")
    a.tap("#toggle-sidebar")
    b = a.boxes()
    check(any(k.startswith("row:") for k in b) and any(k.startswith(".nav-row:Travel") for k in b), "everything is in the panel")
    shot(a, "41-panel-again")
    for q, name in [("goa", "42-page-again"), ("second", "43-canvas-again"), ("people", "44-map-again")]:
        a.key("k", "Ctrl", wait=0.4)
        a.type(q)
        a.key("Enter", wait=1.0)
        shot(a, name)
    b = a.boxes()
    for k, name in [("row:🎨 Untitled note", "45-hover-row"), (next(k for k in b if k.startswith(".nav-row:My Notes")), "46-hover-notebook"), (".sec-head@2", "47-hover-shelf")]:
        x, y, w, h = b[k]
        a.move(x + 60, y + h / 2)
        time.sleep(0.5)
        shot(a, name)
    check(a.close() == 0, "closes")


def back():
    """The copy the web edited (first5web.mjs), opened again."""
    for d in ["data2", "cfg2"]:
        shutil.rmtree(W / d, ignore_errors=True)
        (W / d).mkdir(parents=True)
    for x in ["", "-wal"]:
        if Path(str(W / "web.db") + x).exists():
            shutil.copy(str(W / "web.db") + x, str(W / "data2/notes.db") + x)
    e = dict(env(), OMX_DATA=str(W / "data2"), OMX_CONFIG=str(W / "cfg2"))
    a = App(e, W / "log3.txt")
    shot(a, "50-back")
    for q, name in [("web was here", "51-back-page"), ("typed in the web", "52-back-canvas")]:
        a.key("k", "Ctrl", wait=0.4)
        a.type(q)
        shot(a, name + "-search")
        a.key("Enter", wait=1.2)
        shot(a, name)
    a.type("native again")
    a.key("Escape", wait=1.2)
    c = sqlite3.connect(f"file:{W / 'data2/notes.db'}?mode=ro", uri=True)
    r = [x[0] for x in c.execute("SELECT content FROM notes")]
    check(any("The web was here" in x for x in r) and any("typed in the web" in x and "sticky words" in x for x in r), "both apps' words are there")
    check(any("native again" in x and "typed in the web" in x for x in r), "and native goes on from the web's")
    # Quick note: what kind, by the other button and by a hold (the web's note-create menu)
    count = lambda: sqlite3.connect(f"file:{W / 'data2/notes.db'}?mode=ro", uri=True).execute("SELECT COUNT(*) FROM notes").fetchone()[0]
    if "#rail-new-note" not in a.boxes():
        a.tap("#toggle-sidebar", wait=0.8)
    x, y, w, h = a.boxes()["#rail-new-note"]
    n0 = count()
    a.move(x + w / 2, y + h / 2)
    a.button(3, True)
    a.button(3, False)
    time.sleep(0.5)
    shot(a, "48-new-menu")
    check("menu.item:2" in a.boxes(), "the other button asks what kind of note")
    a.key("Escape", wait=0.4)
    a.move(x + w / 2, y + h / 2)
    a.button(1, True)
    time.sleep(0.6)
    a.button(1, False)
    time.sleep(0.4)
    check("menu.item:2" in a.boxes() and count() == n0, "held, it asks too and makes nothing yet")
    a.tap("menu.item:2", wait=0.9)
    check(sqlite3.connect(f"file:{W / 'data2/notes.db'}?mode=ro", uri=True).execute("SELECT note_type FROM notes ORDER BY id DESC LIMIT 1").fetchone()[0] == "mindmap" and count() == n0 + 1, "a mind map is made")
    check(a.close() == 0, "closes")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    app = ROOT / "build/pnote/linux/pnote"
    newer = [str(f) for d in ["examples/pnote", "mojoui", "hosts"] for f in (ROOT / d).rglob("*.mojo") if not app.exists() or f.stat().st_mtime > app.stat().st_mtime]
    if newer:  # (a walk of yesterday's app says nothing)
        sys.exit(f"first5: REFUSED: build first (scripts/build.sh pnote linux); newer than the app: {newer[:4]}")
    for part in sys.argv[1:] or ["fresh", "again"]:
        {"fresh": fresh, "again": again, "back": back}[part]()
    print("first5:", "ok" if not bad else f"{len(bad)} BAD: " + "; ".join(bad))
