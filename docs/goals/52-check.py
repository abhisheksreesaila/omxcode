"""Goal 52: everything on Mojo 1.2, Flare 0.13, and the engine beside Flare. Prints PASS/FAIL per milestone in GOAL.md.
    scripts/check            # every milestone
    scripts/check M1 M5      # only those
M3 reuses build/g52/sweep.json when its stamp is these sources' (scripts/sweep.py), else runs the sweep (about an hour).
M4 runs goal 50's checker; M6 reads the newest Mac run (scripts/mac-ci), which must be built from these sources."""
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
BUILD = ROOT / "build"
G52 = BUILD / "g52"
BASELINE = ROOT / "docs" / "goals" / "52" / "baseline.json"
ENGINE_PIN = "834ef9a"
ENGINE_PATCH = ROOT / "vendor" / "patches" / f"omxcore-{ENGINE_PIN}-mojo12.patch"
FLARE_TAG = "v0.13.1"
FLARE_PATCH = ROOT / "vendor" / "patches" / "flare-0.13-stream-body.patch"
# the libc functions the engine now looks up instead of declaring (its patch's _libc.mojo), M1 and M5
LOOKED_UP = ["read", "write", "mmap", "munmap", "unlink", "strtod", "pthread_create", "pthread_join", "pthread_detach"]
sys.path.insert(0, str(ROOT / "scripts"))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run(cmd, cwd=ROOT, env=None, timeout=3600):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=dict(os.environ, **(env or {})), timeout=timeout)


def mojo_version(where):
    """`mojo --version` of a checkout's own env (its binary, not `pixi run`: inside this checker's pixi run, another
    checkout's pixi would warn about the manifest in the environment)."""
    exe = where / ".pixi" / "envs" / "default" / "bin" / "mojo"
    if not exe.exists():
        return "(no env)"
    r = run([str(exe), "--version"], cwd=where)
    return r.stdout.strip()


def flare_build(src, exe):
    exe.parent.mkdir(parents=True, exist_ok=True)
    b = run(["scripts/mojo_flare.sh", "build", str(src), "-o", str(exe)])
    return None if b.returncode == 0 else f"{src} doesn't build: " + (b.stdout + b.stderr)[-600:]


# M0 ---------------------------------------------------------------------------------------------------------------
def m0():
    problems = []
    here = mojo_version(ROOT)
    if not here.startswith("Mojo 1.2"):
        problems.append(f"this checkout's mojo is {here!r}")
    others = {}
    for other in ("mojo-ui", "mojo-ui-g50"):
        p = ROOT.parent / other
        if p.exists():
            others[other] = mojo_version(p)
            if not others[other].startswith("Mojo 1.1"):
                problems.append(f"../{other} is on {others[other]!r} (only this checkout moves)")
    pixi = ROOT / ".pixi"
    if pixi.is_symlink() or not pixi.is_dir():
        problems.append(".pixi is a symlink, not this checkout's own env")
    if 'mojo = ">=1.2, <1.3"' not in (ROOT / "pixi.toml").read_text():
        problems.append("pixi.toml doesn't pin mojo >=1.2,<1.3")
    return not problems, "; ".join(problems) or f"{here} here; " + ", ".join(f"../{k}: {v}" for k, v in others.items())


# M1 ---------------------------------------------------------------------------------------------------------------
PATCH_FILES = {"kernels_aot/kernels_aot_gpu.mojo", "kernels_aot/pipeline_gpu.mojo", "mojo/omxcore/gpu.mojo", "mojo/omxcore/_libc.mojo",
               "mojo/omxcore/csv.mojo", "mojo/omxcore/fan.mojo", "mojo/omxcore/job.mojo", "mojo/omxcore/mapped.mojo",
               "mojo/omxcore/parquet.mojo", "mojo/omxcore/sortspill.mojo"}
REMOVED_OK = re.compile(r"has_apple_gpu_accelerator|external_call\[\"(" + "|".join(LOOKED_UP) + r")\"")


