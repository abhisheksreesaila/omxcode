"""Both apps open at once on one notes file, edited on both sides at random (goal 79, continuation 23): the real web Personal Note
(its API and page, CPU Chromium) and the real native app (real X input, CPU drawing), pages, a canvas and a map. Every word typed
is one of its own; at the end each is in the file, or in an edit native holds and says so. Scratch files only.
   pixi run python -B docs/goals/79/bothopen.py [minutes, default 10] [seed]"""
import json, os, random, re, shutil, sqlite3, subprocess, sys, threading, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from xdrive import App, ROOT, X
MIN = float(sys.argv[1]) if len(sys.argv) > 1 else 10
rnd = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
W = ROOT / "build/bothopen"
shutil.rmtree(W, ignore_errors=True)
for d in ["data", "cfg", "home", "web", "shots"]:
    (W / d).mkdir(parents=True)
DB = W / "data/notes.db"


class Web:
    def __init__(self):
        self.p = subprocess.Popen(["nice", "taskset", "-c", "4-7", "node", str(ROOT / "docs/goals/79/webside.mjs"), str(DB), "4987", str(W / "web")],
                                  cwd=os.path.expanduser("~/Projects/personalnotev2"), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.errors = []
        while not self.read().startswith("READY"):
            pass

    def read(self):
        l = self.p.stdout.readline()
        if not l:
            raise SystemExit("the web side ended")
        if l.startswith("PAGEERROR"):
            self.errors.append(l.strip())
        return l

    def __call__(self, *a):
        self.p.stdin.write(json.dumps(a) + "\n")
        self.p.stdin.flush()
        while True:
            l = self.read()
            if l.startswith("R "):
                r = json.loads(l[2:])
                if isinstance(r, str) and r.startswith("ERR"):
                    self.errors.append(f"{a}: {r[:160]}")
                return r


def rows(sql):
    c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    try:
        return c.execute(sql).fetchall()
    finally:
        c.close()


def held():
    d = W / "cfg/unsaved"
    return "\n".join((d / f).read_text() for f in os.listdir(d) if f.endswith(".json")) if d.exists() else ""


def env():
    return {"OMX_DATA": str(W / "data"), "OMX_CONFIG": str(W / "cfg"), "HOME": str(W / "home"), "PNOTE_BOXES": str(W / "boxes.json")}


def found(text):
    """The words in a text, also one another was typed into the middle of (a click on it puts the caret there): taken out one by one."""
    out = set()
    for part in set(text.split('"')):
        while m := WORD.findall(part):
            out |= set(m)
            part = WORD.sub("", part)
    return out


WORD = re.compile(r"(?:nat|web)[0-9]+q")
ever, words, where = set(), [], {}  # words seen in the file or held, at some moment; typed; where


def watch():
    while True:
        try:
            t = "\n".join(r[0] for r in rows("SELECT content FROM notes")) + held()
            ever.update(found(t))
        except (sqlite3.Error, OSError):
            pass
        time.sleep(0.15)


web = Web()
threading.Thread(target=watch, daemon=True).start()
for kind, title in [("page", "Alpha"), ("page", "Beta"), ("canvas", "Board"), ("mindmap", "Map")]:
    web("make", kind, title)
web("reload")
NOTES = {"Alpha": "page", "Beta": "page", "Board": "canvas", "Map": "mindmap"}


def start():
    a = App(env(), W / f"native-{int(time.time())}.txt", (1200, 800))
    X.XRaiseWindow.argtypes = [__import__("ctypes").c_void_p, __import__("ctypes").c_ulong]
    X.XRaiseWindow(a.d, a.win)
    X.XSetInputFocus(a.d, a.win, 1, 0)
    X.XSync(a.d, 0)
    time.sleep(0.5)
    return a


a = start()
n_at, w_at, n, nat_ops, web_ops, restarts = "", "", 0, 0, 0, 0
shots = 0
end = time.time() + MIN * 60
while time.time() < end:
    n += 1
    if rnd.random() < 0.5:  # native
        nat_ops += 1
        if n_at == "" or rnd.random() < 0.3:
            n_at = rnd.choice(list(NOTES))
            a.key("k", "Ctrl", wait=0.4)
            a.type(n_at, wait=0.5)
            a.key("Enter", wait=0.9)
        w = f"nat{n}q"
        kind = NOTES[n_at]
        if kind == "page":
            a.key("End", "Ctrl")
            a.type(" " + w, wait=0.1)
        elif kind == "canvas":
            a.key("Escape")
            a.key("t", wait=0.1)
            a.click(420 + rnd.randrange(260), 200 + rnd.randrange(420), wait=0.2)
            a.type(w, wait=0.1)
            if rnd.random() < 0.6:
                a.key("Escape")
        else:
            a.key("Tab", wait=0.2)
            a.type(w, wait=0.1)
            a.key("Enter", wait=0.2)
        words.append(w)
        where[w] = f"native {n_at}"
        if rnd.random() < 0.04:  # (closed and opened again)
            a.key("Escape")
            assert a.close() == 0
            a, n_at, restarts = start(), "", restarts + 1
    else:
        web_ops += 1
        if w_at == "" or rnd.random() < 0.3:
            w_at = rnd.choice([t for t in NOTES if NOTES[t] != "mindmap"])
            web("open", w_at)
        w = f"web{n}q"
        if web("title") != w_at:  # (the web didn't open it: nothing is typed, and it is said)
            print("the web stayed on", web("title"), "instead of", w_at, flush=True)
            w_at = ""
            continue
        if NOTES[w_at] == "page":
            web("pageend")
            f0 = web("focus")
            web("type", " " + w, 15)
            t = web("pagetext")
            if w not in t:
                print("web page without its word:", w, w_at, "| island:", web("title"), "| focus", f0, "->", web("focus"), "| text:", repr(t[-60:]), flush=True)
        else:
            web("press", "Escape")
            web("press", "t")
            web("click", 420 + rnd.randrange(260), 200 + rnd.randrange(420))
            web("wait", 250)
            web("type", w, 15)
            web("press", "Escape")
        words.append(w)
        where[w] = f"web {w_at}: {web('title')}"
    time.sleep(rnd.choice([0.05, 0.2, 0.6, 1.5, 3.0]))
    late = [x for x in words[:-12] if x not in ever]  # (typed twelve edits ago and never anywhere)
    if late and shots < 4 and late[-1] not in where.get("shot", []):
        shots += 1
        where.setdefault("shot", []).append(late[-1])
        print("never arrived so far:", late[-1], where[late[-1]], "| web state:", web("state")[:100], flush=True)
        a.shot(W / f"shots/late{shots}-native.png")
        web("shot", str(W / f"shots/late{shots}-web.png"))
a.shot(W / "shots/native.png")
web("shot", str(W / "shots/web.png"))
a.key("Escape")
web("press", "Escape")
time.sleep(8)
rc = a.close()
web("wait", 4000)
text = found("\n".join(r[0] for r in rows("SELECT content FROM notes")))
h = found(held())
lost = [w for w in words if w not in text and w not in h]
only_held = [w for w in words if w not in text and w in h]
print(f"bothopen: {MIN:g} minutes, {nat_ops} edits native, {web_ops} in the web, {restarts} restarts; closed {rc}; web errors {len(web.errors)} {web.errors[:3]}")
print("  never reached the file or a held file:", [(w, where[w]) for w in words if w not in ever][:40])
print("  were there and are gone:", [(w, where[w]) for w in lost if w in ever])
print("  words", len(words), "in the file", sum(w in text for w in words), "held by native (said)", len(only_held), "LOST", lost)
logs = "\n".join(p.read_text() for p in W.glob("native-*.txt"))
print("  native said:", logs.count("PNOTE SAVE: conflict"), "conflicts,", logs.count("with the same words"), "rows that had only moved on,", logs.count("PNOTE FEED"), "feed reads")
# the next start shows what is held, and every note opens
b = start()
for t in NOTES:
    b.key("k", "Ctrl", wait=0.4)
    b.type(t, wait=0.5)
    b.key("Enter", wait=0.9)
b.shot(W / "shots/after.png")
assert b.close() == 0
text = found("\n".join(r[0] for r in rows("SELECT content FROM notes")) + held())
lost2 = [w for w in words if w not in text]
web.p.stdin.write('["quit"]\n')
web.p.stdin.flush()
print("bothopen:", "ok" if not lost and not lost2 and rc == 0 else f"BAD lost {lost} after the next start {lost2}")
sys.exit(1 if lost or lost2 or rc else 0)
