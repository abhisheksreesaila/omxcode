"""Goal 62's proof: omxplorer on the web, safe to share (GOAL.md). Prints "Mn: PASS|FAIL|BLOCKED  why" per milestone.

    pixi run python docs/goals/62-check.py [M0 M1 ...]      (default: every milestone)

Every web server here runs CPU-only (CUDA_VISIBLE_DEVICES=""), on a free port, with its own scratch folder under
build/g62/; the visitors are headless Chromium pages that only click (docs/goals/62/story.py). The starter
(build/starter/robot) is made by scripts/starter.py from goal 47's full set (read-only, another session's folder).
"""
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1].parent
sys.path.insert(0, str(ROOT / "docs/goals/62"))
sys.path.insert(0, str(ROOT / "scripts"))
from harness import Server, OUT, G47, STARTER, MODULE, settle, try_settle, PROBE, OBJECTS, Net, chromium, get  # noqa: E402

PY = sys.executable


def run(cmd, timeout=3600, env=None, cwd=ROOT):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))


def build_web():
    """The web version, built from this tree (scripts/build.sh skips what didn't change), and the upload check beside it."""
    r = run(["scripts/build.sh", "omxplorer", "web"], 1800)
    if r.returncode:
        raise RuntimeError("build: " + (r.stdout + r.stderr)[-800:])
    v = MODULE / "validate"
    if not v.exists() or v.stat().st_mtime < max((ROOT / f).stat().st_mtime for f in ("mojoui/csvio.mojo", "hosts/validate_main.mojo")):
        r = run(["scripts/mxbuild.sh", "hosts/validate_main.mojo", "-o", str(v)], 1800)
        if r.returncode:
            raise RuntimeError("validator build: " + (r.stdout + r.stderr)[-800:])


def starter():
    """The robot starter (scripts/starter.py makes it once; it checks itself on later calls)."""
    r = run([PY, "scripts/starter.py", "--from", str(G47), "--to", str(STARTER)], 7200)
    if r.returncode or not (STARTER / "story.json").exists():
        raise RuntimeError("starter: " + (r.stdout + r.stderr)[-800:])
    return STARTER


def tree_hash(folder):
    """sha256 of every file under folder (following links), by its path relative to folder."""
    files = sorted(p for p in Path(folder).rglob("*") if p.is_file())

    def one(p):
        h = hashlib.sha256()
        with open(p, "rb") as f:
            while chunk := f.read(1 << 22):
                h.update(chunk)
        return str(p.relative_to(folder)), h.hexdigest()

    with ThreadPoolExecutor(8) as ex:
        return dict(ex.map(one, files))


