# Goal 36b M7 · the particle field on the real desktop

Every run passed the quiet gate: 1-minute load < 2.0 and no other process on the GPU (compute apps over 16 MiB); waited 1620 s in all.

Setup: Hyprland 0.56.2 on Wayland (wayland-1), monitor HDMI-A-2 3440×1440 @ 59.973 Hz, scale 1.6, VRR False, DPMS on True; GTK 4.22.4; Chromium 152.0.7977.82. Vsync: off for every row: C GDK_DEBUG=no-vsync (GTK's frame clock uncapped); A, A-cpu, B-wasm Chromium --disable-gpu-vsync --disable-frame-rate-limit; B-native wgpu present mode Immediate (in a window the compositor still paces it) or offscreen. Pixels: 1280×720 for every row (C: MOJOUI_CANVAS_SCALE=1; the browsers' and wgpu's canvases are 1280×720 pixels and the compositor or browser scales them to the 1.6× monitor); C-hidpi: 2048×1152.

Commit `844ab64`, sources sha256 `8bd35549e625`, 2026-10-28 10:25; 24 cores, NVIDIA GeForce RTX 3090, 610.57.04, NVIDIA GeForce RTX 3090, 610.57.04.
Protocol: scripts/particles_bench.py (docstring): 60 warm-up + 600 measured frames, 3 runs, each run's frame ms is the mean frame interval (throughput); the table shows the median of the runs (± spread = max - min).

## Headline: frame ms (throughput, vsync off) and the largest N at 60 fps

Holds 60 fps = frame ms ≤ 16.7 and the 95th-percentile frame interval ≤ 20 ms.

| Row | largest N at 60 fps | 1M | 2M | 5M | 10M | 20M |
|---|---|---|---|---|---|---|
| A · JS + WebGPU | 20M | 1.21 ±0.05 | 1.24 ±0.17 | 1.35 ±0.04 | 1.53 ±0.02 | 3.01 ±0.00 |
| A-cpu · plain JS (CPU) | 100k | 13.88 ±0.55 ✗ | 25.06 ±0.18 ✗ | 57.27 ±0.38 ✗ | 110.65 ±0.45 ✗ | 217.70 ±1.37 ✗ |
| B-wasm · JS + Rust/wasm | 2M | 1.86 ±0.01 | 3.51 ±0.13 | 16.67 ±3.78 ✗ | 28.12 ±0.29 ✗ | 53.45 ±2.93 ✗ |
| B-native · Rust + wgpu (in a window) | 10M | 16.65 ±0.00 | 16.66 ±0.08 | 16.66 ±0.08 | 16.66 ±0.00 | 16.89 ±0.08 ✗ |
| B-native · Rust + wgpu (offscreen) | 20M | 0.34 ±0.00 | 0.64 ±0.00 | 1.52 ±0.00 | 3.00 ±0.00 | 5.99 ±0.00 |
| C · omxcode (Mojo) | 20M | 1.23 ±0.02 | 1.31 ±0.03 | 1.57 ±0.02 | 2.07 ±0.09 | 3.13 ±0.02 |

## Each 36b feature's effect on C (frame ms, the same protocol)

| C with (GTK renderer used) | 1M | 5M | 20M |
|---|---|---|---|
| C · goal 36's path (readback, 3 atomics) (GskVulkanRenderer) | 5.54 ±0.41 | 6.18 ±0.16 | 8.48 ±0.29 |
| C · goal 36's path on GTK's GL renderer (GskGLRenderer) | 4.45 ±0.07 | 4.40 ±0.69 | 6.74 ±0.72 |
| C · + M6 zero-copy (GskGLRenderer) | 1.24 ±0.01 | 1.76 ±0.05 | 3.81 ±0.02 |
| C · + M6c packed splat (GskGLRenderer) | 1.21 ±0.04 | 1.56 ±0.01 | 3.07 ±0.01 |
| C · + M6b (all of 36b: blending measured at run time) (GskGLRenderer) | 1.23 ±0.02 | 1.57 ±0.02 | 3.13 ±0.02 |
| C · M6b blending always (GskGLRenderer) | 1.21 ±0.02 | 6.13 ±0.04 | 11.22 ±0.00 |
| C · at the screen's 1.6× (2048×1152) (GskGLRenderer) | 1.36 ±0.04 | 1.77 ±0.02 | 3.66 ±0.01 |

Effect of each (frame ms saved, before → after): GTK's GL renderer instead of its Vulkan one (goal 36's path both): 1M 1.09, 5M 1.78, 20M 1.74; M6 the picture kept on the GPU (no readback, no CPU hand-over; GL renderer both): 1M 3.21, 5M 2.64, 20M 2.92; M6c packed splat: 1M 0.03, 5M 0.20, 20M 0.75; M6b blending, measured: 1M -0.02, 5M -0.01, 20M -0.06.

