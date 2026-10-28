# Goal 36 M4 · the particle field, measured

Every run passed the quiet gate: 1-minute load < 2.0 and no other process on the GPU (compute apps over 16 MiB; idle desktop clients hold 6 MiB); waited 1740 s in all.

Commit `7680e98`, sources sha256 `041657ae7d8a`, 2026-10-28 03:48; 24 cores, NVIDIA GeForce RTX 3090, 610.57.04, NVIDIA GeForce RTX 3090, 610.57.04.
Protocol: scripts/particles_bench.py (docstring): 60 warm-up + 600 measured frames, 3 runs, each run's frame ms is the mean frame interval (throughput); the table shows the median of the runs (± spread = max - min).

## Headline: frame ms (throughput, vsync off) and the largest N at 60 fps

Holds 60 fps = frame ms ≤ 16.7 and the 95th-percentile frame interval ≤ 20 ms.

| Row | largest N at 60 fps | 1M | 2M | 5M | 10M | 20M |
|---|---|---|---|---|---|---|
| A · JS + WebGPU | 20M | 1.29 ±0.03 | 1.31 ±0.10 | 1.35 ±0.09 | 1.70 ±0.03 | 3.26 ±0.01 |
| A-cpu · plain JS (CPU) | 100k | 14.26 ±0.07 ✗ | 25.16 ±0.30 ✗ | 57.46 ±0.28 ✗ | 111.23 ±0.40 ✗ | 220.01 ±0.40 ✗ |
| B-wasm · JS + Rust/wasm | 5M | 2.06 ±0.03 | 3.75 ±0.03 | 13.65 ±0.13 | 28.58 ±0.79 ✗ | 55.72 ±2.02 ✗ |
| B-native · Rust + wgpu | 20M | 0.34 ±0.03 | 0.63 ±0.00 | 1.51 ±0.00 | 2.99 ±0.01 | 5.97 ±0.01 |
| C · omxcode (Mojo) | 20M | 5.33 ±0.11 | 4.44 ±0.90 | 5.74 ±1.14 | 6.11 ±1.22 | 7.63 ±1.17 |

A-cpu at 100k: 3.55 ms ±0.33 (holds 60 fps; p95 5.40 ms).

How each row's frame ms is measured:

- A · JS + WebGPU: window wall time to the last frame's GPU completion / 600 (&await=0, vsync/limiter off).
- A-cpu · plain JS (CPU): mean rAF interval, vsync/limiter off.
- B-wasm · JS + Rust/wasm: mean rAF interval, vsync/limiter off (headless).
- B-native · Rust + wgpu: mean loop interval (offscreen, two frames in flight).
- C · omxcode (Mojo): mean canvas frame interval, GDK_DEBUG=no-vsync (GTK's frame clock uncapped).

## Separately (labelled; not comparable across rows unless the label matches)

| Row | N | p95 interval | step ms | step is | GPU frame ms | CPU encode ms | readback ms | cold start ms | peak PSS MB | peak RSS MB |
|---|---|---|---|---|---|---|---|---|---|---|
| A | 1M | 1.20 | 0.040 | GPU timestamp-query around the step pass | 0.163 | 0.100 | – | 1197 | 620 | 1309 |
| A | 2M | 1.20 | 0.078 | GPU timestamp-query around the step pass | 0.297 | 0.100 | – | 1225 | 644 | 1345 |
| A | 5M | 1.30 | 0.191 | GPU timestamp-query around the step pass | 0.708 | 0.100 | – | 1258 | 694 | 1454 |
| A | 10M | 1.90 | 0.378 | GPU timestamp-query around the step pass | 1.378 | 0.100 | – | 1388 | 867 | 1624 |
| A | 20M | 2.30 | 0.770 | GPU timestamp-query around the step pass | 2.753 | 0.100 | – | 1612 | 1182 | 2046 |
| A-cpu | 100k | 5.40 | 0.400 | CPU (plain JS, main thread) | – | – | – | 972 | 661 | 1339 |
| A-cpu | 1M | 23.30 | 3.500 | CPU (plain JS, main thread) | – | – | – | 1026 | 652 | 1316 |
| A-cpu | 2M | 36.80 | 7.000 | CPU (plain JS, main thread) | – | – | – | 1039 | 674 | 1344 |
| A-cpu | 5M | 72.80 | 17.700 | CPU (plain JS, main thread) | – | – | – | 1095 | 711 | 1373 |
| A-cpu | 10M | 132.40 | 35.700 | CPU (plain JS, main thread) | – | – | – | 1191 | 794 | 1456 |
| A-cpu | 20M | 249.50 | 71.700 | CPU (plain JS, main thread) | – | – | – | 1347 | 942 | 1610 |
| B-wasm | 1M | 2.44 | 1.158 | CPU: wasm step + pack, 22 threads (wall) | – | 1.632 | – | 1008 | 856 | 1798 |
| B-wasm | 2M | 4.87 | 2.170 | CPU: wasm step + pack, 22 threads (wall) | – | 3.175 | – | 1029 | 929 | 1980 |
| B-wasm | 5M | 16.58 | 7.660 | CPU: wasm step + pack, 24 threads (wall) | – | 12.562 | – | 1126 | 1154 | 2242 |
| B-wasm | 10M | 32.33 | 16.847 | CPU: wasm step + pack, 24 threads (wall) | – | 27.105 | – | 1241 | 1287 | 2374 |
| B-wasm | 20M | 64.98 | 34.087 | CPU: wasm step + pack, 24 threads (wall) | – | 53.048 | – | 1473 | 1553 | 2639 |
| B-native | 1M | 0.65 | 0.037 | GPU timestamp queries around the compute pass | – | – | – | 257 | 171 | 192 |
| B-native | 2M | 1.26 | 0.073 | GPU timestamp queries around the compute pass | – | – | – | 262 | 173 | 192 |
| B-native | 5M | 3.07 | 0.184 | GPU timestamp queries around the compute pass | – | – | – | 295 | 173 | 225 |
| B-native | 10M | 6.16 | 0.369 | GPU timestamp queries around the compute pass | – | – | – | 320 | 173 | 244 |
| B-native | 20M | 12.32 | 0.771 | GPU timestamp queries around the compute pass | – | – | – | 373 | 320 | 340 |
| C | 1M | 7.62 | 0.042 | GPU step, timed on a separate pass (each part waited for on its own) | 0.219 | – | 0.419 | 325 | 236 | 264 |
| C | 2M | 5.57 | 0.080 | GPU step, timed on a separate pass (each part waited for on its own) | 0.363 | – | 0.418 | 341 | 252 | 280 |
| C | 5M | 7.86 | 0.194 | GPU step, timed on a separate pass (each part waited for on its own) | 0.753 | – | 0.418 | 358 | 298 | 327 |
| C | 10M | 8.39 | 0.383 | GPU step, timed on a separate pass (each part waited for on its own) | 1.445 | – | 0.418 | 386 | 374 | 403 |
| C | 20M | 10.46 | 0.763 | GPU step, timed on a separate pass (each part waited for on its own) | 2.811 | – | 0.418 | 454 | 526 | 555 |

GPU frame ms: A = GPU timestamps from the step's start to the tone pass's end; C = its timed step + splat (the separate pass). CPU encode: A = JS encode + submit; B-wasm = step + pack + upload + draw call on the CPU. C's work per frame (step + splat + readback, one wait) is in results.json (work_ms).

B-wasm thread probe (one run each, frame ms; the better count was used): 1M: {'24': 2.116, '22': 2.059}; 2M: {'24': 3.868, '22': 3.764}; 5M: {'24': 13.462, '22': 13.511}; 10M: {'24': 28.502, '22': 29.088}; 20M: {'24': 55.467, '22': 57.381}

## Code and effort (counted by scripts/particles_bench.py, not by hand)

| Build | lines of code | files | languages | build steps | toolchains to install |
|---|---|---|---|---|---|
| A | 522 | 8 | CSS, HTML, JavaScript, Python, WGSL | 2 | Python (a static server); Chromium with WebGPU |
| A-cpu | 243 | 3 | CSS, HTML, JavaScript, Python | 2 | Python (a static server); Chromium |
| B (both apps: wasm and native) | 1051 | 13 | Bash, CSS, GLSL, HTML, JavaScript, Python, Rust, TOML, WGSL | 10 | pixi (installs the rest); Rust (rustc + cargo), the wasm32 target and rust-src (build-std for wasm threads); wasm-bindgen-cli; binaryen (wasm-opt); Python (a static server); Chromium |
| B-wasm | 374 | 10 | Bash, CSS, GLSL, HTML, JavaScript, Python, Rust, TOML | 8 | pixi (installs the rest); Rust (rustc + cargo), the wasm32 target and rust-src (build-std for wasm threads); wasm-bindgen-cli; binaryen (wasm-opt); Python (a static server); Chromium |
| B-native | 771 | 6 | Rust, TOML, WGSL | 3 | pixi (installs the rest); Rust (rustc + cargo) |
| C | 257 | 1 | Mojo | 3 | pixi (installs the rest); Mojo 1.1 + MAX 26.6 (through pixi) |

Lines exclude blank and comment-only lines (and docstrings). B-wasm and B-native share the sim crate and the workspace Cargo.toml (counted in both); B is the two apps together. C counts the app (examples/particles) only: mojoui (the framework) is a library, as WebGPU, wgpu, wasm-bindgen and rayon are. But this goal also added 252 lines to the framework and its tests for C (mojoui/gpu.mojo +164, tests/test_pointcloud_step.mojo +88; added lines that aren't blank or a comment, git diff from 858eff5): PointCloud's step, splat and readback, reusable by any app. Build steps, clean checkout to running:

- A: `python showcase/js-webgpu/serve.py  (any static server)` → `open http://127.0.0.1:<port>/index.html in Chromium (WebGPU)`
- A-cpu: `python showcase/js-webgpu/serve.py  (any static server)` → `open http://127.0.0.1:<port>/index.html?mode=cpu`
- B: `pixi install  (Rust 1.99, wasm32 std, rust-src, wasm-bindgen-cli, binaryen)` → `RUSTC_BOOTSTRAP=1 CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_RUSTFLAGS='-C target-feature=+atomics,+bulk-memory,+mutable-globals,+simd128 -C link-arg=--shared-memory -C link-arg=--import-memory -C link-arg=--max-memory=4294967296 -C link-arg=--export=__wasm_init_tls -C link-arg=--export=__tls_size -C link-arg=--export=__tls_align -C link-arg=--export=__tls_base' cargo build --release --target wasm32-unknown-unknown -p particles-wasm -Z build-std=panic_abort,std` → `wasm-bindgen --target web --out-dir "$OUT/pkg" target/wasm32-unknown-unknown/release/particles_wasm.wasm` → `sed -i "s|import('../../..')|import('../../../particles_wasm.js')|" "$OUT"/pkg/snippets/wasm-bindgen-rayon-*/src/workerHelpers.js` → `wasm-opt -O3 --enable-threads --enable-bulk-memory --enable-simd --enable-mutable-globals --enable-nontrapping-float-to-int --enable-sign-ext "$OUT/pkg/particles_wasm_bg.wasm" -o "$OUT/pkg/particles_wasm_bg.wasm"` → `cp web/index.html web/main.js web/worker.js "$OUT/"` → `cargo build --release -p particles-native` → `python showcase/js-rust/serve.py  (COOP/COEP headers, for wasm threads)` → `open http://127.0.0.1:<port>/index.html` → `target/release/particles-native  (the native row)`
- B-wasm: `pixi install  (Rust 1.99, wasm32 std, rust-src, wasm-bindgen-cli, binaryen)` → `RUSTC_BOOTSTRAP=1 CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_RUSTFLAGS='-C target-feature=+atomics,+bulk-memory,+mutable-globals,+simd128 -C link-arg=--shared-memory -C link-arg=--import-memory -C link-arg=--max-memory=4294967296 -C link-arg=--export=__wasm_init_tls -C link-arg=--export=__tls_size -C link-arg=--export=__tls_align -C link-arg=--export=__tls_base' cargo build --release --target wasm32-unknown-unknown -p particles-wasm -Z build-std=panic_abort,std` → `wasm-bindgen --target web --out-dir "$OUT/pkg" target/wasm32-unknown-unknown/release/particles_wasm.wasm` → `sed -i "s|import('../../..')|import('../../../particles_wasm.js')|" "$OUT"/pkg/snippets/wasm-bindgen-rayon-*/src/workerHelpers.js` → `wasm-opt -O3 --enable-threads --enable-bulk-memory --enable-simd --enable-mutable-globals --enable-nontrapping-float-to-int --enable-sign-ext "$OUT/pkg/particles_wasm_bg.wasm" -o "$OUT/pkg/particles_wasm_bg.wasm"` → `cp web/index.html web/main.js web/worker.js "$OUT/"` → `python showcase/js-rust/serve.py  (COOP/COEP headers, for wasm threads)` → `open http://127.0.0.1:<port>/index.html`
- B-native: `pixi install  (Rust 1.99)` → `cargo build --release -p particles-native` → `target/release/particles-native`
- C: `pixi install  (Mojo 1.1, MAX 26.6)` → `scripts/build.sh particles linux` → `build/particles/linux/particles`

## Caveats (every one)

- A draws with an atomic compute rasteriser (two u32 atomics per on-screen particle): it loads the pixel's count first and skips both atomics once the pixel is saturated (past the tone map's white for the dimmest channel), as C does; its look is a tone map, not the SPEC's clamp. ?render=points (hardware point blending) exists and is not measured here.
- C's splat is the framework's generic PointCloud.splat: three u32 atomics per particle (r, g, b), each skipped once that channel's sum is saturated (an atomic load first; exact: the GPU still matches the CPU path). That skip was modelled on A's (a fair-play fix after review); A then got C's load-first form, so both skip the same way.
- B draws with hardware blending (WebGL2 points / wgpu point list, additive). B-wasm steps on the CPU (wasm SIMD + a rayon pool in a worker) and uploads one packed u32 per particle to the GPU every frame.
- C copies its finished picture (1280 × 720 × 4 bytes) from the GPU to the CPU every frame and hands it to GTK as a texture: that is the framework's Canvas path today. readback ms is that copy alone, measured on the separate pass.
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
