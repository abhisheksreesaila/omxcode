"""Milestone checker for GOAL.md (goal 36: three stacks, one particle field; goal 36b: M6-M8). Prints PASS/FAIL per milestone.

Run: scripts/check   (a subset: scripts/check M0 M4)
Each milestone's proof comes from GOAL.md's words (never weaker). M1-M3 run each build's own check script and need
its "ok" lines; M4 checks docs/goals/36/results.json, written by scripts/particles_bench.py.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
OUT = ROOT / "docs" / "goals" / "36"


def run(cmd, timeout=3600):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)


def needs_ok(cmd, labels, timeout=3600):
    """Runs a build's check; every label must print '<label>: ok'."""
    r = run([sys.executable, *cmd], timeout)
    out = r.stdout + r.stderr
    lines = [l.strip() for l in out.splitlines()]
    missing = [lab for lab in labels if not any(l.startswith(f"{lab}: ok") for l in lines)]
    if r.returncode != 0 or missing:
        tail = " | ".join(l for l in lines if l)[-900:]
        return False, f"{' '.join(cmd)}: exit {r.returncode}, no ok for {missing or labels}: {tail}"
    return True, "; ".join(next(l for l in lines if l.startswith(f"{lab}: ok")) for lab in labels)


def m0():
    """The spec and the reference: SPEC.md and reference.py; N = 10,000 after 120 steps, two runs byte-equal."""
    for f in ("showcase/SPEC.md", "showcase/reference.py"):
        if not (ROOT / f).exists():
            return False, f"{f} missing"
    with tempfile.TemporaryDirectory() as d:
        outs = []
        for k in range(2):
            p = Path(d) / f"ref{k}.bin"
            r = run([sys.executable, "showcase/reference.py", "10000", "120", str(p)], 600)
            if r.returncode != 0 or not p.exists():
                return False, f"reference.py failed: {r.stderr[-500:]}"
            outs.append(p.read_bytes())
    if len(outs[0]) != 10000 * 2 * 4:
        return False, f"reference wrote {len(outs[0])} bytes, not 10,000 × 2 float32"
    if outs[0] != outs[1]:
        return False, "two reference runs differ"
    import hashlib
    return True, f"reference N=10,000 F=120: two runs byte-equal ({len(outs[0])} bytes, sha256 {hashlib.sha256(outs[0]).hexdigest()[:12]})"


def m1():
    """A · JS + WebGPU on the RTX 3090 matches the reference, and the plain-JS CPU row (A-cpu)."""
    ok1, msg1 = needs_ok(["showcase/js-webgpu/check_a.py"], ["A"])
    ok2, msg2 = needs_ok(["showcase/js-webgpu/check_a.py", "--cpu"], ["A-cpu"])
    return ok1 and ok2, f"{msg1}; {msg2}"


def m2():
    """B · JS + Rust: the wasm row and the native wgpu row both match the reference."""
    return needs_ok(["showcase/js-rust/check_b.py"], ["B-wasm", "B-native"])


def m3():
    """C · omxcode: examples/particles on GTK (GPU) matches the reference."""
    return needs_ok(["showcase/omxcode/check_c.py"], ["C"])


