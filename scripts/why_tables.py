"""Writes docs/why.html's generated parts from docs/goals/36/results.json and the builds' real files (goal 36 M5).

  pixi run python scripts/why_tables.py               # rewrite the page's generated parts from results.json
  pixi run python scripts/why_tables.py --check       # exit 1 if the page differs from what results.json gives
  pixi run python scripts/why_tables.py --provisional # from results-provisional.json (marked PROVISIONAL on the page)

Every number on the page, and every sentence that says who is faster, comes from here, so the final measurement drops
in by rerunning it. Each part lives between <!-- why:NAME --> and <!-- /why:NAME --> in docs/why.html. The code
excerpts are cut from the builds' files by line range and highlighted here (plain CSS classes, no library).
"""

import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGE = ROOT / "docs" / "why.html"
RESULTS = ROOT / "docs" / "goals" / "36" / "results.json"
PROVISIONAL = ROOT / "docs" / "goals" / "36" / "results-provisional.json"
REPO = "https://github.com/abhisheksreesaila/omxcode/blob/main/"

NAMES = {"A-cpu": "Plain JS (CPU)", "A": "JS + WebGPU", "B-wasm": "JS + Rust/wasm", "B-native": "Rust + wgpu (native, offscreen)",
         "C": "omxcode (Mojo)"}
ORDER = ["A-cpu", "A", "B-wasm", "B-native", "C"]
EFFORT_NAMES = {"A-cpu": "Plain JS (CPU)", "A": "JS + WebGPU", "B": "JS + Rust (wasm and native)", "C": "omxcode",
                "B-wasm": "JS + Rust/wasm", "B-native": "Rust + wgpu (native)"}
EFFORT_ORDER = ["A-cpu", "A", "B", "C"]
COUNT_ORDER = ["A-cpu", "A", "B-wasm", "B-native", "B", "C"]
TRANSCRIPT = ROOT / "docs" / "goals" / "36" / "mcp-transcript.json"
SIZES = [1_000_000, 5_000_000, 20_000_000]
E = html.escape


def mn(n):
    return f"{n // 1_000_000}M" if n % 1_000_000 == 0 else f"{n // 1000}k"


def f2(x, places=2):
    return "–" if x is None else f"{x:,.{places}f}"


def row(res, r, n):
    return res["rows"].get(r, {}).get(str(n))


# ---------- the measured parts ----------

def headline(res):
    c, a, b = (row(res, r, 1_000_000) for r in ("C", "A", "B-native"))
    big = res["largest_n_at_60"]
    same = [NAMES[r] for r in ("A", "B-native", "B-wasm", "A-cpu") if big.get(r) == big["C"]]
    ef = res["effort"]
    top = max(res["protocol"]["sizes"])
    held = mn(big["C"])
    byf = ef["C"].get("framework_added", {}).get("by_file", {})
    fw = sum(n for f, n in byf.items() if not f.startswith("tests/"))
    fwt = sum(n for f, n in byf.items() if f.startswith("tests/"))
    bw, bn = ef["B-wasm"], ef["B-native"]
    return f"""<div class="nums whynums">
  <div><b>{held}</b><span>particles, the largest size tested, with omxcode's frames averaging under 16.7 ms (60 fps) and the slowest one in twenty under 20 ms. Measured with vsync off on a virtual display, not a real screen. {(' and '.join(same) + (' do' if len(same) > 1 else ' does') + ' it too.') if same else ''}</span></div>
  <div><b>{ef['C']['lines']}<small>app lines</small></b><span>in {ef['C']['files']} Mojo file for omxcode, plus {fw} framework lines (and {fwt} test lines) this goal added for it: PointCloud's step and draw, reusable by any app. JS + WebGPU: {ef['A']['lines']:,} lines, {ef['A']['files']} files, {len(ef['A']['languages'])} languages. JS + Rust is two apps: {bw['lines']:,} lines, {bw['files']} files, {len(bw['languages'])} languages for wasm; {bn['lines']:,}, {bn['files']} and {len(bn['languages'])} for native.</span></div>
  <div><b>{f2(c['frame_ms'])}<small>ms</small></b><span>an omxcode frame at 1M. JS + WebGPU takes {f2(a['frame_ms'])} ms and native Rust + wgpu (offscreen) {f2(b['frame_ms'])} ms: {'omxcode is slower, and the page says why.' if c['frame_ms'] > min(a['frame_ms'], b['frame_ms']) else 'omxcode is the fastest here.'}</span></div>
</div>"""