def patch_scope():
    """None when the engine patch touches only the files and lines 1.2 (the accelerator query) and M5 (the looked-up
    functions) need, else why not."""
    text = ENGINE_PATCH.read_text()
    files = set(re.findall(r"^\+\+\+ [^/\s]+/(\S+)", text, re.M))
    if not files:
        return "the engine patch names no files (its +++ lines didn't parse)"
    if files - PATCH_FILES:
        return f"the engine patch touches {sorted(files - PATCH_FILES)}"
    removed = [l[1:] for l in text.splitlines() if l.startswith("-") and not l.startswith("---")]
    stray = [l.strip() for l in removed if not REMOVED_OK.search(l)]
    if stray:
        return f"the engine patch changes other lines: {stray[:3]}"
    # added lines: anything in the new _libc.mojo; elsewhere only calls of it, its import, or the accelerator query
    added, current = [], ""
    for l in text.splitlines():
        if l.startswith("+++ "):
            current = l
        elif l.startswith("+") and "_libc.mojo" not in current:
            added.append(l[1:])
    if any("has_apple_gpu_accelerator" in l for l in added):
        return "the patch still uses has_apple_gpu_accelerator"
    # (`made` holds a _libc_pthread_create result: (rc, thread id), D-5217)
    loose = [l.strip() for l in added if l.strip() and "_libc" not in l and "default_accelerator" not in l
             and not re.search(r"\bmade\[[01]\]$", l.strip())]
    if loose:
        return f"the engine patch adds other lines: {loose[:3]}"
    return None


GPU_PROBE = '''from omxcore.gpu import HAS_GPU
from omxcore.kernels.pipeline_gpu import APPLE_GPU

def main():
    comptime if HAS_GPU:
        print("MARK_GPU_ON")
    else:
        print("MARK_GPU_OFF")
    comptime if APPLE_GPU:
        print("MARK_APPLE_ON")
    else:
        print("MARK_APPLE_OFF")
'''


def gpu_switch():
    """(None or why, what each target compiled): Linux on (not Apple), a Mac with a Metal target on and Apple, a Mac
    without one off (as on 1.1: has_apple_gpu_accelerator() was false there too)."""
    G52.mkdir(parents=True, exist_ok=True)
    src = G52 / "gpu_switch.mojo"
    src.write_text(GPU_PROBE)
    want = {"linux": ("MARK_GPU_ON", "MARK_APPLE_OFF"), "mac-metal": ("MARK_GPU_ON", "MARK_APPLE_ON"),
            "mac": ("MARK_GPU_OFF", "MARK_APPLE_OFF")}
    flags = {"linux": [], "mac-metal": ["--target-triple", "arm64-apple-macosx13.0", "--target-accelerator", "metal:4"],
             "mac": ["--target-triple", "arm64-apple-macosx13.0"]}
    seen = {}
    for name, f in flags.items():
        obj = G52 / f"gpu_switch-{name}.o"
        b = run(["pixi", "run", "mojo", "build", "--disable-warnings", "-I", "vendor", str(src), *f, "--emit", "object", "-o", str(obj)])
        if b.returncode != 0:
            return f"the GPU switch probe doesn't build for {name}: {(b.stdout + b.stderr)[-300:]}", seen
        marks = set(re.findall(rb"MARK_[A-Z_]+", obj.read_bytes()))
        seen[name] = sorted(m.decode() for m in marks)
        for m in want[name]:
            if m.encode() not in marks:
                return f"{name}: compiled {seen[name]}, wanted {list(want[name])}", seen
    return None, seen


