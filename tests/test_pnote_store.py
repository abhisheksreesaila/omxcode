"""Goal 79 (D-7927): pnote's web look on Personal Note's own database, end to end on the hidden test screen.

1. A secure note (its words only sealed, an empty placeholder in `content`, as services.save_note leaves it) opens as a
   locked cover; typing, pasting, Backspace, Enter and a rename through the island card change nothing in the file:
   content, title, revision, sealed and its search row are byte-for-byte what they were.
2. A save conflict: pnote opens a page, another writer (the web app) saves it behind pnote's back, then pnote types.
   pnote's save carries the revision it read, so it writes nothing, says "Couldn’t save", and the newer words stay.
3. The debounce: a burst of keys is one write (one new revision), 650 ms after the last key.

    pixi run python tests/test_pnote_store.py            → "pnote store: ok"   (needs scripts/build.sh pnote linux)
"""
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build/pnote/linux/pnote"
REF_DB = ROOT / "build/g79/ref/pn.db"
OUT = ROOT / "build/g79/store"


def fail(why):
    print("pnote store: FAIL " + why)
    sys.exit(1)


def run_app(db, steps, cfg, during=None):
    env = dict(os.environ, PNOTE_DB=str(db), PNOTE_SKIN="paper", OMX_CONFIG=str(cfg), PNOTE_DIR=str(cfg),
               PNOTE_BOXES=str(OUT / "boxes.json"), MOJOUI_TEST=";".join(steps[:1] + ["render:desk=" + str(OUT / "first.png")] + steps[1:]), MOJOUI_SHOT="")
    # (a render step shows the test window; without one it is never drawn and taps find no boxes)
    p = subprocess.Popen([str(ROOT / "scripts/testscreen"), str(APP)], cwd=ROOT, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True)
    if during:
        threading.Thread(target=during, daemon=True).start()
    out, _ = p.communicate(timeout=300)
    return out


def row(db, nid):
    c = sqlite3.connect(db)
    r = c.execute("SELECT title, content, revision, sealed, updated_at FROM notes WHERE id = ?", (nid,)).fetchone()
    s = c.execute("SELECT title, body FROM note_search WHERE note_id = ?", (nid,)).fetchall()
    c.close()
    return r, s


def box(name):
    b = json.loads((OUT / "boxes.json").read_text())
    items = b if isinstance(b, list) else b.get("boxes", b)
    for it in items if isinstance(items, list) else []:
        if it.get("name") == name:
            return it
    if isinstance(items, dict) and name in items:
        v = items[name]
        return {"x": v[0], "y": v[1], "w": v[2], "h": v[3]}
    return None


def centre(name):
    b = box(name)
    if not b:
        fail(f"no box {name} in {OUT / 'boxes.json'}")
    # (tapat takes thousandths of the canvas, 1440 × 900 logical px)
    return f"{(b['x'] + b['w'] / 2) / 1440 * 1000:.0f},{(b['y'] + b['h'] / 2) / 900 * 1000:.0f}"


