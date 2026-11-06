"""Goal 55: omxconsole, a desktop app for MAX, all omxcode (GOAL.md). Prints PASS/FAIL per milestone.
  scripts/check            every milestone
  scripts/check M2 M3      only those
Everything runs against a throwaway MXC_HOME (build/g55/home) on a free port, with a user's MAX install
(build/g55/max: `pixi install` there; or $MXC_MAX): never the owner's daemon on :11435 or ~/.mxc."""
import hashlib
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
BUILD = ROOT / "build"
G55 = BUILD / "g55"
HOME = G55 / "home"
SMALL = "Qwen/Qwen2.5-0.5B-Instruct"   # the model the checks pull, chat with and benchmark
TINY = "HuggingFaceTB/SmolLM2-135M-Instruct"   # pulled and deleted (M2)
BIG = "Qwen/Qwen2.5-1.5B-Instruct"     # its pull is cancelled midway (M2)
STEPS = ROOT / "docs/goals/55"         # the console's GTK step files (M3, M4)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g50 = load("g50check", ROOT / "docs/goals/50-check.py")
run, mojo_build, free_port, wait_port, http = g50.run, g50.mojo_build, g50.free_port, g50.wait_port, g50.http


def user_max():
    """A user's MAX: $MXC_MAX, else the install under build/g55/max (has `max serve`)."""
    if os.environ.get("MXC_MAX"):
        return os.environ["MXC_MAX"]
    return str(G55 / "max/.pixi/envs/default/bin/max")


def hub(path):
    with urllib.request.urlopen("https://huggingface.co" + path, timeout=60) as r:
        return json.loads(r.read())


