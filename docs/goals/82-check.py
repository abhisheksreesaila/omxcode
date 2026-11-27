"""Milestone checker for goal 82 (docs/goals/82-draft.md). Prints "Mn: PASS|FAIL|BLOCKED  why" per milestone.

    pixi run python docs/goals/82-check.py [M3 M7 ...]          (scripts/check 82 [M3 M7 …])

Worker B (2026-11-26) wrote M3 (import and export) and M7 (live updates and the deletion fix); other workers add theirs here
by the same pattern (m<n>_* functions, ALL below), merged later. Written before the runs from the draft's words; never edited
to make a milestone pass (add, don't weaken; checker bugs are logged in docs/decisions.md with why the fix isn't a weakening).

Machine rules: every Mojo build and GUI run takes ~/.cache/omx-quiet.lock shared (a judged race holds it alone), builds and
the app use 6 cores at most, windows only on a headless Xvfb (scripts/headless.py through docs/goals/79/xdrive.py), the Mac
through scripts/mac82 (which takes ~/.cache/omx-mac.lock itself). Scratch files only, under build/g82; the web app
(~/Projects/personalnotev2) is run read-only: its own Python, -B -I, on scratch databases (docs/goals/82/webport.py).
"""
import json
import os
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
OUT = ROOT / "build" / "g82"
CORES = os.environ.get("G82_CORES", "0-5")
LOCK = os.path.expanduser("~/.cache/omx-quiet.lock")
WEB = Path(os.path.expanduser("~/Projects/personalnotev2"))
WEBPY = WEB / ".venv/bin/python"

# ---- the bars, from the draft ----
M7_SHOWN_MS = 300        # another app's write on pnote's screen (from 2 s: the feed's poll)
M7_BOTHOPEN_MIN = 3      # minutes of goal 79's both-open run (with deletions on both sides and through the API)


def run(cmd, timeout, env=None, lock=True, cwd=None):
    e = dict(os.environ)
    e.update(env or {})
    pre = (["flock", "-s", LOCK] if lock and not os.environ.get("G82_LOCKED") else []) + ["taskset", "-c", CORES, "nice", "-n", "5"]
    try:
        return subprocess.run(pre + cmd, cwd=cwd or ROOT, capture_output=True, text=True, timeout=timeout, env=e)
    except subprocess.TimeoutExpired as x:
        return subprocess.CompletedProcess(cmd, 124, str(x.stdout or ""), str(x.stderr or "") + f"\ntimeout after {timeout}s")


def tail(s, n=300):
    return (s or "").strip()[-n:].replace("\n", " | ")


def facts(text):
    out = {}
    for line in text.splitlines():
        if line.startswith("FACT "):
            p = line.split()
            if len(p) >= 3:
                out[p[1]] = p[2]
    return out


def num(f, k, d=float("nan")):
    try:
        return float(f[k])
    except (KeyError, ValueError):
        return d


def need(checks):
    bad = [why for ok, why in checks if not ok]
    return ("FAIL", "; ".join(bad)) if bad else ("PASS", "; ".join(why for _, why in checks))


def mojo_test(path, built=False, timeout=2400):
    """(facts, error): a Mojo test ending with its own `<name>: ok`; built: with pnote's modules, as a binary (job threads)."""
    name = Path(path).stem.removeprefix("test_")
    if built:
        exe = OUT / f"bin_{name}"
        r = run(["pixi", "run", "mojo", "build", "-I", ".", "-I", "vendor", "-I", "examples/pnote", path, "-o", str(exe)], timeout)
        if r.returncode != 0:
            return {}, f"{path} build: {tail(r.stdout + r.stderr)}"
        r = run([str(exe)], timeout, lock=False)
    else:
        r = run(["pixi", "run", "mojo", "run", "-I", ".", "-I", "vendor", path], timeout)
    said = r.stdout + r.stderr
    if r.returncode != 0 or f"{name}: ok" not in said:
        return facts(said), f"{path} rc {r.returncode}: {tail(said)}"
    return facts(said), None