def compare(res, x, y="C"):
    """One plain sentence: how y (omxcode) does against x at every size."""
    sizes = res["protocol"]["sizes"]
    pairs = [(n, row(res, x, n)["frame_ms"], row(res, y, n)["frame_ms"]) for n in sizes if row(res, x, n) and row(res, y, n)]
    faster = [n for n, xm, ym in pairs if ym < xm]
    slower = [n for n, xm, ym in pairs if ym > xm]
    ends = (f"{f2(pairs[0][1])} ms against omxcode's {f2(pairs[0][2])} ms at {mn(pairs[0][0])}; "
            f"{f2(pairs[-1][1])} against {f2(pairs[-1][2])} ms at {mn(pairs[-1][0])}")
    if not faster:
        return f"<b>{NAMES[x]} is faster than omxcode at every size measured</b> ({ends})."
    if not slower:
        return f"<b>omxcode is faster than {NAMES[x]} at every size measured</b> ({ends})."
    return (f"<b>omxcode is faster than {NAMES[x]} at {', '.join(mn(n) for n in faster)} and slower at "
            f"{', '.join(mn(n) for n in slower)}</b> ({ends}).")


def verdict(res):
    big, top = res["largest_n_at_60"], max(res["protocol"]["sizes"])
    held = {}
    for r in ORDER:
        held.setdefault(big[r], []).append(NAMES[r])
    lines = []
    for n in sorted(held, reverse=True):
        who = held[n]
        lines.append(f"{' and '.join([', '.join(who[:-1]), who[-1]] if len(who) > 1 else who)} {'hold' if len(who) > 1 else 'holds'} 60 fps up to {mn(n)}{' (the largest size tested)' if n == top else ''}")
    s20 = {r: row(res, r, top)["step_ms"] for r in ("A", "B-native", "C")}
    lo, hi = min(s20.values()), max(s20.values())
    c20 = row(res, "C", top)
    rest = c20["frame_ms"] - c20.get("work_ms", 0)
    fastest = {n: min((row(res, r, n)["frame_ms"], r) for r in ORDER if row(res, r, n)) for n in SIZES}
    c1, a1, b1 = (row(res, r, 1_000_000) for r in ("C", "A", "B-native"))
    starts = sorted((row(res, r, 1_000_000)["cold_start_ms"], r) for r in ORDER)
    mem = sorted((row(res, r, 1_000_000)["peak_pss_mb"], r) for r in ORDER)
    dip = next((n for n in res["protocol"]["sizes"][1:] if round(row(res, "C", n)["frame_ms"], 2) < round(c1["frame_ms"], 2)), None)
    out = [
        "<p>" + "; ".join(lines) + ".</p>",
        "<p>The fastest frame: " + "; ".join(f"{NAMES[r]} at {mn(n)} ({f2(ms)} ms)" for n, (ms, r) in fastest.items()) + ".</p>",
        "<ul class='verdict'>",
        f"<li>{compare(res, 'B-native')} Native Rust renders offscreen here and never presents to a window (see the caveats), so its frame skips the window system the others pay for.</li>",
        f"<li>{compare(res, 'A')}</li>",
        f"<li>{compare(res, 'B-wasm')}</li>",
        f"<li>{compare(res, 'A-cpu')}</li>",
        f"<li><b>The GPU step itself is a tie.</b> At {mn(top)} it takes {f2(s20['A'], 3)} ms in JS + WebGPU, {f2(s20['B-native'], 3)} ms in Rust + wgpu and "
        f"{f2(s20['C'], 3)} ms in omxcode: the same arithmetic on the same GPU, within {round((hi / lo - 1) * 100)} % of each other.</li>",
        f"<li><b>Where omxcode's frame goes.</b> At {mn(top)} its GPU work is {f2(c20['gpu_frame_ms'])} ms (step and draw) plus "
        f"{f2(c20['readback_ms'])} ms copying the finished picture to the CPU; with one wait a frame that is {f2(c20.get('work_ms'))} ms. "
        f"The other {f2(rest)} ms of its {f2(c20['frame_ms'])} ms frame is inferred, not measured: the frame minus that work. "
        f"We read it as the GTK host taking the picture as a texture and compositing it (here with GTK's software renderer on a virtual display), "
        f"because it hardly depends on N: the same residual is {f2(c1['frame_ms'] - c1['work_ms'])} ms at 1M and {f2(rest)} ms at {mn(top)}, "
        f"{top // 1_000_000} times the particles. The copy and that path, not the GPU, are what make omxcode slower today; "
        "drawing straight from the GPU into the window is not built yet.</li>",
        f"<li><b>omxcode's frame is noisy.</b> Its spread across the three runs is up to ±{f2(max(row(res, 'C', n)['frame_ms_spread'] for n in res['protocol']['sizes']))} ms"
        + (f", and its {mn(dip)} figure ({f2(row(res, 'C', dip)['frame_ms'])} ms) is below its 1M one: read its line as flat within that noise.</li>" if dip else ": read its line as flat within that noise.</li>"),
        f"<li><b>Start and memory.</b> At 1M, cold start to the first drawn frame: " + ", ".join(f"{NAMES[r]} {f2(ms, 0)} ms" for ms, r in starts) +
        ". Native Rust has no window or swapchain to make, as it renders offscreen. Peak memory (the process tree's PSS, so pages Chromium's processes share count once; GPU memory not included): " + ", ".join(f"{NAMES[r]} {f2(mb, 0)} MB" for mb, r in mem) +
        ". The browser rows carry Chromium itself in both.</li>",
        "</ul>",
    ]
    return "\n".join(out)