def engine_tests():
    """Builds and runs the engine's own Mojo tests (its scripts/mojo_test.sh at the pin) against build/omxcore-src
    (the archive with the patch). The runner's "uses Python" check greps ldd for "python", which every binary built
    with PyPI's Mojo matches (its libraries live under python3.13/site-packages); here it greps for libpython (as the
    rest of that check already looks for Python symbols)."""
    from engine_lineage import REPO
    work = G52 / "engine-test"
    if work.exists():
        shutil.rmtree(work)
    shutil.copytree(BUILD / "omxcore-src", work, ignore=shutil.ignore_patterns("pkg.*", ".omxcore-pkg.lock", ".mxframe-pkg.lock"))
    a = subprocess.run(f"git -C {REPO} archive {ENGINE_PIN} scripts/mojo_test.sh scripts/check_list_lifetimes.py mojo/tools | tar -x -C {work}",
                       shell=True, capture_output=True, text=True)
    if a.returncode != 0:
        return f"git archive of the engine's test runner failed: {a.stderr[-200:]}", ""
    runner = work / "scripts" / "mojo_test.sh"
    t = runner.read_text()
    old = 'if ldd "$out/$name" | grep -i python > /dev/null'
    if old not in t:
        return "the engine's test runner changed (its Python check isn't the one this adjusts)", ""
    runner.write_text(t.replace(old, 'if ldd "$out/$name" | grep -i libpython > /dev/null'))
    (work / ".pixi" / "envs").mkdir(parents=True, exist_ok=True)
    os.symlink(ROOT / ".pixi" / "envs" / "default", work / ".pixi" / "envs" / "default")
    r = run(["pixi", "run", "--manifest-path", str(ROOT / "pixi.toml"), "bash", "scripts/mojo_test.sh"], cwd=work,
            env={"MXFRAME_TEST_TMPDIR": str(work / "build" / "tmp")}, timeout=5400)
    out = r.stdout + r.stderr
    (G52 / "engine-tests.log").write_text(out)
    oks = re.findall(r"^ok\s+(\S+)", out, re.M)
    fails = re.findall(r"^FAIL.*$", out, re.M)
    if r.returncode != 0 or fails or len(oks) < 30:
        return f"engine tests: exit {r.returncode}, {len(oks)} ok, failing: {fails[:5]}", out
    return None, f"{len(oks)} engine tests ok"


def m1():
    from engine_lineage import vendored_at_least
    problems = []
    why = vendored_at_least(ENGINE_PIN)
    if why:
        problems.append(why)
    commit = (ROOT / "vendor" / "OMXCORE_COMMIT").read_text()
    if ENGINE_PATCH.name not in commit or "Mojo 1.2" not in commit:
        problems.append("vendor/OMXCORE_COMMIT doesn't name the 1.2 build and its patch")
    why = patch_scope()
    if why:
        problems.append(why)
    why, seen = gpu_switch()
    if why:
        problems.append(why)
    if problems:
        return False, "; ".join(problems)
    why, tests = engine_tests()
    if why:
        return False, why
    return True, f"vendor/omxcore.mojoc is {ENGINE_PIN}'s archive + {ENGINE_PATCH.name} built by 1.2 (lineage proved); {tests}; GPU switch {seen}"


# M2 ---------------------------------------------------------------------------------------------------------------
STREAM_BODY = '''# The request body of a streamed POST through Flare's client reaches the server (goal 52 M2): the patch's proof.
from mojoui.serve import Server, Service, Req, Reply
from flare.http import HttpClient, Request as FlareRequest
from flare.tls import TlsConfig


struct Echo(Service):
    def __init__(out self):
        pass

    def tick(mut self):
        pass

    def stop(mut self):
        pass

    def answer(mut self, mut req: Req) -> Reply:
        return Reply.text("got " + String(req.body.byte_length()) + ": " + req.body)


def main() raises:
    var server = Server.start(Echo(), workers=2)
    var body = String('{"messages": [1, 2, 3]}')
    var b = List[UInt8]()
    for c in body.as_bytes():
        b.append(c)
    var client = HttpClient(TlsConfig(), timeout_ms=5000)
    var s = client.send_streaming(FlareRequest(method="POST", url="http://127.0.0.1:" + String(server.port) + "/", body=b^))
    var got = List[UInt8]()
    while not s.done():
        var c = s.read_chunk(65536)
        if len(c) == 0:
            break
        got += c^
    s.close()
    server.stop()
    print("BODY " + String(unsafe_from_utf8=got))
'''


