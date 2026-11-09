"""Goal 64: the two things omxconsole still can't do (GOAL.md) — porting a model MAX can't run, and
reaching the endpoint from another machine over HTTPS. Prints PASS, FAIL or BLOCKED per milestone.
  scripts/check            every milestone
  scripts/check M2 M4      only those
Everything runs against a throwaway MXC_HOME under build/g64 on free ports, with stand-ins for the three
external programs the pipeline drives (claude, the skill's gates, max): never the owner's daemon on :11435,
never ~/.mxc, never a real API key, never a real multi-hour port."""
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
BUILD = ROOT / "build"
G64 = BUILD / "g64"
FIX = ROOT / "docs/goals/64"          # the stand-ins and step files


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g50 = load("g50check", ROOT / "docs/goals/50-check.py")
g55 = load("g55check", ROOT / "docs/goals/55-check.py")
run, mojo_build, free_port, wait_port, http = g50.run, g50.mojo_build, g50.free_port, g50.wait_port, g50.http
body = g55.body
new_key = g55.new_key

BLOCKED = "BLOCKED"


class Daemon:
    """consoled on a throwaway home and a free port, with the pipeline's stand-ins wired in."""

    def __init__(self, home, extra=None):
        self.home, self.extra = Path(home), extra or {}
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        self.admin = "g64-admin-" + os.urandom(4).hex()
        self.p = None
        self.log_path = G64 / (self.home.name + ".log")

    def env(self):
        e = dict(os.environ, MXC_HOME=str(self.home), MXC_PORT=str(self.port), MXC_ADMIN_KEY=self.admin)
        e.update(self.extra)
        return e

    def start(self):
        self.home.mkdir(parents=True, exist_ok=True)
        self.log = open(self.log_path, "a")
        self.p = subprocess.Popen([str(BUILD / "consoled")], cwd=ROOT, env=self.env(), stdout=self.log,
                                  stderr=subprocess.STDOUT)
        return wait_port(self.port, 30)

    def stop(self):
        if self.p and self.p.poll() is None:
            self.p.send_signal(signal.SIGTERM)
            try:
                self.p.wait(30)
            except subprocess.TimeoutExpired:
                self.p.kill()
        self.p = None

    def call(self, method, path, body=None, admin=True, timeout=120):
        return http(method, self.url + path, body, {"X-Mst-Admin": self.admin} if admin else {}, timeout=timeout)

    def log_text(self):
        return self.log_path.read_text(errors="replace") if self.log_path.exists() else ""

    def __enter__(self):
        if not self.start():
            raise RuntimeError("consoled didn't listen: " + self.log_text()[-600:])
        return self

    def __exit__(self, *a):
        self.stop()


def build_all():
    err = mojo_build("examples/consoled/main.mojo", BUILD / "consoled")
    if err:
        return err
    r = run(["scripts/build.sh", "console", "linux"])
    return None if r.returncode == 0 else "console build: " + (r.stdout + r.stderr)[-400:]



# ---- the fake-port harness (D-6402: the Python version's own stand-ins, which is what makes M2 provable) --------

def py():
    return sys.executable


def plain_py():
    """A Python outside $HOME: inside the port's sandbox $HOME is an empty tmpfs, so a stand-in run from the pixi
    environment (which lives under $HOME) would not be there — the real `claude` is bound back by tool_roots."""
    for cand in ("/usr/bin/python3", "/bin/python3"):
        if Path(cand).exists():
            return cand
    return sys.executable


