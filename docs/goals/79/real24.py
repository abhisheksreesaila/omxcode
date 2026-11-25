"""What was said to be fixed and had only a test without a window (continuation 24): in the real app, with real input on a headless X
server, CPU drawing, scratch files; the real web app beside it where it matters.
   pixi run python -B docs/goals/79/real24.py [parts]"""
import json, os, re, shutil, sqlite3, subprocess, sys, time
from pathlib import Path
import numpy as np
from PIL import Image
sys.path.insert(0, str(Path(__file__).parent))
from xdrive import App, ROOT, X, free_port, own_group, end_group
import ctypes
X.XRaiseWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
W = ROOT / "build/real24"
bad = []


def note(ok, what):
    print(("ok   " if ok else "BAD  ") + what, flush=True)
    if not ok:
        bad.append(what)


class Place:
    def __init__(self, name, kinds, web=True):
        self.w = W / name
        shutil.rmtree(self.w, ignore_errors=True)
        for d in ["data", "cfg", "home", "web"]:
            (self.w / d).mkdir(parents=True)
        self.db = self.w / "data/notes.db"
        self.p = None
        self.logs = []
        self.port = str(free_port())
        self.p = subprocess.Popen(["nice", "taskset", "-c", "4-7", "node", str(ROOT / "docs/goals/79/webside.mjs"), str(self.db), self.port, str(self.w / "web")],
                                  cwd=os.path.expanduser("~/Projects/personalnotev2"), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, preexec_fn=own_group)
        import atexit
        atexit.register(end_group, self.p)
        while not self.p.stdout.readline().startswith("READY"):
            pass
        for k, t in kinds:
            self.web("make", k, t)
        self.web("reload")

    def web(self, *a):
        self.p.stdin.write(json.dumps(a) + "\n")
        self.p.stdin.flush()
        while True:
            l = self.p.stdout.readline()
            assert l, "the web side ended"
            if l.startswith("R "):
                return json.loads(l[2:])

    def api(self, method, path, body=None):
        import urllib.request
        q = urllib.request.Request(f"http://127.0.0.1:{self.port}/api{path}", method=method, data=json.dumps(body).encode() if body is not None else None,
                                   headers={"x-personal-note": "1", "content-type": "application/json"})
        try:
            with urllib.request.urlopen(q, timeout=10) as r:
                return r.status
        except urllib.error.HTTPError as e:
            return e.code

    def rows(self, sql):
        c = sqlite3.connect(f"file:{self.db}?mode=ro", uri=True)
        try:
            return c.execute(sql).fetchall()
        finally:
            c.close()

    def content(self, title):
        return self.rows(f"SELECT content FROM notes WHERE title = '{title}'")[0][0]

    def held(self):
        d = self.w / "cfg/unsaved"
        return "\n".join((d / f).read_text() for f in os.listdir(d) if f.endswith(".json")) if d.exists() else ""

    def start(self):
        log = self.w / f"native-{len(self.logs)}.txt"
        self.logs.append(log)
        a = App({"OMX_DATA": str(self.w / "data"), "OMX_CONFIG": str(self.w / "cfg"), "HOME": str(self.w / "home"), "PNOTE_BOXES": str(self.w / "boxes.json")}, log, (1200, 800))
        X.XRaiseWindow(a.d, a.win)
        X.XSetInputFocus(a.d, a.win, 1, 0)
        X.XSync(a.d, 0)
        time.sleep(0.5)
        return a

    def open(self, a, title):
        a.key("k", "Ctrl", wait=0.5)
        a.type(title, wait=0.6)
        a.key("Enter", wait=1.2)

    def said(self):
        return "\n".join(p.read_text() for p in self.logs)

    def end(self):
        self.p.stdin.write('["quit"]\n')
        self.p.stdin.flush()
        self.p.wait(15)


def picture(a, p):
    a.shot(p)
    return np.asarray(Image.open(p).convert("RGB")).astype(int)