class Daemon:
    """consoled on a throwaway home and a free port."""

    def __init__(self, home=HOME, extra=None):
        self.home, self.extra = Path(home), extra or {}
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        self.admin = "g55-admin-" + os.urandom(4).hex()
        self.p = None

    def start(self):
        self.home.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, MXC_HOME=str(self.home), MXC_PORT=str(self.port), MXC_ADMIN_KEY=self.admin,
                   MXC_MAX=user_max())
        env.update(self.extra)  # (extra may replace MXC_MAX: a fake max for the failure paths)
        self.log = open(G55 / "consoled.log", "a")
        self.p = subprocess.Popen([str(BUILD / "consoled")], cwd=ROOT, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        return wait_port(self.port, 30)

    def stop(self):
        if self.p and self.p.poll() is None:
            self.p.send_signal(signal.SIGTERM)
            try:
                self.p.wait(30)
            except subprocess.TimeoutExpired:
                self.p.kill()
        self.p = None

    def call(self, method, path, body=None, admin=True):
        return http(method, self.url + path, body, {"X-Mst-Admin": self.admin} if admin else {}, timeout=120)

    def __enter__(self):
        if not self.start():
            raise RuntimeError("consoled didn't listen: " + (G55 / "consoled.log").read_text()[-400:])
        return self

    def __exit__(self, *a):
        self.stop()


def body(r):
    """http() → (status, parsed JSON or text)."""
    status, text = r[0], r[1]
    try:
        return status, json.loads(text)
    except Exception:  # noqa: BLE001
        return status, text


def build_all():
    for src, exe in (("examples/consoled/main.mojo", BUILD / "consoled"),):
        err = mojo_build(src, exe)
        if err:
            return err
    r = run(["scripts/build.sh", "console", "linux"])
    return None if r.returncode == 0 else "console build: " + (r.stdout + r.stderr)[-400:]


def model_named(d, repo):
    s, models = body(d.call("GET", "/admin/models"))
    for m in (models if isinstance(models, list) else models.get("models", []) if isinstance(models, dict) else []):
        if m.get("repo_id") == repo:
            return m
    return None


def pull(d, ref, timeout=1800, cancel_after_bytes=0):
    s, j = body(d.call("POST", "/admin/pulls", {"ref": ref}))
    if s not in (200, 201, 202) or not isinstance(j, dict) or "id" not in j:
        raise RuntimeError(f"POST /admin/pulls {ref}: {s} {str(j)[:200]}")
    pid = j["id"]
    t0 = time.time()
    while time.time() - t0 < timeout:
        s, j = body(d.call("GET", f"/admin/pulls/{pid}"))
        if cancel_after_bytes and isinstance(j, dict) and (j.get("done_bytes") or 0) >= cancel_after_bytes:
            d.call("POST", f"/admin/pulls/{pid}/cancel")
            cancel_after_bytes = 0
        if isinstance(j, dict) and j.get("status") in ("done", "failed", "cancelled", "unsupported"):
            return j
        time.sleep(1)
    raise RuntimeError(f"pull {ref} didn't finish in {timeout} s")


def ensure_small(d):
    """The SMALL model pulled into HOME (pulled once; later milestones reuse it)."""
    m = model_named(d, SMALL)
    if m:
        return m
    j = pull(d, SMALL)
    if j.get("status") != "done":
        raise RuntimeError(f"pull {SMALL}: {j.get('status')} {j.get('message')}")
    return model_named(d, SMALL)


def new_key(d):
    s, j = body(d.call("POST", "/admin/keys", {"app": "g55-" + os.urandom(3).hex()}))
    if s not in (200, 201) or not isinstance(j, dict):
        raise RuntimeError(f"POST /admin/keys: {s} {str(j)[:200]}")
    return j.get("key") or j.get("api_key") or j.get("token")


def sdk_stream(d, name, key, prompt="Write two sentences about the sea.", max_tokens=128):
    """The OpenAI SDK's own measurement: (text, ttft_s, decode_tok_s, chunks)."""
    from openai import OpenAI
    c = OpenAI(base_url=d.url + "/v1", api_key=key, timeout=300)
    t0 = time.time()
    first = last = None
    n = 0
    text = ""
    for ch in c.chat.completions.create(model=name, messages=[{"role": "user", "content": prompt}], max_tokens=max_tokens,
                                        stream=True):
        piece = ch.choices[0].delta.content if ch.choices else None
        if piece:
            now = time.time()
            first = first or now
            last = now
            n += 1
            text += piece
    if first is None:
        raise RuntimeError("no tokens streamed")
    return text, first - t0, (n - 1) / (last - first) if last > first else 0.0, n


SENTENCES = ["The quick brown fox jumps over the lazy dog while the farmer watches from the porch.",
             "A good benchmark repeats the same small task many times so that noise averages out and the signal remains.",
             "The ferry crosses the bay in forty minutes when the wind is calm and in an hour when it is not.",
             "Every spring the town repaints the bridge a slightly different shade of green, and nobody agrees which was best."]


def bench_prompt(nonce):
    """The benchmark's workload (bench.py build_prompt, ~512 tokens): the SDK's reference measures the same task."""
    task = "Continue this passage in the same style, for as long as you can."
    head = nonce + "\n"
    budget = 512 * 4 - len(task) - 1 - len(head)
    parts, size, i = [], 0, 0
    while size + len(SENTENCES[i % 4]) + 1 <= budget:
        parts.append(SENTENCES[i % 4])
        size += len(SENTENCES[i % 4]) + 1
        i += 1
    return head + " ".join(parts) + " " + task


def console(steps_file, d, shot, extra=None, timeout=900):
    """The console on GTK against `d`, driven by a step file; (ok, stdout)."""
    steps = ";".join(l.strip() for l in steps_file.read_text().splitlines() if l.strip() and not l.startswith("#"))
    env = dict(os.environ, MXC_URL=d.url, MXC_ADMIN_KEY=d.admin, MOJOUI_TEST=steps, MOJOUI_SHOT=str(shot), **(extra or {}))
    r = subprocess.run([str(BUILD / "console/linux/console")], cwd=ROOT, env=env, capture_output=True, text=True,
                       timeout=timeout)
    return r.returncode == 0, r.stdout + r.stderr


# ---- milestones -------------------------------------------------------------------------------------------------------

def m0():
    err = build_all()
    if err:
        return False, err
    if not Path(user_max()).exists():
        return False, f"no MAX at {user_max()} (pixi install in build/g55/max, or MXC_MAX)"
    with Daemon(G55 / "home-m0") as d:
        s, _ = d.call("GET", "/health", admin=False)[:2]
        return s == 200, f"consoled on :{d.port} (throwaway home) answers /health {s}; MAX at {user_max()}"


def m1():
    r = run(["scripts/mojo_flare.sh", "build", "tests/test_hf.mojo", "-o", str(BUILD / "test_hf")])
    if r.returncode != 0:
        return False, "test_hf build: " + (r.stdout + r.stderr)[-400:]
    t = run([str(BUILD / "test_hf")], timeout=300)
    if t.returncode != 0 or "hf: ok" not in t.stdout:
        return False, "test_hf: " + (t.stdout + t.stderr)[-400:]
    if build_all():
        return False, "build failed"
    with Daemon(G55 / "home-m1") as d:
        s, j = body(d.call("GET", "/admin/search?q=" + urllib.request.quote("SmolLM2-135M-Instruct")))
        text = json.dumps(j)
        found = TINY in text
        sized = bool(re.search(r'"size_gb":\s*[0-9.]*[1-9]', text))
        fits = '"fit"' in text
        return s == 200 and found and sized and fits, \
            f"test_hf ok; /admin/search for a model not in the curated list: {s}, {TINY} {'found' if found else 'missing'}, " \
            f"size {'shown' if sized else 'missing'}, fit {'shown' if fits else 'missing'}"


def m2():
    if build_all():
        return False, "build failed"
    problems = []
    # the safety rules under downloads and deletes, offline (review round 1: redirect tokens, remove_tree, Hub names)
    r = run(["scripts/mojo_flare.sh", "build", "tests/test_safety.mojo", "-o", str(BUILD / "test_safety")])
    t = run([str(BUILD / "test_safety")], timeout=120) if r.returncode == 0 else r
    if t.returncode != 0 or "safety: ok" not in t.stdout:
        problems.append("test_safety: " + (t.stdout + t.stderr)[-300:])
    # what consoled may delete (review round 2: owned_folder, remove_parts)
    r = run(["scripts/mojo_flare.sh", "build", "-I", "examples/consoled", "tests/test_consoled_paths.mojo", "-o", str(BUILD / "test_consoled_paths")])
    t = run([str(BUILD / "test_consoled_paths")], timeout=120) if r.returncode == 0 else r
    if t.returncode != 0 or "consoled paths: ok" not in t.stdout:
        problems.append("test_consoled_paths: " + (t.stdout + t.stderr)[-300:])
    # a dropped connection is picked up where it stopped (tests/resume_server.py drops it mid-file)
    r = run(["scripts/mojo_flare.sh", "build", "tests/test_resume.mojo", "-o", str(BUILD / "test_resume")])
    if r.returncode != 0:
        problems.append("test_resume build: " + (r.stdout + r.stderr)[-300:])
    else:
        srv = subprocess.Popen([sys.executable, "tests/resume_server.py"], cwd=ROOT, stdout=subprocess.PIPE, text=True)
        try:
            port = srv.stdout.readline().split()[1]
            t = run([str(BUILD / "test_resume")], env={"RESUME_TEST_URL": f"http://127.0.0.1:{port}/"}, timeout=120)
            if t.returncode != 0 or "resume: ok" not in t.stdout:
                problems.append("test_resume: " + (t.stdout + t.stderr)[-300:])
        finally:
            srv.kill()
            srv.wait()
    with Daemon() as d:
        m = ensure_small(d)
        if not m:
            return False, f"{SMALL} isn't registered after its pull"
        folder = Path(m.get("weights_path") or HOME / "models" / SMALL.replace("/", "--"))  # (/admin/models doesn't list it: D-5502's folder)
        info = hub(f"/api/models/{SMALL}?blobs=true")
        checked = 0
        for f in info.get("siblings", []):
            lfs = f.get("lfs")
            if not lfs:
                continue
            p = folder / f["rfilename"]
            if not p.exists():
                problems.append(f"{f['rfilename']} missing in {folder}")
                continue
            h = hashlib.sha256(p.read_bytes()).hexdigest()
            if h != lfs.get("sha256", lfs.get("oid")):
                problems.append(f"{f['rfilename']}: sha256 differs from the Hub's")
            checked += 1
        if checked == 0:
            problems.append("no LFS file checked")
        # a cancelled pull leaves nothing
        j = pull(d, BIG, timeout=900, cancel_after_bytes=50_000_000)
        if j.get("status") != "cancelled":
            problems.append(f"cancel: the pull ended {j.get('status')}")
        if model_named(d, BIG):
            problems.append("cancel: the cancelled model is registered")
        if (HOME / "models" / BIG.replace("/", "--")).exists():
            problems.append("cancel: its files stayed")
        # pull, then delete
        j = pull(d, TINY, timeout=900)
        tm = model_named(d, TINY)
        if j.get("status") != "done" or not tm:
            problems.append(f"{TINY}: pull {j.get('status')}")
        else:
            s, _ = d.call("DELETE", f"/admin/models/{tm['name']}")[:2]
            if s not in (200, 204) or model_named(d, TINY) or (HOME / "models" / TINY.replace("/", "--")).exists():
                problems.append(f"DELETE /admin/models/{tm['name']}: {s}, row or files stayed")
    # a load whose server never comes up: 503 with why, nothing left waiting; a daemon stopping answers a waiting load
    # 503 too (D-5539). Fake `max` programs, no GPU: one that exits at once, one that never answers /health. After the
    # pull above: on a clean tree no model is registered before it (review round 2)
    problems += parked_loads()
    return not problems, "; ".join(problems) or f"{SMALL} pulled ({checked} files match the Hub's sha256), a cancel left nothing, a delete removed {TINY}"


def parked_loads():
    """POST /admin/models/{name}/load's failure paths with fake max programs (the 200 path is M3's, on real MAX)."""
    problems = []
    dies, hangs = G55 / "fake-max-dies", G55 / "fake-max-hangs"
    dies.write_text("#!/bin/sh\necho 'fake max: no GPU here' >&2\nexit 3\n")
    hangs.write_text("#!/bin/sh\nexec sleep 120\n")
    for f in (dies, hangs):
        f.chmod(0o755)

    def load(d, name, timeout=120):
        return body(http("POST", d.url + "/admin/models/" + urllib.request.quote(name) + "/load", None,
                         {"X-Mst-Admin": d.admin}, timeout=timeout))

    with Daemon(HOME, extra={"MXC_MAX": str(dies)}) as d:
        _, ms = body(d.call("GET", "/admin/models"))
        names = [x.get("name") for x in ms] if isinstance(ms, list) else []
        if not names:
            return ["parked loads: no registered model in " + str(HOME)]
        t0 = time.time()
        s1, j1 = load(d, names[0])
        took = time.time() - t0
        why = str(j1)
        if not (s1 == 503 and "failed to start" in why and "exited (3)" in why and took < 30):
            problems.append(f"a load whose max exits: {s1} {why[:160]} after {took:.0f} s")
        # five more, one at a time, past the cap of MAX_WAITING (4): a load left waiting would turn one into "already waiting"
        for k in range(5):
            s2, j2 = load(d, names[0])
            if not (s2 == 503 and "failed to start" in str(j2)):
                problems.append(f"load {k + 2} after a failed start: {s2} {str(j2)[:120]} (something stayed waiting)")
                break
    d = Daemon(HOME, extra={"MXC_MAX": str(hangs)})
    with d:
        got = {}

        def call():
            got["r"] = load(d, names[0], timeout=60)
        th = threading.Thread(target=call)
        th.start()
        time.sleep(3)  # (parked: its server never answers /health)
        d.stop()
        th.join(60)
    s3, j3 = got.get("r", (0, None))
    if not (s3 == 503 and "stopping" in str(j3)):
        problems.append(f"a load waiting while consoled stops: {s3} {str(j3)[:160]} (want 503, stopping)")
    return problems


def m3():
    if build_all():
        return False, "build failed"
    with Daemon() as d:
        m = ensure_small(d)
        # a cold model's load answers once its server runs, as gateway.py's admin_load did: the console's Add flow reads
        # a loaded model as ready (D-5539; a fresh install failed at "the server is starting, not ready")
        t0 = time.time()
        s, j = body(http("POST", d.url + "/admin/models/" + urllib.request.quote(m["name"]) + "/load", None, {"X-Mst-Admin": d.admin}, timeout=700))
        took = time.time() - t0
        _, ms = body(d.call("GET", "/admin/models"))
        state = next((x.get("state") for x in ms if x.get("name") == m["name"]), None) if isinstance(ms, list) else None
        if s != 200 or not isinstance(j, dict) or j.get("state") != "ready" or state != "ready":
            return False, f"a cold load answered {s} {str(j)[:160]} after {took:.0f} s, then /admin/models said {state} (want ready, ready)"
        s, j = body(d.call("POST", "/admin/try/chat", {"model": m["name"], "max_tokens": 24,
                                                       "messages": [{"role": "user", "content": "Say hello in five words."}]}))
        reply = (j.get("choices") or [{}])[0].get("message", {}).get("content", "") if isinstance(j, dict) else ""
        if s != 200 or len(reply.split()) < 2:
            return False, f"POST /admin/try/chat: {s} {str(j)[:200]}"
        key = new_key(d)
        text, ttft, tps, n = sdk_stream(d, m["name"], key)
        if n < 5:
            return False, f"the SDK streamed {n} pieces"
        steps = STEPS / "m3.steps"
        if not steps.exists():
            return False, "no docs/goals/55/m3.steps (search, pull, Ready, chat)"
        ok, out = console(steps, d, G55 / "console-chat.png")
        said = [x.strip("“”\"") for x in re.findall(r"SAYS: tl-detail@-1 = (.+)", out)]
        good = ok and said and len(said[-1].split()) >= 2
        return bool(good), f"a cold load answered ready ({took:.0f} s); try/chat: {reply[:60]!r}; SDK streamed {n} pieces; console: " + \
            (f"reply {said[-1][:60]!r}" if said else "no SAYS: tl-detail@-1 line: " + out[-300:])


def wait_quiet_gpu(limit_s=1800, under=15, hold_s=15):
    """Until GPU 0 has stayed under `under` % for `hold_s` s (other projects share it): measurements start on a quiet GPU."""
    quiet, t0 = 0, time.time()
    while time.time() - t0 < limit_s:
        u = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits", "-i", "0"],
                           capture_output=True, text=True).stdout.strip()
        quiet = quiet + 1 if u.isdigit() and int(u) < under else 0
        if quiet >= hold_s:
            return True
        time.sleep(1)
    return False


