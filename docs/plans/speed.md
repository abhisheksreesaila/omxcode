# Speed on every host: NVIDIA, Apple's GPU, the browser (goal 32 M6)

Owner, 2026-10-24: "the speed has to tap into NVIDIA in the Linux world, WebGPU on the web, Apple on the Mac, now that
we have the source to look at." MAX became source-available on 2026-10-22 (github.com/modular/modular, `max/`); the
licence rules in the owner's brief hold: call MAX's API and the Apache-2.0 kernels, read the MAX-License trees to
understand them, copy nothing from them.

## What the audit found (scripts/gpu_audit.py)
- Shared memory: mojoui's two kernels (`frame_gpu._frame_kernel`, `gpu._group_kernel`) use 2 KB each; MX frame
  23edc59's GPU path uses none. Apple's limit is 32 KB: nothing to change.
- Atomics: MX frame's GPU path has none. mojoui's kernels add with atomics, and `frame_gpu` adds **64-bit** sums
  (`Atomic.fetch_add` on UInt64). Metal's 64-bit atomics are limited (min/max on recent GPUs, no general add): the first
  Mac pass must not depend on them. Plan: per-block 32-bit partials written out (no atomics), summed on the host, behind
  a capability check, so NVIDIA keeps its path.

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

## From MX frame
What omxcode needs from the engine (the owner offered to make it happen):
1. A GPU path with no 64-bit atomics (or a capability switch), and explicit stage-in / stage-out on Apple.
2. `gpu_available()` true on Apple Silicon, and the device's name and API for the status bar.
3. A thread-count setting for the CPU path (the web host pins it).
4. A stream (or DeviceContext) per query, so the app can give each tab or chart its own queue and poll an event.
5. Top-k, cumulative sums and gathers through MAX's Apache-2.0 kernels (`max/kernels/src/nn/topk.mojo`, `cumsum.mojo`,
   `gather_scatter.mojo`) instead of the engine's own, where they're faster.
