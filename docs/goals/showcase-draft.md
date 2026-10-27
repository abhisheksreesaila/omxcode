# GOAL (draft, 2026-10-27, after goal 34): three stacks, one app, side by side

**Why (owner, 2026-10-27):** "after 34, showcase the power of the framework: JS with GPU, JS and Rust GPU, and Mojo,
side by side: how easy, and the performance."

## The contenders (the same app, the same picture)
- **A · JS + WebGPU:** UI in JS/HTML, kernels in WGSL.
- **B · JS + Rust (wgpu):** UI in JS/HTML, GPU work in Rust (wasm in the browser; native wgpu as a second row).
- **C · omxcode:** UI and GPU kernels in Mojo, one file (native GTK/Mac and the web host).

## The workload (owner, 2026-10-27: "eye-catching stuff; a simplified app is OK")
A GPU particle field: millions of particles swirl and follow the cursor (or finger); a slider raises the count
(1M → 5M → 20M) until a stack drops frames. Each frame is one compute step and one draw, so the app stays tiny in every
language and the comparison is about the stack. Headline number: particles held at 60 fps. Optional second scene: the
Data Lens's 20M-point cloud with pan, zoom and colour by a slider (already in Mojo). Same GPU (RTX 3090), same seed,
same picture.

## Measures
- Speed: GPU time per update, input-to-pixel latency, frames per second while dragging, cold start, memory, download size.
- Ease: languages, files, lines of code, build steps, tools to install, data boundaries crossed.
- Same answer: from the same seed, all three step the same particles: positions compared after N frames (within float tolerance) and the frames compared as pictures.

## Fair play
Each build is written by its own agent from that stack's official docs and idiomatic examples, without seeing the
others, then reviewed for performance mistakes; the code is published with an invitation to make it faster; losses are
reported as plainly as wins (e.g. in-browser WebGPU has no server round-trip, our web build does).

## Order (owner: "after 34")
Proposed: this is goal 35; Mojo 1.2 + flare becomes 36; measuring the FastHTML host (no action) 37.