def best(values, low=True):
    vals = [v for v in values if v is not None]
    return (min(vals) if low else max(vals)) if vals else None


def perf(res):
    top = max(res["protocol"]["sizes"])
    head = ("<tr><th>Build</th><th>Largest N at 60 fps</th>" + "".join(f"<th>Frame ms · {mn(n)}</th>" for n in SIZES) +
            f"<th>Step ms · {mn(top)}</th><th>Cold start ms · 1M</th><th>Peak memory MB (PSS) · 1M / {mn(top)}</th></tr>")
    cols = {n: best([row(res, r, n)["frame_ms"] for r in ORDER if row(res, r, n)]) for n in SIZES}
    body = []
    for r in ORDER:
        cells = [f"<th scope='row'>{NAMES[r]}</th>", f"<td>{mn(res['largest_n_at_60'][r])}</td>"]
        for n in SIZES:
            d = row(res, r, n)
            if not d:
                cells.append("<td>–</td>")
                continue
            cls = ["best"] if d["frame_ms"] == cols[n] else []
            if not d.get("holds_60"):
                cls.append("miss")
            mark = " <span class='x' title='does not hold 60 fps'>✗</span>" if not d.get("holds_60") else ""
            cells.append(f"<td class='{' '.join(cls)}'>{f2(d['frame_ms'])}<small>±{f2(d['frame_ms_spread'])}</small>{mark}</td>")
        d20, d1 = row(res, r, top), row(res, r, 1_000_000)
        cells.append(f"<td>{f2(d20['step_ms'], 3)}<small class='is'>{E(d20['step_ms_is'])}</small></td>")
        cells.append(f"<td>{f2(d1['cold_start_ms'], 0)}</td>")
        cells.append(f"<td>{f2(d1['peak_pss_mb'], 0)} / {f2(d20['peak_pss_mb'], 0)}</td>")
        body.append(f"<tr class='r-{r}'>" + "".join(cells) + "</tr>")
    how = "".join(f"<li><b>{NAMES[r]}:</b> {E(row(res, r, 1_000_000)['frame_ms_is'])}.</li>" for r in ORDER)
    extra = res["protocol"].get("extra_sizes", {}).get("A-cpu", [])
    small = "".join(f" Plain JS at {mn(n)}: {f2(row(res, 'A-cpu', n)['frame_ms'])} ms (p95 interval {f2(row(res, 'A-cpu', n)['p95_interval_ms'])} ms)."
                    for n in extra if row(res, "A-cpu", n))
    p = res["protocol"]
    return f"""<div class="tscroll"><table class="mtable perf">
<thead>{head}</thead>
<tbody>
{chr(10).join(body)}
</tbody></table></div>
<p class="tnote">Median of {p['runs']} runs of {p['warmup']} warm-up and {p['frames']} measured frames, vsync off (± is the spread, max − min). Holds 60 fps = frame ≤ {p['frame_60_ms']} ms and the 95th-percentile frame interval ≤ {p['p95_max_ms']:g} ms; ✗ = it doesn't. The fastest in each column is marked. A's p95 is a rAF interval that runs ahead of its GPU, so for A the p95 test never binds; its throughput does.{small}</p>
<ul class="hownote">{how}</ul>"""


