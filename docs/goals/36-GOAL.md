# GOAL 36: three stacks, one particle field

**End goal (owner, 2026-10-27; the page's four chapters added the same night, before its work):** "the particle showcase, where JS, JS + Rust and omxcode: what the difference is…
show something where JS alone just doesn't work; then people put in Rust and swap the hard paths… they don't have
this… front and centre, its own page." Eye-catching and simple (docs/goals/showcase-draft.md). Spec: showcase/SPEC.md.

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | The spec and the reference | showcase/SPEC.md and showcase/reference.py; the reference's 120-step positions for N = 10,000 are reproducible (two runs byte-equal) |
| M1 | A · JS + WebGPU | showcase/js-webgpu: plain JS + WGSL compute and render, no framework; runs in Chromium on the RTX 3090 (WebGPU, headless with a GPU); scripted mode writes positions.bin and timings.json; positions match the reference (SPEC "Correctness") at N = 10,000 |
| M2 | B · JS + Rust | showcase/js-rust: the UI in JS/HTML, the step in Rust compiled to wasm (wasm-bindgen; SIMD + threads if the browser allows) and a second row: the same Rust with wgpu natively (a window, compute + render); both scripted, both match the reference at N = 10,000 |
| M3 | C · omxcode | examples/particles: one Mojo file (UI + GPU step + draw through the framework's Canvas/GPU path), native on GTK (and builds for the web host); scripted mode; matches the reference at N = 10,000 |
| M4 | The measure | scripts/particles_bench.py runs each build scripted on the same machine: for N in the slider steps, mean frame ms (throughput) and step ms over 600 frames after 60 warm-up, the median of three runs (amended 2026-10-28, D-730: "median" read as the median frame interval, which a pipelined loop's bursts make meaningless; the mean counts every frame's work, for every row alike, so the bar is not weaker); the largest N each holds at ≥ 60 fps; cold start; peak memory; plus lines of code, files, languages and build steps per build (counted by a script, not by hand); writes docs/goals/36/results.json and a table |
| M5 | The page | docs/why.html (the site's style, omxqua dark), four chapters, each JS + WebGPU vs JS + Rust vs omxcode: (1) performance: the problem (JS alone drops frames), the usual fix (Rust/wasm: languages, bindings, builds, a boundary every frame), omxcode, with a side-by-side clip/shots at the same N and M4's measured table, every loss stated; (2) the code: the same feature (the step + the slider + the readout) shown side by side from each build's real files, with M4's counts (lines, files, languages, build steps); (3) the agent's view: what an agent writes in each stack (three languages, bindings and builds vs one Mojo file), how an agent uses the running app (screenshots and clicks vs omxcode's MCP tools, with an example tool call), and AG-UI (the agent sends data, the runtime builds native UI; an example payload and the resulting screen); (4) a feature table (AG-UI built in, every app an MCP server, native on every platform, the GPU in the same language, theme and security by default, …) with ✓/✗ per stack, each ✓ linked to its proof and each ✗ stated plainly; linked from the cover's developer strip |

## Fair play
Each build is written by its own agent from that stack's official docs and idiomatic examples, without reading the
other builds; then a reviewer looks for performance mistakes in each. Numbers come only from M4's script on one
machine (RTX 3090, Chromium 152, Mojo 1.1). Losses are reported as plainly as wins.

## Out of bounds
Pushing (the owner decides); tuning one build after seeing another's numbers without giving the others the same chance.

## Done means
`scripts/check` PASS for M0–M5; the reviewer passes it; docs/why.html previewed for the owner.

# GOAL 36b: close the presentation gap (zero-copy), then measure on the real desktop

**End goal (owner, 2026-10-28):** "close the gap the usual way rather than just explain it, before publishing."
Goal 36's C frame was its GPU work, plus a 0.42 ms GPU→CPU readback of the picture every frame, plus an inferred
~4.3 ms GTK cost from the software (cairo) renderer on Xvfb. 36b removes the readback in the framework and measures
every row again on the owner's GPU-composited Hyprland desktop (D-735). Written before the work (2026-10-28 05:35);
goal 36's milestones and proofs stay as they are (M4/M5 still pass, re-measured if the sources change).

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M6 | Zero-copy presentation | A GPU Canvas picture reaches GTK without a GPU→CPU readback, generic in mojoui: (a) its own test, tests/test_canvas_present.mojo, on the NVIDIA GPU with no window: the picture PointCloud.splat leaves on the GPU, copied by mojoui's presenter into a GL texture (CUDA↔GL), read back from GL, equals the CPU-readback picture byte for byte (1280×720 and an odd size); the presenter's texture ring never hands out a texture GTK hasn't released; the run-time choice reports why when interop is unavailable (turned off, no GL) and the copy path is used instead; (b) on the headless display (no GL) the particles app reports the CPU fallback and showcase/omxcode/check_c.py still prints "C: ok"; (c) on the live desktop (a 36b measurement window) the particles app reports the GPU path and its host counts zero readbacks for every presented frame (docs/goals/36/present-desktop.json, from scripts/present_smoke.py); examples/particles/app.mojo is not changed by M6 (any app's GPU Canvas gets it) |
| M6b | Hardware-blended drawing | A generic drawing mode of the GPU canvas: points and lines drawn by the GPU's fixed-function blending (additive, and normal "over"), the technique native Rust/wgpu uses, from the same app-written Mojo place/tint functions (mojoui runs them in a GPU kernel that fills a vertex buffer; the framework's one fixed shader pair only passes them through, no app maths in a shader language), on GTK through the same GL context and texture ring as M6 (no readback): (a) its own test, tests/test_canvas_blend.mojo, on the NVIDIA GPU with no window: points (additive) match the compute splat's picture within 2 levels per channel on every pixel and exactly on unsaturated single-point pixels; lines (additive and over) light the pixels between their ends; "over" draws in point order; (b) the compute splat stays the fallback, chosen at run time (no GL context, MOJOUI_BLEND=0) and reported; (c) the particle app's correctness check still prints "C: ok"; no particle names in mojoui (the console lint's rule) |
| M6c | A cheaper compute splat | The compute splat adds light with fewer atomics per point than goal 36's three (red and green packed into one 64-bit atomic, blue in a 32-bit one: two), exact: tests/test_pointcloud_step.mojo's GPU = CPU picture checks still pass, a new case drives a pixel's packed channel past saturation and checks no channel bleeds into another; the particle app's correctness check still "C: ok" |
| M7 | Every row on the real desktop | scripts/particles_bench.py --desktop: goal 36's protocol unchanged (quiet gate, 60 warm-up + 600 frames, 3 runs, median ± spread, the same sizes and fields), every row on the owner's Hyprland desktop (Wayland, GPU-composited), one display for all: C in GTK on Wayland with the zero-copy path (reported per run), A, A-cpu and B-wasm in headed Chromium on Wayland with GPU compositing, B-native presenting to a window if it can (else offscreen, labelled); vsync and frame limiters off as in goal 36; every field 1280×720 pixels (the monitor's scale applied by the compositor or browser, stated); NVIDIA adapter asserted; writes docs/goals/36/results-desktop.json and results-desktop.md with the setup recorded (compositor and version, monitor, refresh, scale, vsync settings, GTK renderer, present path) and fresh for the sources |
| M8 | The page from the desktop | docs/why.html's performance chapter is generated from results-desktop.json (scripts/why_tables.py --check equal for both result files), the setup stated (real desktop, compositor, refresh, vsync off and how, scale), every number on the page found in a results file, the caveats updated: the inferred software-renderer residual dropped if the desktop run shows it gone (else restated with the desktop number), and what remains of C's frame said plainly; M5 still passes |

Widened by the owner (2026-10-28, through the coordinator, before M6b/M6c's work): "borrow all the tricks needed to
render it, but don't overfit the benchmark: it must support the framework's vision (performant, modular components,
Linux, Mac, then phones)." Every capability is generic (any app's GPU Canvas or PointCloud gets it, no particle code in
mojoui), and each API names the seam a Metal (Mac) or Vulkan/OpenCL-class phone GPU would implement later (not built
now). M7's report gives each feature's effect on omxcode's frame ms at 1M/5M/20M (M6, M6b, M6c switched on in turn).

## Fair play (as goal 36)
Every row gets the same display and the same chance: if one row may present to a real window, all may. No build is
tuned after seeing another's desktop numbers without giving the others the same chance. Losses reported as plainly as wins.

## Out of bounds
Pushing; touching anything on the desktop besides the windows the measurement opens (each closed, only PIDs it started
stopped); desktop windows for anything but 36b's measurement (builds, tests and other checks stay headless).

## Done means
`scripts/check` PASS for M6–M8 (and M0–M5 still); the reviewer passes it.