def serve_fixture(script, *args):
    """One of docs/goals/64's stand-in servers on a free port; (port, process)."""
    port = free_port()
    p = subprocess.Popen([py(), "-I", str(FIX / script), str(port), *[str(a) for a in args]],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait_port(port, 20)
    return port, p


def wrapper(path, target, env=None):
    """A tiny shell wrapper, so the daemon finds "claude" or "max" on a path we choose. The stand-in it runs is
    copied next to the wrapper: inside the port's sandbox $HOME is an empty tmpfs (so this checkout is not there),
    and what is bound back read-only is the wrapper's own install prefix — exactly as the real claude is."""
    path.parent.mkdir(parents=True, exist_ok=True)
    beside = path.parent.parent / "fakes" / Path(target).name
    beside.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(target, beside)
    target = beside
    lines = "\n".join(f'export {k}={v}' for k, v in (env or {}).items())
    path.write_text(f'#!/bin/sh\n{lines}\nexec "{plain_py()}" -I "{target}" "$@"\n')
    path.chmod(0o755)
    return str(path)


def skill_clone(dest):
    """The stand-in skill clone as a git repo (the pipeline updates it with git, and restores gates from it)."""
    dest = Path(dest)
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(FIX / "skill", dest)
    git = ["git", "-c", "user.email=g64@local", "-c", "user.name=g64"]
    subprocess.run(["git", "init", "-q", "."], cwd=dest, check=True)
    subprocess.run(git + ["add", "-A"], cwd=dest, check=True)
    subprocess.run(git + ["commit", "-q", "-m", "stand-in skill"], cwd=dest, check=True)
    return str(dest)


def port_daemon(home, mode="ok", porter="claude-code", extra=None):
    """A daemon whose port pipeline drives the stand-ins: a fake claude, the stand-in skill clone and its gates,
    a fake max and a fake Hub. Nothing real is downloaded, compiled or served."""
    home = Path(home)
    if home.exists():
        shutil.rmtree(home)
    home.mkdir(parents=True)
    hub_port, hub = serve_fixture("fake_hub.py", FIX / "weird")
    claude = wrapper(G64 / "bin" / f"claude-{mode}", FIX / "fake_claude.py",
                     {"FAKE_CLAUDE_MODE": mode, "FAKE_CLAUDE_PROBE": str(ROOT / "CLAUDE.md"),
                      "FAKE_CLAUDE_RO": f"{home}/skills/modular:{home}/models/acme--weird:{home}/mst.db:/usr"})
    max_exe = wrapper(G64 / "bin" / "max", FIX / "fake_max.py")
    repo = skill_clone(G64 / "skill-src")
    d = Daemon(home, extra=dict({
        "MXC_CLAUDE": claude,
        "MXC_MAX": max_exe,
        "MXC_GATE_CMD": plain_py() + " -I",
        "MXC_SKILLS_REPO": repo,
        "MOJOUI_HF_BASE": f"http://127.0.0.1:{hub_port}",
    }, **(extra or {})))
    d.hub = hub
    return d


def setup_porter(d, kind="claude-code", key="", base=""):
    s, j = body(d.call("POST", "/admin/porter", {"kind": kind, "key": key, "base_url": base}))
    if s != 200:
        raise RuntimeError(f"POST /admin/porter: {s} {str(j)[:200]}")
    return j


def start_port(d, ref="acme/weird", **kw):
    s, j = body(d.call("POST", "/admin/ports", dict({"ref": ref}, **kw)))
    return s, j


def wait_port_job(d, pid, timeout=300, until=("done", "failed", "cancelled")):
    t0 = time.time()
    last = {}
    while time.time() - t0 < timeout:
        s, j = body(d.call("GET", f"/admin/ports/{pid}"))
        if isinstance(j, dict):
            last = j
            if j.get("status") in until:
                return j
        time.sleep(0.5)
    raise RuntimeError(f"port {pid} didn't finish in {timeout} s (status {last.get('status')}, stage {last.get('stage')})")


def rows(job):
    return [(s["name"], s["attempt"], s["status"]) for s in job.get("stages", [])]


def port_log(d, pid):
    p = Path(d.home) / "ports" / str(pid) / "port.log"
    return p.read_text(errors="replace") if p.exists() else ""


# ---- milestones -------------------------------------------------------------------------------------------------------

def m0():
    """The porting assistant setting: Claude Code on this machine, or a key for a frontier model, stored 0600,
    never logged, never shown in full, never in a URL, removable; and a bad key fails in seconds."""
    err = build_all()
    if err:
        return False, err
    problems = []
    r = run(["scripts/mojo_flare.sh", "build", "-I", "examples/consoled", "tests/test_porter.mojo", "-o", str(BUILD / "test_porter")])
    t = run([str(BUILD / "test_porter")], timeout=120) if r.returncode == 0 else r
    if t.returncode != 0 or "porter: ok" not in t.stdout:
        problems.append("test_porter: " + (t.stdout + t.stderr)[-300:])
    good = "sk-g64-" + os.urandom(8).hex()
    gw_port, gw = serve_fixture("fake_porter.py", good)
    home = G64 / "home-m0"
    try:
        with Daemon(home) as d:
            s, j = body(d.call("GET", "/admin/porter"))
            if not (s == 200 and j.get("configured") is False and j.get("beta") is True and "detected" in j):
                problems.append(f"GET /admin/porter before anything: {s} {str(j)[:200]}")
            base = f"http://127.0.0.1:{gw_port}/v1"
            # a bad key fails in seconds, not minutes into a port
            t0 = time.time()
            s, j = body(d.call("POST", "/admin/porter", {"kind": "openai-compatible", "base_url": base, "key": "sk-wrong-0123456789"}))
            took = time.time() - t0
            if not (s == 400 and isinstance(j, dict) and "refused" in json.dumps(j) and took < 20):
                problems.append(f"a bad key: {s} {str(j)[:200]} after {took:.0f} s")
            if body(d.call("GET", "/admin/porter"))[1].get("configured") is not False:
                problems.append("a refused key must not be stored")
            # the owner's own small model is never offered as the porter (frontier models only)
            s, j = body(d.call("POST", "/admin/porter", {"kind": "local-model", "key": good}))
            if s != 400:
                problems.append(f"a local model must not be accepted as the porter: {s} {str(j)[:160]}")
            # the key must not travel in the URL
            s, j = body(d.call("POST", "/admin/porter", {"kind": "openai-compatible", "base_url": base + "?key=" + good, "key": good}))
            if s != 400 or "URL" not in json.dumps(j):
                problems.append(f"a key in the URL must be refused: {s} {str(j)[:160]}")
            # the good key goes through
            s, j = body(d.call("POST", "/admin/porter", {"kind": "openai-compatible", "base_url": base, "key": good}))
            if not (s == 200 and j.get("configured") and j.get("has_key")):
                problems.append(f"the good key: {s} {str(j)[:200]}")
            if good in json.dumps(j):
                problems.append("the key must never be in a response: " + json.dumps(j)[:200])
            if not (j.get("key_prefix", "").startswith(good[:8]) and good[8:] not in j.get("key_prefix", "")):
                problems.append(f"only the prefix may be shown: {j.get('key_prefix')!r}")
            # stored for omxconsole only, 0600, and nowhere else
            f = Path(d.home) / "porter.json"
            mode = oct(f.stat().st_mode & 0o777)[2:] if f.exists() else "missing"
            if mode != "600":
                problems.append(f"porter.json mode is {mode}, not 600")
            leaks = []
            for other in Path(d.home).rglob("*"):
                if other.is_file() and other != f and good.encode() in other.read_bytes():
                    leaks.append(str(other))
            if d.log_text().find(good) >= 0:
                leaks.append("the daemon log")
            for view in ("/admin/porter", "/admin/info", "/admin/system", "/admin/network", "/admin/gateway"):
                if good in str(body(d.call("GET", view))[1]):
                    leaks.append(view)
            if leaks:
                problems.append("the key leaked into: " + ", ".join(leaks))
            # removable
            s, j = body(d.call("DELETE", "/admin/porter"))
            if not (s == 200 and j.get("removed") and j.get("configured") is False and not f.exists()):
                problems.append(f"DELETE /admin/porter: {s} {str(j)[:160]}")
    finally:
        gw.kill()
    return not problems, "; ".join(problems) or ("the setting takes Claude Code or a frontier key, stores it 0600 "
                                                 "(prefix only in every view, in no log and in no other file), refuses a bad key in seconds, and removes it")


def m1():
    """Guided, not a dead end: clicking "Port it" with nothing set up gets an answer that says what was detected,
    the choice is made and saved without leaving the port screen, and the button becomes "Port it". The daemon
    half is driven here; the screen's own half is the port card in examples/console/add.mojo, whose inline card is
    asserted to be wired to it (its GTK and web run is NOT proven here: see docs/goals/64-report.md)."""
    if build_all():
        return False, "build failed"
    problems = []
    d = port_daemon(G64 / "home-m1")
    try:
        with d:
            # nothing set up: the port is refused with what was detected, not with a shrug
            s, j = start_port(d)
            text = json.dumps(j)
            if not (s == 400 and "porter_not_configured" in text):
                problems.append(f'"Port it" with nothing set up: {s} {text[:200]}')
            if "Claude Code" not in text:
                problems.append(f"the refusal must say what was detected: {text[:200]}")
            if body(d.call("GET", "/admin/ports"))[1].get("ports"):
                problems.append("a refused port must leave no job behind")
            # the workspace is bound read-write into the agent's sandbox, so a name that would leave
            # MXC_HOME/ports is refused at the boundary (security audit round 1)
            setup_porter(d)
            for bad in ("..", "../skills/modular", "a/b", "/etc", ".hidden"):
                s, j = start_port(d, name=bad)
                if s != 400:
                    problems.append(f'a port named {bad!r} must be refused: {s} {str(j)[:120]}')
            if list((Path(d.home) / "ports").glob("*")):
                problems.append("a refused port must make no folder: " + str(list((Path(d.home) / "ports").glob("*"))))
            d.call("DELETE", "/admin/porter")
            # the detected assistant is offered, and saving it takes one call from the same screen
            s, j = body(d.call("GET", "/admin/porter"))
            if not (j.get("detected", {}).get("claude_code") and j["detected"]["path"]):
                problems.append(f"Claude Code on this machine was not detected: {str(j)[:200]}")
            t0 = time.time()
            s, j = body(d.call("POST", "/admin/porter", {"kind": "claude-code"}))
            if not (s == 200 and j.get("kind") == "claude-code" and time.time() - t0 < 20):
                problems.append(f"saving the detected assistant: {s} {str(j)[:200]}")
            # and now the same click starts a port
            s, j = start_port(d)
            if s != 202:
                problems.append(f'"Port it" after saving: {s} {str(j)[:200]}')
            else:
                job = wait_port_job(d, j["id"])
                if job["status"] != "done":
                    problems.append(f"the port after saving: {job['status']} {job.get('message', '')[:200]}")
            # a key that does not work is refused in seconds, before any agent runs
            d.call("DELETE", "/admin/porter")
            gw_port, gw = serve_fixture("fake_porter.py", "sk-good-" + os.urandom(4).hex())
            try:
                t0 = time.time()
                s, j = body(d.call("POST", "/admin/porter", {"kind": "openai-compatible", "key": "sk-bad-0123456789",
                                                             "base_url": f"http://127.0.0.1:{gw_port}/v1"}))
                if not (s == 400 and time.time() - t0 < 20):
                    problems.append(f"a bad key must fail in seconds: {s} after {time.time() - t0:.0f} s")
            finally:
                gw.kill()
    finally:
        d.hub.kill()
    # the screen's side: the inline card, its buttons and its fields are on the port screen, not in Settings
    card = (ROOT / "examples/console/add.mojo").read_text()
    flow = (ROOT / "examples/console/addflow.mojo").read_text()
    for want in ["ADD_PORTER_CLAUDE", "ADD_PORTER_KEY", "ADD_PORTER_SAVE", "Use Claude Code on this machine",
                 "API key for a frontier model", "porter_found"]:
        if want not in card:
            problems.append(f"the port card is missing {want}")
    for want in ['api.post(ADD_GOT_PORTER_SAVE, "/admin/porter"', 'api.get(ADD_GOT_PORTER, "/admin/porter")',
                 'porter_not_configured', 'a.porter_key = ""']:
        if want not in flow:
            problems.append(f"the port flow is missing {want}")
    return not problems, "; ".join(problems) or ("the port is refused with what was detected, the choice is saved from "
                                                 "the port screen in one call and the next click ports, and a bad key fails in seconds (the screen's own "
                                                 "GTK and web run is not proven: budget)")


def m2():
    """The worker, against the fake-port harness: the stages, the streamed log, the retry that carries the error
    back, the stop-on-repeat rule, and a cancel that leaves nothing of ours running."""
    if build_all():
        return False, "build failed"
    problems = []
    # the happy path
    d = port_daemon(G64 / "home-m2")
    try:
        with d:
            setup_porter(d)
            s, j = start_port(d)
            if s != 202 or not isinstance(j, dict) or "id" not in j:
                return False, f"POST /admin/ports: {s} {str(j)[:300]} · log {d.log_text()[-300:]}"
            job = wait_port_job(d, j["id"])
            if job["status"] != "done":
                problems.append(f"the happy path: {job['status']} {job.get('message', '')[:300]}")
            want = ["workspace", "skills", "generate", "build", "parity", "register", "serve"]
            if [s["name"] for s in job["stages"]] != want:
                problems.append(f"stages: {rows(job)}")
            if not all(s["status"] == "done" and s["started"] and s["ended"] for s in job["stages"]):
                problems.append(f"every stage must be done with its times: {rows(job)}")
            if job.get("model") != "weird":
                problems.append(f"the model registered: {job.get('model')!r}")
            models = body(d.call("GET", "/admin/models"))[1]
            registered = [m for m in (models if isinstance(models, list) else []) if m.get("name") == "weird"]
            if not registered:
                problems.append("the port is not in /admin/models")
            log = port_log(d, j["id"])
            for want_line in ["== workspace: looking up acme/weird", "-- workspace done:", "== skills:",
                              "-- patched Modular's skill:", "MAX pinned to 26.7.0.dev2026100905",
                              "== generate (attempt 1):", "-- generate done:",
                              "== build (attempt 1):", "-- build done:", "== parity (attempt 1):", "== register:",
                              "== done: Ported weird"]:
                if want_line not in log:
                    problems.append(f"the log is missing {want_line!r}")
            if "claude> Bash pixi run python scripts/scaffold.py" not in log:
                problems.append("the agent's stream-json is not rendered into the log")
            if "sandboxed with bubblewrap" not in log:
                problems.append("the agent was not confined")
            # the agent saw an empty $HOME and the workspace as its only writable place
            seen = [json.loads(l) for l in (Path(d.home) / "ports/weird/.fake-claude.jsonl").read_text().splitlines()]
            # $HOME is an empty tmpfs with only the toolchain prefixes bound back read-only, as the Python version
            # confined it: nothing of the person's own may be in there, and nothing of this checkout either
            sensitive = [x for x in seen[0]["home_listing"]
                         if x in (".ssh", ".aws", ".gnupg", ".config", ".local", ".claude", ".mxc", "Documents", "Downloads")]
            if sensitive:
                problems.append(f"the agent could see {sensitive} in $HOME")
            if seen[0]["probe_exists"]:
                problems.append(f"the agent could read this checkout ({seen[0]['probe']}) through a bound toolchain root")
            # $HOME and /tmp are private tmpfs (thrown away with the job); nothing *shared* may be writable
            if "/" in seen[0]["writable"]:
                problems.append("the agent could write to the system")
            if seen[0]["ro_writable"]:
                problems.append(f"the agent could write to something shared: {seen[0]['ro_writable']}")
            if [x for x in seen[0]["env"] if "TOKEN" in x or "SECRET" in x or "_KEY" in x]:
                problems.append(f"a credential reached the agent: {[x for x in seen[0]['env'] if 'TOKEN' in x or 'SECRET' in x or '_KEY' in x]}")
            if not (Path(d.home) / f"ports/{j['id']}/agent-1.jsonl").exists():
                problems.append("the agent's raw transcript was not kept")
    finally:
        d.hub.kill()
    # a build failure is fed back, and the next attempt fixes it
    d = port_daemon(G64 / "home-m2-retry", mode="fail_once")
    try:
        with d:
            setup_porter(d)
            s, j = start_port(d)
            job = wait_port_job(d, j["id"])
            if job["status"] != "done":
                problems.append(f"fail_once: {job['status']} {job.get('message', '')[:200]}")
            if ("build", 1, "failed") not in rows(job) or ("generate", 2, "done") not in rows(job):
                problems.append(f"the failed attempt and the retry must both be rows: {rows(job)}")
            log = port_log(d, j["id"])
            if "attempt 1 failed:" not in log or "Trying again with the error fed back" not in log:
                problems.append("the log doesn't say the error was fed back")
            prompts = [json.loads(l)["prompt"] for l in (Path(d.home) / "ports/weird/.fake-claude.jsonl").read_text().splitlines()]
            if len(prompts) != 2 or "Fix this" not in prompts[1] or "BROKEN" not in prompts[1]:
                problems.append(f"the second prompt must carry the error: {len(prompts)} prompts")
    finally:
        d.hub.kill()
    # the same failure twice stops early, and the best attempt is kept
    d = port_daemon(G64 / "home-m2-repeat", mode="broken")
    try:
        with d:
            setup_porter(d)
            s, j = start_port(d)
            job = wait_port_job(d, j["id"])
            if job["status"] != "failed" or "same failure twice" not in job.get("message", ""):
                problems.append(f"broken: {job['status']} {job.get('message', '')[:200]}")
            if len([r for r in rows(job) if r[0] == "generate"]) != 2:
                problems.append(f"the same failure twice must stop after two attempts: {rows(job)}")
            if not job.get("best_kept"):
                problems.append("the best attempt's package was not kept")
    finally:
        d.hub.kill()
    # cancel stops the agent and its children
    d = port_daemon(G64 / "home-m2-cancel", mode="hang")
    try:
        with d:
            setup_porter(d)
            s, j = start_port(d)
            pids = Path(d.home) / "ports/weird/.fake-claude-pids"
            t0 = time.time()
            while not pids.exists() and time.time() - t0 < 120:
                time.sleep(0.5)
            if not pids.exists():
                problems.append("the agent never started, so cancel could not be proved")
            else:
                # the pids in there are the sandbox's own (bwrap unshares the pid namespace), so what is checked
                # on this machine is that no process of the stand-in agent or its child is left
                def ours():
                    out = subprocess.run(["ps", "-eo", "pid,args"], capture_output=True, text=True).stdout.splitlines()
                    return [l.strip() for l in out
                            if ("fake_claude.py" in l or "sleep 600" in l) and "ps -eo" not in l and "64-check.py" not in l]
                if not ours():
                    problems.append("the stand-in agent was not running before the cancel")
                d.call("POST", f"/admin/ports/{j['id']}/cancel")
                job = wait_port_job(d, j["id"], timeout=120)
                if job["status"] != "cancelled":
                    problems.append(f"cancel: {job['status']} {job.get('message', '')[:160]}")
                time.sleep(2)
                alive = ours()
                if alive:
                    problems.append(f"still running after cancel: {alive}")
                if job.get("procs"):
                    problems.append("the job still records processes")
    finally:
        d.hub.kill()
    return not problems, "; ".join(problems) or ("seven stages in order with their attempts, the log streamed, a build "
                                                 "failure fed back and fixed on the next attempt, the same failure twice stopped early with the best "
                                                 "attempt kept, and a cancel that left nothing running")


def m3():
    """When it fails, hand it over: the workspace, the full log, the gate that failed and the best attempt kept."""
    if build_all():
        return False, "build failed"
    problems = []
    d = port_daemon(G64 / "home-m3", mode="broken")
    try:
        with d:
            setup_porter(d)
            s, j = start_port(d)
            job = wait_port_job(d, j["id"])
            if job["status"] != "failed":
                problems.append(f"the always-failing agent: {job['status']}")
            for field in ("workspace", "port_dir", "log", "failed_stage", "best_kept", "best_path"):
                if field not in job:
                    problems.append(f"the failed job does not carry {field}")
            if not (Path(job.get("workspace", "/nowhere")).is_dir() and Path(job.get("log", "/nowhere")).is_file()):
                problems.append(f"the workspace and log must be real paths: {job.get('workspace')} {job.get('log')}")
            gate = job.get("failed_stage") or {}
            if not (gate.get("name") == "build" and gate.get("attempt") and "BROKEN" in str(gate.get("detail", "")) + job.get("message", "")):
                problems.append(f"the gate that failed must be named with what it said: {gate}")
            if not (job.get("best_kept") and Path(job.get("best_path", "/nowhere") or "/nowhere").is_dir()):
                problems.append(f"the best attempt must be kept: {job.get('best_path')}")
            if not (job.get("log_tail") and "== build" in job["log_tail"] + port_log(d, j["id"])):
                problems.append("the log tail the screen shows is empty")
            if "Full log:" not in job.get("message", ""):
                problems.append(f"the message must point at the log: {job.get('message', '')[:200]}")
    finally:
        d.hub.kill()
    # the screen shows them: the stage rows carry each failure's detail, and the log pane is the job's log
    screen = (ROOT / "examples/console/add.mojo").read_text()
    if "log_tail" not in (ROOT / "examples/console/add.mojo").read_text() + (ROOT / "examples/console/addflow.mojo").read_text():
        problems.append("the port screen does not read the log tail")
    return not problems, "; ".join(problems) or ("a failed port hands over the workspace, the full log, the gate that "
                                                 "failed with what it said, and the best attempt kept")



def m4():
    """The LAN endpoint: a Caddyfile with tls internal and forward_auth, Caddy found not bundled, the key check,
    and a real HTTPS fetch from another process with a key and without one."""
    if build_all():
        return False, "build failed"
    problems = []
    r = run(["scripts/mojo_flare.sh", "build", "-I", "examples/consoled", "tests/test_caddyfile.mojo", "-o", str(BUILD / "test_caddyfile")])
    t = run([str(BUILD / "test_caddyfile")], timeout=120) if r.returncode == 0 else r
    if t.returncode != 0 or "caddyfile: ok" not in t.stdout:
        problems.append("test_caddyfile: " + (t.stdout + t.stderr)[-300:])
    home = G64 / "home-m4"
    if home.exists():
        shutil.rmtree(home)
    # Caddy is found, not bundled: with none on PATH the answer says how to install it
    with Daemon(home, extra={"PATH": "/nonexistent", "EXPOSE_CADDY_CMD": ""}) as d:
        s, j = body(d.call("POST", "/admin/expose", {}))
        if not (s == 500 and "Caddy was not found" in json.dumps(j) and "install" in json.dumps(j).lower()):
            problems.append(f"with no Caddy: {s} {str(j)[:200]}")
        if body(d.call("GET", "/admin/info"))[1].get("lan_endpoint") is not None:
            problems.append("nothing may claim a LAN endpoint while Caddy is not running")
    caddy = shutil.which("caddy")
    if not caddy:
        return (BLOCKED if not problems else False,
                "; ".join(problems) or "Caddy is not installed on this machine, so the HTTPS half could not be run here (the refusal path passes)")
    data = G64 / "caddy-data"
    https = free_port()  # 8443 may belong to something else on this machine (D-6410)
    with Daemon(home, extra={"XDG_DATA_HOME": str(data), "XDG_CONFIG_HOME": str(G64 / "caddy-config"),
                             "MXC_EXPOSE_PORT": str(https)}) as d:
        key = new_key(d)
        s, j = body(d.call("POST", "/admin/expose", {"host": "localhost"}))
        if s != 200 or not j.get("exposed") or not j.get("beta"):
            return False, f"POST /admin/expose: {s} {str(j)[:300]} · {d.log_text()[-300:]}"
        text = (Path(d.home) / "expose/Caddyfile").read_text()
        for want in ["tls internal", "uri /auth/check", "copy_headers X-Mst-App", "respond 400"]:
            if want not in text:
                problems.append(f"the Caddyfile written is missing {want!r}")
        if not wait_port(https, 30):
            problems.append("Caddy is not listening on the HTTPS port: " + (Path(d.home) / "expose/caddy.log").read_text()[-400:])
        else:
            # from another process, as a client on the network would (curl trusts Caddy's own root for this check)
            root = data / "caddy/pki/authorities/local/root.crt"
            for _ in range(60):
                if root.exists():
                    break
                time.sleep(0.5)
            ca = ["--cacert", str(root)] if root.exists() else ["-k"]
            def curl(*args):
                p = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", *ca, *args],
                                   capture_output=True, text=True, timeout=60)
                return p.stdout.strip()
            with_key = curl("-H", f"Authorization: Bearer {key}", f"https://localhost:{https}/v1/models")
            without = curl(f"https://localhost:{https}/v1/models")
            unclean = curl("-H", f"Authorization: Bearer {key}", "--path-as-is", f"https://localhost:{https}/admin/../v1/models")
            admin = curl("-H", f"Authorization: Bearer {key}", f"https://localhost:{https}/admin/models")
            plain = curl(f"http://127.0.0.1:{d.port}/health")
            if with_key != "200":
                problems.append(f"https with a valid key: {with_key}")
            if without != "401":
                problems.append(f"https without a key: {without} (must be 401)")
            if unclean != "400":
                problems.append(f"a path cleaning would change: {unclean} (must be 400)")
            if admin != "404":
                problems.append(f"an admin route over the LAN: {admin} (must not be forwarded)")
            if plain != "200":
                problems.append(f"localhost over plain http: {plain}")
            # /auth/check itself, as Caddy's forward_auth calls it
            s1 = d.call("GET", "/auth/check", None, admin=False)[0]
            if s1 != 401:
                problems.append(f"/auth/check with no key: {s1}")
            r2 = http("GET", d.url + "/auth/check", None, {"Authorization": "Bearer " + key}, timeout=30)
            if r2[0] != 200:
                problems.append(f"/auth/check with a valid key: {r2[0]}")
            # a revoked key is as good as none (GOAL.md M4) — last, so nothing above loses its key
            apps = body(d.call("GET", "/admin/keys"))[1]
            app = (apps[0]["app"] if isinstance(apps, list) and apps else
                   (apps.get("keys") or [{}])[0].get("app") if isinstance(apps, dict) else None)
            if not app:
                problems.append("no app key to revoke")
            else:
                d.call("DELETE", f"/admin/keys/{app}")
                revoked = curl("-H", f"Authorization: Bearer {key}", f"https://localhost:{https}/v1/models")
                if revoked != "401":
                    problems.append(f"https with a revoked key: {revoked} (must be 401)")
        s, j = body(d.call("POST", "/admin/expose/stop"))
        time.sleep(1)
        if s != 200 or j.get("exposed") is not False:
            problems.append(f"POST /admin/expose/stop: {s} {str(j)[:160]}")
        if wait_port(https, 2):
            problems.append("something still listens on the HTTPS port after stop")
        if body(d.call("GET", "/admin/info"))[1].get("lan_endpoint") is not None:
            problems.append("the LAN endpoint is still claimed after stop")
    return not problems, "; ".join(problems) or ("Caddy (tls internal, forward_auth) reached over HTTPS from another "
                                                 "process: 200 with a valid app key, 401 without, admin and unclean paths refused, localhost plain HTTP "
                                                 "untouched, and stop leaves nothing listening")


