# Speed on every host: NVIDIA, Apple's GPU, the browser (goal 32 M6)

Owner, 2026-10-24: "the speed has to tap into NVIDIA in the Linux world, WebGPU on the web, Apple on the Mac, now that
we have the source to look at." MAX became source-available on 2026-10-22 (github.com/modular/modular, `max/`); the
licence rules in the owner's brief hold: call MAX's API and the Apache-2.0 kernels, read the MAX-License trees to
understand them, copy nothing from them.

## What the audit found (scripts/gpu_audit.py, corrected 2026-10-24)
The first audit read only MX frame's `mojo/` folder and reported "no shared memory, no atomics". Wrong: its GPU kernels
are in `kernels_aot/`. Read whole, MX frame 23edc59:
- **The GPU is compiled out on the Mac.** `mojo/mxframe/gpu.mojo:32` `HAS_GPU = CompilationTarget.is_linux() and …`, and
  `gpu_available()` returns False off Linux (our own D-56 asked for that, before MAX could reach Apple's GPU).
- **Every number on the GPU is a Float64.** `pipeline_gpu.mojo` (the query interpreter every GPU query runs through)
  keeps its registers, constants and accumulators as Float64, integers as int64 bits inside them. Metal has no double:
  the kernel can't be compiled for Apple at all, even for an integer-only query.
- **64-bit atomics** for counts, integer sums and min/max (`pipeline_gpu.mojo:127-169`, `_atomic.mojo`, raw
  `llvm.atomicrmw` on i64 and f64). Metal has no general 64-bit atomic add.
- **Shared memory budgeted at 48 KB** (`pipeline_gpu.mojo:954-964`; `kernels_aot_gpu.mojo`: 96 KB per SM, sm_80/86).
  Apple's is 32 KB: plans sized between 32 and 48 KB would fail to launch instead of falling back.
- **PTX** in `_atomic.mojo:148` (`red.relaxed.gpu.global.add.f32`) and `kernels_aot_gpu.mojo:331` (`match.any.sync`).
- **NVIDIA sizing:** grids from `sm_count` and fixed 100 KB / 1,536-thread figures (`pipeline_gpu.mojo:1012`,
  `query.mojo:1764`).
- Fine already: blocks of 128–256 threads (Apple: 1,024), 32-lane warp code (Apple's SIMD groups are 32 wide), results
  copied back explicitly (no zero-copy reads; the pinned staging buffers in `gpu.mojo:250` still need a run on Apple,
  modular #6145).
- mojoui's own two kernels: 2 KB of shared memory each, fine; `frame_gpu` adds 64-bit sums with atomics, the same
  problem as above, fixed the same way.

## Measured: a Mojo kernel on a Mac's GPU, in CI (2026-10-24)
GitHub's macOS 26 runner (a virtual M1) ran `ci/mac/gpuprobe.mojo` through MAX on its GPU: `DEVICE: Apple Paravirtual
device · metal`, `RESULT: ok` (4,096 values copied in, a kernel, copied out, checked). On its own the compiler stops at
"Unknown GPU architecture detected" (the virtual GPU names no M-series family); `mojo run --target-accelerator metal:1`
builds for M1's Metal family and runs. So the Mac GPU path can be tested on every push, not only on the owner's Mac;
the owner's Mac still proves speed (a virtual GPU's timings mean little).

## Linux (NVIDIA)
- Already: MX frame on the RTX 3090 (0.7 ms over 20M rows); queries as jobs off the window (goal 30).
- Next: a second stream per query and an event the window polls (DeviceContext's `create_stream`,
  `enqueue_record_event`, Apache-2.0) instead of a host thread waiting; a recorded kernel chain (`DeviceGraphCache`) for
  the chart sentence's repeated "same chain, new parameters" clicks.
- State the minimum precisely from MAX's execution configs (`_nvidia/`: Turing consumer and up).

## Mac (Metal through MAX)
- MAX ships Apple targets (`apple-m1` … `apple-m6`), a Metal plugin and Apple execution configs. Needs macOS 15+, Xcode
  16+ and the Metal toolchain on the machine that builds the `.metallib`.
- Steps: (1) a probe app (`examples/gpuprobe`) that asks MAX for the default device and runs one tiny kernel with
  explicit copies, printing `DEVICE: <name> · <api>`; built for the Mac, run in CI (GitHub's Macs are virtual and may
  have no usable GPU: the probe says so) and on the owner's Mac; (2) MX frame's GPU path on the Mac with explicit
  stage-in / stage-out (zero-copy results were wrong on shared-memory Apple systems, modular/modular #6145), compared
  with pyarrow like the Linux checks; (3) the island and status bar read "Apple M4 · Metal".
- Only the owner's Mac can prove (2) and (3).

## Web
- Today the web host runs the native app on the server: a hosted page already computes on the server's GPU (or its
  CPU). Pin the CPU path's threads so the engine and the web server's workers don't fight for cores, and give each tab
  its own stream so one tab's 100M-row open doesn't queue behind another's chart.
- The browser's own GPU (WebGPU) is a different target: Mojo and MAX don't emit WGSL/SPIR-V for browsers today, so
  "WebGPU" means either hand-written WGSL kernels driven from JavaScript (a second language: against the claim) or
  waiting for a Mojo WebGPU target. Recommendation: the server path now; a WebGPU spike only when a Mojo route exists
  (track Modular's roadmap). Decision D-297.

## From MX frame: Apple's GPU, in order
The last big piece before the announcement. Each item names what to change and how we'll know it worked.
1. **Integers and Float32 on the GPU, no Float64.** The interpreter's word becomes an Int64 (or two 32-bit halves);
   DECIMAL columns are already scaled integers, so sums stay exact. FLOAT64 columns stay on the CPU on Apple (they
   already do everywhere, `query.mojo:425`). Proof: the pipeline kernel compiles with `--target-accelerator metal:1`.
2. **No 64-bit atomics on Apple.** Per-block partials written out and merged in a second small kernel (the engine's
   modes 0, 3 and 4 already work this way), chosen by a capability check so NVIDIA keeps its atomics. Proof: counts,
   sums, min and max of a 1M-row file equal pyarrow's, on the Mac runner's GPU.
3. **Shared memory from the device, not 48 KB.** Ask the device its limit (32 KB on Apple) and size plans to it, falling
   back as today when one doesn't fit. Proof: `scripts/gpu_audit.py` passes.
4. **No PTX on Apple.** The `red.relaxed` add and `match.any.sync` behind a `CompilationTarget` check, or left out of the
   Apple package. Proof: the Mac link probe lists no unresolved PTX symbols.
5. **Grids sized from the device**, not `sm_count` and NVIDIA's figures. Proof: scratch rows equal blocks launched.
6. **The GPU on, on the Mac.** `HAS_GPU` and `gpu_available()` true when MAX sees an Apple GPU; the device's name and
   API for the status bar ("Apple M4 · Metal"). Proof: the CI probe prints the engine's own `DEVICE:` line.
7. Later, for speed everywhere: a stream per query (the app polls an event instead of a thread waiting), a CPU
   thread-count setting (the web host pins it), and MAX's Apache-2.0 top-k, cumsum and gather kernels where faster.

How we'll test it without the owner's Mac: GitHub's macOS 26 runner has a virtual Apple GPU that MAX can use
(`metal:1`, above). Each step lands with a CI job that runs the engine's query on it and compares with pyarrow. Only the
owner's Mac says how fast.