def main():
    if not APP.exists() or not REF_DB.exists():
        fail("build pnote (scripts/build.sh pnote linux) and the reference (scripts/check M0) first")
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    cfg = OUT / "cfg"
    cfg.mkdir()

    # ---- 1. a secure note, locked, never written
    db = OUT / "secure.db"
    shutil.copy(REF_DB, db)
    c = sqlite3.connect(db)
    nid = c.execute("SELECT id FROM notes WHERE title = 'Reading list'").fetchone()[0]
    # services.save_note on a secure note: placeholder content, words sealed, search sees the title only; newest so it opens first
    c.execute("UPDATE notes SET secure = 1, secure_key_id = 'k1', seal_id = 's1', sealed = 'SEALED-BLOB', "
              "content = '{\"version\":1,\"markdown\":\"\",\"ink\":{\"marks\":[],\"drawings\":[]}}', updated_at = '2099-01-01 00:00:00' WHERE id = ?", (nid,))
    c.execute("DELETE FROM note_search WHERE note_id = ?", (nid,))
    c.execute("INSERT INTO note_search (note_id, title, body) VALUES (?, 'Reading list', '')", (nid,))
    c.commit()
    c.close()
    before = row(db, nid)
    out = run_app(db, ["wait:1200", "render:desk=" + str(OUT / "secure.png"), "wait:200"], cfg)
    if "PNOTE WEB:" not in out:
        fail("the web look didn't start: " + out[-400:])
    if not box("locked-cover") or not box("locked-heading:Locked note"):
        fail("the secure note didn't open as a locked cover (no locked-cover box)")
    if box(".page-paper") or box(".cm-content"):
        fail("the secure note's page was drawn under the cover")
    island = centre("#share-button")
    steps = ["wait:1200", "typekeys:desk=leak", "key:desk=Return", "key:desk=BackSpace", "clipboard:pasted words", "key:desk=ctrl+v",
             "wait:900", f"tapat:desk={island}", "wait:300", "render:desk=" + str(OUT / "card.png"), "wait:100"]
    out = run_app(db, steps, cfg)
    title_field = centre("#note-title")
    steps2 = ["wait:1500", f"tapat:desk={island}", "wait:600", f"tapat:desk={title_field}", "wait:300", "key:desk=ctrl+a", "typekeys:desk=Renamed", "wait:200",
              "key:desk=Return", "wait:900", "quit"]
    out += run_app(db, steps2, cfg)
    after = row(db, nid)
    if after != before:
        fail(f"the secure note changed: {before} → {after}")
    if f"PNOTE SAVE: refused (note {nid}: secure" not in out:  # (the words since goal 79's ddabcd7c, review 3; this very note: D-8209)
        fail("the rename never reached the save path (no refusal logged): " + " | ".join(l for l in out.splitlines() if l[:5] in ("PNOTE", "TEST:"))[-600:])
    if "PNOTE ERROR" in out:
        fail("errors: " + " | ".join(l for l in out.splitlines() if "PNOTE ERROR" in l)[:400])
    print(f"  secure: locked cover drawn; typed, pasted, renamed: row and search unchanged (revision {after[0][2]})")

    # ---- 2. a conflict: the web saves the page behind pnote's back, then pnote types
    db2 = OUT / "conflict.db"
    shutil.copy(REF_DB, db2)
    c = sqlite3.connect(db2)
    pid = c.execute("SELECT id FROM notes WHERE title = 'Weekly review'").fetchone()[0]
    c.execute("UPDATE notes SET updated_at = '2099-01-01 00:00:00' WHERE id = ?", (pid,))
    c.commit()
    c.close()
    rev0 = row(db2, pid)[0][2]
    theirs = '{"version":1,"markdown":"# Saved by the web\\n","ink":{"marks":[],"drawings":[]}}'

    def web_saves():
        time.sleep(2.5)  # (pnote has opened the page by now; it types at 4 s)
        k = sqlite3.connect(db2, timeout=10)
        k.execute("UPDATE notes SET content = ?, revision = revision + 1 WHERE id = ?", (theirs, pid))
        k.commit()
        k.close()

    out = run_app(db2, ["wait:4000", "typekeys:desk=mine", "wait:1500", "quit"], cfg, during=web_saves)
    r2 = row(db2, pid)[0]
    if r2[1] != theirs:
        fail(f"pnote overwrote the newer web save: {r2[1][:120]!r}")
    if r2[2] != rev0 + 1:
        fail(f"revision {r2[2]}, expected {rev0 + 1} (the web's save only)")
    if "PNOTE SAVE: conflict" not in out:
        fail("no conflict reported: " + " | ".join(l for l in out.splitlines() if l.startswith("PNOTE"))[:400])
    print(f"  conflict: the web's revision {r2[2]} kept, pnote said 'Couldn’t save'")

    # ---- 3. the debounce: eight keys, one write
    db3 = OUT / "debounce.db"
    shutil.copy(db2.parent / "conflict.db", db3) if False else shutil.copy(REF_DB, db3)
    c = sqlite3.connect(db3)
    c.execute("UPDATE notes SET updated_at = '2099-01-01 00:00:00' WHERE id = ?", (pid,))
    c.commit()
    c.close()
    rev0 = row(db3, pid)[0][2]
    out = run_app(db3, ["wait:1500", "typekeys:desk=eightkey", "wait:1500", "quit"], cfg)
    r3 = row(db3, pid)
    if r3[0][2] != rev0 + 1:
        fail(f"eight keys made {r3[0][2] - rev0} revisions (want one write after the burst)")
    if "eightkey" not in json.loads(r3[0][1])["markdown"]:
        fail("the typed words weren't saved: " + r3[0][1][:160])
    if not any("eightkey" in b for _, b in r3[1]):
        fail("the search row lacks the typed words")
    print(f"  debounce: 8 keys → 1 revision ({rev0} → {r3[0][2]}), search row updated")
    print("pnote store: ok")


if __name__ == "__main__":
    main()