def m5():
    """Honest labels and no regressions."""
    problems = []
    # beta, with the real hit rate, in the app and on the cover
    app = (ROOT / "examples/console/add.mojo").read_text()
    if "8 ported and served" not in app or "beta" not in app:
        problems.append("the port card does not say beta with the real hit rate")
    sec = (ROOT / "examples/console/security.mojo").read_text()
    if "beta" not in sec:
        problems.append("the network screen does not say beta")
    cover = (ROOT / "docs/omxconsole.html").read_text()
    for want in ("beta", "8 of 14", "porting a model max can't run is back", "caddy"):
        if want not in cover.lower():
            problems.append(f"the cover page does not mention {want}")
    if "aren't in this one yet" in cover or "porting a model MAX can't run, and reaching the endpoint" in cover:
        problems.append("the cover's honest edges still say these two are missing")
    if "8 of 14" not in cover:
        problems.append("the cover does not give the real hit rate")
    # the console's own Mojo tests, and goal 64's
    tests = {"test_consoled_paths": "examples/consoled", "test_console_api": "examples/console",
             "test_console_places": "examples/console", "test_console_labels": "examples/console", "test_port_donor": "examples/consoled",
             "test_port_sandbox": "examples/consoled", "test_ports_pure": "examples/consoled",
             "test_porter": "examples/consoled", "test_caddyfile": "examples/consoled",
             "test_process_cwd": "examples/consoled", "test_port_boundary": "examples/consoled"}
    for name, include in tests.items():
        src = f"tests/{name}.mojo"
        r = run(["scripts/mojo_flare.sh", "build", "-I", include, src, "-o", str(BUILD / name)])
        t = run([str(BUILD / name)], timeout=300) if r.returncode == 0 else r
        if t.returncode != 0:
            problems.append(f"{name}: " + (t.stdout + t.stderr)[-200:])
    # the component matrix is fresh
    r = run([sys.executable, "scripts/components.py"])
    if r.returncode != 0:
        problems.append("scripts/components.py: " + (r.stdout + r.stderr)[-200:])
    diff = run(["git", "diff", "--stat", "--", "docs/components.md"])
    if diff.stdout.strip():
        problems.append("docs/components.md was stale: " + diff.stdout.strip()[-120:])
    # goal 55's own check: its first milestone needs a real MAX install (a user's, several GB), which this
    # machine does not have, so that half is BLOCKED rather than faked
    have_max = Path(g55.user_max()).exists() if hasattr(g55, "user_max") else False
    if have_max:
        r55 = run([sys.executable, "docs/goals/55-check.py", "M0", "M1"], timeout=3600)
        if r55.returncode != 0:
            problems.append("goal 55: " + (r55.stdout + r55.stderr)[-300:])
        tail = "and goal 55's M0 and M1 still pass"
    else:
        tail = ("and goal 55's own check is BLOCKED here: it needs a user's MAX install (build/g55/max or $MXC_MAX), "
                "which this machine does not have")
    if problems:
        return False, "; ".join(problems)
    word = True if have_max else BLOCKED
    return word, ("both features marked beta with the real hit rate in the app and on the cover, ten Mojo tests "
                  "pass, docs/components.md is fresh, " + tail)



MILESTONES = [("M0", m0), ("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4), ("M5", m5)]


def main():
    G64.mkdir(parents=True, exist_ok=True)
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
        results.append(ok is True or ok == BLOCKED)
        word = "PASS" if ok is True else ("BLOCKED" if ok == BLOCKED else "FAIL")
        print(f"{word}  {name}  {msg}  ({time.time() - t0:.0f} s)", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