def caveats(res):
    return "<ul class='caveats'>" + "".join(f"<li>{E(c)}</li>" for c in res["caveats"]) + "</ul>"


def provenance(res):
    flag = "" if not res.get("provisional") else " <b class='prov'>PROVISIONAL: measured on a busy machine, not the result.</b>"
    return (f"Measured by scripts/particles_bench.py at commit {E(res['commit'])} on {E(res['date'])} "
            f"({E(res['machine'].split(',')[0])}, {E(res['machine'].split(',')[1].strip())}; Chromium for the browser rows, Mojo 1.1); "
            f"sources sha256 {E(res['sources_sha256'][:12])}; the raw numbers are in docs/goals/36/results.json.{flag}")


def effort(res):
    ef = res["effort"]
    rows = []
    fw = ef["C"].get("framework_added", {})
    for k in COUNT_ORDER:
        e = ef[k]
        cls = " class='r-C'" if k == "C" else " class='sum'" if k == "B" else ""
        name = {"B": "JS + Rust, both apps", "C": "omxcode (the app)"}.get(k, EFFORT_NAMES[k])
        rows.append(f"<tr{cls}><th scope='row'>{name}</th><td>{e['lines']:,}</td><td>{e['files']}</td>"
                    f"<td>{len(e['languages'])}<small class='is'>{E(', '.join(e['languages']))}</small></td>"
                    f"<td>{e['build_steps']}</td><td class='tc'>{E('; '.join(e['toolchains']))}</td></tr>")
    steps = "".join(
        f"<div class='steps'><b>{EFFORT_NAMES[k]}</b><ol>" + "".join(f"<li><code>{E(s)}</code></li>" for s in ef[k]["steps"]) + "</ol></div>"
        for k in ("B-wasm", "B-native", "C"))
    return f"""<div class="tscroll"><table class="mtable effort">
<thead><tr><th>Build</th><th>Lines of code</th><th>Files</th><th>Languages</th><th>Build steps</th><th>Toolchains to install</th></tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody></table></div>
<p class="tnote">Counted by scripts/particles_bench.py, not by hand: blank and comment-only lines (and docstrings) left out.
The two Rust apps share the sim crate and the workspace Cargo.toml (counted in each). omxcode's row is the app; mojoui, the framework, is a library,
as WebGPU, wgpu, wasm-bindgen and rayon are. But this goal also added {fw.get('lines', 0)} lines to the framework and its test for omxcode
({', '.join(f'{E(f)} +{n}' for f, n in fw.get('by_file', {}).items())}; from git, since the goal began): PointCloud's step, draw and readback,
which any app can now use. Build steps run from a clean checkout to the app on screen.</p>
<div class="stepsrow">{steps}</div>"""


# What an agent has to write and wire in each stack (read from the builds' files; the counts come from results.json).
SEAMS = {
    "A-cpu": "No seam, and no GPU: one thread steps and draws every particle. Simple, and it runs out of frames first.",
    "A": "Two languages meet by hand. A <code>Params</code> struct in WGSL must match a 32-byte buffer that JavaScript packs "
         "field by field (main.js 177); every buffer, pipeline and bind group is made in JavaScript, and remade when the count changes.",
    "B": "Rust in three crates, JavaScript around it, GLSL for the browser's draw and WGSL for the native one. wasm-bindgen writes "
         "the glue; JavaScript reads wasm memory through raw pointers and must re-take its view when memory grows. Threads need "
         "COOP/COEP headers, a worker (rayon blocks its caller), <code>-Z build-std</code> unlocked on a stable compiler, and a "
         "<code>sed</code> patch to a generated file. The native build repeats the step in WGSL and pads its structs by hand.",
    "C": "One Mojo file. The step is a Mojo function (<code>advance</code>) handed to the GPU as a parameter; the slider and "
         "the readout are widgets in the same <code>view()</code>. No glue, no second language, one build. It leans on the "
         "framework's PointCloud, which this goal extended (counted in chapter 2).",
}


