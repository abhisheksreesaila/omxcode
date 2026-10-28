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