def m4():
    """The measure: results.json is the final gated measurement (not provisional), every row at every size, from one
    protocol, fresh for these sources."""
    import particles_bench as pb
    path = OUT / "results.json"
    if not path.exists() or not (OUT / "results.md").exists():
        prov = " (only the PROVISIONAL busy-machine results exist: results-provisional.json)" if (OUT / "results-provisional.json").exists() else ""
        return False, "docs/goals/36/results.json or results.md missing: run scripts/particles_bench.py through the quiet gate" + prov
    res = json.loads(path.read_text())
    problems = []
    if res.get("provisional") is not False or res.get("gated") is not True or not (res.get("protocol", {}).get("gate") or {}).get("load1_below"):
        problems.append("results.json is not the final gated measurement (provisional or ungated)")
    if "PROVISIONAL" in (OUT / "results.md").read_text():
        problems.append("results.md is marked PROVISIONAL")
    if res.get("sources_sha256") != pb.sources_sha():
        problems.append("stale: the sources changed since results.json was measured (rerun scripts/particles_bench.py)")
    p = res.get("protocol", {})
    if (p.get("warmup"), p.get("frames"), p.get("runs")) != (60, 600, 3):
        problems.append(f"protocol {p.get('warmup')}/{p.get('frames')}/{p.get('runs')}, not 60 warm-up / 600 frames / 3 runs")
    need = ["frame_ms", "frame_ms_spread", "p95_interval_ms", "cold_start_ms", "peak_rss_mb", "peak_pss_mb", "holds_60", "frame_ms_is", "step_ms_is"]
    for row in pb.ROWS:
        rows = res.get("rows", {}).get(row)
        if not rows:
            problems.append(f"{row}: no results")
            continue
        for n in pb.EXTRA.get(row, []) + pb.SIZES:
            r = rows.get(str(n))
            if not r:
                problems.append(f"{row} {n}: missing")
                continue
            miss = [k for k in need if r.get(k) is None]
            if miss:
                problems.append(f"{row} {n}: no {miss}")
            if not all((x.get("machine") or {}).get("gated") for x in r.get("runs", [])) or not r.get("machine", {}).get("gated"):
                problems.append(f"{row} {n}: a run didn't pass the quiet gate")
            if len(r.get("runs", [])) != 3:
                problems.append(f"{row} {n}: {len(r.get('runs', []))} runs")
            if row != "A-cpu":
                a = (r.get("adapter") or "").lower()
                if "nvidia" not in a or "swiftshader" in a or "llvmpipe" in a:
                    problems.append(f"{row} {n}: adapter {r.get('adapter')}")
            if row == "C" and r.get("readback_ms") is None:
                problems.append(f"C {n}: no readback_ms")
            if row == "B-wasm" and (not r.get("crossOriginIsolated") or r.get("threads", 1) <= 1):
                problems.append(f"B-wasm {n}: not multi-threaded")
            if r.get("holds_60") != (r.get("frame_ms", 99) <= 1000 / 60 and r.get("p95_interval_ms", 99) <= 20):
                problems.append(f"{row} {n}: holds_60 disagrees with its numbers")
    if not (res.get("effort", {}).get("C", {}).get("framework_added") or {}).get("lines"):
        problems.append("effort C: the framework lines this goal added aren't counted")
    for b in ("A", "A-cpu", "B", "B-wasm", "B-native", "C"):
        e = res.get("effort", {}).get(b, {})
        if not all(e.get(k) for k in ("lines", "files", "languages", "build_steps", "toolchains")):
            problems.append(f"effort {b}: incomplete")
    if res.get("effort") and res["effort"] != pb.effort():
        problems.append("effort counts differ from a fresh count")
    md = (OUT / "results.md").read_text()
    for word in ("atomic", "saturat", "hardware blending", "readback", "offscreen", "single-threaded"):
        if word not in md:
            problems.append(f"results.md doesn't state the caveat '{word}'")
    if problems:
        return False, "; ".join(problems[:12])
    big = res["largest_n_at_60"]
    return True, (f"results.json fresh (commit {res['commit']}, sources {res['sources_sha256'][:10]}); largest N at 60 fps: "
                  + ", ".join(f"{r} {pb.mill(v) if v else 'none'}" for r, v in big.items()))