def writes(res):
    ef = res["effort"]
    cards = []
    for k in EFFORT_ORDER:
        e = ef[k]
        chips = "".join(f"<i>{E(l)}</i>" for l in e["languages"])
        cls = " me" if k == "C" else ""
        cards.append(f"<div class='wcard{cls}'><h3>{EFFORT_NAMES[k]}</h3><div class='wnum'><b>{len(e['languages'])}</b> "
                     f"language{'s' if len(e['languages']) > 1 else ''} · <b>{e['files']}</b> file{'s' if e['files'] > 1 else ''} · "
                     f"<b>{e['build_steps']}</b> build steps</div><div class='langs'>{chips}</div><p>{SEAMS[k]}</p></div>")
    return "<div class='wgrid'>" + "".join(cards) + "</div>"


# ---------- the code: excerpts cut from the real files ----------

# (feature, build) -> [(file, first line, last line, what it is)]
EXCERPTS = {
    "step": {
        "A-cpu": [("showcase/js-webgpu/cpu.js", 43, 53, "JavaScript: every particle, one loop, the main thread")],
        "A": [("showcase/js-webgpu/step.wgsl", 15, 26, "WGSL: the kernel, one GPU thread per particle"),
              ("showcase/js-webgpu/main.js", 180, 186, "JavaScript: encode a compute pass and dispatch it")],
        "B": [("showcase/js-rust/sim/src/lib.rs", 27, 41, "Rust: the step (a SIMD128 version for wasm is lines 43–73)"),
              ("showcase/js-rust/wasm/src/lib.rs", 32, 43, "Rust → JS: exported through wasm-bindgen, split over a rayon pool"),
              ("showcase/js-rust/web/worker.js", 70, 76, "JavaScript: cross into wasm, then upload every particle to the GPU"),
              ("showcase/js-rust/native/src/shader.wgsl", 19, 30, "WGSL: the native build's step, a second copy of the maths")],
        "C": [("examples/particles/app.mojo", 40, 46, "Mojo: one particle; mojoui.gpu runs it as a GPU kernel"),
              ("examples/particles/app.mojo", 222, 222, "Mojo: each frame")],
    },
    "count": {
        "A-cpu": [("showcase/js-webgpu/index.html", 24, 24, "HTML: the slider"),
                  ("showcase/js-webgpu/cpu.js", 95, 100, "JavaScript: wire it up")],
        "A": [("showcase/js-webgpu/index.html", 24, 24, "HTML: the slider"),
              ("showcase/js-webgpu/main.js", 245, 247, "JavaScript: wire it up (setN rebuilds the buffers and bind groups, lines 147–172)")],
        "B": [("showcase/js-rust/web/index.html", 19, 22, "HTML: a select on the page"),
              ("showcase/js-rust/web/main.js", 24, 24, "JavaScript: post it to the worker"),
              ("showcase/js-rust/web/worker.js", 54, 61, "JavaScript: rebuild the field in wasm memory, re-take the view"),
              ("showcase/js-rust/native/src/main.rs", 589, 594, "Rust: the native window has no widgets: keys 1 to 5")],
        "C": [("examples/particles/app.mojo", 320, 320, "Mojo: the slider, in the view"),
              ("examples/particles/app.mojo", 237, 245, "Mojo: its message, in update()")],
    },
    "readout": {
        "A-cpu": [("showcase/js-webgpu/cpu.js", 84, 93, "JavaScript: fps and step ms into the page")],
        "A": [("showcase/js-webgpu/main.js", 229, 239, "JavaScript: fps and step ms into the page"),
              ("showcase/js-webgpu/main.js", 276, 282, "JavaScript: step ms read back from GPU timestamp queries (a pool, lines 257–283)")],
        "B": [("showcase/js-rust/web/worker.js", 82, 85, "JavaScript: the worker formats it and posts it"),
              ("showcase/js-rust/web/main.js", 12, 13, "JavaScript: the page shows it"),
              ("showcase/js-rust/native/src/main.rs", 341, 348, "Rust: the native window draws its text with a 3×5 bitmap font in a shader")],
        "C": [("examples/particles/app.mojo", 310, 313, "Mojo: the readout, in the view"),
              ("examples/particles/app.mojo", 221, 230, "Mojo: the step timed four times a second")],
    },
}
FEATURES = [("step", "The step"), ("count", "The count"), ("readout", "The readout")]
CODE_BUILDS = [("A-cpu", "Plain JS"), ("A", "JS + WebGPU"), ("B", "JS + Rust"), ("C", "omxcode")]
LANG = {".js": "js", ".wgsl": "wgsl", ".rs": "rust", ".mojo": "mojo", ".html": "html"}
KW = {
    "js": "const let var function return if else for of new await async true false null this",
    "wgsl": "fn let var struct return if override const true false",
    "rust": "pub fn let mut for in if else use impl struct const as return self Self true false unsafe while match",
    "mojo": "def var return if elif else for in and or not struct from import comptime self True False",
    "html": "",
}
TYPES = r"\b(?:f32|u32|i32|vec2f|vec4f|vec2|vec3|vec4|vec3u|usize|Float32|Float64|Int|Bool|String|Point|Knobs|SIMD|Vec|Field)\b"