def flare_tree_diff():
    """None when vendor/flare is the tag's flare/ with the patch applied, else why not."""
    src = BUILD / "flare-src"
    if not (src / ".git").exists():
        r = run(["git", "clone", "-q", "https://github.com/ehsanmok/flare.git", str(src)], timeout=600)
        if r.returncode != 0:
            return f"can't clone flare: {r.stderr[-200:]}"
    run(["git", "-C", str(src), "fetch", "-q", "--tags"], timeout=600)
    tmp = G52 / "flare-tag"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    a = subprocess.run(f"git -C {src} archive {FLARE_TAG} flare | tar -x -C {tmp}", shell=True, capture_output=True, text=True)
    if a.returncode != 0:
        return f"git archive {FLARE_TAG}: {a.stderr[-200:]}"
    (tmp / "vendor").mkdir()
    (tmp / "flare").rename(tmp / "vendor" / "flare")
    p = subprocess.run(["patch", "-p1", "-s", "-i", str(FLARE_PATCH)], cwd=tmp, capture_output=True, text=True)
    if p.returncode != 0:
        return f"{FLARE_PATCH.name} doesn't apply to {FLARE_TAG}: {(p.stdout + p.stderr)[-200:]}"
    d = run(["diff", "-rq", "-x", "__pycache__", "-x", "*.so", "-x", "*.dylib", str(tmp / "vendor" / "flare"), str(ROOT / "vendor" / "flare")])
    if d.returncode != 0:
        return f"vendor/flare isn't {FLARE_TAG} + {FLARE_PATCH.name}: {d.stdout[:300]}"
    lic = run(["git", "-C", str(src), "show", f"{FLARE_TAG}:LICENSE"]).stdout
    if lic != (ROOT / "vendor/LICENSES/flare.txt").read_text():
        return "vendor/LICENSES/flare.txt isn't the tag's LICENSE"
    return None


def stream_body():
    """(None or why, detail): the patched Flare sends a streamed request's body; the tag's own sources still don't
    (so the patch is still needed)."""
    G52.mkdir(parents=True, exist_ok=True)
    src = G52 / "stream_body.mojo"
    src.write_text(STREAM_BODY)
    why = flare_build(src, G52 / "stream_body")
    if why:
        return why, ""
    r = run([str(G52 / "stream_body")], timeout=60)
    want = 'BODY got 23: {"messages": [1, 2, 3]}'
    if want not in r.stdout:
        return f"the patched Flare's streamed POST: {(r.stdout + r.stderr)[-300:]}", ""
    # the same program on the tag's unpatched sources (-I to a copy ahead of vendor/)
    plain = G52 / "flare-plain"
    if plain.exists():
        shutil.rmtree(plain)
    plain.mkdir(parents=True)
    shutil.copytree(G52 / "flare-tag" / "vendor" / "flare", plain / "flare")
    p = subprocess.run(["patch", "-R", "-p2", "-s", "-i", str(FLARE_PATCH)], cwd=plain, capture_output=True, text=True)
    if p.returncode != 0:
        return f"couldn't unpatch a copy: {(p.stdout + p.stderr)[-200:]}", ""
    # (scripts/mojo_flare.sh's flags with the unpatched copy first on the import path)
    lib = ROOT / ".pixi" / "envs" / "default" / "lib"
    b = run(["pixi", "run", "mojo", "build", "--disable-warnings", "-D", "MOJOUI_FLARE", "-I", str(plain), "-I", ".", "-I", "vendor",
             str(src), "-o", str(G52 / "stream_body_plain"), "-Xlinker", str(BUILD / "codecs" / "libzstd.so.1"),
             "-Xlinker", str(BUILD / "codecs" / "libsnappy.so.1"), "-Xlinker", f"-rpath={BUILD / 'codecs'}",
             "-Xlinker", "-rpath", "-Xlinker", str(BUILD / "flare" / "lib")])
    if b.returncode != 0:
        return f"the unpatched build: {(b.stdout + b.stderr)[-300:]}", ""
    u = run([str(G52 / "stream_body_plain")], timeout=60)
    if want in u.stdout:
        return f"{FLARE_TAG} sends the body without the patch: drop {FLARE_PATCH.name}", ""
    if "BODY got 0:" not in u.stdout:  # (only a dropped body proves the patch is needed, not a crash or a hang)
        return f"the unpatched run didn't show a dropped body: exit {u.returncode}, {(u.stdout + u.stderr)[-200:]}", ""
    return None, f"patched: body arrives; {FLARE_TAG} alone: {(u.stdout.strip().splitlines() or ['(nothing)'])[-1][:60]!r}"