def m4():
    if build_all():
        return False, "build failed"
    with Daemon() as d:
        m = ensure_small(d)
        key = new_key(d)
        _, ttft, tps, _ = sdk_stream(d, m["name"], key, prompt=bench_prompt("SDK warm-up"))  # (warm: loaded before both)
        if not wait_quiet_gpu():
            return False, "GPU 0 never stayed quiet for 15 s in 30 min (another job on it): not measured"
        refs = [sdk_stream(d, m["name"], key, prompt=bench_prompt(f"SDK reference {i}")) for i in range(5)]
        s, j = body(d.call("POST", "/admin/bench", {"models": [m["name"]], "runs": 5}))
        if s not in (200, 201, 202):
            return False, f"POST /admin/bench: {s} {str(j)[:200]}"
        run_id = j.get("id") if isinstance(j, dict) else None
        t0 = time.time()
        row = None
        while time.time() - t0 < 900:
            s, j = body(d.call("GET", "/admin/bench"))
            latest = j.get("latest") if isinstance(j, dict) else None
            if isinstance(j, dict) and not j.get("running") and isinstance(latest, dict) and (run_id is None or latest.get("id") == run_id):
                for r in latest.get("results", []):
                    if r.get("model") == m["name"]:
                        row = r
                break
            time.sleep(2)
        if not row:
            return False, f"no benchmark result for {m['name']}: {str(j)[:300]}"
        refs += [sdk_stream(d, m["name"], key, prompt=bench_prompt(f"SDK reference after {i}")) for i in range(5)]
        # the SDK's medians over five runs before the benchmark and five after it (D-5532): a burst of another job's
        # GPU work can't sit on one instrument's side only
        ttft = sorted(r[1] for r in refs)[len(refs) // 2]
        tps = sorted(r[2] for r in refs)[len(refs) // 2]
        best_sdk = max(r[2] for r in refs)
        bt, btps = float(row.get("ttft_p50_ms") or 0) / 1000, float(row.get("decode_tps") or 0)
        import sqlite3
        db = sqlite3.connect(f"file:{HOME / 'mst.db'}?mode=ro", uri=True)
        best_bench = db.execute("SELECT max(decode_tps) FROM bench_samples WHERE run_id = ? AND error IS NULL",
                                (latest.get("id"),)).fetchone()[0] or 0
        db.close()
        close = btps > 0 and abs(btps - tps) / tps <= 0.25  # (the contract's medians: D-5516's best-run comparison withdrawn, D-5528)
        steps = STEPS / "m4.steps"
        if not steps.exists():
            return False, "no docs/goals/55/m4.steps (the Benchmark tab)"
        ok, out = console(steps, d, G55 / "console-bench.png")
        bars = ok and bool(re.search(r"SAYS: bench-bars = .*\d", out))
        return close and bars, f"bench p50: ttft {bt * 1000:.0f} ms, {btps:.1f} tok/s; SDK p50: ttft {ttft * 1000:.0f} ms, {tps:.1f} tok/s; " \
            f"medians {'within' if close else 'outside'} 25 % (best runs: bench {best_bench:.1f}, SDK {best_sdk:.1f}); console bars {'drawn' if bars else 'missing: ' + out[-200:]}"


def m5():
    if build_all():
        return False, "build failed"
    problems = []
    # the console starts its own consoled and stops it on quit
    port = free_port()
    steps = "wait:8000"
    env = dict(os.environ, MXC_PORT=str(port), MXC_HOME=str(G55 / "home-m5"), MXC_MAX=user_max(), MOJOUI_TEST=steps)
    env.pop("MXC_ADMIN_KEY", None)
    env.pop("MXC_URL", None)  # (its own address: MXC_URL would point it elsewhere, where it starts nothing)
    p = subprocess.Popen([str(BUILD / "console/linux/console")], cwd=ROOT, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True)
    up = wait_port(port, 20)
    out = p.communicate(timeout=120)[0]
    t0 = time.time()
    closed = False
    while time.time() - t0 < 15:
        try:
            http("GET", f"http://127.0.0.1:{port}/health", timeout=1)
        except Exception:  # noqa: BLE001
            closed = True
            break
        time.sleep(0.5)
    if not up:
        problems.append("the console didn't start a consoled on its port: " + out[-200:])
    if not closed:
        problems.append("its consoled still answers 15 s after the console quit")
    # a console killed outright (SIGKILL: no App.closing) still takes its consoled with it (review round 1: an orphaned
    # consoled kept a model on the GPU after M5's bare run)
    port = free_port()
    env.update(MXC_PORT=str(port), MOJOUI_TEST="pause:60000")
    p = subprocess.Popen([str(BUILD / "console/linux/console")], cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not wait_port(port, 20):
        problems.append("the console didn't start a consoled (kill test)")
    p.kill()
    p.wait()
    t0 = time.time()
    gone = False
    while time.time() - t0 < 15:
        try:
            http("GET", f"http://127.0.0.1:{port}/health", timeout=1)
        except Exception:  # noqa: BLE001
            gone = True
            break
        time.sleep(0.5)
    if not gone:
        problems.append("its consoled outlived a killed console by 15 s")
    # the download, run bare
    tar = ROOT / "dist/omxconsole-linux-x86_64.tar.gz"
    # (the released download when dist/ holds it: then the run tests what people get; else a fresh package)
    rel = subprocess.run(["gh", "release", "view", "gallery-apps", "-R", "abhisheksreesaila/omxcode", "--json", "assets",
                          "-q", '.assets[] | select(.name == "omxconsole-linux-x86_64.tar.gz") | .digest'], capture_output=True, text=True).stdout.strip()
    shipped = tar.exists() and rel == "sha256:" + hashlib.sha256(tar.read_bytes()).hexdigest()
    if not shipped:
        r = run(["scripts/package.sh", "omxconsole", "linux"])
        if r.returncode != 0 or not tar.exists():
            problems.append("package: " + (r.stdout + r.stderr)[-300:])
            return False, "; ".join(problems)
    import headless
    headless.ensure()
    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(tar) as t:
            t.extractall(tmp, filter="tar")
        here = Path(tmp) / "omxconsole-linux-x86_64"
        fresh = Path(tmp) / "home"
        fresh.mkdir()
        port = free_port()
        benv = {"HOME": str(fresh), "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "XDG_RUNTIME_DIR": tmp,
                "MXC_MAX": user_max(), "MXC_PORT": str(port), "MXC_HOME": str(HOME)}
        benv.update({k: os.environ[k] for k in ("DISPLAY", "GDK_BACKEND", "GSK_RENDERER", "GDK_DISABLE", "GDK_SCALE",
                                                "XKB_CONFIG_ROOT") if k in os.environ})
        log = open(G55 / "bare-omxconsole.log", "w")
        p = subprocess.Popen([str(here / "omxconsole")], cwd=here, env=benv, stdout=log, stderr=subprocess.STDOUT)
        try:
            if not wait_port(port, 30):
                problems.append("bare: no consoled on its port: " + (G55 / "bare-omxconsole.log").read_text()[-300:])
            else:
                shot = G55 / "bare-omxconsole.png"
                time.sleep(4)
                subprocess.run(["import", "-display", benv["DISPLAY"], "-window", "root", str(shot)], capture_output=True)
                n = int(subprocess.run(["magick", str(shot), "-format", "%k", "info:"], capture_output=True, text=True).stdout or 0)
                if n <= 16:
                    problems.append(f"bare: the window looks empty ({n} colours)")
                # a chat through the bundled consoled (its admin key is the store's own: read it the way the console does)
                admin = (HOME / "admin_key").read_text().strip() if (HOME / "admin_key").exists() else "1"
                d = Daemon(HOME)
                d.port, d.url, d.admin = port, f"http://127.0.0.1:{port}", admin
                m = model_named(d, SMALL)
                if not m:
                    problems.append(f"bare: {SMALL} not listed (run M2 first)")
                else:
                    text, *_ = sdk_stream(d, m["name"], new_key(d), max_tokens=32)
                    if len(text.split()) < 2:
                        problems.append("bare: the chat said nothing")
        finally:
            p.terminate()
            try:
                p.wait(20)
            except subprocess.TimeoutExpired:
                p.kill()
            log.close()
    headless.stop()
    return not problems, "; ".join(problems) or ("the console starts and stops its own consoled (a killed console's too); the " + ("released" if shipped else "freshly packaged") +
                                                 " download runs bare (fresh HOME, no Mojo or pixi): window drawn, consoled up, a chat answered")


def m6():
    runs = sorted((BUILD / "mac-ci").glob("[0-9]*"), key=lambda p: p.stat().st_mtime, reverse=True)
    for r in runs:
        outs = [r / f"report-{o}/omxconsole-stdout.txt" for o in ("macos-15", "macos-26")]
        if not all(o.exists() for o in outs):
            continue
        problems = []
        for o in outs:
            t = o.read_text()
            if not t.rstrip().endswith("exit 0"):
                problems.append(f"{o.parent.name}: {t.strip().splitlines()[-1] if t.strip() else 'no output'}")
            if not re.search(r"MAX (isn't|is not) installed|MAX not found", t):
                problems.append(f"{o.parent.name}: no MAX-not-installed message")
            if not re.search(r"CONSOLED UP", t):
                problems.append(f"{o.parent.name}: consoled didn't start")
        if list(r.rglob("*.ips")):
            problems.append("crash logs")
        return not problems, "; ".join(problems) or f"macOS 15 and 26 (run {r.name}): opens, starts consoled, says MAX isn't installed"
    return False, "no mac-ci run with omxconsole on both runners (scripts/mac-ci omxconsole)"


def m7():
    page = (ROOT / "docs/gallery/index.html").read_text()
    card = re.search(r'<article class="card[^"]*" id="omxconsole">(.*?)</article>', page, re.S)
    if not card:
        return False, "no omxconsole card in the gallery"
    links = re.findall(r'class="dl" href="([^"]+)"', card.group(1))
    r = run([sys.executable, "docs/goals/53-check.py"], timeout=900)
    return bool(links) and r.returncode == 0, f"omxconsole card with {len(links)} downloads; 53-check " + \
        ("passes" if r.returncode == 0 else "fails: " + r.stdout[-300:])


MILESTONES = [("M0", m0), ("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4), ("M5", m5), ("M6", m6), ("M7", m7)]


def main():
    G55.mkdir(parents=True, exist_ok=True)
    import headless
    headless.ensure()
    only = sys.argv[1:]
    results = []
    for name, fn in MILESTONES:
        if only and name not in only:
            continue
        t0 = time.time()
        try:
            ok, msg = fn()
        except Exception as e:  # noqa: BLE001
            import traceback
            traceback.print_exc()
            ok, msg = False, f"crashed: {e!r}"
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {msg}  ({time.time() - t0:.0f} s)", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
