"""Milestone checker for goal 82 (docs/goals/82-draft.md): pnote's features at parity with the web Personal Note.
Prints "Mn: PASS|FAIL|BLOCKED  why" per milestone.

    pixi run python docs/goals/82-check.py [M5 M6 ...]          (scripts/check 82 M5 runs this)

This file holds worker C's milestones (M5 Voice, M6 AI); its functions are named m5_* and m6_* so the other workers'
checkers (M1/M2/M4, M3/M7) merge beside them. Written from the draft's words before each milestone was called done; a
check is never weakened to pass (a checker bug is logged in docs/decisions.md with why its fix is not a weakening).

Machine rules: every Mojo build runs alone under `flock ~/.cache/omx-build.lock` (6 cores); GPU model runs and GUI tests under `flock -s ~/.cache/omx-quiet.lock`; a GPU model
run starts only when scripts/gpu-free says yes; GUI tests run on the hidden test screen (scripts/testscreen); the Mac
half holds ~/.cache/omx-mac.lock (scripts/mac-test, scripts/mac-ssh). Scratch databases only (build/g82/).
"""
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
OUT = ROOT / "build" / "g82"
APP = ROOT / "build" / "pnote" / "linux" / "pnote"
CLIPS = ROOT / "docs" / "goals" / "43" / "clips"
QUIET = ["flock", "-s", os.path.expanduser("~/.cache/omx-quiet.lock")]  # tests and GUI runs
BUILD = ["flock", os.path.expanduser("~/.cache/omx-build.lock")]  # (11-26, the main session) one Mojo build at a time on the machine, 6 cores
PN = Path(os.path.expanduser("~/Projects/personalnotev2"))  # the web app: read and run only

# ---- the bars, from the draft ----
WER_MAX = 0.10          # M5: word errors of a recorded clip played as the microphone
FIRST_WORDS_S = 1.0     # M5: first words on screen within 1 s of speaking (warm: the model already loaded)
M5_CLIPS = ["1284-1180-0000", "2094-142345-0001", "2300-131720-0000", "1089-134686-0000"]


def run(cmd, timeout=3600, env=None, cwd=ROOT):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def tail(s, n=600):
    return s[-n:].replace("\n", " | ")


def gpu_free():
    r = run([str(ROOT / "scripts" / "gpu-free")], 30)
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def build_test(name):
    """tests/<name>.mojo → build/g82/<name> (6 cores at most, under the quiet lock); "" or why not."""
    OUT.mkdir(parents=True, exist_ok=True)
    r = run(BUILD + ["pixi", "run", "mojo", "build", "-j", "6", "-I", ".", "-I", "vendor", f"tests/{name}.mojo", "-o", str(OUT / name)], 1800)
    if r.returncode or not (OUT / name).exists():
        return f"{name} didn't build: " + tail("\n".join(l for l in (r.stdout + r.stderr).splitlines() if " error" in l or "error:" in l), 800)
    return ""


def build_linux():
    """pnote, unless the binary is newer than every source it is built from (the machine builds one thing at a time)."""
    if APP.exists():
        newest = max(f.stat().st_mtime for d in ["mojoui", "examples/pnote", "themes", "hosts"] for f in (ROOT / d).rglob("*") if f.is_file())
        real = APP.with_name("pnote.bin") if APP.with_name("pnote.bin").exists() else APP
        if real.stat().st_mtime > newest:
            return ""
    r = run(BUILD + ["nice", "-n", "5", "taskset", "-c", "0-5", "bash", "scripts/build.sh", "pnote", "linux"], 3600)
    if r.returncode or not APP.exists():
        return "pnote didn't build: " + tail(r.stdout + r.stderr, 800)
    return ""


def words_of(text):
    return re.findall(r"[a-z0-9']+", text.lower())


def wer(ref, hyp):
    r, h = words_of(ref), words_of(hyp)
    prev = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        cur = [i]
        for j in range(1, len(h) + 1):
            cur.append(min(prev[j - 1] + (r[i - 1] != h[j - 1]), prev[j] + 1, cur[j - 1] + 1))
        prev = cur
    return prev[len(h)], len(r)


def clip_seconds(name):
    import wave
    with wave.open(str(CLIPS / f"{name}.wav")) as w:
        return w.getnframes() / w.getframerate()


# ---------------------------------------------------------------- M5 Voice