def m2():
    problems = []
    version = (ROOT / "vendor" / "FLARE_VERSION").read_text()
    if not version.startswith(f"flare {FLARE_TAG}") or "json v0.4.2" not in version:
        problems.append(f"vendor/FLARE_VERSION: {version[:80]}")
    notice = (ROOT / "NOTICE").read_text()
    if f"Flare {FLARE_TAG}" not in notice or "json v0.4.2" not in notice:
        problems.append("NOTICE doesn't name Flare v0.13.1 and json v0.4.2")
    why = flare_tree_diff()
    if why:
        problems.append(why)
    why, body = stream_body()
    if why:
        problems.append(why)
    g50 = load("goal50", "docs/goals/50-check.py")
    (BUILD / "g50").mkdir(parents=True, exist_ok=True)
    # (goal 50's M0 names Flare v0.12.0 in its FLARE_VERSION check; its proof, the link test, runs here instead)
    for test, mark in (("test_flare_link", "link: ok"), ("test_hash", "hash: ok")):
        why = g50.mojo_test(test, mark)
        if why:
            problems.append(why)
    for name in ("m1", "m2", "m3"):
        ok, msg = getattr(g50, name)()
        if not ok:
            problems.append(f"goal 50's {name.upper()}: {msg[:300]}")
    return not problems, "; ".join(problems) or f"Flare {FLARE_TAG} + json v0.4.2 vendored and proved against the tag; stream body: {body}; test_flare_link, goal 50's M1-M3 (HTTPS, serve, process) and test_hash pass on 1.2"


# M3 ---------------------------------------------------------------------------------------------------------------
def kgen(root):
    syms = set()
    for o in sorted(root.glob("build/*/ios/app.o")):
        r = run(["pixi", "run", "llvm-nm", "-u", str(o)])
        syms |= {s for s in r.stdout.split() if "KGEN_" in s}
    return syms


def m3():
    import sweep
    if not BASELINE.exists():
        return False, f"no {BASELINE.relative_to(ROOT)} (scripts/sweep.py --root ../mojo-ui-g50)"
    base = json.loads(BASELINE.read_text())
    if not base["mojo"].startswith("Mojo 1.1"):
        return False, f"the baseline ran on {base['mojo']}"
    out = G52 / "sweep.json"
    cur = json.loads(out.read_text()) if out.exists() else {}
    if cur.get("stamp") != sweep.stamp(ROOT):
        r = run(["pixi", "run", "python", "scripts/sweep.py", "--out", str(out), "--jobs", "8"], timeout=7200)
        if r.returncode != 0:
            return False, f"the sweep failed: {(r.stdout + r.stderr)[-300:]}"
        cur = json.loads(out.read_text())
    problems = []
    if not cur["mojo"].startswith("Mojo 1.2"):
        problems.append(f"the sweep ran on {cur['mojo']}")
    lost_builds = [f"{a}/{p}" for a, v in base["examples"].items() for p, r in v.items()
                   if r["ok"] and not cur["examples"].get(a, {}).get(p, {}).get("ok")]
    lost_tests = [n for n, v in base["tests"].items() if v["passed"] and not cur["tests"].get(n, {}).get("passed")]
    # a test that passed on 1.1 and failed in the parallel sweep is built and run once more on its own (ports, CPU),
    # with what goal 50's checker leaves behind and the 1.1 checkout had (test_process starts build/serve_demo)
    if lost_tests:
        why = flare_build(ROOT / "tests" / "serve_demo.mojo", BUILD / "serve_demo")
        if why:
            return False, why
    again = []
    for n in lost_tests:
        _, r = sweep.test(ROOT, ROOT / "tests" / f"{n}.mojo")
        if not r["passed"]:
            again.append(f"{n}: {r['tail'][-160:]}")
    if lost_builds:
        problems.append(f"built on 1.1, not on 1.2: {lost_builds}")
    if again:
        problems.append(f"passed on 1.1, fail on 1.2: {again[:6]}")
    base_k, cur_k = kgen(Path(base["root"])), kgen(ROOT)
    if cur_k - base_k:
        problems.append(f"new KGEN_ symbols in iPhone objects: {sorted(cur_k - base_k)}")
    if not cur_k:
        problems.append("no iPhone objects to read (build/*/ios/app.o)")
    lint = run(["pixi", "run", "python", "scripts/libc_lint.py"])
    if lint.returncode != 0:
        problems.append("libc lint: " + lint.stdout[-300:])
    builds = sum(1 for v in cur["examples"].values() for r in v.values() if r["ok"])
    total = sum(len(v) for v in cur["examples"].values())
    passed = sum(1 for v in cur["tests"].values() if v["passed"])
    base_pass = sum(1 for v in base["tests"].values() if v["passed"])
    base_builds = sum(1 for v in base["examples"].values() for r in v.values() if r["ok"])
    return not problems, "; ".join(problems) or (
        f"examples {builds}/{total} build (1.1: {base_builds}); tests {passed}/{len(cur['tests'])} pass (1.1: {base_pass}/{len(base['tests'])}; "
        f"{len(lost_tests)} reran alone and passed); iPhone KGEN_ {sorted(cur_k)} as on 1.1; libc lint ok")