def mac_tests(paths, timeout=3600):
    """(output, error, blocked): Mojo tests on the M4 (scripts/mac82)."""
    r = subprocess.run([str(ROOT / "scripts/mac82"), *paths], cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    said = r.stdout + r.stderr
    if r.returncode == 75 or "UNREACHABLE" in said:
        return said, tail(said), True
    return said, None, False


def web(*args, timeout=300):
    """The web app's own code (webport.py) on scratch files: its JSON answer."""
    r = subprocess.run([str(WEBPY), "-B", "-I", str(ROOT / "docs/goals/82/webport.py"), *map(str, args)], cwd=WEB, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"web {args[0]}: {tail(r.stderr, 600)}")
    return json.loads(r.stdout.strip().splitlines()[-1])


def pnote_built():
    """The Linux app, newer than every source it is built from (a stale binary proves nothing: lessons)."""
    exe = ROOT / "build/pnote/linux/pnote"
    newest = max(p.stat().st_mtime for d in ["mojoui", "examples/pnote"] for p in (ROOT / d).rglob("*.mojo"))
    if not exe.exists() or exe.stat().st_mtime < newest:
        r = run(["bash", "scripts/build.sh", "pnote", "linux"], 3600)
        if r.returncode != 0:
            return f"pnote build: {tail(r.stdout + r.stderr)}"
    return None


def native(db, log, env=None):
    """pnote (the real app) on a headless display, on notes file `db`: an xdrive.App."""
    sys.path.insert(0, str(ROOT / "docs/goals/79"))
    from xdrive import App
    d = Path(db).parent
    e = {"PNOTE_DB": str(db), "OMX_CONFIG": str(d / "cfg"), "OMX_DATA": str(d / "data"), "HOME": str(d / "home"), "OMX_EXPORTS": str(d / "exports"),
         "PNOTE_BOXES": str(d / "boxes.json")}
    for k in ("cfg", "data", "home", "exports"):
        (d / k).mkdir(parents=True, exist_ok=True)
    e.update(env or {})
    return App(e, log, (1200, 800))


def wait_log(log, words, secs=60):
    t = time.time()
    while time.time() - t < secs:
        text = Path(log).read_text(errors="replace") if Path(log).exists() else ""
        if words in text:
            return text
        time.sleep(0.2)
    return None


def m3_without_blank(notes):
    """A note pnote makes on an empty file (one blank canvas to start on, as the web does) isn't an import's."""
    return [n for n in notes if not (n["type"] == "canvas" and n["title"] == "Untitled note" and not n.get("nodes"))]


def m3_import_with_pnote(name, source):
    """A fresh notes file (made by the web: its schema), pnote started with `source` (Open With: PNOTE_OPEN), imported, closed:
    (the notes as the web reads them, error)."""
    d = OUT / f"m3-{name}"
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    db = d / "notes.db"
    web("rows", db)  # (the web makes its own empty notes file)
    log = d / "native.txt"
    a = native(db, log, {"PNOTE_OPEN": str(source)})
    said = wait_log(log, "PNOTE IMPORT:", 60)
    rc = a.close()
    if said is None or "PNOTE IMPORT: failed" in said:
        return None, f"{name}: pnote didn't import: {tail(log.read_text(errors='replace'), 400)}"
    if rc != 0:
        return None, f"{name}: pnote closed with {rc}"
    return m3_without_blank(web("norm", db)), None


def m3_export_with_pnote(src_dir):
    """pnote (the real app) on a copy of the seed: the card's Backup and Obsidian tiles tapped, as a person taps them. (the two
    files, error)."""
    d = OUT / "m3-pnexport"
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(src_dir, d)
    log = d / "native.txt"
    a = native(d / "notes.db", log)
    files = []
    try:
        for tile in ("#share-backup", "#share-vault"):
            before = log.read_text(errors="replace").count("PNOTE EXPORT:")
            a.tap("#share-button", wait=0.8)
            a.tap(tile, wait=0.5)
            t = time.time()
            while time.time() - t < 30 and log.read_text(errors="replace").count("PNOTE EXPORT:") == before:
                time.sleep(0.2)
            lines = [x for x in log.read_text(errors="replace").splitlines() if x.startswith("PNOTE EXPORT:")]
            if len(lines) == before:
                return None, f"{tile}: no export: {tail(log.read_text(errors='replace'), 300)}"
            files.append(lines[-1].split("PNOTE EXPORT: ", 1)[1].rsplit(" ", 2)[0] if tile == "#share-vault" else lines[-1].split("PNOTE EXPORT: ", 1)[1])
    finally:
        rc = a.close()
    if rc != 0:
        return None, f"pnote closed with {rc}"
    return files, None


def m3():
    checks = []
    for t in ["tests/test_archive.mojo", "tests/test_mediafiles.mojo"]:
        f, e = mojo_test(t)
        checks.append((e is None, f"{t}: {'ok' if e is None else e}"))
    made = ROOT / "build/test_archive/made.zip"
    try:
        z = zipfile.ZipFile(made)
        checks.append((z.testzip() is None and len(z.namelist()) == 3, "Python's zipfile reads mojoui.archive's zip"))
    except Exception as x:
        checks.append((False, f"Python's zipfile on our zip: {x}"))
    e = pnote_built()
    if e:
        return "FAIL", e
    # the seed: a workspace the web made, its own backup and vault
    seed = OUT / "m3-seed"
    shutil.rmtree(seed, ignore_errors=True)
    web("seed", seed)
    want = web("norm", seed / "notes.db")
    b1, v1 = OUT / "web-backup.json", OUT / "web-vault.zip"
    web("backup", seed / "notes.db", b1)
    web("vault", seed / "notes.db", v1)
    vdir = OUT / "web-vault"
    shutil.rmtree(vdir, ignore_errors=True)
    zipfile.ZipFile(v1).extractall(vdir)
    ev = OUT / "m3-webvault"
    shutil.rmtree(ev, ignore_errors=True)
    ev.mkdir(parents=True)
    web("import-vault", ev / "notes.db", v1)
    want_vault = m3_without_blank(web("norm", ev / "notes.db"))
    # 1. the web's files into pnote
    got, e = m3_import_with_pnote("backup", b1)
    checks.append((got == want, f"the web's backup imported by pnote: {len(got or [])} of {len(want)} notes equal as the web reads them" if got == want else (e or f"differ: {m3_diff(want, got)}")))
    got, e = m3_import_with_pnote("vaultzip", v1)
    checks.append((got == want_vault, f"the web's vault zip imported by pnote: {len(got or [])} notes, as the web's own import makes them" if got == want_vault else (e or f"differ: {m3_diff(want_vault, got)}")))
    got, e = m3_import_with_pnote("vaultdir", vdir)
    checks.append((got == want_vault, "the web's vault folder imported by pnote: the same" if got == want_vault else (e or f"differ: {m3_diff(want_vault, got)}")))
    one = next(vdir.rglob("*.canvas"))
    got, e = m3_import_with_pnote("canvas", one)
    board = [n for n in want_vault if n["title"] == one.stem]
    checks.append((got is not None and len(got) == 1 and [dict(g, notebook="") for g in got] == [dict(b, notebook="") for b in board], f"one JSON Canvas file imported by pnote as a canvas: {one.name}" if got and len(got) == 1 else (e or f"got {got}")))
    # 2. pnote's files into the web
    files, e = m3_export_with_pnote(seed)
    if e:
        checks.append((False, "pnote's export: " + e))
    else:
        pb, pv = files
        try:
            zipfile.ZipFile(pv).testzip()
            e1, e2 = OUT / "m3-web-from-pnbackup", OUT / "m3-web-from-pnvault"
            for d in (e1, e2):
                shutil.rmtree(d, ignore_errors=True)
                d.mkdir(parents=True)
            web("import-backup", e1 / "notes.db", pb)
            web("import-vault", e2 / "notes.db", pv)
            g1 = m3_without_blank(web("norm", e1 / "notes.db"))
            g2 = m3_without_blank(web("norm", e2 / "notes.db"))
            checks.append((g1 == want, f"pnote's backup ({Path(pb).name}) imported by the web: {len(g1)} notes equal" if g1 == want else f"pnote's backup in the web differs: {m3_diff(want, g1)}"))
            checks.append((g2 == want_vault, f"pnote's vault ({Path(pv).name}) imported by the web: equal to the web's own vault's import" if g2 == want_vault else f"pnote's vault in the web differs: {m3_diff(want_vault, g2)}"))
        except Exception as x:
            checks.append((False, f"the web on pnote's files: {x}"))
    # 3. an import never changes what exists
    d = OUT / "m3-keep"
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(seed, d)
    before = web("rows", d / "notes.db")
    log = d / "native.txt"
    a = native(d / "notes.db", log, {"PNOTE_OPEN": str(b1)})
    said = wait_log(log, "PNOTE IMPORT:", 60)
    a.close()
    after = web("rows", d / "notes.db")
    checks.append((said is not None and after[: len(before)] == before and len(after) == 2 * len(before), f"into a file with {len(before)} notes: they are byte for byte as they were, {len(after) - len(before)} added"))
    # the Mac: the generic parts
    out, e, blocked = mac_tests(["tests/test_archive.mojo", "tests/test_mediafiles.mojo"])
    if blocked:
        s, w = need(checks)
        return ("BLOCKED" if s == "PASS" else "FAIL"), w + "; Mac: " + e
    checks.append(("archive: ok" in out and "mediafiles: ok" in out, "the M4: archive and mediafiles tests pass" if "archive: ok" in out and "mediafiles: ok" in out else f"the M4: {tail(out)}"))
    return need(checks)


def m3_diff(a, b):
    if b is None:
        return "nothing read"
    sa = {json.dumps(x, sort_keys=True) for x in a}
    sb = {json.dumps(x, sort_keys=True) for x in b}
    return f"only the web's: {sorted(sa - sb)[:2]} | only pnote's: {sorted(sb - sa)[:2]}"


def m7_live():
    """The real app on a canvas; the web's own NoteService (an agent's write) adds words to it: ms until pnote's window shows
    them (pixels of the window, read with XGetImage). (times, error)."""
    import ctypes
    d = OUT / "m7-live"
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    db = d / "notes.db"
    web("seed", d)
    log = d / "native.txt"
    a = native(db, log)
    try:
        a.key("k", "Ctrl", wait=0.6)
        a.type("Board", wait=0.6)
        a.key("Enter", wait=1.5)
        a.key("Escape", wait=0.5)
        X = ctypes.CDLL("libX11.so.6")
        X.XGetImage.restype = ctypes.c_void_p
        X.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int]
        X.XDestroyImage = X.XDestroyImage if hasattr(X, "XDestroyImage") else None

        class XImage(ctypes.Structure):
            _fields_ = [("width", ctypes.c_int), ("height", ctypes.c_int), ("xoffset", ctypes.c_int), ("format", ctypes.c_int), ("data", ctypes.c_void_p),
                        ("byte_order", ctypes.c_int), ("bitmap_unit", ctypes.c_int), ("bitmap_bit_order", ctypes.c_int), ("bitmap_pad", ctypes.c_int),
                        ("depth", ctypes.c_int), ("bytes_per_line", ctypes.c_int)]

        def grab():
            p = X.XGetImage(a.d, a.win, 0, 0, 1200, 800, 0xFFFFFFFF, 2)
            if not p:
                return b""
            img = XImage.from_address(p)
            data = ctypes.string_at(img.data, img.bytes_per_line * img.height)
            ctypes.CDLL("libc.so.6").free(ctypes.c_void_p(img.data))
            ctypes.CDLL("libc.so.6").free(ctypes.c_void_p(p))
            return data

        times = []
        for k in range(8):
            time.sleep(0.8)
            p0 = grab()
            code = f"""
import sys, json; sys.path.insert(0, {str(WEB)!r}); sys.dont_write_bytecode = True
from services import NoteService
s = NoteService({str(db)!r})
n = [x for x in s.list_notes() if x['title'] == 'Board'][0]
full = s.get_note(n['id'])
c = full['content']
c['nodes'].append({{'id': 'ag{k}', 'type': 'text', 'text': 'agent words {k}', 'x': 520, 'y': {150 + 70 * k}, 'width': 260, 'height': 50}})
import time; t0 = time.time()
s.update_note(n['id'], {{'title': 'Board', 'content': c, 'pageState': full.get('pageState'), 'expectedRevision': full['revision']}})
print(t0)
"""
            r = subprocess.run([str(WEBPY), "-B", "-I", "-c", code], cwd=WEB, capture_output=True, text=True, timeout=60)
            t1 = time.time()
            if r.returncode != 0:
                return None, f"the agent's write failed: {tail(r.stderr)}"
            t0 = float(r.stdout.strip().splitlines()[-1])
            shown = None
            while time.time() - t0 < 3.0:
                if grab() != p0:
                    shown = (time.time() - t0) * 1000
                    break
                time.sleep(0.004)
            times.append(round(shown, 1) if shown is not None else None)
        return times, None
    finally:
        rc = a.close()


