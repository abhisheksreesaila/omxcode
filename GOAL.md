# GOAL 36: three stacks, one particle field

**End goal (owner, 2026-10-27):** "the particle showcase, where JS, JS + Rust and omxcode: what the difference is…
show something where JS alone just doesn't work; then people put in Rust and swap the hard paths… they don't have
this… front and centre, its own page." Eye-catching and simple (docs/goals/showcase-draft.md). Spec: showcase/SPEC.md.

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | The spec and the reference | showcase/SPEC.md and showcase/reference.py; the reference's 120-step positions for N = 10,000 are reproducible (two runs byte-equal) |
| M1 | A · JS + WebGPU | showcase/js-webgpu: plain JS + WGSL compute and render, no framework; runs in Chromium on the RTX 3090 (WebGPU, headless with a GPU); scripted mode writes positions.bin and timings.json; positions match the reference (SPEC "Correctness") at N = 10,000 |
| M2 | B · JS + Rust | showcase/js-rust: the UI in JS/HTML, the step in Rust compiled to wasm (wasm-bindgen; SIMD + threads if the browser allows) and a second row: the same Rust with wgpu natively (a window, compute + render); both scripted, both match the reference at N = 10,000 |
| M3 | C · omxcode | examples/particles: one Mojo file (UI + GPU step + draw through the framework's Canvas/GPU path), native on GTK (and builds for the web host); scripted mode; matches the reference at N = 10,000 |
| M4 | The measure | scripts/particles_bench.py runs each build scripted on the same machine: for N in the slider steps, median frame ms and step ms over 600 frames after 60 warm-up; the largest N each holds at ≥ 60 fps; cold start; peak memory; plus lines of code, files, languages and build steps per build (counted by a script, not by hand); writes docs/goals/36/results.json and a table |
| M5 | The page | docs/why.html (the site's style, omxqua dark): the problem (JS alone drops frames), the usual fix (add Rust/wasm: languages, bindings, builds, a boundary every frame), omxcode (one file, native, the GPU in the same language); a side-by-side clip/shots of the three at the same N, the measured table with every loss stated plainly; linked from the cover's developer strip |

## Fair play
Each build is written by its own agent from that stack's official docs and idiomatic examples, without reading the
other builds; then a reviewer looks for performance mistakes in each. Numbers come only from M4's script on one
machine (RTX 3090, Chromium 152, Mojo 1.1). Losses are reported as plainly as wins.

## Out of bounds
Pushing (the owner decides); tuning one build after seeing another's numbers without giving the others the same chance.

## Done means
`scripts/check` PASS for M0–M5; the reviewer passes it; docs/why.html previewed for the owner.