def highlight(src, lang):
    if lang == "html":
        out, pos = [], 0
        for m in re.finditer(r'<!--.*?-->|"[^"]*"|</?[a-zA-Z][\w-]*|/?>', src):
            out.append(E(src[pos:m.start()]))
            t = m.group(0)
            cls = "c" if t.startswith("<!--") else "s" if t.startswith('"') else "k"
            out.append(f"<span class='{cls}'>{E(t)}</span>")
            pos = m.end()
        return "".join(out) + E(src[pos:])
    comment = r"#.*" if lang == "mojo" else r"//.*"
    kws = r"\b(?:" + "|".join(KW[lang].split()) + r")\b"
    rx = re.compile(f'(?P<c>{comment})|(?P<s>"[^"\\n]*"|\'[^\'\\n]*\'|`[^`\\n]*`)|(?P<a>@\\w+)|(?P<k>{kws})|(?P<t>{TYPES})'
                    r"|(?P<n>\b0x[0-9a-fA-F_]+u?\b|\b\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?[fu]?\b)|(?P<f>\b[a-zA-Z_]\w*(?=\s*[(\[]))")
    out, pos = [], 0
    for m in rx.finditer(src):
        out.append(E(src[pos:m.start()]))
        out.append(f"<span class='{m.lastgroup}'>{E(m.group(0))}</span>")
        pos = m.end()
    return "".join(out) + E(src[pos:])


def excerpt(path, a, b):
    lines = (ROOT / path).read_text().splitlines()
    if b > len(lines):
        raise SystemExit(f"{path} has {len(lines)} lines, not {b}")
    block = lines[a - 1:b]
    indent = min((len(l) - len(l.lstrip()) for l in block if l.strip()), default=0)
    return "\n".join(l[indent:] for l in block)


def code():
    parts = []
    for fk, fname in FEATURES:
        cards = []
        for bk, bname in CODE_BUILDS:
            blocks, files, langs, count = [], set(), set(), 0
            for path, a, b, what in EXCERPTS[fk][bk]:
                src = excerpt(path, a, b)
                lang = LANG[Path(path).suffix]
                files.add(path)
                langs.add({"js": "JavaScript", "wgsl": "WGSL", "rust": "Rust", "mojo": "Mojo", "html": "HTML"}[lang])
                count += sum(1 for l in src.splitlines() if l.strip())
                rng = f"{a}" if a == b else f"{a}–{b}"
                anchor = f"#L{a}" if a == b else f"#L{a}-L{b}"
                blocks.append(f"<figure class='blk'><figcaption><a href='{REPO}{path}{anchor}'>{E(path.split('/', 1)[1] if path.startswith('showcase/') else path)}"
                              f"<span>:{rng}</span></a>{E(what)}</figcaption><pre><code>{highlight(src, lang)}</code></pre></figure>")
            tally = f"{count} lines shown · {len(files)} file{'s' if len(files) > 1 else ''} · {', '.join(sorted(langs))}"
            cls = " me" if bk == "C" else ""
            cards.append(f"<div class='ccard{cls}'><div class='chead'><b>{bname}</b><span>{tally}</span></div>{''.join(blocks)}</div>")
        parts.append(f"<div class='feature' data-f='{fk}'><h3 class='fname'>{fname}</h3><div class='cgrid'>{''.join(cards)}</div></div>")
    return "\n".join(parts)


# ---------- the page ----------

