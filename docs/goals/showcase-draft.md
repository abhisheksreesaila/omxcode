# GOAL (draft, 2026-10-27, after goal 34): three stacks, one app, side by side

**Why (owner, 2026-10-27):** "after 34, showcase the power of the framework: JS with GPU, JS and Rust GPU, and Mojo,
side by side: how easy, and the performance."

## The contenders (the same app, the same picture)
- **A · JS + WebGPU:** UI in JS/HTML, kernels in WGSL.
- **B · JS + Rust (wgpu):** UI in JS/HTML, GPU work in Rust (wasm in the browser; native wgpu as a second row).
- **C · omxcode:** UI and GPU kernels in Mojo, one file (native GTK/Mac and the web host).

## The workload
One interaction on real scale: drag a filter → the GPU recomputes a group-by over 100M rows (or the Data Lens's 20M
points) → the chart redraws. Same data file, same GPU (RTX 3090), same output.

## Measures
- Speed: GPU time per update, input-to-pixel latency, frames per second while dragging, cold start, memory, download size.
- Ease: languages, files, lines of code, build steps, tools to install, data boundaries crossed.
- Same answer: all three draw the same picture from the same numbers (pixel compare, and the numbers equal pyarrow's).

## Fair play
Each build is written by its own agent from that stack's official docs and idiomatic examples, without seeing the
others, then reviewed for performance mistakes; the code is published with an invitation to make it faster; losses are
reported as plainly as wins (e.g. in-browser WebGPU has no server round-trip, our web build does).

## Order (owner: "after 34")
Proposed: this is goal 35; Mojo 1.2 + flare becomes 36; measuring the FastHTML host (no action) 37.
