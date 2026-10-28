# Goal 36 M4 · the particle field, measured

Every run passed the quiet gate: 1-minute load < 2.0 and no other process on the GPU (compute apps over 16 MiB; idle desktop clients hold 6 MiB); waited 3722 s in all.

Commit `c3a9813`, sources sha256 `f6c6a582fb13`, 2026-10-28 02:43; 24 cores, NVIDIA GeForce RTX 3090, 610.57.04, NVIDIA GeForce RTX 3090, 610.57.04.
Protocol: scripts/particles_bench.py (docstring): 60 warm-up + 600 measured frames, 3 runs, median of the runs (± spread = max - min).

## Headline: frame ms (throughput, vsync off) and the largest N at 60 fps

Holds 60 fps = frame ms ≤ 16.7 and the 95th-percentile frame interval ≤ 20 ms.

| Row | largest N at 60 fps | 1M | 2M | 5M | 10M | 20M |
|---|---|---|---|---|---|---|
| A · JS + WebGPU | 20M | 1.33 ±0.01 | 1.38 ±0.09 | 1.39 ±0.06 | 1.51 ±0.05 | 2.67 ±0.00 |
| A-cpu · plain JS (CPU) | 100k | 15.14 ±1.17 ✗ | 26.75 ±2.73 ✗ | 58.11 ±0.18 ✗ | 112.43 ±0.81 ✗ | 220.34 ±1.69 ✗ |
| B-wasm · JS + Rust/wasm | 5M | 2.05 ±0.01 | 3.76 ±0.13 | 13.56 ±0.10 | 29.31 ±1.00 ✗ | 55.70 ±1.77 ✗ |
| B-native · Rust + wgpu | 20M | 0.34 ±0.02 | 0.64 ±0.00 | 1.51 ±0.00 | 2.99 ±0.01 | 5.96 ±0.01 |
| C · omxcode (Mojo) | 20M | 5.21 ±0.39 | 5.21 ±0.29 | 4.60 ±1.06 | 5.26 ±1.09 | 6.77 ±1.23 |

A-cpu at 100k: 3.87 ms ±0.70 (holds 60 fps; p95 6.20 ms).

How each row's frame ms is measured:

- A · JS + WebGPU: window wall time to the last frame's GPU completion / 600 (&await=0, vsync/limiter off).
- A-cpu · plain JS (CPU): mean rAF interval, vsync/limiter off.
- B-wasm · JS + Rust/wasm: mean rAF interval, vsync/limiter off (headless).
- B-native · Rust + wgpu: mean loop interval (offscreen, two frames in flight).
- C · omxcode (Mojo): mean canvas frame interval, GDK_DEBUG=no-vsync (GTK's frame clock uncapped).

## Separately (labelled; not comparable across rows unless the label matches)

| Row | N | p95 interval | step ms | step is | GPU frame ms | CPU encode ms | readback ms | cold start ms | peak RSS MB |
|---|---|---|---|---|---|---|---|---|---|
| A | 1M | 1.30 | 0.040 | GPU timestamp-query around the step pass | 0.142 | 0.100 | – | 1224 | 1303 |
| A | 2M | 1.30 | 0.078 | GPU timestamp-query around the step pass | 0.251 | 0.100 | – | 1245 | 1332 |
| A | 5M | 1.30 | 0.190 | GPU timestamp-query around the step pass | 0.586 | 0.100 | – | 1360 | 1434 |
| A | 10M | 1.40 | 0.379 | GPU timestamp-query around the step pass | 1.141 | 0.100 | – | 1440 | 1693 |
| A | 20M | 2.10 | 0.773 | GPU timestamp-query around the step pass | 2.295 | 0.100 | – | 1705 | 2163 |
| A-cpu | 100k | 6.20 | 0.400 | CPU (plain JS, main thread) | – | – | – | 979 | 1324 |
| A-cpu | 1M | 25.40 | 3.600 | CPU (plain JS, main thread) | – | – | – | 1069 | 1312 |
| A-cpu | 2M | 39.70 | 7.400 | CPU (plain JS, main thread) | – | – | – | 1104 | 1334 |
| A-cpu | 5M | 73.00 | 17.900 | CPU (plain JS, main thread) | – | – | – | 1103 | 1377 |
| A-cpu | 10M | 133.80 | 35.900 | CPU (plain JS, main thread) | – | – | – | 1203 | 1452 |
| A-cpu | 20M | 251.70 | 71.800 | CPU (plain JS, main thread) | – | – | – | 1351 | 1603 |
| B-wasm | 1M | 2.40 | 1.150 | CPU: wasm step + pack, 22 threads (wall) | – | 1.605 | – | 1017 | 1816 |
| B-wasm | 2M | 4.92 | 2.173 | CPU: wasm step + pack, 22 threads (wall) | – | 3.202 | – | 1021 | 1972 |
| B-wasm | 5M | 16.27 | 7.555 | CPU: wasm step + pack, 22 threads (wall) | – | 12.502 | – | 1127 | 2255 |
| B-wasm | 10M | 32.82 | 16.840 | CPU: wasm step + pack, 24 threads (wall) | – | 28.233 | – | 1231 | 2378 |
| B-wasm | 20M | 64.89 | 34.060 | CPU: wasm step + pack, 24 threads (wall) | – | 53.052 | – | 1473 | 2628 |
| B-native | 1M | 0.65 | 0.037 | GPU timestamp queries around the compute pass | – | – | – | 268 | 192 |
| B-native | 2M | 1.26 | 0.073 | GPU timestamp queries around the compute pass | – | – | – | 266 | 192 |
| B-native | 5M | 3.07 | 0.184 | GPU timestamp queries around the compute pass | – | – | – | 290 | 225 |
| B-native | 10M | 6.17 | 0.369 | GPU timestamp queries around the compute pass | – | – | – | 311 | 259 |
| B-native | 20M | 12.30 | 0.771 | GPU timestamp queries around the compute pass | – | – | – | 380 | 340 |
| C | 1M | 7.42 | 0.042 | GPU step, timed on a separate pass (each part waited for on its own) | 0.218 | – | 0.418 | 328 | 264 |
| C | 2M | 7.24 | 0.080 | GPU step, timed on a separate pass (each part waited for on its own) | 0.366 | – | 0.419 | 335 | 280 |
| C | 5M | 5.55 | 0.194 | GPU step, timed on a separate pass (each part waited for on its own) | 0.751 | – | 0.418 | 349 | 327 |
| C | 10M | 6.56 | 0.383 | GPU step, timed on a separate pass (each part waited for on its own) | 1.445 | – | 0.418 | 381 | 403 |
| C | 20M | 8.57 | 0.763 | GPU step, timed on a separate pass (each part waited for on its own) | 2.820 | – | 0.418 | 454 | 555 |

GPU frame ms: A = GPU timestamps from the step's start to the tone pass's end; C = its timed step + splat (the separate pass). CPU encode: A = JS encode + submit; B-wasm = step + pack + upload + draw call on the CPU. C's work per frame (step + splat + readback, one wait) is in results.json (work_ms).

B-wasm thread probe (one run each, frame ms; the better count was used): 1M: {'24': 2.125, '22': 2.083}; 2M: {'24': 3.837, '22': 3.772}; 5M: {'24': 13.807, '22': 13.707}; 10M: {'24': 29.453, '22': 29.528}; 20M: {'24': 55.627, '22': 57.207}

## Code and effort (counted by scripts/particles_bench.py, not by hand)

| Build | lines of code | files | languages | build steps | toolchains to install |
|---|---|---|---|---|---|
| A | 521 | 8 | CSS, HTML, JavaScript, Python, WGSL | 2 | Python (a static server); Chromium with WebGPU |
| A-cpu | 243 | 3 | CSS, HTML, JavaScript, Python | 2 | Python (a static server); Chromium |
| B | 1051 | 13 | Bash, CSS, GLSL, HTML, JavaScript, Python, Rust, TOML, WGSL | 10 | pixi (installs the rest); Rust (rustc + cargo), the wasm32 target and rust-src (build-std for wasm threads); wasm-bindgen-cli; binaryen (wasm-opt); Python (a static server); Chromium |
| C | 257 | 1 | Mojo | 3 | pixi (installs the rest); Mojo 1.1 + MAX 26.6 (through pixi) |

Lines exclude blank and comment-only lines (and docstrings). C counts the app (examples/particles) only: mojoui (the framework, including PointCloud's step/splat kernels) is a library, as WebGPU, wgpu, wasm-bindgen and rayon are. Build steps, clean checkout to running:

- A: `python showcase/js-webgpu/serve.py  (any static server)` → `open http://127.0.0.1:<port>/index.html in Chromium (WebGPU)`
- A-cpu: `python showcase/js-webgpu/serve.py  (any static server)` → `open http://127.0.0.1:<port>/index.html?mode=cpu`
- B: `pixi install  (Rust 1.99, wasm32 std, rust-src, wasm-bindgen-cli, binaryen)` → `RUSTC_BOOTSTRAP=1 CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_RUSTFLAGS='-C target-feature=+atomics,+bulk-memory,+mutable-globals,+simd128 -C link-arg=--shared-memory -C link-arg=--import-memory -C link-arg=--max-memory=4294967296 -C link-arg=--export=__wasm_init_tls -C link-arg=--export=__tls_size -C link-arg=--export=__tls_align -C link-arg=--export=__tls_base' cargo build --release --target wasm32-unknown-unknown -p particles-wasm -Z build-std=panic_abort,std` → `wasm-bindgen --target web --out-dir "$OUT/pkg" target/wasm32-unknown-unknown/release/particles_wasm.wasm` → `sed -i "s|import('../../..')|import('../../../particles_wasm.js')|" "$OUT"/pkg/snippets/wasm-bindgen-rayon-*/src/workerHelpers.js` → `wasm-opt -O3 --enable-threads --enable-bulk-memory --enable-simd --enable-mutable-globals --enable-nontrapping-float-to-int --enable-sign-ext "$OUT/pkg/particles_wasm_bg.wasm" -o "$OUT/pkg/particles_wasm_bg.wasm"` → `cp web/index.html web/main.js web/worker.js "$OUT/"` → `cargo build --release -p particles-native` → `python showcase/js-rust/serve.py  (COOP/COEP headers, for wasm threads)` → `open http://127.0.0.1:<port>/index.html` → `target/release/particles-native  (the native row)`
- C: `pixi install  (Mojo 1.1, MAX 26.6)` → `scripts/build.sh particles linux` → `build/particles/linux/particles`

## Caveats (every one)

- A draws with an atomic compute rasteriser (two u32 atomics per on-screen particle) and skips the second atomic once a pixel is saturated (its count is past the tone map's white for the dimmest channel); its look is a tone map, not the SPEC's clamp. ?render=points (hardware point blending) exists and is about half as fast at 20M.
- C's splat is the framework's generic PointCloud.splat: three u32 atomics per particle (r, g, b), each skipped once that channel's sum is saturated (an atomic load first; exact: the GPU still matches the CPU path).
- B draws with hardware blending (WebGL2 points / wgpu point list, additive). B-wasm steps on the CPU (wasm SIMD + a rayon pool in a worker) and uploads one packed u32 per particle to the GPU every frame.
- C copies its finished picture (1280 × 720 × 4 bytes) from the GPU to the CPU every frame and hands it to GTK as a texture: that is the framework's Canvas path today. readback ms is that copy alone, measured on the separate pass.
- C's step ms comes from a separate timed pass after the measured frames (Mojo 1.1's DeviceEvent has no elapsed time; the frame loop waits for the GPU once a frame, so it can't split step from splat).
- C runs in the real GTK host on Xvfb, where GTK composites with its cairo (software) renderer; on a real display GTK uses its GL renderer. A and A-cpu run in Chromium on the same Xvfb display (ANGLE/Vulkan, no Vulkan surface).
- C's frame clock is capped at 60 fps by GTK unless GDK_DEBUG=no-vsync (verified: 16.7 ms at every N with the cap, 4.8 ms at 1M without), so its headline is measured uncapped.
- A's headline comes from &await=0 with the queue drained at the warm-up's end: Chromium's onSubmittedWorkDone round trip (5-9 ms here) would otherwise dominate, and the rAF interval alone runs ahead of the GPU.
- B-native renders offscreen only (NVIDIA's Vulkan driver can't present to Xvfb), two frames in flight: it never presents to a window here.
- B-wasm runs in headless Chromium (no Xvfb), WebGL2 through ANGLE on NVIDIA's EGL (OpenGL), the fastest path found.
- A-cpu is single-threaded by design (plain JS on the main thread, the 'JS alone' baseline); it uses no GPU for the step, and Chromium composites its canvas.
- Peak memory is the RSS of the launched process tree (Chromium's processes, or the one native process), sampled every 20 ms; GPU memory is not included. C keeps a CPU copy of all points (16 bytes each) by design of PointCloud.
- Cold start includes each runtime's own start: Chromium's for A, A-cpu and B-wasm; the GPU driver's for all.
- The machine has two RTX 3090s; each runtime picks its own (all report an NVIDIA GeForce RTX 3090). Each run's 1-minute load and the GPU's compute apps at its start are in results.json.