# M4 ---------------------------------------------------------------------------------------------------------------
def m4():
    g50 = load("goal50", "docs/goals/50-check.py")
    (BUILD / "g50").mkdir(parents=True, exist_ok=True)
    problems, notes = [], []
    for name in ("m4", "m5"):
        ok, msg = getattr(g50, name)()
        if not ok:
            problems.append(f"goal 50's {name.upper()}: {msg[:400]}")
        else:
            notes.append(f"{name.upper()}: {msg[:160]}")
    if problems:
        return False, "; ".join(problems)
    ok, msg = g50.m6()
    # (its problems are joined by "; " and goal 33's own message has some: cut out the 33-M5 one, which sits before
    # the matrix's problems, then nothing may be left)
    other = msg
    if not ok and "33-M5: " in msg:
        before, rest = msg.split("33-M5: ", 1)
        cut = rest.find("; docs/components.md")
        other = before.rstrip("; ") + (rest[cut:] if cut >= 0 else "")
    if not ok and other.strip("; "):
        return False, f"goal 50's M6 fails on more than goal 33's M5: {other[:400]}"
    if not ok and "33-M5: " in msg:
        # pinned to what failed at goal 50 (and on unchanged main): the console asking the fixture for `GET /`
        misses = re.findall(r"doesn't answer: (\[[^\]]*\])", rest)
        if not misses or any(m != "['GET /']" for m in misses):
            return False, f"goal 33's M5 fails differently than at goal 50: {rest[:400]}"
    return True, "goal 50's M4, M5 pass on 1.2 (" + " | ".join(notes) + ")" + ("; M6 fails on goal 33's M5 only, as at goal 50" if not ok else "; M6 passes")


# M5 ---------------------------------------------------------------------------------------------------------------
def m5():
    g50 = load("goal50", "docs/goals/50-check.py")
    (G52).mkdir(parents=True, exist_ok=True)
    why = g50.mojo_test("test_engine_flare", "engine + flare: ok", timeout=300)
    if why:
        return False, why
    call = re.compile(r'external_call\[\s*"(' + "|".join(LOOKED_UP) + r')"')
    declared = []
    for d in ("mojo/omxcore", "kernels_aot"):
        for f in sorted((BUILD / "omxcore-src" / d).glob("*.mojo")):
            for i, line in enumerate(f.read_text().splitlines(), 1):
                if call.search(line):
                    declared.append(f"{f.name}:{i}")
    if declared:
        return False, f"the engine still declares a looked-up function: {declared[:5]}"
    framefeed = (ROOT / "mojoui" / "framefeed.mojo").read_text()
    if 'external_call["pthread_create"' in framefeed:
        return False, "mojoui/framefeed.mojo declares pthread_create itself"
    out = run([str(BUILD / "test_engine_flare")], timeout=120).stdout.strip()
    return True, f"{out}; the engine declares none of {', '.join(LOOKED_UP)}"