def m5_engine_linux():
    """tests/test_dictation: the clips as the microphone through mojoui.dictation (Parakeet in process on the GPU)."""
    err = build_test("test_dictation")
    if err:
        return "FAIL", err
    ok, why = gpu_free()
    if not ok:
        return "BLOCKED", "the GPU is busy (scripts/gpu-free: " + why + ")"
    r = run(QUIET + [str(OUT / "test_dictation")], 900)
    out = r.stdout + r.stderr
    (OUT / "m5-engine-linux.log").write_text(out)
    if "dictation: BLOCKED" in out:
        return "BLOCKED", re.search(r"dictation: BLOCKED.*", out).group(0)
    m = re.search(r"^dictation wer: (\d+) / (\d+)", out, re.M)
    if r.returncode or not m or "dictation: ok" not in out:
        return "FAIL", "test_dictation: " + tail(out)
    rate = int(m.group(1)) / max(int(m.group(2)), 1)
    firsts = [float(x) for x in re.findall(r"^dictation first-words: \S+ ([\d.]+) s after the voice starts$", out, re.M)]
    if rate > WER_MAX:
        return "FAIL", f"word errors {rate:.3f} > {WER_MAX}"
    if not firsts or max(firsts) > FIRST_WORDS_S:
        return "FAIL", f"first words (warm) {firsts} s, bar {FIRST_WORDS_S} s"
    return "PASS", f"Linux engine: WER {m.group(1)}/{m.group(2)} = {rate:.3f} (≤ {WER_MAX}); first words {', '.join(f'{f:.2f}' for f in firsts)} s after the voice starts (≤ {FIRST_WORDS_S})"


def seed_db(db, cfg):
    """A scratch Personal Note file (pnote makes it, as on a first start) with a page note "Dictation" ending in "Notes:"."""
    for f in [db, Path(str(db) + "-wal"), Path(str(db) + "-shm")]:
        f.unlink(missing_ok=True)
    shutil.rmtree(cfg, ignore_errors=True)
    cfg.mkdir(parents=True)
    env = dict(os.environ, PNOTE_DB=str(db), OMX_CONFIG=str(cfg), PNOTE_DIR=str(cfg), MOJOUI_TEST="wait:300;quit:")
    r = run(QUIET + ["scripts/testscreen", str(APP)], 300, env=env)
    if not db.exists():
        raise RuntimeError("pnote made no notes file: " + tail(r.stdout + r.stderr))
    con = sqlite3.connect(db)
    md = "# Dictation\n\nNotes:"
    content = json.dumps({"version": 1, "markdown": md, "ink": {"marks": [], "drawings": []}})
    cur = con.execute("INSERT INTO notes (resource_id, note_type, title, content, content_format) VALUES ('res_g82m5page', 'page', 'Dictation', ?, 'page')", (content,))
    con.execute("INSERT INTO note_search (note_id, title, body) VALUES (?, 'Dictation', ?)", (cur.lastrowid, md))
    con.commit()
    page = cur.lastrowid
    canvas = con.execute("SELECT id FROM notes WHERE note_type = 'canvas'").fetchone()[0]
    con.close()
    return page, canvas


def pnote_dictate(db, cfg, first, steps, clips, tag):
    """pnote on the hidden screen, the clips (one after another, 1.5 s apart) as its microphone."""
    at, parts = 0.0, []
    for c in clips:
        parts.append(f"{CLIPS / (c + '.wav')}@{at:.2f}")
        at += clip_seconds(c) + 1.5
    boxes = OUT / f"m5-{tag}.boxes.json"
    env = dict(os.environ, PNOTE_DB=str(db), PNOTE_FIRST=str(first), OMX_CONFIG=str(cfg), PNOTE_DIR=str(cfg), PNOTE_BOXES=str(boxes),
               PNOTE_VOICE_SOURCE="file:" + ",".join(parts), MOJOUI_TEST=";".join(steps))
    r = run(QUIET + ["scripts/testscreen", str(APP)], 600, env=env)
    log = r.stdout + r.stderr
    (OUT / f"m5-{tag}.log").write_text(log)
    return log, at


def note_text(db, id):
    con = sqlite3.connect(db)
    kind, content = con.execute("SELECT note_type, content FROM notes WHERE id = ?", (id,)).fetchone()
    con.close()
    if kind == "page":
        return json.loads(content)["markdown"]
    doc = json.loads(content)
    return "\n".join(n.get("text", "") for n in doc.get("nodes", []) if n.get("type") == "text")