def problem(res):
    """Chapter 1's first card: where plain JS stops keeping up, from its rows."""
    rows = {int(n): d for n, d in res["rows"]["A-cpu"].items()}
    ok = [n for n, d in sorted(rows.items()) if d["holds_60"]]
    fails = [(n, d) for n, d in sorted(rows.items()) if not d["holds_60"]]
    parts = [f"At {mn(max(ok))} particles it keeps up ({f2(rows[max(ok)]['frame_ms'])} ms a frame)." if ok else ""]
    for n, d in fails[:2]:
        if d["frame_ms"] <= res["protocol"]["frame_60_ms"]:
            parts.append(f"At {mn(n)} its average frame still fits ({f2(d['frame_ms'])} ms), but it stutters: the slowest frame in "
                         f"twenty takes {f2(d['p95_interval_ms'], 1)} ms.")
        else:
            parts.append(f"At {mn(n)} a frame takes {f2(d['frame_ms'])} ms on average: it can't keep 60 fps, and it only gets worse from there.")
            break
    return ("<p>One thread steps every particle and paints every pixel. " + " ".join(p for p in parts if p) +
            " It is single-threaded on purpose: it is the \"JavaScript alone\" baseline.</p>")


def mcp():
    """Chapter 3's session, printed from the committed transcript (scripts/why_mcp.py), never typed by hand."""
    t = json.loads(TRANSCRIPT.read_text())
    msgs = t["messages"]
    out = ["<div class='call'>",
           "<div class='who'>Once: <code>scripts/agent.sh particles</code> prints the <code>claude mcp add</code> line</div>"]
    calls = {m["msg"]["id"]: m["msg"] for m in msgs if m["from"] == "agent" and m["msg"].get("method") == "tools/call"}
    said = {"screen": "The agent calls screen", "slider": "Then moves the slider (an MCP tools/call)", "read": "Three seconds later it reads the screen"}
    for m in msgs:
        r = m["msg"]
        if m["from"] != "agent host" or r.get("id") not in calls:
            continue
        call = calls[r["id"]]
        name = call["params"]["name"]
        out.append(f"<div class='who'>{E(said.get(name, name))}</div>")
        if name == "slider":
            out.append(f"<pre>{E(json.dumps({'method': call['method'], 'params': call['params']}))}</pre>")
            out.append("<div class='who'>And gets back what changed, in words</div>")
        text = "\n".join(c["text"] for c in r["result"]["content"] if c["type"] == "text")
        out.append(f"<pre class='res'>{E(text)}</pre>")
    out.append("</div>")
    out.append(f"<p style='font-size:13.5px'>Recorded {E(t['date'])} by scripts/why_mcp.py: {E(t['app'])}; the agent host attached "
               "to it. Printed here from the committed transcript (docs/goals/36/mcp-transcript.json, every JSON-RPC line after the "
               "MCP handshake), unedited. The fps in it is the app's own smoothed readout with an agent attached, not the measurement. "
               "Nothing in <code>app.mojo</code> was written for it.</p>")
    return "\n".join(out)


def fragments(res):
    return {"headline": headline(res), "verdict": verdict(res), "perf": perf(res), "caveats": caveats(res),
            "provenance": provenance(res), "effort": effort(res), "writes": writes(res), "code": code(),
            "problem": problem(res), "mcp": mcp()}


def apply(text, frags):
    for name, body in frags.items():
        rx = re.compile(f"(<!-- why:{name} -->)(.*?)(<!-- /why:{name} -->)", re.S)
        if not rx.search(text):
            raise SystemExit(f"docs/why.html has no <!-- why:{name} --> … <!-- /why:{name} --> markers")
        text = rx.sub(lambda m: m.group(1) + "\n" + body + "\n" + m.group(3), text, count=1)
    return text


def load(provisional=False):
    path = PROVISIONAL if provisional else RESULTS
    if not path.exists():
        raise SystemExit(f"{path.relative_to(ROOT)} doesn't exist yet" + ("" if provisional else " (--provisional uses the busy-machine run)"))
    return json.loads(path.read_text())


def main(args):
    res = load("--provisional" in args)
    page = PAGE.read_text()
    new = apply(page, fragments(res))
    if "--check" in args:
        if new != page:
            print("docs/why.html differs from what results.json gives: rerun scripts/why_tables.py")
            return 1
        print("docs/why.html matches results.json")
        return 0
    PAGE.write_text(new)
    print(f"docs/why.html: {len(fragments(res))} parts written from {'results-provisional.json (PROVISIONAL)' if res.get('provisional') else 'results.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