def m5():
    """The page: docs/why-details.html in four chapters, its generated parts equal to what the final results.json gives
    (scripts/why_tables.py --check), no provisional text, every ✓ in the feature table links to something that exists,
    every ✗ says why, and every image it shows exists."""
    import re
    import why_tables as wt
    page_path = ROOT / "docs" / "why-details.html"
    if not page_path.exists():
        return False, "docs/why-details.html missing"
    page = page_path.read_text()
    problems = []
    for cid in ("performance", "code", "agents", "features"):
        if f'id="{cid}"' not in page:
            problems.append(f"no chapter #{cid}")
    if not (OUT / "results.json").exists():
        return False, "docs/goals/36/results.json missing (the final measurement): the page can't be checked against it"
    res = json.loads((OUT / "results.json").read_text())
    if res.get("provisional") is not False:
        problems.append("results.json is provisional")
    if wt.apply(page, wt.fragments(res)) != page:
        problems.append("the page's tables differ from results.json: rerun scripts/why_tables.py")
    if "provisional" in page.lower():
        problems.append("the page says 'provisional'")
    mcp = re.search(r"<!-- why:mcp -->(.*?)<!-- /why:mcp -->", page, re.S)
    if not mcp or "<pre" not in mcp.group(1):
        problems.append("no example MCP tool call in chapter 3")
    if not wt.TRANSCRIPT.exists():
        problems.append("docs/goals/36/mcp-transcript.json (scripts/why_mcp.py) missing")
    else:
        tr = json.loads(wt.TRANSCRIPT.read_text())
        if "linux/particles" not in tr.get("app", "") or "no-vsync" not in tr.get("app", ""):
            problems.append("the MCP transcript isn't from the native GTK build with vsync off")
        elif mcp and wt.mcp() not in mcp.group(1):
            problems.append("the page's MCP session differs from the committed transcript")

    def exists(href):
        href = href.split("#")[0]
        if href.startswith(wt.REPO):
            return (ROOT / href[len(wt.REPO):]).exists()
        if href.startswith("https://"):
            return True  # outside the repo (npm, crates.io, the AG-UI docs): not checked offline
        return bool(href) and (ROOT / "docs" / href).exists()

    table = re.search(r'<table class="mtable ftable">(.*?)</table>', page, re.S)
    yes = no = 0
    if not table:
        problems.append("no feature table")
    else:
        for tr in re.findall(r"<tr>(.*?)</tr>", table.group(1), re.S):
            feature = re.sub(r"<.*?>", "", (re.search(r"<th[^>]*>(.*?)</th>", tr, re.S) or [None, "?"])[1])
            for td in re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S):
                note = re.sub(r"<.*?>", "", td.split("</span>", 1)[-1]).strip()
                if 'class="m yes"' in td:
                    yes += 1
                    hrefs = re.findall(r'href="([^"]+)"', td)
                    if not hrefs:
                        problems.append(f"{feature}: a ✓ without a link")
                    problems += [f"{feature}: ✓ links to {h}, which doesn't exist" for h in hrefs if not exists(h)]
                elif 'class="m no"' in td or 'class="m part"' in td:
                    no += 1
                    if len(note) < 12:
                        problems.append(f"{feature}: a ✗ or partial without a reason")
    for src in re.findall(r'<img[^>]+src="([^"]+)"', page) + re.findall(r'href="(img/[^"]+)"', page):
        if not (ROOT / "docs" / src).exists():
            problems.append(f"image {src} missing")
    if problems:
        return False, "; ".join(problems[:12])
    big = res["largest_n_at_60"]
    return True, (f"docs/why-details.html: four chapters, tables match results.json (commit {res['commit']}), feature table {yes} ✓ "
                  f"all linked, {no} ✗/partial all explained; largest N at 60 fps on the page: "
                  + ", ".join(f"{r} {wt.mn(v)}" for r, v in big.items()))


_C_OK = {}


def c_ok():
    """showcase/omxcode/check_c.py (the particle app's correctness check), run once for M6, M6b and M6c."""
    if "r" not in _C_OK:
        _C_OK["r"] = needs_ok(["showcase/omxcode/check_c.py"], ["C"])
    return _C_OK["r"]


def mojo_test(path, ok_line):
    r = run(["pixi", "run", "mojo", "run", "-I", ".", path], 1800)
    out = r.stdout + r.stderr
    lines = [l.strip() for l in out.splitlines() if l.startswith("  ") and "warning" not in l and not l.strip().startswith(("^", "~", "Pointer", "unsafe_"))]
    if r.returncode != 0 or ok_line not in out:
        return False, f"{path}: exit {r.returncode}: " + " | ".join(l for l in out.splitlines() if "error" in l.lower() or "Assert" in l or "SKIP" in l)[-600:], []
    return True, f"{path}: {ok_line}", [l for l in lines if l and not l.startswith(("def ", "var ", "pts", "Mojo/"))][:8]


