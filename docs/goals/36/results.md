# Goal 36 M4 · the particle field, measured

Every run passed the quiet gate: 1-minute load < 2.0 and no other process on the GPU (compute apps over 16 MiB; idle desktop clients hold 6 MiB); waited 10268 s in all.

Commit `06bc74a`, sources sha256 `ea4c9d7044aa`, 2026-10-29 11:49; 24 cores, NVIDIA GeForce RTX 3090, 610.57.04, NVIDIA GeForce RTX 3090, 610.57.04.
Protocol: scripts/particles_bench.py (docstring): 60 warm-up + 600 measured frames, 3 runs, each run's frame ms is the mean frame interval (throughput); the table shows the median of the runs (± spread = max - min).

## Headline: frame ms (throughput, vsync off) and the largest N at 60 fps

Holds 60 fps = frame ms ≤ 16.7 and the 95th-percentile frame interval ≤ 20 ms.

| Row | largest N at 60 fps | 1M | 2M | 5M | 10M | 20M |
|---|---|---|---|---|---|---|
| A · JS + WebGPU | 20M | 1.30 ±0.02 | 1.31 ±0.04 | 1.40 ±0.02 | 1.70 ±0.01 | 3.26 ±0.04 |
| A-cpu · plain JS (CPU) | 100k | 14.38 ±0.20 ✗ | 25.13 ±0.57 ✗ | 58.05 ±0.89 ✗ | 113.33 ±6.75 ✗ | 233.21 ±15.42 ✗ |
| B-wasm · JS + Rust/wasm | 5M | 2.10 ±0.18 | 3.83 ±0.09 | 13.69 ±0.53 | 29.01 ±0.55 ✗ | 55.92 ±0.31 ✗ |
| B-native · Rust + wgpu | 20M | 0.34 ±0.03 | 0.64 ±0.00 | 1.51 ±0.00 | 2.99 ±0.00 | 5.97 ±0.01 |
| C · omxcode (Mojo) | 20M | 4.23 ±0.90 | 5.54 ±1.21 | 5.47 ±1.15 | 6.08 ±0.20 | 7.21 ±1.17 |

A-cpu at 100k: 3.76 ms ±0.31 (holds 60 fps; p95 6.70 ms).

How each row's frame ms is measured:

- A · JS + WebGPU: window wall time to the last frame's GPU completion / 600 (&await=0, vsync/limiter off).
- A-cpu · plain JS (CPU): mean rAF interval, vsync/limiter off.
- B-wasm · JS + Rust/wasm: mean rAF interval, vsync/limiter off (headless).
- B-native · Rust + wgpu: mean loop interval (offscreen, two frames in flight).
- C · omxcode (Mojo): mean canvas frame interval, GDK_DEBUG=no-vsync (GTK's frame clock uncapped).

## Separately (labelled; not comparable across rows unless the label matches)

| Row | N | p95 interval | step ms | step is | GPU frame ms | CPU encode ms | readback ms | cold start ms | peak PSS MB | peak RSS MB |
|---|---|---|---|---|---|---|---|---|---|---|
| A | 1M | 1.30 | 0.040 | GPU timestamp-query around the step pass | 0.163 | 0.100 | – | 1196 | 549 | 1321 |
| A | 2M | 1.30 | 0.078 | GPU timestamp-query around the step pass | 0.299 | 0.100 | – | 1226 | 567 | 1351 |
| A | 5M | 1.30 | 0.191 | GPU timestamp-query around the step pass | 0.712 | 0.100 | – | 1248 | 613 | 1433 |
| A | 10M | 1.80 | 0.378 | GPU timestamp-query around the step pass | 1.402 | 0.100 | – | 1373 | 722 | 1686 |
| A | 20M | 2.30 | 0.770 | GPU timestamp-query around the step pass | 2.754 | 0.100 | – | 1614 | 969 | 2183 |
| A-cpu | 100k | 6.70 | 0.400 | CPU (plain JS, main thread) | – | – | – | 997 | 582 | 1333 |
| A-cpu | 1M | 23.70 | 3.500 | CPU (plain JS, main thread) | – | – | – | 994 | 579 | 1318 |
| A-cpu | 2M | 37.20 | 7.000 | CPU (plain JS, main thread) | – | – | – | 1066 | 593 | 1345 |
| A-cpu | 5M | 72.30 | 17.800 | CPU (plain JS, main thread) | – | – | – | 1164 | 638 | 1380 |
| A-cpu | 10M | 134.80 | 36.100 | CPU (plain JS, main thread) | – | – | – | 1317 | 709 | 1456 |
| A-cpu | 20M | 282.60 | 73.100 | CPU (plain JS, main thread) | – | – | – | 1494 | 919 | 1606 |
| B-wasm | 1M | 2.48 | 1.180 | CPU: wasm step + pack, 22 threads (wall) | – | 1.680 | – | 1030 | 846 | 1814 |
| B-wasm | 2M | 4.92 | 2.155 | CPU: wasm step + pack, 22 threads (wall) | – | 3.245 | – | 1024 | 912 | 1978 |
| B-wasm | 5M | 16.50 | 7.580 | CPU: wasm step + pack, 22 threads (wall) | – | 12.540 | – | 1128 | 1141 | 2256 |
| B-wasm | 10M | 32.97 | 16.865 | CPU: wasm step + pack, 24 threads (wall) | – | 27.405 | – | 1267 | 1278 | 2376 |
| B-wasm | 20M | 65.59 | 34.092 | CPU: wasm step + pack, 24 threads (wall) | – | 53.070 | – | 1481 | 1533 | 2637 |
| B-native | 1M | 0.65 | 0.037 | GPU timestamp queries around the compute pass | – | – | – | 266 | 179 | 192 |
| B-native | 2M | 1.26 | 0.073 | GPU timestamp queries around the compute pass | – | – | – | 259 | 181 | 192 |
| B-native | 5M | 3.09 | 0.184 | GPU timestamp queries around the compute pass | – | – | – | 294 | 181 | 225 |
| B-native | 10M | 6.18 | 0.369 | GPU timestamp queries around the compute pass | – | – | – | 314 | 181 | 251 |
| B-native | 20M | 12.32 | 0.771 | GPU timestamp queries around the compute pass | – | – | – | 373 | 329 | 340 |
| C | 1M | 5.55 | 0.042 | GPU step, timed on a separate pass (each part waited for on its own) | 0.198 | – | 0.419 | 329 | 244 | 264 |
| C | 2M | 7.80 | 0.080 | GPU step, timed on a separate pass (each part waited for on its own) | 0.304 | – | 0.418 | 338 | 260 | 280 |
| C | 5M | 7.60 | 0.194 | GPU step, timed on a separate pass (each part waited for on its own) | 0.633 | – | 0.418 | 354 | 307 | 327 |
| C | 10M | 8.54 | 0.383 | GPU step, timed on a separate pass (each part waited for on its own) | 1.156 | – | 0.418 | 389 | 383 | 402 |
| C | 20M | 9.79 | 0.762 | GPU step, timed on a separate pass (each part waited for on its own) | 2.235 | – | 0.418 | 461 | 535 | 554 |

GPU frame ms: A = GPU timestamps from the step's start to the tone pass's end; C = its timed step + splat (the separate pass). CPU encode: A = JS encode + submit; B-wasm = step + pack + upload + draw call on the CPU. C's work per frame (step + splat + readback, one wait) is in results.json (work_ms).

B-wasm thread probe (one run each, frame ms; the better count was used): 1M: {'24': 2.312, '22': 2.129}; 2M: {'24': 4.026, '22': 3.87}; 5M: {'24': 13.856, '22': 13.829}; 10M: {'24': 28.702, '22': 28.943}; 20M: {'24': 55.568, '22': 58.708}

## Code and effort (counted by scripts/particles_bench.py, not by hand)

| Build | lines of code | files | languages | build steps | toolchains to install |
|---|---|---|---|---|---|
| A | 522 | 8 | CSS, HTML, JavaScript, Python, WGSL | 2 | Python (a static server); Chromium with WebGPU |
| A-cpu | 243 | 3 | CSS, HTML, JavaScript, Python | 2 | Python (a static server); Chromium |
| B (both apps: wasm and native) | 1051 | 13 | Bash, CSS, GLSL, HTML, JavaScript, Python, Rust, TOML, WGSL | 10 | pixi (installs the rest); Rust (rustc + cargo), the wasm32 target and rust-src (build-std for wasm threads); wasm-bindgen-cli; binaryen (wasm-opt); Python (a static server); Chromium |
| B-wasm | 374 | 10 | Bash, CSS, GLSL, HTML, JavaScript, Python, Rust, TOML | 8 | pixi (installs the rest); Rust (rustc + cargo), the wasm32 target and rust-src (build-std for wasm threads); wasm-bindgen-cli; binaryen (wasm-opt); Python (a static server); Chromium |
| B-native | 771 | 6 | Rust, TOML, WGSL | 3 | pixi (installs the rest); Rust (rustc + cargo) |
| C | 257 | 1 | Mojo | 3 | pixi (installs the rest); Mojo 1.1 + MAX 26.6 (through pixi) |

Lines exclude blank and comment-only lines (and docstrings). B-wasm and B-native share the sim crate and the workspace Cargo.toml (counted in both); B is the two apps together. C counts the app (examples/particles) only: mojoui (the framework) is a library, as WebGPU, wgpu, wasm-bindgen and rayon are. But this goal also added 1761 lines to the framework and its tests for C (mojoui/app.mojo +5, mojoui/canvas.mojo +12, mojoui/gpu.mojo +460, mojoui/hosts/gtk.mojo +206, mojoui/hosts/web.py +6, mojoui/look.mojo +1, mojoui/present.mojo +626, mojoui/shared.mojo +8, tests/test_canvas_blend.mojo +152, tests/test_canvas_present.mojo +153, tests/test_pointcloud_step.mojo +132; added lines that aren't blank or a comment, git diff from 858eff5): PointCloud's step, splat and readback, reusable by any app. Build steps, clean checkout to running:

- A: `python showcase/js-webgpu/serve.py  (any static server)` → `open http://127.0.0.1:<port>/index.html in Chromium (WebGPU)`
- A-cpu: `python showcase/js-webgpu/serve.py  (any static server)` → `open http://127.0.0.1:<port>/index.html?mode=cpu`
- B: `pixi install  (Rust 1.99, wasm32 std, rust-src, wasm-bindgen-cli, binaryen)` → `RUSTC_BOOTSTRAP=1 CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_RUSTFLAGS='-C target-feature=+atomics,+bulk-memory,+mutable-globals,+simd128 -C link-arg=--shared-memory -C link-arg=--import-memory -C link-arg=--max-memory=4294967296 -C link-arg=--export=__wasm_init_tls -C link-arg=--export=__tls_size -C link-arg=--export=__tls_align -C link-arg=--export=__tls_base' cargo build --release --target wasm32-unknown-unknown -p particles-wasm -Z build-std=panic_abort,std` → `wasm-bindgen --target web --out-dir "$OUT/pkg" target/wasm32-unknown-unknown/release/particles_wasm.wasm` → `sed -i "s|import('../../..')|import('../../../particles_wasm.js')|" "$OUT"/pkg/snippets/wasm-bindgen-rayon-*/src/workerHelpers.js` → `wasm-opt -O3 --enable-threads --enable-bulk-memory --enable-simd --enable-mutable-globals --enable-nontrapping-float-to-int --enable-sign-ext "$OUT/pkg/particles_wasm_bg.wasm" -o "$OUT/pkg/particles_wasm_bg.wasm"` → `cp web/index.html web/main.js web/worker.js "$OUT/"` → `cargo build --release -p particles-native` → `python showcase/js-rust/serve.py  (COOP/COEP headers, for wasm threads)` → `open http://127.0.0.1:<port>/index.html` → `target/release/particles-native  (the native row)`
- B-wasm: `pixi install  (Rust 1.99, wasm32 std, rust-src, wasm-bindgen-cli, binaryen)` → `RUSTC_BOOTSTRAP=1 CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_RUSTFLAGS='-C target-feature=+atomics,+bulk-memory,+mutable-globals,+simd128 -C link-arg=--shared-memory -C link-arg=--import-memory -C link-arg=--max-memory=4294967296 -C link-arg=--export=__wasm_init_tls -C link-arg=--export=__tls_size -C link-arg=--export=__tls_align -C link-arg=--export=__tls_base' cargo build --release --target wasm32-unknown-unknown -p particles-wasm -Z build-std=panic_abort,std` → `wasm-bindgen --target web --out-dir "$OUT/pkg" target/wasm32-unknown-unknown/release/particles_wasm.wasm` → `sed -i "s|import('../../..')|import('../../../particles_wasm.js')|" "$OUT"/pkg/snippets/wasm-bindgen-rayon-*/src/workerHelpers.js` → `wasm-opt -O3 --enable-threads --enable-bulk-memory --enable-simd --enable-mutable-globals --enable-nontrapping-float-to-int --enable-sign-ext "$OUT/pkg/particles_wasm_bg.wasm" -o "$OUT/pkg/particles_wasm_bg.wasm"` → `cp web/index.html web/main.js web/worker.js "$OUT/"` → `python showcase/js-rust/serve.py  (COOP/COEP headers, for wasm threads)` → `open http://127.0.0.1:<port>/index.html`
- B-native: `pixi install  (Rust 1.99)` → `cargo build --release -p particles-native` → `target/release/particles-native`
- C: `pixi install  (Mojo 1.1, MAX 26.6)` → `scripts/build.sh particles linux` → `build/particles/linux/particles`

## Caveats (every one)

- A draws with an atomic compute rasteriser (two u32 atomics per on-screen particle): it loads the pixel's count first and skips both atomics once the pixel is saturated (past the tone map's white for the dimmest channel), as C does; its look is a tone map, not the SPEC's clamp. ?render=points (hardware point blending) exists and is not measured here.
- C's splat is the framework's generic PointCloud.splat: two atomics per particle since goal 36b M6c (red and green packed in one 64-bit atomic, blue in a 32-bit one; goal 36 measured three u32 atomics), each channel skipped once its sum is saturated (an atomic load first; exact: the GPU still matches the CPU path). That skip was modelled on A's (a fair-play fix after review); A then got C's load-first form, so both skip the same way.
- B draws with hardware blending (WebGL2 points / wgpu point list, additive). B-wasm steps on the CPU (wasm SIMD + a rayon pool in a worker) and uploads one packed u32 per particle to the GPU every frame.
- C copies its finished picture (1280 × 720 × 4 bytes) from the GPU to the CPU every frame and hands it to GTK as a texture here: on Xvfb there is no GL, so the framework's zero-copy path (goal 36b M6) reports it can't be used and falls back to this copy. readback ms is that copy alone, measured on the separate pass. On a real desktop there is no readback (results-desktop.md).
- C's step ms comes from a separate timed pass after the measured frames (Mojo 1.1's DeviceEvent has no elapsed time; the frame loop waits for the GPU once a frame, so it can't split step from splat).
- C runs in the real GTK host on Xvfb, where GTK composites with its cairo (software) renderer; on a real display GTK uses its GL renderer. A and A-cpu run in Chromium on the same Xvfb display (ANGLE/Vulkan, no Vulkan surface).
- C's frame clock is capped at 60 fps by GTK unless GDK_DEBUG=no-vsync (verified: 16.7 ms at every N with the cap, 4.8 ms at 1M without), so its headline is measured uncapped.
- A's headline comes from &await=0 with the queue drained at the warm-up's end: Chromium's onSubmittedWorkDone round trip (5-9 ms here) would otherwise dominate, and the rAF interval alone runs ahead of the GPU. So A's p95 is a rAF interval that runs ahead of the GPU: for A the p95 test never binds, the throughput figure does.
- A's CPU encode reads 0.100 ms at every size: Chromium clamps performance.now() to 100 µs on a page that isn't cross-origin isolated, so it means 'under about 0.1 ms'.
- B-wasm's thread count was chosen by its own probe (every core, and cores - 2, one run each; the faster used).
- B-native renders offscreen only (NVIDIA's Vulkan driver can't present to Xvfb), two frames in flight: it never presents to a window here, so its frame, cold start and memory have no window or swapchain in them.
- B-wasm runs in headless Chromium (no Xvfb), WebGL2 through ANGLE on NVIDIA's EGL (OpenGL), the fastest path found.
- A-cpu is single-threaded by design (plain JS on the main thread, the 'JS alone' baseline); it uses no GPU for the step, and Chromium composites its canvas.
- Peak memory is the PSS of the launched process tree (Chromium's processes, or the one native process), from smaps_rollup every 100 ms: a page shared by several processes counts once in all. RSS (every 20 ms) is in results.json too; it counts a shared page once per process, which inflates the multi-process browser rows. GPU memory is not included. C keeps a CPU copy of all points (16 bytes each) by design of PointCloud.
- Cold start includes each runtime's own start: Chromium's for A, A-cpu and B-wasm; the GPU driver's for all.
- The machine has two RTX 3090s; each runtime picks its own (all report an NVIDIA GeForce RTX 3090). Each run's 1-minute load and the GPU's compute apps at its start are in results.json.