A-cpu at 100k: 3.03 ms ±0.15 (holds 60 fps; p95 4.90 ms).

How each row's frame ms is measured:

- A · JS + WebGPU: window wall time to the last frame's GPU completion / 600 (&await=0, vsync/limiter off).
- A-cpu · plain JS (CPU): mean rAF interval, vsync/limiter off.
- B-wasm · JS + Rust/wasm: mean rAF interval, vsync/limiter off.
- B-native · Rust + wgpu (in a window): mean loop interval (a Wayland window, present mode Immediate).
- B-native · Rust + wgpu (offscreen): mean loop interval (offscreen, two frames in flight).
- C · omxcode (Mojo): mean canvas frame interval, GDK_DEBUG=no-vsync (GTK's frame clock uncapped).
- C · goal 36's path (readback, 3 atomics): mean canvas frame interval, GDK_DEBUG=no-vsync (GTK's frame clock uncapped).
- C · goal 36's path on GTK's GL renderer: mean canvas frame interval, GDK_DEBUG=no-vsync (GTK's frame clock uncapped).
- C · + M6 zero-copy: mean canvas frame interval, GDK_DEBUG=no-vsync (GTK's frame clock uncapped).
- C · + M6c packed splat: mean canvas frame interval, GDK_DEBUG=no-vsync (GTK's frame clock uncapped).
- C · M6b blending always: mean canvas frame interval, GDK_DEBUG=no-vsync (GTK's frame clock uncapped).
- C · at the screen's 1.6× (2048×1152): mean canvas frame interval, GDK_DEBUG=no-vsync (GTK's frame clock uncapped).

## Separately (labelled; not comparable across rows unless the label matches)

| Row | N | p95 interval | step ms | step is | GPU frame ms | CPU encode ms | readback ms | cold start ms | peak PSS MB | peak RSS MB |
|---|---|---|---|---|---|---|---|---|---|---|
| A | 1M | 1.20 | 0.041 | GPU timestamp-query around the step pass | 0.179 | 0.100 | – | 974 | 588 | 1253 |
| A | 2M | 1.20 | 0.078 | GPU timestamp-query around the step pass | 0.324 | 0.100 | – | 882 | 609 | 1289 |
| A | 5M | 1.30 | 0.191 | GPU timestamp-query around the step pass | 0.727 | 0.100 | – | 926 | 657 | 1409 |
| A | 10M | 1.80 | 0.378 | GPU timestamp-query around the step pass | 1.419 | 0.100 | – | 1047 | 777 | 1579 |
| A | 20M | 2.30 | 0.774 | GPU timestamp-query around the step pass | 2.852 | 0.100 | – | 1278 | 1130 | 1978 |
| A-cpu | 100k | 4.90 | 0.400 | CPU (plain JS, main thread) | – | – | – | 666 | 600 | 1248 |
| A-cpu | 1M | 23.00 | 3.500 | CPU (plain JS, main thread) | – | – | – | 792 | 612 | 1256 |
| A-cpu | 2M | 35.00 | 7.000 | CPU (plain JS, main thread) | – | – | – | 818 | 631 | 1277 |
| A-cpu | 5M | 71.80 | 17.700 | CPU (plain JS, main thread) | – | – | – | 878 | 679 | 1333 |
| A-cpu | 10M | 132.30 | 35.500 | CPU (plain JS, main thread) | – | – | – | 953 | 754 | 1406 |
| A-cpu | 20M | 251.30 | 71.200 | CPU (plain JS, main thread) | – | – | – | 1115 | 898 | 1545 |
| B-wasm | 1M | 2.15 | 1.130 | CPU: wasm step + pack, 22 threads (wall) | – | 1.485 | – | 1129 | 870 | 1685 |
| B-wasm | 2M | 4.20 | 2.160 | CPU: wasm step + pack, 22 threads (wall) | – | 3.085 | – | 1168 | 892 | 1712 |
| B-wasm | 5M | 16.73 | 7.135 | CPU: wasm step + pack, 22 threads (wall) | – | 12.140 | – | 1375 | 978 | 1782 |
| B-wasm | 10M | 30.68 | 16.595 | CPU: wasm step + pack, 22 threads (wall) | – | 27.095 | – | 1484 | 1101 | 1909 |
| B-wasm | 20M | 60.09 | 34.288 | CPU: wasm step + pack, 24 threads (wall) | – | 52.058 | – | 1769 | 1408 | 2210 |
| B-native | 1M | 16.77 | 1.905 | GPU timestamp queries around the compute pass | – | – | – | 300 | 164 | 167 |
| B-native | 2M | 16.91 | 1.585 | GPU timestamp queries around the compute pass | – | – | – | 302 | 164 | 167 |
| B-native | 5M | 16.74 | 0.363 | GPU timestamp queries around the compute pass | – | – | – | 313 | 164 | 200 |
| B-native | 10M | 16.90 | 0.718 | GPU timestamp queries around the compute pass | – | – | – | 328 | 164 | 238 |
| B-native | 20M | 16.74 | 0.776 | GPU timestamp queries around the compute pass | – | – | – | 374 | 311 | 314 |
| B-native-off | 1M | 0.65 | 0.037 | GPU timestamp queries around the compute pass | – | – | – | 211 | 146 | 150 |
| B-native-off | 2M | 1.26 | 0.073 | GPU timestamp queries around the compute pass | – | – | – | 214 | 146 | 149 |
| B-native-off | 5M | 3.09 | 0.184 | GPU timestamp queries around the compute pass | – | – | – | 250 | 146 | 184 |
| B-native-off | 10M | 6.16 | 0.369 | GPU timestamp queries around the compute pass | – | – | – | 279 | 146 | 222 |
| B-native-off | 20M | 12.33 | 0.771 | GPU timestamp queries around the compute pass | – | – | – | 326 | 146 | 298 |
| C | 1M | 1.40 | 0.042 | GPU step, timed on a separate pass (each part waited for on its own) | 0.193 | – | – | 461 | 294 | 314 |
| C | 2M | 1.59 | 0.080 | GPU step, timed on a separate pass (each part waited for on its own) | 0.301 | – | – | 473 | 310 | 329 |
| C | 5M | 2.13 | 0.194 | GPU step, timed on a separate pass (each part waited for on its own) | 0.632 | – | – | 505 | 358 | 376 |
| C | 10M | 3.12 | 0.383 | GPU step, timed on a separate pass (each part waited for on its own) | 1.169 | – | – | 529 | 431 | 449 |
| C | 20M | 5.19 | 0.762 | GPU step, timed on a separate pass (each part waited for on its own) | 2.297 | – | – | 601 | 584 | 604 |
| C-36 | 1M | 6.43 | 0.042 | GPU step, timed on a separate pass (each part waited for on its own) | 0.213 | – | 0.419 | 616 | 342 | 356 |
| C-36 | 5M | 7.17 | 0.194 | GPU step, timed on a separate pass (each part waited for on its own) | 0.749 | – | 0.418 | 658 | 406 | 423 |
| C-36 | 20M | 10.69 | 0.762 | GPU step, timed on a separate pass (each part waited for on its own) | 2.818 | – | 0.416 | 751 | 631 | 645 |
| C-36gl | 1M | 4.91 | 0.042 | GPU step, timed on a separate pass (each part waited for on its own) | 0.222 | – | 0.419 | 456 | 315 | 334 |
| C-36gl | 5M | 5.11 | 0.194 | GPU step, timed on a separate pass (each part waited for on its own) | 0.764 | – | 0.417 | 493 | 374 | 395 |
| C-36gl | 20M | 8.76 | 0.762 | GPU step, timed on a separate pass (each part waited for on its own) | 2.830 | – | 0.417 | 636 | 606 | 625 |
| C+M6 | 1M | 1.35 | 0.042 | GPU step, timed on a separate pass (each part waited for on its own) | 0.217 | – | – | 447 | 290 | 309 |
| C+M6 | 5M | 2.16 | 0.194 | GPU step, timed on a separate pass (each part waited for on its own) | 0.787 | – | – | 500 | 352 | 371 |
| C+M6 | 20M | 5.37 | 0.763 | GPU step, timed on a separate pass (each part waited for on its own) | 2.900 | – | – | 609 | 582 | 600 |
| C+M6c | 1M | 1.36 | 0.042 | GPU step, timed on a separate pass (each part waited for on its own) | 0.193 | – | – | 468 | 291 | 310 |
| C+M6c | 5M | 2.02 | 0.194 | GPU step, timed on a separate pass (each part waited for on its own) | 0.636 | – | – | 506 | 354 | 372 |
| C+M6c | 20M | 4.79 | 0.762 | GPU step, timed on a separate pass (each part waited for on its own) | 2.299 | – | – | 600 | 582 | 600 |
| C-blend | 1M | 1.66 | 0.042 | GPU step, timed on a separate pass (each part waited for on its own) | 0.193 | – | – | 475 | 297 | 316 |
| C-blend | 5M | 7.87 | 0.194 | GPU step, timed on a separate pass (each part waited for on its own) | 0.635 | – | – | 503 | 358 | 377 |
| C-blend | 20M | 17.25 | 0.762 | GPU step, timed on a separate pass (each part waited for on its own) | 2.309 | – | – | 606 | 585 | 604 |
| C-hidpi | 1M | 1.61 | 0.042 | GPU step, timed on a separate pass (each part waited for on its own) | 0.194 | – | – | 476 | 300 | 319 |
| C-hidpi | 5M | 3.10 | 0.194 | GPU step, timed on a separate pass (each part waited for on its own) | 0.640 | – | – | 507 | 362 | 381 |
| C-hidpi | 20M | 8.33 | 0.762 | GPU step, timed on a separate pass (each part waited for on its own) | 2.309 | – | – | 616 | 588 | 607 |

GPU frame ms: A = GPU timestamps from the step's start to the tone pass's end; C = its timed step + splat (the separate pass). CPU encode: A = JS encode + submit; B-wasm = step + pack + upload + draw call on the CPU. C's work per frame (step + splat + readback, one wait) is in results.json (work_ms).

B-wasm thread probe (one run each, frame ms; the better count was used): 1M: {'24': 1.881, '22': 1.845}; 2M: {'24': 3.588, '22': 3.358}; 5M: {'24': 16.7, '22': 12.684}; 10M: {'24': 28.519, '22': 28.154}; 20M: {'24': 53.481, '22': 53.487}

## Code and effort (counted by scripts/particles_bench.py, not by hand)

| Build | lines of code | files | languages | build steps | toolchains to install |
|---|---|---|---|---|---|
| A | 522 | 8 | CSS, HTML, JavaScript, Python, WGSL | 2 | Python (a static server); Chromium with WebGPU |
| A-cpu | 243 | 3 | CSS, HTML, JavaScript, Python | 2 | Python (a static server); Chromium |
| B (both apps: wasm and native) | 1051 | 13 | Bash, CSS, GLSL, HTML, JavaScript, Python, Rust, TOML, WGSL | 10 | pixi (installs the rest); Rust (rustc + cargo), the wasm32 target and rust-src (build-std for wasm threads); wasm-bindgen-cli; binaryen (wasm-opt); Python (a static server); Chromium |
| B-wasm | 374 | 10 | Bash, CSS, GLSL, HTML, JavaScript, Python, Rust, TOML | 8 | pixi (installs the rest); Rust (rustc + cargo), the wasm32 target and rust-src (build-std for wasm threads); wasm-bindgen-cli; binaryen (wasm-opt); Python (a static server); Chromium |
| B-native | 771 | 6 | Rust, TOML, WGSL | 3 | pixi (installs the rest); Rust (rustc + cargo) |
| C | 258 | 1 | Mojo | 3 | pixi (installs the rest); Mojo 1.1 + MAX 26.6 (through pixi) |

Lines exclude blank and comment-only lines (and docstrings). B-wasm and B-native share the sim crate and the workspace Cargo.toml (counted in both); B is the two apps together. C counts the app (examples/particles) only: mojoui (the framework) is a library, as WebGPU, wgpu, wasm-bindgen and rayon are. But this goal also added 1744 lines to the framework and its tests for C (mojoui/app.mojo +3, mojoui/canvas.mojo +12, mojoui/gpu.mojo +460, mojoui/hosts/gtk.mojo +206, mojoui/present.mojo +626, tests/test_canvas_blend.mojo +152, tests/test_canvas_present.mojo +153, tests/test_pointcloud_step.mojo +132; added lines that aren't blank or a comment, git diff from 858eff5): PointCloud's step, splat and readback, reusable by any app. Build steps, clean checkout to running:

- A: `python showcase/js-webgpu/serve.py  (any static server)` → `open http://127.0.0.1:<port>/index.html in Chromium (WebGPU)`
- A-cpu: `python showcase/js-webgpu/serve.py  (any static server)` → `open http://127.0.0.1:<port>/index.html?mode=cpu`
- B: `pixi install  (Rust 1.99, wasm32 std, rust-src, wasm-bindgen-cli, binaryen)` → `RUSTC_BOOTSTRAP=1 CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_RUSTFLAGS='-C target-feature=+atomics,+bulk-memory,+mutable-globals,+simd128 -C link-arg=--shared-memory -C link-arg=--import-memory -C link-arg=--max-memory=4294967296 -C link-arg=--export=__wasm_init_tls -C link-arg=--export=__tls_size -C link-arg=--export=__tls_align -C link-arg=--export=__tls_base' cargo build --release --target wasm32-unknown-unknown -p particles-wasm -Z build-std=panic_abort,std` → `wasm-bindgen --target web --out-dir "$OUT/pkg" target/wasm32-unknown-unknown/release/particles_wasm.wasm` → `sed -i "s|import('../../..')|import('../../../particles_wasm.js')|" "$OUT"/pkg/snippets/wasm-bindgen-rayon-*/src/workerHelpers.js` → `wasm-opt -O3 --enable-threads --enable-bulk-memory --enable-simd --enable-mutable-globals --enable-nontrapping-float-to-int --enable-sign-ext "$OUT/pkg/particles_wasm_bg.wasm" -o "$OUT/pkg/particles_wasm_bg.wasm"` → `cp web/index.html web/main.js web/worker.js "$OUT/"` → `cargo build --release -p particles-native` → `python showcase/js-rust/serve.py  (COOP/COEP headers, for wasm threads)` → `open http://127.0.0.1:<port>/index.html` → `target/release/particles-native  (the native row)`
- B-wasm: `pixi install  (Rust 1.99, wasm32 std, rust-src, wasm-bindgen-cli, binaryen)` → `RUSTC_BOOTSTRAP=1 CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_RUSTFLAGS='-C target-feature=+atomics,+bulk-memory,+mutable-globals,+simd128 -C link-arg=--shared-memory -C link-arg=--import-memory -C link-arg=--max-memory=4294967296 -C link-arg=--export=__wasm_init_tls -C link-arg=--export=__tls_size -C link-arg=--export=__tls_align -C link-arg=--export=__tls_base' cargo build --release --target wasm32-unknown-unknown -p particles-wasm -Z build-std=panic_abort,std` → `wasm-bindgen --target web --out-dir "$OUT/pkg" target/wasm32-unknown-unknown/release/particles_wasm.wasm` → `sed -i "s|import('../../..')|import('../../../particles_wasm.js')|" "$OUT"/pkg/snippets/wasm-bindgen-rayon-*/src/workerHelpers.js` → `wasm-opt -O3 --enable-threads --enable-bulk-memory --enable-simd --enable-mutable-globals --enable-nontrapping-float-to-int --enable-sign-ext "$OUT/pkg/particles_wasm_bg.wasm" -o "$OUT/pkg/particles_wasm_bg.wasm"` → `cp web/index.html web/main.js web/worker.js "$OUT/"` → `python showcase/js-rust/serve.py  (COOP/COEP headers, for wasm threads)` → `open http://127.0.0.1:<port>/index.html`
- B-native: `pixi install  (Rust 1.99)` → `cargo build --release -p particles-native` → `target/release/particles-native`
- C: `pixi install  (Mojo 1.1, MAX 26.6)` → `scripts/build.sh particles linux` → `build/particles/linux/particles`

## Caveats (every one)

- The desktop: the owner's Hyprland session (Wayland, GPU-composited), measured while the owner was away (D-735); each row's window opened tiled on the active workspace beside one other window and was closed after its run. The monitor runs at 59.97 Hz, scale 1.6, VRR and tearing off. With vsync off, GTK and Chromium render frames faster than the screen shows them (the compositor shows the newest); the headline is frames rendered (throughput), as in goal 36.
- Every field is 1280 × 720 pixels: C with MOJOUI_CANVAS_SCALE=1 (GTK scales the texture to the 1.6× monitor on the GPU), the browsers' canvases are 1280 × 720 pixels at any scale, wgpu's surface is 1280 × 720 physical pixels. C-hidpi shows C at the screen's own scale (2048 × 1152 pixels, 2.56× the pixels).
- C on the desktop: GTK 4.22 on Wayland with its GL renderer (asked for by the framework when CUDA↔GL works, D-737); the picture goes from CUDA memory into a GL texture GPU→GPU (or is blended into one), no readback: each run's present counters (gpu_copied, gpu_blended, cpu_copied = 0) are in results-desktop.json. The host waits for the GPU once a frame before GTK draws (NVIDIA stalls GL behind queued CUDA work, D-746); one frame in flight is opt-in and off here (D-747). The renderer GTK actually drew with is recorded for every C run (GSK_DEBUG=renderer): goal 36's path (C-36) uses GTK's default, Vulkan; C-36gl is the same path on GL, so the renderer and the readback are measured apart.
- C's additive points use the compute splat, and blending is measured against it after 120 frames and then 240, 480… (D-739): inside the 600 measured frames that is two short measurements (6 frames of the splat, then blending until it is clearly slower, at most 6 frames); C-blend has blending on every frame.
- C's splat is the framework's PointCloud.splat: two atomics per particle (M6c; C-36 and C+M6 run goal 36's three), each channel skipped once saturated, exact (GPU = CPU picture).
- C's step ms and GPU frame ms come from a separate timed pass after the measured frames (each part waited for on its own), with the compute splat; readback ms is shown only for rows whose frames copy the picture to the CPU (C-36).
- A, A-cpu and B-wasm run in headed Chromium 152 on Wayland (/usr/lib/chromium/chromium, the same flags for all three; Chromium refuses Vulkan compositing on Wayland, so it composites with GL; WebGPU uses Dawn on Vulkan). Goal 36 ran B-wasm headless through the /usr/bin/chromium wrapper.
- A draws with an atomic compute rasteriser (two u32 atomics per on-screen particle, skipped once the pixel is saturated, the same load-first form as C); A's headline is &await=0 with the queue drained at the warm-up's end, as in goal 36. B draws with hardware blending (WebGL2 points / wgpu point list, additive).
- B-native in a Wayland window is paced by the compositor, about one frame per screen refresh at every N, with present mode Immediate or Mailbox (both tried in a probe, both offered by the driver; that probe read 18.5 ms a frame, and GTK with its frame clock capped read 18.8 ms then). Its throughput is only measurable offscreen, so B-native-off is the same binary offscreen (two frames in flight), as in goal 36.
- A-cpu is single-threaded by design (plain JS on the main thread). B-wasm's thread count is chosen by its own probe.
- Peak memory is the PSS of the launched process tree, as in goal 36; GPU memory is not included. Cold start includes each runtime's own start.
- The machine has two RTX 3090s; the compositor and GTK's GL run on the second (CUDA 1), and the framework puts C's GPU work there too (D-738); A, B pick their own.
