# PROVISIONAL · Goal 36 M4 · the particle field, measured on a busy machine

**PROVISIONAL: measured without the quiet gate, while another project's builds and GPU tests ran (1-minute load up to 22.5 on 24 cores, other processes on the RTX 3090; per-row load and GPU apps in the JSON). Not the result.**

Commit `3c622d8`, sources sha256 `a2ab8835b1ff`, 2026-10-28 00:44; 24 cores, NVIDIA GeForce RTX 3090, 610.57.04, NVIDIA GeForce RTX 3090, 610.57.04.
Protocol: scripts/particles_bench.py (docstring): 60 warm-up + 600 measured frames, 3 runs, median of the runs (± spread = max - min).

## Headline: frame ms (throughput, vsync off) and the largest N at 60 fps

Holds 60 fps = frame ms ≤ 16.7 and the 95th-percentile frame interval ≤ 20 ms.

| Row | largest N at 60 fps | 1M | 2M | 5M | 10M | 20M |
|---|---|---|---|---|---|---|
| A · JS + WebGPU | 20M | 1.31 ±0.05 | 1.46 ±0.39 | 1.49 ±0.04 | 1.53 ±0.29 | 2.73 ±0.07 |
| A-cpu · plain JS (CPU) | 100k | 16.09 ±1.92 ✗ | 29.15 ±0.53 ✗ | 64.78 ±1.68 ✗ | 122.45 ±2.51 ✗ | 278.86 ±54.37 ✗ |
| B-wasm · JS + Rust/wasm | 5M | 2.62 ±0.20 | 5.06 ±0.65 | 14.75 ±0.71 | 31.87 ±1.53 ✗ | 60.41 ±4.09 ✗ |
| B-native · Rust + wgpu | 20M | 0.35 ±0.02 | 0.64 ±0.00 | 1.51 ±0.01 | 2.99 ±0.00 | 5.97 ±0.03 |
| C · omxcode (Mojo) | 20M | 5.88 ±1.26 | 5.57 ±0.60 | 5.26 ±1.25 | 6.88 ±1.43 | 7.58 ±0.90 |

A-cpu at 100k: 3.90 ms ±0.68 (holds 60 fps; p95 5.60 ms).

How each row's frame ms is measured:

- A · JS + WebGPU: window wall time to the last frame's GPU completion / 600 (&await=0, vsync/limiter off).
- A-cpu · plain JS (CPU): mean rAF interval, vsync/limiter off.
- B-wasm · JS + Rust/wasm: mean rAF interval, vsync/limiter off (headless).
- B-native · Rust + wgpu: mean loop interval (offscreen, two frames in flight).
- C · omxcode (Mojo): mean canvas frame interval, GDK_DEBUG=no-vsync (GTK's frame clock uncapped).

## Separately (labelled; not comparable across rows unless the label matches)

| Row | N | p95 interval | step ms | step is | GPU frame ms | CPU encode ms | readback ms | cold start ms | peak RSS MB |
|---|---|---|---|---|---|---|---|---|---|
| A | 1M | 1.30 | 0.040 | GPU timestamp-query around the step pass | 0.144 | 0.100 | – | 1303 | 1299 |
| A | 2M | 1.30 | 0.078 | GPU timestamp-query around the step pass | 0.254 | 0.100 | – | 1270 | 1337 |
| A | 5M | 1.40 | 0.190 | GPU timestamp-query around the step pass | 0.596 | 0.100 | – | 1403 | 1426 |
| A | 10M | 1.40 | 0.379 | GPU timestamp-query around the step pass | 1.160 | 0.100 | – | 1447 | 1689 |
| A | 20M | 2.30 | 0.788 | GPU timestamp-query around the step pass | 2.340 | 0.100 | – | 1666 | 2157 |
| A-cpu | 100k | 5.60 | 0.400 | CPU (plain JS, main thread) | – | – | – | 1023 | 1345 |
| A-cpu | 1M | 27.00 | 3.700 | CPU (plain JS, main thread) | – | – | – | 1190 | 1303 |
| A-cpu | 2M | 47.70 | 7.500 | CPU (plain JS, main thread) | – | – | – | 1137 | 1318 |
| A-cpu | 5M | 85.40 | 18.700 | CPU (plain JS, main thread) | – | – | – | 1156 | 1377 |
| A-cpu | 10M | 158.90 | 37.150 | CPU (plain JS, main thread) | – | – | – | 1238 | 1451 |
| A-cpu | 20M | 422.70 | 86.300 | CPU (plain JS, main thread) | – | – | – | 1972 | 1596 |
| B-wasm | 1M | 3.40 | 1.380 | CPU: wasm step + pack, 24 threads (wall) | – | 2.145 | – | 1095 | 1833 |
| B-wasm | 2M | 9.04 | 2.558 | CPU: wasm step + pack, 22 threads (wall) | – | 3.940 | – | 1119 | 2124 |
| B-wasm | 5M | 18.50 | 7.845 | CPU: wasm step + pack, 22 threads (wall) | – | 13.103 | – | 1190 | 2227 |
| B-wasm | 10M | 39.51 | 16.985 | CPU: wasm step + pack, 22 threads (wall) | – | 30.353 | – | 1341 | 2364 |
| B-wasm | 20M | 68.58 | 34.535 | CPU: wasm step + pack, 24 threads (wall) | – | 59.750 | – | 1512 | 2636 |
| B-native | 1M | 0.67 | 0.037 | GPU timestamp queries around the compute pass | – | – | – | 314 | 191 |
| B-native | 2M | 1.26 | 0.073 | GPU timestamp queries around the compute pass | – | – | – | 274 | 191 |
| B-native | 5M | 3.07 | 0.184 | GPU timestamp queries around the compute pass | – | – | – | 305 | 225 |
| B-native | 10M | 6.16 | 0.369 | GPU timestamp queries around the compute pass | – | – | – | 323 | 263 |
| B-native | 20M | 12.31 | 0.771 | GPU timestamp queries around the compute pass | – | – | – | 385 | 340 |
| C | 1M | 8.21 | 0.043 | GPU step, timed on a separate pass (each part waited for on its own) | 0.216 | – | 0.438 | 344 | 265 |
| C | 2M | 7.54 | 0.081 | GPU step, timed on a separate pass (each part waited for on its own) | 0.367 | – | 0.426 | 346 | 279 |
| C | 5M | 6.48 | 0.194 | GPU step, timed on a separate pass (each part waited for on its own) | 0.764 | – | 0.433 | 362 | 326 |
| C | 10M | 9.58 | 0.383 | GPU step, timed on a separate pass (each part waited for on its own) | 1.456 | – | 0.438 | 401 | 402 |
| C | 20M | 9.80 | 0.763 | GPU step, timed on a separate pass (each part waited for on its own) | 2.821 | – | 0.437 | 470 | 554 |

GPU frame ms: A = GPU timestamps from the step's start to the tone pass's end; C = its timed step + splat (the separate pass). CPU encode: A = JS encode + submit; B-wasm = step + pack + upload + draw call on the CPU. C's work per frame (step + splat + readback, one wait) is in results.json (work_ms).

B-wasm thread probe (one run each, frame ms; the better count was used): 1M: {'24': 2.327, '22': 2.592}; 2M: {'24': 4.986, '22': 4.645}; 5M: {'24': 16.46, '22': 15.573}; 10M: {'24': 32.301, '22': 31.173}; 20M: {'24': 60.338, '22': 62.966}

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