def echoes():
    """(review 5, SHOULD 1) The web has the same canvas open and idle; native draws and writes at a person's pace: no conflict."""
    P = Place("echoes", [("canvas", "Board")])
    note(P.web("title") == "Board", "echoes: the web has the canvas open (its newest note)")
    a = P.start()
    P.open(a, "Board")
    a.key("Escape", wait=0.3)
    n = 0
    for k, pause in enumerate([0.9, 1.6, 1.9, 2.2, 2.6, 3.2, 1.1, 2.0]):
        if k % 2 == 0:
            a.key("p", wait=0.2)
            a.path([(380 + k * 20 + q * 9, 260 + k * 30 + (q % 3) * 8) for q in range(14)], wait=0.1)
            a.key("v", wait=0.1)
        else:
            a.key("t", wait=0.2)
            a.click(700, 200 + k * 50, wait=0.3)
            a.type(f"echoword{k}", wait=0.1)
            a.key("Escape")
            n += 1
        time.sleep(pause)
    time.sleep(4)
    t = P.content("Board")
    log = P.said()
    revs = P.rows("SELECT revision FROM notes WHERE title = 'Board'")[0][0]
    svgs = len(re.findall(r'"file":\s*"(?:media/)?[0-9a-f]{64}\.svg"', t))
    note(all(f"echoword{k}" in t for k in [1, 3, 5, 7]) and t.count('"ink"') >= 4, f"echoes: every word and stroke is in the file (revision {revs}, {t.count(chr(34) + 'ink' + chr(34))} ink)")
    note("conflict" not in log and P.held() == "" and "#save-copy" not in a.boxes(), f"echoes: no conflict; the web wrote picture names into {svgs}; rows that had only moved on, met by a save: {log.count('with the same words')}")
    note(svgs >= 3 and revs > 9, "echoes: and the web did write it again (else nothing was tested)")
    note("PNOTE FEED" in log and a.key("z", "Ctrl", wait=2.5) is None and len(json.loads(P.content("Board"))["nodes"]) == len(json.loads(t)["nodes"]) - 1, "echoes: the note wasn't opened again under the person: Ctrl+Z still takes back the last thing")
    a.key("Escape")
    note(a.close() == 0, "echoes: closes")
    P.end()


def ink():
    """(review 5, M1) A stroke past the paper's left edge: the paper grows there, and everything, the ink too, stays where it was."""
    P = Place("ink", [("canvas", "Board")])
    a = P.start()
    P.open(a, "Board")
    a.key("Escape", wait=0.3)
    a.key("p", wait=0.2)
    a.path([(520 + 8 * q, 300 + (q % 5) * 10) for q in range(20)], wait=0.3)
    a.key("t", wait=0.2)
    a.click(640, 460, wait=0.3)
    a.type("beside", wait=0.2)
    a.key("Escape", wait=0.3)
    a.key("v", wait=0.2)
    time.sleep(3)
    before = json.loads(P.content("Board"))
    sheet0 = a.boxes().get("#paper-sheet")
    pic0 = picture(a, P.w / "0.png")
    a.key("p", wait=0.2)
    x0 = sheet0[0]
    a.path([(x0 + 40 - 6 * q, 560 + (q % 3) * 6) for q in range(22)], wait=0.6)
    a.key("v", wait=0.2)
    time.sleep(3)
    after = json.loads(P.content("Board"))
    pic1 = picture(a, P.w / "1.png")
    pos = lambda d: {n["id"]: (n["x"], n["y"]) for n in d["nodes"]}
    p0, p1 = pos(before), pos(after)
    moves = {(round(p1[i][0] - p0[i][0]), round(p1[i][1] - p0[i][1])) for i in p0 if i in p1}
    note(after["pn"]["page"]["columns"] == before["pn"]["page"]["columns"] + 1 and len(moves) == 1 and moves != {(0, 0)}, f"ink: the paper grew to the left; every node moved as one: {moves}")
    d = np.abs(pic0 - pic1).max(axis=2)[270:480, 500:760] > 60
    note(d.mean() < 0.01, f"ink: on the screen the first stroke and the words stand where they stood ({d.mean():.4f} of their pixels differ)")
    a.key("z", "Ctrl", wait=1.0)
    time.sleep(3)
    back = json.loads(P.content("Board"))
    note(len(back["nodes"]) == len(before["nodes"]), "ink: undone")
    a.close()
    b = P.start()
    P.open(b, "Board")
    pic2 = picture(b, P.w / "2.png")
    note((pic2.max(axis=2) < 120).sum() > 300, "ink: opens again with its ink")
    b.close()
    P.end()


def conflict():
    """A real clash, its button pressed by hand: Save a copy; then a locked file and Retry by hand."""
    P = Place("conflict", [("page", "Plan"), ("page", "Other")])
    a = P.start()
    P.open(a, "Plan")
    a.key("End", "Ctrl")
    a.type("ours1 ", wait=2.5)
    c = sqlite3.connect(P.db)
    c.execute("UPDATE notes SET content = replace(content, 'ours1', 'ours1 theirs1'), revision = revision + 1 WHERE title = 'Plan'")  # (no feed row: native isn't told)
    c.commit()
    a.type("ours2", wait=3)
    b = a.boxes()
    note("#save-copy" in b and "ours2" in P.held() and "theirs1" in P.content("Plan") and "ours2" not in P.content("Plan"), "conflict: said, held, theirs untouched")
    a.tap("#save-copy", wait=2.0)
    copies = P.rows("SELECT content FROM notes WHERE title = 'Plan (my copy)'")
    note(len(copies) == 1 and "ours2" in copies[0][0] and P.held() == "" and "theirs1" in P.content("Plan"), "conflict: Save a copy, by hand: a note of its own, nothing held any more")
    P.open(a, "Other")
    a.key("End", "Ctrl")
    c.execute("BEGIN IMMEDIATE")
    a.type("lockedwords", wait=0.2)
    t0 = time.time()
    while time.time() - t0 < 80 and "#save-retry" not in a.boxes():
        time.sleep(1)
        a.move(600 + int(time.time()) % 5, 500)
    note("#save-retry" in a.boxes() and "lockedwords" in P.held(), f"conflict: a file locked by another program: said after {time.time() - t0:.0f} s, the words on disk")
    c.execute("ROLLBACK")
    if "#save-retry" in a.boxes():
        a.tap("#save-retry", wait=2.5)
    note("lockedwords" in P.content("Other") and P.held() == "", "conflict: Retry, by hand: in the file")
    c.close()
    note(a.close() == 0, "conflict: closes")
    P.end()