def m7():
    checks = []
    f, e = mojo_test("tests/test_filewatch.mojo")
    checks.append((e is None and num(f, "filewatch_worst_ms") <= M7_SHOWN_MS, f"filewatch: a write to an open file (a WAL) heard in {f.get('filewatch_worst_ms')} ms at worst" if e is None else e))
    f, e = mojo_test("tests/test_merge3.mojo")
    checks.append((e is None and num(f, "merge3_wrong") == 0, f"merge3: {f.get('merge3_seeds')} seeds, {f.get('merge3_wrong')} wrong, mutants caught {f.get('merge3_mutants_caught')}" if e is None else e))
    f, e = mojo_test("tests/test_pnwatch.mojo", built=True)
    checks.append((e is None and num(f, "pnwatch_shown_worst_ms") <= M7_SHOWN_MS, f"pnote (no window): another writer's change shown in {f.get('pnwatch_shown_worst_ms')} ms at worst; a deletion under unsaved edits stays deleted; an overlap is held" if e is None else e))
    for t in ["tests/test_saveattack.mojo", "tests/test_review4.mojo", "tests/test_wordsafe.mojo", "tests/test_pnnotes.mojo", "tests/test_opendoc.mojo"]:
        f, e = mojo_test(t, built=True)
        checks.append((e is None, f"{Path(t).stem}: still passes" if e is None else e))
    e = pnote_built()
    if e:
        return "FAIL", e
    times, e = m7_live()
    ok = times is not None and all(t is not None and t <= M7_SHOWN_MS for t in times)
    checks.append((ok, f"the real app: an agent's write on the screen after {times} ms (8 writes; the bar {M7_SHOWN_MS})" if times else e))
    r = run(["pixi", "run", "python", "-B", "docs/goals/79/bothopen.py", str(M7_BOTHOPEN_MIN), "107"], 3600)
    said = r.stdout + r.stderr
    ok = r.returncode == 0 and "bothopen: ok" in said
    lines = [x for x in said.splitlines() if x.strip().startswith(("words", "deleted on either side", "bothopen:", "deletions stay", "Caretboard", "Caretpage", "Caretmap"))]
    checks.append((ok, "both apps open (goal 79's run, seed 107): " + " | ".join(x.strip()[:160] for x in lines)))
    out, e, blocked = mac_tests(["tests/test_filewatch.mojo", "tests/test_merge3.mojo", "tests/test_pnwatch.mojo"])
    if blocked:
        s, w = need(checks)
        return ("BLOCKED" if s == "PASS" else "FAIL"), w + "; Mac: " + e
    mac_ok = all(f"{n}: ok" in out for n in ("filewatch", "merge3", "pnwatch"))
    mf = facts(out)
    checks.append((mac_ok and num(mf, "filewatch_worst_ms") <= M7_SHOWN_MS and num(mf, "pnwatch_shown_worst_ms") <= M7_SHOWN_MS,
                   f"the M4 (kqueue): filewatch {mf.get('filewatch_worst_ms')} ms, pnote {mf.get('pnwatch_shown_worst_ms')} ms, merge3 ok" if mac_ok else f"the M4: {tail(out, 500)}"))
    return need(checks)


ALL = {"M3": m3, "M7": m7}

if __name__ == "__main__":
    if not os.environ.get("G82_LOCKED"):  # (the whole run holds the quiet lock, shared: the real app's windows and builds alike)
        os.environ["G82_LOCKED"] = "1"
        os.execvp("flock", ["flock", "-s", LOCK, sys.executable, *sys.argv])
    OUT.mkdir(parents=True, exist_ok=True)
    bad = False
    for k in (sys.argv[1:] or list(ALL)):
        if k not in ALL:
            print(f"{k}: BLOCKED  not this worker's milestone (worker B wrote M3 and M7)", flush=True)
            continue
        try:
            s, why = ALL[k]()
        except Exception as x:
            s, why = "FAIL", f"the checker raised: {type(x).__name__}: {x}"
        bad |= s == "FAIL"
        print(f"{k}: {s}  {why}", flush=True)
    sys.exit(1 if bad else 0)