def m6():
    """Zero-copy presentation (GOAL.md 36b M6): (a) tests/test_canvas_present.mojo; (b) headless: the fallback is
    reported and C still ok; (c) the desktop proof (present-desktop.json) fresh, zero readbacks; the app unchanged."""
    import particles_bench as pb
    import headless
    problems, notes = [], []
    ok, msg, lines = mojo_test("tests/test_canvas_present.mojo", "canvas present: ok")
    (notes if ok else problems).append(msg)
    if ok and not any("byte for byte" in l for l in lines):
        problems.append("the test didn't compare the GL texture with the readback picture")
    cok, cmsg = c_ok()  # (builds the app)
    (notes if cok else problems).append(cmsg)
    headless.ensure()
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run([str(ROOT / "build/particles/linux/particles"), "--scripted", "--n", "10000", "--frames", "30",
                            "--out", d, "--positions", "0"], cwd=ROOT, capture_output=True, text=True, timeout=300,
                           env=dict(os.environ, MOJOUI_PRESENT_STATS="1"))
    out = r.stdout + r.stderr
    told = next((l for l in out.splitlines() if l.startswith("mojoui: GPU canvas pictures")), "")
    if "copied to the CPU for the screen (" not in told:
        problems.append(f"headless: the fallback wasn't reported (got {told!r})")
    else:
        notes.append("headless: " + told[len("mojoui: "):])
    pd = OUT / "present-desktop.json"
    if not pd.exists():
        problems.append("docs/goals/36/present-desktop.json missing: run scripts/present_smoke.py on the desktop")
    else:
        d = json.loads(pd.read_text())
        if d.get("sources_sha256") != pb.sources_sha():
            problems.append("present-desktop.json is stale (the sources changed): rerun scripts/present_smoke.py")
        if d.get("cpu_copied") != 0 or d.get("gpu_presented", 0) < d.get("frames", 1) - 1 or "without a copy" not in d.get("path", ""):
            problems.append(f"desktop: {d.get('cpu_copied')} readbacks, {d.get('gpu_presented')} of {d.get('frames')} frames from the GPU")
        else:
            notes.append(f"desktop: {d['gpu_presented']} of {d['frames']} frames shown from the GPU, 0 readbacks "
                         f"({d['gsk_renderer']} renderer, {d['frame_ms_mean']:.2f} ms/frame at 1M)")
    # (review item 1, D-752: the app's only change is declaring its GPU canvas)
    # and, exactly, D-767's swap of std.sys/std.os for mojoui.shared (goal 3's framework-only imports, D-768)
    d767 = {"-from std.sys import argv, exit", "-from std.os import getenv",
            "+from mojoui.shared import arguments, environment, exit_with",
            "-    var args = argv()", "+    var args = arguments()",
            "-    var v = getenv(env)", "+    var v = environment(env)",
            "-            exit(1)", "+            exit_with(1)", "-        exit(0)", "+        exit_with(0)"}
    added = [l for l in run(["git", "diff", "-U0", "216c2b5", "--", "examples/particles/app.mojo"]).stdout.splitlines()
             if l[:1] in "+-" and not l.startswith(("+++", "---")) and l not in d767]
    if added and (len(added) != 1 or "comptime GPU_CANVAS = True" not in added[0]):
        problems.append("examples/particles/app.mojo changed beyond declaring its GPU canvas: " + "; ".join(added)[:300])
    ok_t, msg_t, _ = mojo_test("tests/test_gpu_canvas_gate.mojo", "gpu canvas gate: ok")
    (notes if ok_t else problems).append(msg_t)
    hb = run(["scripts/build.sh", "hello", "linux"], 900)
    hello = ROOT / "build/hello/linux/hello"
    if hb.returncode != 0 or not hello.exists():
        problems.append("couldn't build examples/hello")
    else:
        r = subprocess.run([str(hello)], cwd=ROOT, capture_output=True, text=True, timeout=120,
                           env=dict(os.environ, MOJOUI_PRESENT_STATS="1", MOJOUI_TEST=""))
        st = next((l for l in (r.stdout + r.stderr).splitlines() if "present stats" in l), "")
        if "gpu device ''" not in st or "declares no GPU canvas" not in st:
            problems.append(f"a non-GPU app (hello) wasn't left alone: {st!r}")
        else:
            notes.append("hello (no GPU canvas): not probed, MOJOUI_GPU_DEVICE unset, renderer as the host set it")
    if problems:
        return False, "; ".join(problems)
    return True, "; ".join(notes)


def m6b():
    """Hardware-blended drawing (GOAL.md 36b M6b): tests/test_canvas_blend.mojo, C still ok, no particle names in mojoui."""
    problems, notes = [], []
    ok, msg, lines = mojo_test("tests/test_canvas_blend.mojo", "canvas blend: ok")
    (notes if ok else problems).append(msg)
    if ok:
        notes += [l for l in lines if l.startswith(("additive", "lines", "over", "MOJOUI_BLEND"))]
    hits = run(["git", "grep", "-n", "-i", "particle", "--", "mojoui"]).stdout.strip()
    if hits:
        problems.append("particle names in mojoui: " + hits[:300])
    cok, cmsg = c_ok()
    (notes if cok else problems).append(cmsg)
    return (not problems), "; ".join(problems or notes)