def elsewhere():
    """Deleted by the web while words here aren't saved yet; the words are a note of their own."""
    P = Place("elsewhere", [("page", "Doomed"), ("page", "Safe")])
    a = P.start()
    P.open(a, "Doomed")
    a.key("End", "Ctrl")
    a.type("first ", wait=2.5)
    a.type("unsavedwords", wait=0.1)
    P.web("del", "Doomed")
    time.sleep(6)
    t = P.rows("SELECT title, content FROM notes")
    note(any("unsavedwords" in x[1] and x[0] == "Doomed (my copy)" for x in t) and not any(x[0] == "Doomed" for x in t), f"elsewhere: {[x[0] for x in t]}")
    note(a.close() == 0, "elsewhere: closes")
    P.end()


def jump():
    """(D-8078) A long page, jumped through by its keys: every picture right after a jump shows the words it shows later."""
    P = Place("jump", [("page", "Long")])
    c = sqlite3.connect(P.db)
    md = "\n\n".join(f"Paragraph {k} " + "some words " * (k % 37) for k in range(700))
    c.execute("UPDATE notes SET content = json_set(content, '$.markdown', ?), revision = revision + 1 WHERE title = 'Long'", (md,))
    c.commit()
    c.close()
    a = P.start()
    P.open(a, "Long")
    blank = []
    for k, key in enumerate([("End", "Ctrl"), ("Home", "Ctrl"), ("End", "Ctrl"), ("Prior",), ("Prior",), ("Home", "Ctrl"), ("Next",), ("Next",), ("Next",)]):
        a.key(key[0], *key[1:], wait=0.0)
        time.sleep(0.12)
        subprocess.run(["import", "-display", os.environ["DISPLAY"], "-window", "root", "-crop", "1200x800+0+0", "+repage", str(P.w / f"j{k}.png")], check=True)
        now = np.asarray(Image.open(P.w / f"j{k}.png").convert("L")).astype(int)
        time.sleep(1.0)
        later = picture(a, P.w / f"l{k}.png").mean(axis=2)
        ink0, ink1 = (now[120:780] < 110).sum(), (later[120:780] < 110).sum()
        if ink0 < 0.9 * ink1:
            blank.append((key, int(ink0), int(ink1)))
    note(not blank, f"jump: nothing blank right after nine jumps {blank}")
    note(a.close() == 0, "jump: closes")
    P.end()


def two_windows():
    """Two native windows on one file: both write the same page; nothing is lost, the second's clash is said."""
    P = Place("two", [("page", "Shared")])
    a = P.start()
    P.open(a, "Shared")
    b = P.start()
    P.open(b, "Shared")
    X.XSetInputFocus(a.d, a.win, 1, 0)
    X.XRaiseWindow(a.d, a.win)
    X.XSync(a.d, 0)
    time.sleep(0.5)
    a.key("End", "Ctrl")
    a.type("fromfirst ", wait=0.1)
    X.XSetInputFocus(b.d, b.win, 1, 0)
    X.XRaiseWindow(b.d, b.win)
    X.XSync(b.d, 0)
    time.sleep(0.3)
    b.key("End", "Ctrl")
    b.type("fromsecond", wait=4)
    both = P.content("Shared") + P.held()
    note("fromfirst" in both and "fromsecond" in both, "two windows: both's words are in the file or held")
    for w in (b, a):
        X.XSetInputFocus(w.d, w.win, 1, 0)
        X.XSync(w.d, 0)
        time.sleep(0.3)
        w.close()
    c = P.start()
    P.open(c, "Shared")
    c.close()
    both = " ".join(x[0] for x in P.rows("SELECT content FROM notes")) + P.held()
    note("fromfirst" in both and "fromsecond" in both, "two windows: after both closed and a start")
    P.end()


for f in [globals()[n] for n in (sys.argv[1:] or ["echoes", "ink", "conflict", "elsewhere", "jump", "two_windows"])]:
    try:
        f()
    except Exception as e:
        import traceback
        traceback.print_exc()
        note(False, f"{f.__name__}: {type(e).__name__}: {e}")
print("real24:", "ok" if not bad else f"BAD {bad}")
sys.exit(1 if bad else 0)