def visitor(url, out, *args, timeout=1200):
    """One visitor playing the story in its own process (docs/goals/62/story.py): its results.json, parsed."""
    p = subprocess.Popen([PY, str(ROOT / "docs/goals/62/story.py"), "--url", url, "--out", str(out), *args], cwd=ROOT,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return p


def visitor_result(p, out, timeout=1200):
    try:
        text, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        text, _ = p.communicate()
    Path(out).mkdir(parents=True, exist_ok=True)
    (Path(out) / "visitor.log").write_text(text or "")
    try:
        return json.loads((Path(out) / "results.json").read_text())
    except (OSError, ValueError):
        return {"ok": False, "beats": {}, "timings": {}, "log": (text or "")[-1500:]}


def failed_beats(R):
    return [f"{k}: {v['note'][:160]}" for k, v in R.get("beats", {}).items() if not v["ok"]] or ([] if R.get("beats") else [R.get("log", "no beats")[-400:]])


# ---------------------------------------------------------------- M0
def m0():
    probs = []
    r = run(["bash", "-c", "scripts/mxbuild.sh tests/test_sheetjobs_wake.mojo -o build/test_sheetjobs_wake && CUDA_VISIBLE_DEVICES= build/test_sheetjobs_wake"], 1800)
    said = (r.stdout + r.stderr).strip().splitlines()
    if r.returncode or not any("test_sheetjobs_wake: ok" in l for l in said):
        probs.append("test_sheetjobs_wake: " + " | ".join(said[-4:])[:500])
    build_web()
    from playwright.sync_api import sync_playwright
    landed, times = 0, []
    with sync_playwright() as p:
        b = chromium(p)
        for i in range(20):
            srv = Server(OUT / f"m0/{i}", starter=None)
            try:
                ctx = b.new_context(viewport={"width": 1440, "height": 900})
                page = ctx.new_page()
                # no moving canvas: a canvas that asks for frames gets "gone" and stops, so no frame event reaches the
                # app; only the jobs' wake can land the open
                page.route(re.compile(r".*/frame/.*tick=1.*"), lambda route: route.fulfill(status=204, headers={"X-Mojoui-Gone": "1"}))
                page.goto(srv.url)
                settle(page)
                m = srv.mark()
                t0 = time.perf_counter()
                page.set_input_files("input[type=file] >> nth=0", str(G47 / "fleet.csv"))
                ok = False
                while time.perf_counter() - t0 < 10:
                    if "63,344" in page.inner_text("body") and srv.traced("JOB: landed open fleet.csv", m, 0):
                        ok = True
                        break
                    page.wait_for_timeout(100)
                took = time.perf_counter() - t0
                landed += ok
                times.append(round(took, 2))
                if not ok:
                    page.screenshot(path=str(OUT / f"m0/{i}/hung.png"))
                    probs.append(f"server {i}: not landed in 10 s ({srv.traced('JOB:', m, 0) or 'no JOB line'})")
                ctx.close()
            finally:
                srv.stop()
        b.close()
    (OUT / "m0/times.json").write_text(json.dumps(times))
    if landed < 20:
        probs.insert(0, f"landed in {landed} of 20")
    return (not probs), ("; ".join(probs)[:1500] if probs else
                         f"test_sheetjobs_wake ok (warm, open, chart, column); fleet.csv landed in 20 of 20 tabs with no moving canvas, "
                         f"slowest {max(times):.2f} s, median {statistics.median(times):.2f} s")


# ---------------------------------------------------------------- M1
def m1():
    probs = []
    build_web()
    st = starter()
    before = tree_hash(st)
    story = json.loads((st / "story.json").read_text())
    from playwright.sync_api import sync_playwright
    srv = Server(OUT / "m1", public=True)
    mems, results = [], []
    try:
        first = get(srv.url, headers={"Sec-Fetch-Dest": "document", "Sec-Fetch-Mode": "navigate"})[2].decode(errors="replace")
        for gone in ("Taxi trips", "Connect a database"):  # (the first HTML itself, not only the page once it settled)
            if gone in first:
                probs.append(f"the first public page holds “{gone}”")
        if any("agent link at" in l for l in srv.log):
            probs.append("the agent link is on")
        mems.append(("server up", srv.memory()))
        with sync_playwright() as p:
            b = chromium(p)
            import story as S  # (docs/goals/62/story.py)
            for k in range(1, 4):
                ctx = b.new_context(viewport={"width": 1440, "height": 900}, accept_downloads=True)
                page = ctx.new_page()
                page.add_init_script(PROBE)
                net = Net(page)
                page.goto(srv.url)
                settle(page)
                if k == 1:
                    body = page.inner_text("body")
                    if not ("DROID" in body and "CC-BY-4.0" in body):
                        probs.append("the Start screen doesn't credit DROID (CC-BY-4.0)")
                    for gone in ("Taxi trips", "Coming with MX frame", "Connect a database"):  # (round 2: what a visitor can't use there)
                        if gone in body:
                            probs.append(f"the public Start screen shows “{gone}”")
                    page.screenshot(path=str(OUT / "m1-start.png"))
                R = S.play(page, OUT / f"m1/tab{k}", net, pack=(k == 1))
                results.append(R)
                ups = [e for e in net.events if e[1] == "request" and ("/upload/" in e[2] or "/dropfile/" in e[2])]
                if ups:
                    probs.append(f"tab {k} uploaded: {ups[0][2]}")
                bad = failed_beats(R)
                if bad:
                    probs.append(f"tab {k}: " + "; ".join(bad))
                page.wait_for_timeout(3000)  # (at rest: the story's jobs ended, the page settled)
                try_settle(page)
                time.sleep(2)
                mems.append((f"tab {k} played the story", srv.memory()))
            b.close()
    finally:
        srv.stop()
    after = tree_hash(st)
    if before != after:
        changed = [k for k in set(before) | set(after) if before.get(k) != after.get(k)]
        probs.append(f"the starter changed: {changed[:5]}")
    rss = [m["mem_mb"] for _, m in mems]  # (RSS + swap: the process's memory, wherever the kernel keeps it)
    adds = [rss[i + 1] - rss[i] for i in range(1, len(rss) - 1)]  # (tabs 2 and 3: each further tab)
    if not adds or max(adds) >= 300:
        probs.append(f"a further tab adds {adds} MB (RSS + swap {rss})")
    (OUT / "m1/memory.json").write_text(json.dumps(mems, indent=1))
    q1 = results[0].get("timings", {}).get("question1", {}) if results else {}
    return (not probs), ("; ".join(probs)[:1500] if probs else
                         f"one click → fleet 63,344 + telemetry 16,847,616 + links, clips, paper in {results[0]['timings'].get('start_s')} s; "
                         f"{len(story.get('questions', []))} questions with their SQL, regrasps 2,997 in {q1.get('clickToRowsMs')} ms; "
                         f"RSS + swap {rss} MB: tabs 2 and 3 add {adds} MB; starter hashes unchanged ({len(before)} files); DROID credited")


# ---------------------------------------------------------------- M2
def m2():
    build_web()
    starter()
    import probes  # (docs/goals/62/probes.py)
    ok, lines = probes.run_all(OUT / "m2")
    (OUT / "m2-probes.txt").write_text("\n".join(lines))
    bad = [l for l in lines if l.startswith("FAIL")]
    return ok and not bad, ("; ".join(bad)[:1500] if bad else f"{len(lines)} probes refused (build/g62/m2-probes.txt)")


# ---------------------------------------------------------------- M3
def m3():
    build_web()
    starter()
    import sessions  # (docs/goals/62/sessions.py)
    ok, lines = sessions.run_all(OUT / "m3")
    (OUT / "m3-sessions.txt").write_text("\n".join(lines))
    bad = [l for l in lines if l.startswith("FAIL")]
    return ok and not bad, ("; ".join(bad)[:1500] if bad else "; ".join(l[4:] for l in lines)[:1500])


# ---------------------------------------------------------------- M4
def m4():
    probs = []
    build_web()
    starter()
    from proxy import Proxy
    srv = Server(OUT / "m4", public=True)
    shots = {}
    try:
        with Proxy(srv.port, rtt_ms=100, down_mbit=10, up_mbit=5) as px:
            out = OUT / "m4/visitor"
            p = visitor(px.url, out, "--no-pack")
            R = visitor_result(p, out)
            bad = failed_beats(R)
            if bad:
                probs.append("story: " + "; ".join(bad))
            v = R.get("timings", {}).get("video", {})
            if (v.get("changesPerSec") or 0) < 12:
                probs.append(f"F00118 at {v.get('changesPerSec')} pictures/s")
            ratio = v.get("bytesPerNewPictureRatio")
            if ratio is None or ratio > 1.5:
                probs.append(f"the video used {ratio}× the bytes of its new pictures")
            q = [R.get("timings", {}).get(f"question{k}", {}).get("clickToRowsMs") for k in (1, 2)]
            if any(x is None or x > 600 for x in q):
                probs.append(f"click → answer {q} ms")
            # a still view, and the two window sizes, each in a fresh page through the same proxy
            from playwright.sync_api import sync_playwright
            with sync_playwright() as pw:
                b = chromium(pw)
                for name, (w, h) in (("desktop", (1440, 900)), ("phone", (390, 844))):
                    ctx = b.new_context(viewport={"width": w, "height": h}, is_mobile=(name == "phone"), has_touch=(name == "phone"))
                    page = ctx.new_page()
                    page.add_init_script(PROBE)
                    net = Net(page)
                    page.goto(px.url)
                    settle(page, 60000)
                    page.screenshot(path=str(OUT / f"m4-{name}-start.png"))
                    shots[f"{name}-start"] = str(OUT / f"m4-{name}-start.png")
                    if name == "desktop":
                        page.locator("button", has_text=re.compile("Start the robot story")).first.click()
                        page.wait_for_function("() => /16,847,616/.test(document.body.innerText)", timeout=180000)
                        settle(page, 60000)
                        page.wait_for_timeout(1500)
                        settle(page, 60000)
                        t0 = time.perf_counter()
                        page.wait_for_timeout(5000)
                        got = net.since(t0)
                        still = sum(e[3] for e in got)
                        if still:
                            probs.append(f"a still view fetched {still} bytes in 5 s: {[e[2].split('/')[3] for e in got][:8]}")
                    else:
                        btn = page.locator("button", has_text=re.compile("Start the robot story")).first
                        if btn.count():
                            btn.click()
                            try:
                                page.wait_for_function("() => /16,847,616/.test(document.body.innerText)", timeout=180000)
                            except Exception:
                                pass
                            settle(page, 60000)
                    page.screenshot(path=str(OUT / f"m4-{name}-story.png"))
                    shots[f"{name}-story"] = str(OUT / f"m4-{name}-story.png")
                    ctx.close()
                b.close()
            down, up = px.bytes_down, px.bytes_up
    finally:
        srv.stop()
    (OUT / "m4/shots.json").write_text(json.dumps(shots, indent=1))
    return (not probs), ("; ".join(probs)[:1500] if probs else
                         f"through 100 ms RTT, 10/5 Mbit/s: every beat; F00118 {v.get('changesPerSec')} pictures/s, {ratio}× the new pictures' bytes; "
                         f"click → answer {q} ms; a still view fetched 0 bytes in 5 s; {down / 2**20:.1f} MB down, {up / 2**20:.1f} MB up; "
                         f"screenshots {', '.join(Path(s).name for s in shots.values())} (look at them)")


# ---------------------------------------------------------------- M5
def plan():
    """The Railway plan's limits, as docs/research/railway.md states them for this app (a `PLAN:` line)."""
    text = (ROOT / "docs/research/railway.md").read_text() if (ROOT / "docs/research/railway.md").exists() else ""
    m = re.search(r"^PLAN: MemoryMax=(\S+) CPUQuota=(\S+) visitors=(\d+)", text, re.M)
    return (m.group(1), m.group(2), int(m.group(3))) if m else None


def m5():
    probs, blocked = [], []
    build_web()
    starter()
    df = ROOT / "Dockerfile.web"
    text = df.read_text() if df.exists() else ""
    for need, why in (("USER ", "non-root"), ("HEALTHCHECK", "a health check"), ("$PORT", "listens on $PORT"), ("MOJOUI_PUBLIC=1", "public mode")):
        if need not in text:
            probs.append(f"Dockerfile.web: no {why}")
    d = run(["docker", "info", "--format", "{{.ServerVersion}}"], 60)
    if d.returncode:
        blocked.append("the image wasn't built: this user can't reach Docker (" + (d.stderr.strip().splitlines() or ["?"])[-1][:120]
                       + "); the owner runs: sudo usermod -aG docker $USER && newgrp docker, then scripts/image-check")
    else:
        r = run(["scripts/image-check"], 7200)
        if r.returncode:
            probs.append("image: " + (r.stdout + r.stderr)[-600:])
    pl = plan()
    if not pl:
        probs.append("docs/research/railway.md names no PLAN: line")
        return False, "; ".join(probs)
    mem, cpu, n = pl
    start = (ROOT / "scripts/web-start").read_text() if (ROOT / "scripts/web-start").exists() else ""
    cap = re.search(r"MOJOUI_MAX_SESSIONS:-(\d+)", start)
    if not cap or int(cap.group(1)) != n:
        probs.append(f"the server's session cap ({cap.group(1) if cap else 'none'}) isn't the measured N ({n})")
    if n < 5:
        probs.append(f"N = {n} < 5")
    srv = Server(OUT / "m5", public=True, limits={"MemoryMax": mem, "CPUQuota": cpu, "MemorySwapMax": "0"},
                 env={"MOJOUI_MAX_SESSIONS": str(n)}, start=["bash", str(ROOT / "scripts/web-start")]) if start else None
    rows = []
    try:
        if srv is None:
            probs.append("no scripts/web-start (the image's start command)")
        else:
            outs = [OUT / f"m5/visitor-{k}" for k in range(n)]
            procs = [visitor(srv.url, o, "--no-pack") for o in outs]
            results = [visitor_result(p, o, 1800) for p, o in zip(procs, outs)]
            mem_after = srv.memory()
            clicks, rates = [], []
            for k, R in enumerate(results):
                bad = failed_beats(R)
                if bad:
                    probs.append(f"visitor {k}: " + "; ".join(bad)[:300])
                t = R.get("timings", {})
                rates.append(t.get("video", {}).get("changesPerSec") or 0)
                clicks += [t.get(f"question{q}", {}).get("clickToRowsMs") or 1e9 for q in (1, 2)]
            p95 = sorted(clicks)[max(0, int(len(clicks) * 0.95 + 0.5) - 1)] if clicks else 1e9
            if min(rates or [0]) < 12:
                probs.append(f"video pictures/s per visitor {rates}")
            if p95 > 1000:
                probs.append(f"click → answer p95 {p95:.0f} ms")
            rows = [n, mem, cpu, rates, round(p95), mem_after]
            if any("Killed" in l or "MemoryMax" in l for l in srv.log):
                probs.append("the server hit its memory limit")
    finally:
        if srv:
            srv.stop()
    wiz = ROOT / "scripts/deploy-railway"
    wtext = wiz.read_text() if wiz.exists() else ""
    if not wtext or run(["bash", "-n", str(wiz)]).returncode:
        probs.append("scripts/deploy-railway missing or not valid bash")
    for need in ("railway whoami", "railway up", "railway domain", "app.omxlabs.tech", "story.py"):
        if need not in wtext:
            probs.append(f"the wizard doesn't run `{need}`")
    if probs:
        return False, "; ".join(probs + blocked)[:1500]
    if blocked:
        return "BLOCKED", "; ".join(blocked) + f" | the rest passes: {n} visitors at once in {mem} / {cpu} CPU, video {rows[3]} pictures/s, p95 click → answer {rows[4]} ms"
    return True, f"image built and the story passed against it; {n} visitors at once in {mem} / {cpu}: video {rows[3]} pictures/s, p95 {rows[4]} ms"


# ---------------------------------------------------------------- M6
def m6():
    import regress  # (docs/goals/62/regress.py)
    ok, lines = regress.run_all(OUT / "m6")
    (OUT / "m6-regress.txt").write_text("\n".join(lines))
    bad = [l for l in lines if l.startswith("FAIL")]
    return ok and not bad, ("; ".join(bad)[:1500] if bad else f"{len(lines)} checks: " + "; ".join(l[4:60] for l in lines)[:1400])


# ---------------------------------------------------------------- M7
def m7():
    build_web()
    starter()
    import budgets  # (docs/goals/62/budgets.py)
    ok, lines = budgets.run_all(OUT / "m7")
    (OUT / "m7-budgets.txt").write_text("\n".join(lines))
    bad = [l for l in lines if l.startswith("FAIL")]
    return ok and not bad, ("; ".join(bad)[:1500] if bad else "; ".join(l[5:] for l in lines)[:1500])


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5, "M6": m6, "M7": m7}

if __name__ == "__main__":
    wanted = sys.argv[1:] or list(MILESTONES)
    bad = 0
    OUT.mkdir(parents=True, exist_ok=True)
    for k in wanted:
        t0 = time.time()
        try:
            ok, why = MILESTONES[k]()
        except Exception as e:  # a crashing proof is a failing proof
            import traceback
            traceback.print_exc()
            ok, why = False, f"crashed: {e!r}"
        word = "BLOCKED" if ok == "BLOCKED" else ("PASS" if ok else "FAIL")
        print(f"{k}: {word}  {why}  ({time.time() - t0:.0f} s)", flush=True)
        bad += word == "FAIL"
    sys.exit(1 if bad else 0)