def m6c():
    """A cheaper compute splat (GOAL.md 36b M6c): two atomics a point, exact (tests/test_pointcloud_step.mojo), C ok."""
    problems, notes = [], []
    ok, msg, lines = mojo_test("tests/test_pointcloud_step.mojo", "test_pointcloud_step: ok")
    (notes if ok else problems).append(msg)
    if ok and not any("no bleed" in l for l in lines):
        problems.append("the packed-splat case didn't run")
    elif ok:
        notes += [l for l in lines if "packed" in l]
    src = (ROOT / "mojoui/gpu.mojo").read_text()
    body = src[src.index("def _splat2_kernel"):src.index("def _resolve_kernel")]
    if body.count("Atomic.fetch_add") != 2:
        problems.append(f"the packed splat has {body.count('Atomic.fetch_add')} atomic adds, not 2")
    cok, cmsg = c_ok()
    (notes if cok else problems).append(cmsg)
    return (not problems), "; ".join(problems or notes)


def m7():
    """Every row on the real desktop (GOAL.md 36b M7): results-desktop.json, gated, fresh, goal 36's protocol, every row
    and size, C's zero-copy path in every C run (0 readbacks, GTK's GL renderer), the setup recorded."""
    import particles_bench as pb
    path, md = OUT / "results-desktop.json", OUT / "results-desktop.md"
    if not path.exists() or not md.exists():
        return False, "docs/goals/36/results-desktop.json/.md missing: run scripts/particles_bench.py --desktop (D-735)"
    res = json.loads(path.read_text())
    problems = []
    if not res.get("desktop") or res.get("provisional") is not False or res.get("gated") is not True:
        problems.append("not the gated desktop measurement")
    if res.get("sources_sha256") != pb.sources_sha():
        problems.append("stale: the sources changed since results-desktop.json (rerun particles_bench.py --desktop)")
    p = res.get("protocol", {})
    if (p.get("warmup"), p.get("frames"), p.get("runs"), p.get("sizes")) != (60, 600, 3, pb.SIZES):
        problems.append("not goal 36's protocol (60 warm-up, 600 frames, 3 runs, the same sizes)")
    need = ["frame_ms", "frame_ms_spread", "p95_interval_ms", "cold_start_ms", "peak_pss_mb", "holds_60", "frame_ms_is"]
    rows = res.get("rows", {})
    for row in pb.DESKTOP_ROWS + list(pb.FEATURES):
        sizes = pb.FEATURE_SIZES if row in pb.FEATURES else pb.EXTRA.get(row, []) + pb.SIZES
        for n in sizes:
            r = rows.get(row, {}).get(str(n))
            if not r:
                problems.append(f"{row} {n}: missing")
                continue
            if [k for k in need if r.get(k) is None] or len(r.get("runs", [])) != 3:
                problems.append(f"{row} {n}: incomplete")
            if not all((x.get("machine") or {}).get("gated") for x in r["runs"]):
                problems.append(f"{row} {n}: a run didn't pass the quiet gate")
            if row != "A-cpu" and "nvidia" not in (r.get("adapter") or "").lower():
                problems.append(f"{row} {n}: adapter {r.get('adapter')}")
            if row.startswith("C") and row not in ("C-36", "C-36gl"):
                if r.get("cpu_copied_max") != 0 or r.get("gpu_presented_min", 0) < 600 or r.get("gsk_renderer") != "gl":
                    problems.append(f"{row} {n}: not the zero-copy path ({r.get('cpu_copied_max')} readbacks, {r.get('gpu_presented_min')} from the GPU, renderer {r.get('gsk_renderer')})")
            if row in ("C-36", "C-36gl") and not r.get("cpu_copied_max"):
                problems.append(f"{row} {n}: goal 36's path should copy to the CPU")
            if row.startswith("C") and not r.get("renderer_used"):
                problems.append(f"{row} {n}: the renderer GTK used isn't recorded")
            if row in ("C-36gl", "C", "C+M6", "C+M6c") and r.get("renderer_used") != ["GskGLRenderer"]:
                problems.append(f"{row} {n}: drew with {r.get('renderer_used')}, not GTK's GL renderer")
            if r.get("holds_60") != (r["frame_ms"] <= 1000 / 60 and r["p95_interval_ms"] <= 20):
                problems.append(f"{row} {n}: holds_60 disagrees with its numbers")
    if "Wayland window" not in (rows.get("B-native", {}).get("1000000", {}).get("frame_ms_is") or ""):
        problems.append("B-native didn't present to a window")
    st = res.get("setup", {})
    m = st.get("monitor", {})
    if not st.get("compositor", "").startswith("Hyprland") or not m.get("refreshRate") or not m.get("scale") or "off" not in st.get("vsync", ""):
        problems.append("the setup (compositor, refresh, scale, vsync) isn't recorded")
    text = md.read_text()
    for word in ("Setup:", "Each 36b feature's effect", "compositor", "1280 × 720"):
        if word not in text:
            problems.append(f"results-desktop.md doesn't state '{word}'")
    if problems:
        return False, "; ".join(problems[:12])
    c = rows["C"]
    return True, (f"results-desktop.json fresh (commit {res['commit']}), {st['compositor'].split(' built')[0]}, "
                  f"{m.get('refreshRate'):.2f} Hz ×{m.get('scale')}; C frame ms "
                  + ", ".join(f"{pb.mill(n)} {c[str(n)]['frame_ms']:.2f}" for n in pb.SIZES)
                  + f"; 0 readbacks in every 36b C run ({sum(1 for r in rows if r.startswith('C') and r not in ('C-36', 'C-36gl'))} rows; goal 36's path C-36/C-36gl copies, as it should)")