def m5_pnote_linux():
    """The real app: tap the page's mic, the clips play as the microphone, tap again; the words are at the caret, saved
    in the notes file. Then a canvas: the dock's mic, a new text under what is there."""
    err = build_linux()
    if err:
        return "FAIL", err
    ok, why = gpu_free()
    if not ok:
        return "BLOCKED", "the GPU is busy (scripts/gpu-free: " + why + ")"
    db, cfg = OUT / "m5.db", OUT / "m5-cfg"
    page, canvas = seed_db(db, cfg)
    clips = M5_CLIPS[:2]
    total = sum(clip_seconds(c) for c in clips) + 1.5 * len(clips)
    mic = "972,956"  # the page's mic: 1440×900 window, (w − 16 − 48 + 24, h − 16 − 48 + 24) in thousandths
    steps = ["wait:1500", f"tapat:desk={mic}", f"wait:{int(total * 1000) + 1500}", f"tapat:desk={mic}", "wait:3000", f"render:desk={OUT / 'm5-page.png'}", "quit:"]
    log, _ = pnote_dictate(db, cfg, page, steps, clips, "page")
    text = note_text(db, page)
    if not text.startswith("# Dictation\n\nNotes:"):
        return "FAIL", f"the page lost its words: {text[:120]!r}"
    said = text[len("# Dictation\n\nNotes:"):]
    ref = " ".join((CLIPS / f"{c}.txt").read_text() for c in clips)
    e, n = wer(ref, said)
    if "PNOTE VOICE: listening kind=page" not in log:
        return "FAIL", "the mic didn't start on the page: " + tail(log)
    if not said.startswith(" ") or e / max(n, 1) > WER_MAX:
        return "FAIL", f"page: WER {e}/{n} on {said!r}"
    first = re.findall(r"^PNOTE VOICE: words ms=(\d+)", log, re.M)
    # the canvas: the dock's mic (its box from the first frame's boxes), one clip
    log2, _ = pnote_dictate(db, cfg, canvas, ["wait:1500", "quit:"], [], "canvas-boxes")
    bx = json.loads((OUT / "m5-canvas-boxes.boxes.json").read_text())
    if "#voice-button" not in bx:
        return "FAIL", "no #voice-button on the canvas dock"
    x, y, w, h = bx["#voice-button"]
    at = f"{round((x + w / 2) / 1440 * 1000)},{round((y + h / 2) / 900 * 1000)}"
    c3 = [M5_CLIPS[2]]
    t3 = clip_seconds(c3[0]) + 1.5
    log3, _ = pnote_dictate(db, cfg, canvas, ["wait:1500", f"tapat:desk={at}", f"wait:{int(t3 * 1000) + 1500}", f"tapat:desk={at}", "wait:3000",
                                               f"render:desk={OUT / 'm5-canvas.png'}", "quit:"], c3, "canvas")
    ctext = note_text(db, canvas)
    e3, n3 = wer((CLIPS / f"{c3[0]}.txt").read_text(), ctext)
    if "PNOTE VOICE: listening kind=canvas" not in log3 or e3 / max(n3, 1) > WER_MAX:
        return "FAIL", f"canvas: WER {e3}/{n3} on {ctext!r}: {tail(log3, 300)}"
    return "PASS", (f"pnote Linux: page WER {e}/{n} (words at the caret after 'Notes:', saved), canvas WER {e3}/{n3} (a new text from the "
                    f"dock's mic); first words {first[0] if first else '?'} ms after the press (with the model's first load)")


def m5_mac():
    """The Mac: tests/test_dictation with Apple's on-device recogniser (the clips fed through the same pipeline)."""
    files = []
    for c in M5_CLIPS:
        files += [f"docs/goals/43/clips/{c}.wav", f"docs/goals/43/clips/{c}.txt"]
    env = dict(os.environ, MAC_TEST_FILES=" ".join(files), MAC_TEST_ENV="MOJOUI_SPEECH_ASK=0")
    r = run(["scripts/mac-test", "tests/test_dictation.mojo"], 2400, env=env)
    out = r.stdout + r.stderr
    (OUT / "m5-mac.log").write_text(out)
    if "dictation rules: ok" not in out:
        return "FAIL", "Mac: " + tail(out)
    if "dictation: BLOCKED" in out:
        return "BLOCKED", "Mac: " + re.search(r"dictation: BLOCKED.*", out).group(0)[19:] + " — the owner allows Speech Recognition once (see the report)"
    m = re.search(r"^dictation wer: (\d+) / (\d+)", out, re.M)
    if not m or "dictation: ok" not in out:
        return "FAIL", "Mac: " + tail(out)
    rate = int(m.group(1)) / max(int(m.group(2)), 1)
    return ("PASS" if rate <= WER_MAX else "FAIL"), f"Mac (Apple on-device): WER {m.group(1)}/{m.group(2)} = {rate:.3f}"


