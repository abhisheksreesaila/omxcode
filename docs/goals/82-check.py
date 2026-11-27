"""Milestone checker for goal 82 (docs/goals/82-draft.md). Prints "Mn: PASS|FAIL|BLOCKED  why" per milestone.

    pixi run python docs/goals/82-check.py [M3 M7 ...]          (scripts/check 82 [M3 M7 …])

Worker B (2026-11-26) wrote M3 (import and export) and M7 (live updates and the deletion fix); other workers add theirs here
by the same pattern (m<n>_* functions, ALL below), merged later. Written before the runs from the draft's words; never edited
to make a milestone pass (add, don't weaken; checker bugs are logged in docs/decisions.md with why the fix isn't a weakening).

Machine rules: every Mojo build takes ~/.cache/omx-build.lock exclusively (one build on the machine at a time) and the whole run
holds ~/.cache/omx-quiet.lock shared (a judged race holds it alone); builds and
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
BUILD_LOCK = os.path.expanduser("~/.cache/omx-build.lock")  # (main session, 2026-11-26 after the 17:39 stop: one Mojo build at a time on the machine, exclusive)
WEB = Path(os.path.expanduser("~/Projects/personalnotev2"))
WEBPY = WEB / ".venv/bin/python"

# ---- the bars, from the draft ----
M7_SHOWN_MS = 300        # another app's write on pnote's screen (from 2 s: the feed's poll)
M7_BOTHOPEN_MIN = 3      # minutes of goal 79's both-open run (with deletions on both sides and through the API)


def run(cmd, timeout, env=None, lock=True, cwd=None, build=False):
    e = dict(os.environ)
    e.update(env or {})
    pre = (["flock", "-s", LOCK] if lock and not os.environ.get("G82_LOCKED") else []) + (["flock", BUILD_LOCK] if build else []) + ["taskset", "-c", CORES, "nice", "-n", "5"]
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
        r = run(["pixi", "run", "mojo", "build", "-I", ".", "-I", "vendor", "-I", "examples/pnote", path, "-o", str(exe)], timeout, build=True)
        if r.returncode != 0:
            return {}, f"{path} build: {tail(r.stdout + r.stderr)}"
        r = run([str(exe)], timeout, lock=False)
    else:
        r = run(["pixi", "run", "mojo", "run", "-I", ".", "-I", "vendor", path], timeout, build=True)  # (mojo run compiles: a build)
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
        r = run(["bash", "scripts/build.sh", "pnote", "linux"], 3600, build=True)
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


def m3_drop(source):
    """The web's vault zip dropped on pnote's window (GTK's own drop signal, the dropfile: step) on a fresh notes file: the
    notes as the web reads them (or an error)."""
    sys.path.insert(0, str(ROOT / "scripts"))
    import headless
    if not headless.ensure():
        return None, "no headless display"
    d = OUT / "m3-drop"
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    web("rows", d / "notes.db")
    for k in ("cfg", "data", "home"):
        (d / k).mkdir()
    e = dict(os.environ, PNOTE_DB=str(d / "notes.db"), OMX_CONFIG=str(d / "cfg"), OMX_DATA=str(d / "data"), HOME=str(d / "home"), CUDA_VISIBLE_DEVICES="", MOJOUI_GPU2D="0",
             LIBGL_ALWAYS_SOFTWARE="1", MOJOUI_TEST=f"pause:2500;dropfile:drop={source};wait:2500;quit")
    r = subprocess.run(["taskset", "-c", "0-3", "nice", "-n", "15", str(ROOT / "build/pnote/linux/pnote")], env=e, capture_output=True, text=True, timeout=180, preexec_fn=headless.with_parent)
    said = r.stdout + r.stderr
    if "PNOTE IMPORT:" not in said or "PNOTE IMPORT: failed" in said:
        return None, f"the drop imported nothing: {tail(said, 400)}"
    return m3_without_blank(web("norm", d / "notes.db")), None


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


def m3_mac_run(name, steps, env, data, fetch, build=False):
    """pnote built and run on the M4 by scripts/mac-ssh (it takes the Mac lock itself): (report folder, its run text)."""
    d = OUT / "mac"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{name}.steps").write_text("\n".join(steps) + "\n")
    e = dict(os.environ, MAC_SSH=os.environ.get("MAC_SSH", "bhoomijaprasad@100.76.9.101"), MAC_ENV=",".join(env), MAC_FETCH=" ".join(fetch), MAC_NOBUILD="0" if build else "1")
    r = subprocess.run([str(ROOT / "scripts/mac-ssh"), "pnote", str(d / f"{name}.steps"), *map(str, data)], cwd=ROOT, capture_output=True, text=True, timeout=3600, env=e)
    said = r.stdout + r.stderr
    last = [x for x in said.strip().splitlines() if x.startswith("build/mac-ssh/")]
    return (ROOT / last[-1] if last and r.returncode == 0 else None), said


def m3_mac(seed, b1, v1, want, want_vault):
    """The real app on the M4: the web's backup and vault imported (Open With), pnote's Backup and Obsidian tiles tapped (taps
    placed from the app's own boxes); the web reads each result. (checks, blocked)."""
    checks = []
    stamp = str(int(time.time()))
    for k, (name, src) in enumerate((("backup", b1), ("vault", v1))):
        db = f"mi-{stamp}-{name}.db"
        rep, said = m3_mac_run(f"import-{name}", ["pause:6000", "quit"], [f"PNOTE_DB={{data}}/{db}", f"PNOTE_OPEN={{data}}/{Path(src).name}"], [b1, v1], [db, db + "-wal"], build=(k == 0))
        if rep is None:
            if "UNREACHABLE" in said or "Connection timed out" in said or "No route" in said:
                return checks, True
            checks.append((False, f"the M4: pnote import of the web's {name}: {tail(said)}"))
            continue
        local = OUT / f"mac-{name}"
        shutil.rmtree(local, ignore_errors=True)
        (local / "media").mkdir(parents=True)
        shutil.copy(rep / "out" / db, local / "notes.db")
        if (rep / "out" / (db + "-wal")).exists():
            shutil.copy(rep / "out" / (db + "-wal"), local / "notes.db-wal")
        for m in (seed / "media").iterdir():  # (content-addressed: a note naming the file names these bytes)
            shutil.copy(m, local / "media" / m.name)
        got = m3_without_blank(web("norm", local / "notes.db"))
        w = want if name == "backup" else want_vault
        imported = "PNOTE IMPORT:" in (rep / "stdout.txt").read_text(errors="replace") if (rep / "stdout.txt").exists() else False
        checks.append((imported and got == w, f"the M4: the web's {name} imported by pnote, equal as the web reads it" if imported and got == w else f"the M4 {name}: {m3_diff(w, got)}"))
    # pnote's tiles on the Mac: where the share button and the tiles are, from its boxes (taps are in thousandths of the desk)
    (OUT / "mac").mkdir(parents=True, exist_ok=True)
    shutil.copy(seed / "notes.db", OUT / "mac" / "seed.db")
    sdb = OUT / "mac" / "seed.db"
    boxes = f"boxes-{stamp}.json"
    rep, said = m3_mac_run("look", ["pause:2500", "quit"], ["PNOTE_DB={data}/seed.db", f"PNOTE_BOXES={{data}}/{boxes}"], [sdb], [boxes])
    if rep is None:
        checks.append((False, f"the M4 boxes: {tail(said)}"))
        return checks, False
    b = json.loads((rep / "out" / boxes).read_text())
    W, H = 1440.0, 900.0
    shot = next(rep.glob("001-*.txt"), None)
    if shot:
        import re as _re
        m = _re.search(r"window content (\d+) x (\d+)", shot.read_text())
        if m:
            W, H = float(m.group(1)), float(m.group(2))

    def per_mille(box):
        x, y, w, h = box
        return f"{round((x + w / 2) / W * 1000)},{round((y + h / 2) / H * 1000)}"
    share = per_mille(b["#share-button"])
    rep, said = m3_mac_run("card", ["pause:2500", f"tapat:desk={share}", "wait:800", "quit"], ["PNOTE_DB={data}/seed.db", f"PNOTE_BOXES={{data}}/{boxes}"], [sdb], [boxes])
    b = json.loads((rep / "out" / boxes).read_text()) if rep else {}
    if "#share-backup" not in b:
        checks.append((False, "the M4: the card didn't open"))
        return checks, False
    exp = f"exp-{stamp}"
    rep, said = m3_mac_run("export", ["pause:2500", f"tapat:desk={share}", "wait:800", f"tapat:desk={per_mille(b['#share-backup'])}", "wait:1500",
                                      f"tapat:desk={share}", "wait:800", f"tapat:desk={per_mille(b['#share-vault'])}", "wait:1500", "quit"],
                           ["PNOTE_DB={data}/seed.db", f"OMX_EXPORTS={{data}}/{exp}"], [sdb], [f"{exp}/personal-note-backup.json", f"{exp}/personal-note-obsidian-vault.zip"])
    if rep is None or not (rep / "out" / "personal-note-backup.json").exists() or not (rep / "out" / "personal-note-obsidian-vault.zip").exists():
        checks.append((False, f"the M4: pnote's tiles wrote no files: {tail(said)}"))
        return checks, False
    for name, f, w in (("backup", "personal-note-backup.json", want), ("vault", "personal-note-obsidian-vault.zip", want_vault)):
        e = OUT / f"m3-web-from-mac-{name}"
        shutil.rmtree(e, ignore_errors=True)
        e.mkdir(parents=True)
        web("import-backup" if name == "backup" else "import-vault", e / "notes.db", rep / "out" / f)
        got = m3_without_blank(web("norm", e / "notes.db"))
        checks.append((got == w, f"the M4: pnote's {name} (its tile) imported by the web: equal" if got == w else f"the M4 pnote {name} in the web: {m3_diff(w, got)}"))
    return checks, False


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
    got, e = m3_drop(v1)
    checks.append((got == want_vault, "the web's vault zip dropped on pnote's window: imported, the same" if got == want_vault else (e or f"differ: {m3_diff(want_vault, got)}")))
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
    # the Mac: the generic parts, then the real app both ways
    out, e, blocked = mac_tests(["tests/test_archive.mojo", "tests/test_mediafiles.mojo"])
    if not blocked:
        checks.append(("archive: ok" in out and "mediafiles: ok" in out, "the M4: archive and mediafiles tests pass" if "archive: ok" in out and "mediafiles: ok" in out else f"the M4: {tail(out)}"))
        more, blocked = m3_mac(seed, b1, v1, want, want_vault)
        checks += more
    if blocked:
        s, w = need(checks)
        return ("BLOCKED" if s == "PASS" else "FAIL"), w + "; Mac: unreachable"
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


def m7_mac_live():
    """The real app on the M4 (AppKit) while another writer (the Mac's sqlite3, as an agent's own connection) changes a note four
    times: each is read again by a file event (PNOTE WATCH: µs from the watcher seeing the write to the list and the open note read
    again). (times in ms, error, blocked)."""
    d = OUT / "mac"
    d.mkdir(parents=True, exist_ok=True)
    seed = OUT / "m7-mac-seed"
    shutil.rmtree(seed, ignore_errors=True)
    web("seed", seed)
    shutil.copy(seed / "notes.db", d / "live.db")
    (d / "live.steps").write_text("pause:40000\nquit\n")
    host = os.environ.get("MAC_SSH", "bhoomijaprasad@100.76.9.101")
    e = dict(os.environ, MAC_SSH=host, MAC_ENV="PNOTE_DB={data}/live.db", MAC_NOBUILD="1", MAC_QUIET="0")
    p = subprocess.Popen([str(ROOT / "scripts/mac-ssh"), "pnote", str(d / "live.steps"), str(d / "live.db")], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=e)
    time.sleep(24)
    key = os.path.expanduser(os.environ.get("MAC_SSH_KEY", "~/.ssh/edx_mac"))
    for k in range(4):
        sql = ("BEGIN IMMEDIATE; UPDATE notes SET content = json_insert(content, '$.nodes[#]', json_object('id','mac" + str(k) + "','type','text','text','mac agent " + str(k)
               + "','x',500,'y'," + str(200 + 60 * k) + ",'width',200,'height',50)), revision = revision + 1 WHERE title = 'Board'; UPDATE workspace_state SET sequence = sequence + 1 WHERE id = 1; COMMIT;")
        subprocess.run(["ssh", "-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, "sqlite3 ~/omxcode-g54/data/live.db " + json.dumps(sql).replace("$", "\\$")], capture_output=True, text=True, timeout=60)
        time.sleep(4)
    out, _ = p.communicate(timeout=600)
    if p.returncode != 0:
        return None, tail(out), "UNREACHABLE" in out or "timed out" in out
    rep = ROOT / [x for x in out.strip().splitlines() if x.startswith("build/mac-ssh/")][-1]
    said = (rep / "stdout.txt").read_text(errors="replace")
    import re as _re
    times = [round(int(m) / 1000, 2) for m in _re.findall(r"PNOTE WATCH: read again (\d+) us", said)]
    return times, None, False


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
    times, e, blocked = m7_mac_live()
    if blocked:
        s, w = need(checks)
        return ("BLOCKED" if s == "PASS" else "FAIL"), w + "; Mac: " + e
    checks.append((times is not None and len(times) >= 4 and max(times) <= M7_SHOWN_MS, f"the M4's real app: 4 writes by another program read again {times} ms after its watcher saw them (no poll)" if times else f"the M4's real app: {e}"))
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