# M6 ---------------------------------------------------------------------------------------------------------------
def m6():
    import side
    fresh, why = side.mac_fresh()
    if not fresh:
        return False, f"{why} (scripts/build.sh maccheck mac; scripts/build.sh omxplorer mac; scripts/mac-ci omxplorer maccheck)"
    run_dir = side.newest_mac_run()
    rep = run_dir / "report-macos-26"
    problems = []
    for app in ("maccheck", "omxplorer"):
        f = rep / f"{app}-stdout.txt"
        text = f.read_text(errors="replace") if f.exists() else ""
        if "TIMEOUT" in text or not re.search(r"^exit 0$", text, re.M):
            problems.append(f"{app} on the Mac: {text.strip().splitlines()[-3:] if text.strip() else 'no stdout'}")
        if not any((rep / f"omxcode-report-{app}").glob("*")):
            problems.append(f"no {app} report from the Mac")
    crashes = sorted(p.name for p in rep.rglob("*.ips"))
    if crashes:
        problems.append(f"crash logs: {crashes[:3]}")
    native = (rep / "native-build.txt").read_text(errors="replace") if (rep / "native-build.txt").exists() else ""
    if "NATIVE GPU BUILD IN USE" not in native:
        problems.append("omxplorer's native GPU build wasn't used: " + native[-200:])
    if not re.search(r"Mojo 1\.2", native):
        problems.append("the native build's log doesn't show Mojo 1.2")
    probe = (rep / "gpuprobe.txt").read_text(errors="replace") if (rep / "gpuprobe.txt").exists() else ""
    if "RESULT: ok" not in probe:
        problems.append("the Mac GPU probe: " + probe[-200:])
    return not problems, "; ".join(problems) or f"Mac run {run_dir.name} from these sources: maccheck and omxplorer ran their steps (exit 0), omxplorer's native GPU build with Mojo 1.2, the GPU probe ok"


# M7 ---------------------------------------------------------------------------------------------------------------
def m7():
    g50 = load("goal50", "docs/goals/50-check.py")
    exe = BUILD / "test_ui_thread"
    why = flare_build(ROOT / "tests" / "test_ui_thread.mojo", exe)
    if why:
        return False, why
    lines = []
    for i in range(5):
        r = run([str(exe)], timeout=180)
        out = r.stdout + r.stderr
        if r.returncode != 0 or "ui thread: ok" not in out:
            return False, f"run {i + 1}: exit {r.returncode}: {out[-400:]}"
        lines.append(next((l for l in out.splitlines() if l.startswith("ticks ")), "?"))
    # the handle's lifecycle (review): drop without stop(), stop() then drop, 30 cycles leave no threads or memory
    why = g50.mojo_test("test_served", "served: ok", timeout=300)
    if why:
        return False, why
    gaps = [int(m) for l in lines for m in re.findall(r"longest gap (\d+) ms", l)]
    starts = [int(m) for l in lines for m in re.findall(r"Server.start (\d+) ms", l)]
    return True, f"5 runs: longest frame gap {max(gaps)} ms (≤ 25), Server.start ≤ {max(starts)} ms, stop() 0 ms; e.g. {lines[0]}; test_served: drop/stop/30 cycles ok"


MILESTONES = [("M0", m0), ("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4), ("M5", m5), ("M6", m6), ("M7", m7)]


def main():
    import headless
    headless.ensure()
    G52.mkdir(parents=True, exist_ok=True)
    only = sys.argv[1:]
    results = []
    for name, fn in MILESTONES:
        if only and name not in only:
            continue
        t0 = time.time()
        try:
            ok, msg = fn()
        except Exception as e:
            import traceback
            traceback.print_exc()
            ok, msg = False, f"crashed: {e!r}"
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {msg}  ({time.time() - t0:.0f} s)", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