def m5():
    parts = [("engine", m5_engine_linux), ("pnote", m5_pnote_linux), ("mac", m5_mac)]
    return combine(parts)


# ---------------------------------------------------------------- M6 AI

PN_PY = PN / ".venv" / "bin" / "python"  # the web app's own Python (its checkout's venv), run with -B: nothing written there
JAM_CASES = ROOT / "docs" / "goals" / "82" / "jam-cases.json"
AE_CASES = ROOT / "docs" / "goals" / "82" / "agentedit-cases.json"
TEST_SERVICE = "omxcode g82 check"  # the secret store's item for the checks (never the person's "Personal Note AI")


def json_lines(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("{"):
            out.append(json.loads(line))
    return out


def m6_secrets_linux():
    err = build_test("test_secrets")
    if err:
        return "FAIL", err
    r = run(QUIET + [str(OUT / "test_secrets")], 120)
    out = r.stdout + r.stderr
    if r.returncode or "round trip ok" not in out:
        return "FAIL", "test_secrets: " + tail(out)
    return "PASS", "Linux secret store (libsecret's Secret Service): " + out.strip().splitlines()[-1]


def m6_secrets_mac():
    """The Mac's keychain: the login keychain is locked to an SSH session ("User interaction is not allowed"), so the
    check makes a throwaway keychain of its own, unlocked in the same session, and runs the same test against it."""
    kc = "/Users/bhoomijaprasad/g82-check.keychain-db"
    pre = f"security delete-keychain {kc} >/dev/null 2>&1; security create-keychain -p g82-throwaway {kc} && security set-keychain-settings {kc} && security unlock-keychain -p g82-throwaway {kc};"
    env = dict(os.environ, MAC_TEST_PRE=pre, MAC_TEST_ENV=f"SECRETS_TEST_KEYCHAIN={kc}")
    r = run(["scripts/mac-test", "tests/test_secrets.mojo"], 1800, env=env)
    out = r.stdout + r.stderr
    (OUT / "m6-secrets-mac.log").write_text(out)
    if "round trip ok" not in out:
        if "Connection timed out" in out or "No route" in out:
            return "BLOCKED", "the Mac didn't answer"
        return "FAIL", "Mac: " + tail(out)
    return "PASS", "Mac keychain (a keychain file of the check's own; the login keychain is the same calls): " + [l for l in out.splitlines() if l.startswith("secrets:")][-1]


def m6_jam():
    """Recorded brain replies (docs/goals/82/jam-cases.json) through mojoui.jam and through the web's own jam_brain.py +
    mindmap/jam.js: the same edits, the same refusals in the same words, the same map after."""
    err = build_test("test_jam")
    if err:
        return "FAIL", err
    ours = json_lines(run(QUIET + [str(OUT / "test_jam")], 120).stdout)
    w = run([str(PN_PY), "-I", "-B", str(ROOT / "docs/goals/82/web_jam.py"), str(PN), str(JAM_CASES)], 120)
    a = subprocess.run(["node", str(ROOT / "docs/goals/82/web_jam_apply.mjs"), str(PN), str(JAM_CASES)], input="\n".join(l for l in w.stdout.splitlines() if '"case"' in l),
                       capture_output=True, text=True, timeout=120, cwd=ROOT)
    web = json_lines(a.stdout) + [x for x in json_lines(w.stdout) if "prompt" in x]
    if not web or a.returncode:
        return "FAIL", "the web's side didn't run: " + tail(w.stderr + a.stderr)
    bad = []
    by = {x["case"]: x for x in web if "case" in x}
    cases = json.loads(JAM_CASES.read_text())
    for o in ours:
        if "prompt" in o:
            wp = next((x["prompt"] for x in web if "prompt" in x), None)
            if o["prompt"] != wp:
                bad.append("the prompt differs")
            continue
        c = o["case"]
        x = by.get(c)
        name = cases[c]["name"]
        if x is None or o["ok"] != x["ok"]:
            bad.append(f"{name}: ok {o['ok']} vs web {x and x['ok']} ({o.get('error') or x and x.get('error')})")
            continue
        if not o["ok"]:
            if o["error"] != x["error"]:
                bad.append(f"{name}: {o['error']!r} vs web {x['error']!r}")
            continue
        if o["wire"] != x["wire"] or o["dropped"] != x["dropped"]:
            bad.append(f"{name}: edits {o['wire']} / {o['dropped']} vs web {x['wire']} / {x['dropped']}")
            continue
        def norm(doc):
            ids = {}
            for k, n in enumerate(doc["nodes"]):
                if not str(n["id"]).startswith(("node-", "jam-")):
                    ids[n["id"]] = n["id"]
                else:
                    ids[n["id"]] = f"new{k}"
            nodes = [{**n, "id": ids[n["id"]], "parentId": ids.get(n.get("parentId"), n.get("parentId"))} for n in doc["nodes"]]
            ghosts = [{k: v for k, v in g.items() if k != "id"} for g in doc.get("ghosts", [])]
            return {"nodes": nodes, "ghosts": ghosts, **{k: v for k, v in doc.items() if k not in ("nodes", "ghosts")}}
        if norm(o["map"]) != norm(x["map"]):
            bad.append(f"{name}: map after differs: {json.dumps(norm(o['map']))[:300]} vs web {json.dumps(norm(x['map']))[:300]}")
    if len([o for o in ours if "case" in o]) != len(cases):
        bad.append(f"{len(ours)} lines for {len(cases)} cases")
    if bad:
        return "FAIL", "; ".join(bad[:4])
    return "PASS", f"Jam: {len(cases)} recorded replies give the web's own edits, refusals (same words) and map, the prompt the same"


def m6_ai_linux():
    """Settings → AI's rules, the key in the secret store (never in the file, never printed), a brain call through curl to
    a loopback fake of an OpenAI endpoint (the key only as its header), and agent edits vs the web's agent_edit.py."""
    err = build_test("test_ai")
    if err:
        return "FAIL", err
    d = OUT / "m6-ai"
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    reply = d / "reply.txt"
    reply.write_text('{"edits": []}')
    seen = d / "seen.jsonl"
    key = "sk-g82-" + os.urandom(12).hex()
    fake = subprocess.Popen([sys.executable, "-I", str(ROOT / "docs/goals/82/fake_openai.py"), "0", str(reply), str(seen)], stdout=subprocess.PIPE, text=True)
    try:
        port = int(fake.stdout.readline())
        env = dict(os.environ, AI_TEST_DIR=str(d), AI_TEST_KEY=key, AI_TEST_URL=f"http://127.0.0.1:{port}/v1", AI_TEST_REPLY=str(reply), MOJOUI_AI_SERVICE=TEST_SERVICE)
        r = run(QUIET + [str(OUT / "test_ai")], 300, env=env)
    finally:
        fake.kill()
    out = r.stdout + r.stderr
    (OUT / "m6-ai.log").write_text(out.replace(key, "<KEY>"))
    if r.returncode or "ai call: ok" not in out:
        return "FAIL", "test_ai: " + tail(out.replace(key, "<KEY>"))
    if key in out:
        return "FAIL", "the key was printed"
    leaks = [str(f) for f in d.rglob("*") if f.is_file() and f != seen and key in f.read_text(errors="ignore")]
    if leaks:
        return "FAIL", f"the key is in a file: {leaks}"
    sent = [json.loads(l) for l in seen.read_text().splitlines()]
    if not sent or sent[0]["auth"] != "Bearer " + key or sent[0]["body"].get("model") != "test-model":
        return "FAIL", f"the fake saw {len(sent)} requests; auth right: {bool(sent) and sent[0]['auth'] == 'Bearer ' + key}"
    if subprocess.run(["secret-tool", "lookup", "service", TEST_SERVICE, "account", "api-key"], capture_output=True).returncode == 0:
        return "FAIL", "the test's key is still in the store"
    ours = json_lines(out)
    w = run([str(PN_PY), "-I", "-B", str(ROOT / "docs/goals/82/web_agentedit.py"), str(PN), str(AE_CASES)], 120)
    web = json_lines(w.stdout)
    cases = json.loads(AE_CASES.read_text())
    bad = []
    for o, x in zip(ours, web):
        if o["undo"] != x["undo"]:
            bad.append(f"{cases[o['case']]['name']}: undo {o['undo']!r} vs web {x['undo']!r}")
        if x["span"] is not None and o["span"] != x["span"]:
            bad.append(f"{cases[o['case']]['name']}: span {o['span']} vs web {x['span']}")
    if len(ours) != len(cases) or len(web) != len(cases):
        bad.append(f"{len(ours)} / {len(web)} lines for {len(cases)} cases")
    if bad:
        return "FAIL", "; ".join(bad[:3])
    return "PASS", (f"settings rules in the web's words; key in the store, not in the file or the output; curl sent it only as the bearer header "
                    f"to the loopback fake; {len(cases)} agent-edit undos match the web's agent_edit.py")


def center(bx, name, cw=1440.0, ch=900.0):
    hits = [k for k in bx if k == name or k.startswith(name)]
    if not hits:
        raise KeyError(f"no box {name} (have {[k for k in bx if 'settings' in k or 'jam' in k or 'toast' in k][:12]})")
    x, y, w, h = bx[hits[0]]
    return f"{round((x + w / 2) / cw * 1000)},{round((y + h / 2) / ch * 1000)}"


def pnote_run(db, cfg, first, steps, tag, extra=None, popen=False):
    boxes = OUT / f"m6-{tag}.boxes.json"
    boxes.unlink(missing_ok=True)
    env = dict(os.environ, PNOTE_DB=str(db), PNOTE_FIRST=str(first), OMX_CONFIG=str(cfg), PNOTE_DIR=str(cfg), PNOTE_BOXES=str(boxes),
               MOJOUI_TEST=";".join(steps), MOJOUI_AI_SERVICE=TEST_SERVICE, **(extra or {}))
    cmd = QUIET + ["scripts/testscreen", str(APP)]
    if popen:
        return subprocess.Popen(cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True), boxes
    r = run(cmd, 600, env=env)
    log = r.stdout + r.stderr
    (OUT / f"m6-{tag}.log").write_text(log)
    return log, (json.loads(boxes.read_text()) if boxes.exists() else {})


OPEN_SETTINGS = ["wait:1500", "key:desk=ctrl+k", "wait:400", "typekeys:desk=Open settings", "wait:300", "typekeys:desk=⏎", "wait:800"]


def m6_pnote_linux():
    err = build_linux()
    if err:
        return "FAIL", err
    db, cfg = OUT / "m6.db", OUT / "m6-cfg"
    page, canvas = seed_db(db, cfg)
    # a jam map: the first Jam case's map, in jam mode
    case0 = json.loads(JAM_CASES.read_text())[0]
    con = sqlite3.connect(db)
    jam_doc = json.dumps({**case0["map"], "jam": True})
    cur = con.execute("INSERT INTO notes (resource_id, note_type, title, content, content_format) VALUES ('res_g82m6jam', 'mindmap', 'Trip to Lisbon', ?, 'mindmap')", (jam_doc,))
    con.execute("INSERT INTO note_search (note_id, title, body) VALUES (?, 'Trip to Lisbon', 'Trip to Lisbon')", (cur.lastrowid,))
    con.commit()
    jam = cur.lastrowid
    con.close()
    subprocess.run(["secret-tool", "clear", "service", TEST_SERVICE, "account", "api-key"], capture_output=True)
    results = []
    # ---- Settings → AI: the page's own fields, keys and buttons; a loopback fake as the model
    d = OUT / "m6-fake"
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    (d / "reply.txt").write_text('{"ok": true}')
    seen = d / "seen.jsonl"
    fake = subprocess.Popen([sys.executable, "-I", str(ROOT / "docs/goals/82/fake_openai.py"), "0", str(d / "reply.txt"), str(seen)], stdout=subprocess.PIPE, text=True)
    key = "skg82" + os.urandom(10).hex()
    try:
        port = int(fake.stdout.readline())
        (cfg / "ai-settings.json").write_text(json.dumps({"provider": "openai", "claudeModel": "sonnet", "endpoint": "", "deployment": "", "apiVersion": "2024-10-21",
                                                          "baseUrl": f"http://127.0.0.1:{port}/v1", "model": "test-model"}, indent=2))
        log, bx = pnote_run(db, cfg, page, OPEN_SETTINGS + ["wait:300", "quit:"], "settings-a")
        ai_item = center(bx, "settings.item:AI")
        log, bx = pnote_run(db, cfg, page, OPEN_SETTINGS + [f"tapat:desk={ai_item}", "wait:600", "quit:"], "settings-b")
        steps = OPEN_SETTINGS + [f"tapat:desk={ai_item}", "wait:600",
                                 f"tapat:desk={center(bx, 'settings.field:key')}", "wait:300", f"typekeys:desk={key}", "wait:200", "key:desk=Return", "wait:300",
                                 f"tapat:desk={center(bx, 'settings.button:actions:0')}", "wait:1500",
                                 f"tapat:desk={center(bx, 'settings.button:actions:1')}", "wait:3000", f"render:desk={OUT / 'm6-settings-ai.png'}", "quit:"]
        log, bx2 = pnote_run(db, cfg, page, steps, "settings-c")
    finally:
        fake.kill()
    saved = re.search(r"^PNOTE AI: saved provider=(\S+) key=(\S+)", log, re.M)
    tested = re.search(r"^PNOTE AI: test (.*)$", log, re.M)
    file = (cfg / "ai-settings.json").read_text()
    sent = [json.loads(l) for l in seen.read_text().splitlines()] if seen.exists() else []
    leaked = [str(f) for f in list(cfg.rglob("*")) + [db] if f.is_file() and key in f.read_text(errors="ignore")] + (["the app's output"] if key in log else [])
    stored = subprocess.run(["secret-tool", "lookup", "service", TEST_SERVICE, "account", "api-key"], capture_output=True, text=True).stdout.strip()
    subprocess.run(["secret-tool", "clear", "service", TEST_SERVICE, "account", "api-key"], capture_output=True)
    (OUT / "m6-settings-c.log").write_text(log.replace(key, "<KEY>"))
    if not saved or saved.group(2) != "saved" or stored != key:
        return "FAIL", f"Settings → AI: saved {saved and saved.groups()}, key in the store: {stored == key}: {tail(log.replace(key, '<KEY>'), 400)}"
    if leaked:
        return "FAIL", f"the key is outside the secret store: {leaked}"
    if not tested or not tested.group(1).startswith("Answered in") or not sent or sent[-1]["auth"] != "Bearer " + key:
        return "FAIL", f"Test: {tested and tested.group(1)}; the fake saw {len(sent)} requests (key as the bearer header: {bool(sent) and sent[-1]['auth'] == 'Bearer ' + key})"
    results.append(f"Settings → AI: key typed in the page went to the store only (not in ai-settings.json, the notes file or the log), Test reached the model ({tested.group(1)})")
    # ---- Jam: hold the map's mic (a clip as the microphone), press Jam: the recorded reply's edits on the map
    ok, why = gpu_free()
    if not ok:
        return "BLOCKED", "the GPU is busy (scripts/gpu-free: " + why + ")"
    reply = OUT / "m6-jam-reply.txt"
    reply.write_text(case0["reply"])
    log, bx = pnote_run(db, cfg, jam, ["wait:1500", "quit:"], "jam-a")
    clip = M5_CLIPS[3]
    t = clip_seconds(clip) + 1.5
    mic, go = center(bx, "#map-voice"), center(bx, "#jam-go")
    log, _ = pnote_run(db, cfg, jam, ["wait:1500", f"tapat:desk={mic}", f"wait:{int(t * 1000) + 1500}", f"tapat:desk={mic}", "wait:2500", f"tapat:desk={go}", "wait:2000",
                                      f"render:desk={OUT / 'm6-jam.png'}", "quit:"], "jam-b",
                       {"MOJOUI_BRAIN_REPLAY": str(reply), "PNOTE_VOICE_SOURCE": f"file:{CLIPS / (clip + '.wav')}@0.3"})
    asked = re.search(r"^PNOTE JAM: asked words=(.+)$", log, re.M)
    edits = re.search(r"^PNOTE JAM: edits=(.+)$", log, re.M)
    w = run([str(PN_PY), "-I", "-B", str(ROOT / "docs/goals/82/web_jam.py"), str(PN), str(JAM_CASES)], 120)
    web0 = json_lines(w.stdout)[0]
    if not asked or not edits:
        return "FAIL", f"Jam: asked {bool(asked)}, edits {bool(edits)}: {tail(log, 400)}"
    if json.loads(edits.group(1)) != web0["wire"]:
        return "FAIL", f"Jam: the app's edits {edits.group(1)[:200]} vs the web's {json.dumps(web0['wire'])[:200]}"
    con = sqlite3.connect(db)
    saved_map = json.loads(con.execute("SELECT content FROM notes WHERE id = ?", (jam,)).fetchone()[0])
    con.close()
    texts = {n["text"] for n in saved_map["nodes"]}
    want = {e["text"] for e in web0["wire"] if e["op"] == "add_branch"}
    votes = {n["id"]: n.get("vote") for n in saved_map["nodes"] if n.get("vote")}
    ghosts = [g["text"] for g in saved_map.get("ghosts", [])]
    if not want <= texts or votes != {e["nodeId"]: e["vote"] for e in web0["wire"] if e["op"] == "react"} or ghosts != [e["text"] for e in web0["wire"] if e["op"] == "ghost"]:
        return "FAIL", f"Jam: the saved map has {sorted(texts)}, votes {votes}, ghosts {ghosts}"
    results.append(f"Jam: heard \"{asked.group(1)[:50]}…\", the recorded reply's {len(web0['wire'])} edits = the web's, saved in the map (branches, vote, ghost)")
    # ---- an agent's edit through the web's own CLI while the page is open: Show, then Undo
    def agent_write(text):
        return subprocess.run([str(PN_PY), "-B", str(PN / "personal_note_cli.py"), "--database", str(db), "--agent", "Claude Code", "notes", "write", str(page), "--text", text],
                              capture_output=True, text=True, timeout=60, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
    before = note_text(db, page)
    proc, boxes = pnote_run(db, cfg, page, ["wait:4000", "wait:5000", "quit:"], "agent-a", popen=True)
    time.sleep(3.5)
    agent_write(before + "\n\nPacked by Claude: tent, stove.")
    out_a = proc.communicate(timeout=300)[0]
    bx = json.loads(boxes.read_text()) if boxes.exists() else {}
    if "PNOTE AGENT: offered" not in out_a or "#toast-action" not in bx or "toast.action2" not in bx:
        return "FAIL", f"agent edit: not offered ({tail(out_a, 300)})"
    show, undo = center(bx, "toast.action2"), center(bx, "#toast-action")
    agent_write(before)  # (back as it was, for the second run: the same words, the same toast)
    before = note_text(db, page)
    proc, _ = pnote_run(db, cfg, page, ["wait:4000", "wait:2500", f"tapat:desk={show}", "wait:500", f"tapat:desk={undo}", "wait:2500", "quit:"], "agent-b", popen=True)
    time.sleep(3.5)
    agent_write(before + "\n\nPacked by Claude: tent, stove.")
    out_b = proc.communicate(timeout=300)[0]
    (OUT / "m6-agent-b.log").write_text(out_b)
    con = sqlite3.connect(db)
    state = con.execute("SELECT state FROM agent_edits WHERE note_id = ? ORDER BY id DESC LIMIT 1", (page,)).fetchone()
    con.close()
    after = note_text(db, page)
    if "PNOTE AGENT: show" not in out_b or "PNOTE AGENT: undone" not in out_b or after != before or not state or state[0] != "undone":
        return "FAIL", f"agent edit: show {'PNOTE AGENT: show' in out_b}, undone {'PNOTE AGENT: undone' in out_b}, words back {after == before}, state {state}: {tail(out_b, 300)}"
    results.append("an agent's write (the web's own personal-note CLI, while the page was open): offered with Show and Undo; Show selected its lines; Undo put the words back and marked it undone")
    return "PASS", "; ".join(results)


def m6():
    return combine([("secrets", m6_secrets_linux), ("secrets-mac", m6_secrets_mac), ("jam", m6_jam), ("ai", m6_ai_linux), ("pnote", m6_pnote_linux)])


# ---------------------------------------------------------------- the verdict

def combine(parts):
    """Every part must PASS; a FAIL anywhere fails; a BLOCKED part (the owner's click, a busy GPU) blocks."""
    verdicts, whys = [], []
    for name, f in parts:
        try:
            v, why = f()
        except Exception as ex:  # (a checker crash is a FAIL with its reason, never a pass)
            v, why = "FAIL", f"{name}: checker error {type(ex).__name__}: {ex}"
        verdicts.append(v)
        whys.append(f"[{name} {v}] {why}")
        print(f"   {name}: {v}  {why}", flush=True)
    if not parts:
        return "FAIL", "no checks yet"
    v = "FAIL" if "FAIL" in verdicts else ("BLOCKED" if "BLOCKED" in verdicts else "PASS")
    return v, " ".join(whys)


MILESTONES = {"M5": m5, "M6": m6}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    want = sys.argv[1:] or list(MILESTONES)
    for name in want:
        part = None
        if "." in name:  # M5.engine: one part only
            name, part = name.split(".", 1)
        f = MILESTONES.get(name)
        if not f:
            print(f"{name}: FAIL  no such milestone in this checker")
            continue
        if part:
            g = globals().get(f"{name.lower()}_{part}")
            v, why = g() if g else ("FAIL", "no such part")
        else:
            v, why = f()
        print(f"{name}: {v}  {why}", flush=True)