def m8():
    """The page from the desktop (GOAL.md 36b M8): chapter 1 generated from results-desktop.json (and goal 36's table
    from results.json), the setup stated, no claim left from the inferred software-renderer reading, M5 still passing."""
    import why_tables as wt
    page = (ROOT / "docs" / "why-details.html").read_text()
    problems = []
    d = wt.load_desktop()
    if not d:
        return False, "results-desktop.json missing or provisional: the page can't come from the desktop"
    res = json.loads((OUT / "results.json").read_text())
    frags = wt.fragments(res, d)
    if wt.apply(page, frags) != page:
        problems.append("the page differs from what results-desktop.json and results.json give: rerun scripts/why_tables.py")
    for part in ("setup", "features", "perf_xvfb"):
        if f"<!-- why:{part} -->" not in page:
            problems.append(f"no {part} part on the page")
    for word in ("Hyprland", "Hz", "Vsync", "1280 × 720", "GPU-composited"):
        if word not in frags["setup"] + frags["headline"]:
            problems.append(f"the setup doesn't state '{word}'")
    for stale in ("GTK's software renderer on a virtual display", "drawing straight from the GPU into the window is not built yet",
                  "Measured with vsync off on a virtual display, not a real screen"):
        if stale in page:
            problems.append(f"the page still says: {stale!r}")
    if "the guess was wrong" not in page:
        problems.append("the page doesn't say what became of goal 36's inferred residual")
    if "is GTK's renderer choice" not in page or "C-36gl" not in d["rows"]:
        problems.append("the page doesn't split M6's saving into the renderer and the readback (review item 3)")
    if ("capped (compositor" not in page or "didn't speed up this benchmark" not in page
            or "within the runs' spread" not in page or "omxcode and JS + WebGPU tie" not in page):
        problems.append("review items 7/8/10: ties, the capped window row, M6b's role")
    ok5, msg5 = m5()
    if not ok5:
        problems.append("M5: " + msg5)
    if problems:
        return False, "; ".join(problems[:10])
    c = d["rows"]["C"]
    return True, (f"docs/why-details.html chapter 1 from results-desktop.json (commit {d['commit']}): omxcode "
                  + ", ".join(f"{wt.mn(n)} {c[str(n)]['frame_ms']:.2f} ms" for n in (1_000_000, 5_000_000, 20_000_000))
                  + f"; setup, feature effects and goal 36's Xvfb table on the page; M5 PASS")


MILESTONES = [
    ("M0", m0),
    ("M1", m1),
    ("M2", m2),
    ("M3", m3),
    ("M4", m4),
    ("M5", m5),
    ("M6", m6),
    ("M6b", m6b),
    ("M6c", m6c),
    ("M7", m7),
    ("M8", m8),
]


def main():
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
        except Exception as e:
            import traceback
            traceback.print_exc()
            ok, msg = False, f"crashed: {e!r}"
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {msg}  ({time.time() - t0:.0f} s)", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
