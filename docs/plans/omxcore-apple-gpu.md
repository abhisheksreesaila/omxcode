# omxcore on Apple's GPU: the spec

For the omxcore session (repo `abhisheksreesaila/omxcore`; the engine called MX frame in older docs). Written by the omxcode session, 2026-10-24.
Every file and line below was checked at omxcore `3a33697` (HEAD); the app vendors `23edc59` (same lines, `mojo/mxframe/`
before the rename to `mojo/omxcore/`).

## Why
omxcode's claim is "one readable language, from button to kernel". On Linux, omxcore's queries run on the NVIDIA GPU in
the app's own process (a chart over 1M rows in 0.7 ms). On the Mac they run on the CPU, because omxcore's GPU path is
compiled out there. Modular's MAX now targets Apple GPUs (Metal), and its source is open to read. Getting omxcore's
queries onto Apple's GPU is the last big piece before omxcode is announced.

## Done means
1. `gpu_available()` is true on an Apple Silicon Mac, and a query with `device=GPU` runs there.
2. On a 1,000,000-row file (the app's `orders` sample: INT, DECIMAL and TEXT columns), these give the same answers on
   Apple's GPU as pyarrow: count, sum, min, max of INT and DECIMAL columns, overall and grouped by a TEXT column; a
   WHERE filter; ORDER BY an aggregate with LIMIT.
3. NVIDIA results and speed don't change (the existing Linux suites and benchmarks stay green).
4. The app can show where a query ran: the device's name and API ("Apple M4 · Metal").

## How to test without an Apple Silicon Mac in hand
GitHub's `macos-26` runner has a virtual Apple GPU that MAX can use, if you name M1's Metal family. omxcode already runs
this on every push (its `ci/mac/gpuprobe.mojo` printed `DEVICE: Apple Paravirtual device · metal`, `RESULT: ok`):

```sh
curl -fsSL https://pixi.sh/install.sh | bash && export PATH="$HOME/.pixi/bin:$PATH"
pixi init --platform osx-arm64 . && pixi add "python=3.13.*"
pixi add --pypi "mojo>=1.1,<1.2" "max>=26.6.0,<27"
xcodebuild -downloadComponent MetalToolchain
pixi run mojo run --target-accelerator metal:1 probe.mojo   # without the flag: "Unknown GPU architecture detected"
```

Suggested: one CI job on `macos-26` that builds omxcore for Metal and runs the "done means" queries against pyarrow,
printing each result beside pyarrow's. A virtual GPU's timings mean nothing; the owner's Mac measures speed at the end.

## What stops it today, and what to change (in order)

### 1. Float64 everywhere in the GPU interpreter: Metal has no double
- `kernels_aot/pipeline_gpu.mojo:52` `comptime F64 = DType.float64`; the module's own note: "All arithmetic is float64".
  Registers, constants and accumulators are Float64; integers ride as int64 bits inside them.
- Shared memory is Float64 too: `pipeline_gpu.mojo:612` `external_memory[Scalar[F64], …]`.
- Device buffers: `mojo/omxcore/query.mojo:1705` onwards (`consts`, `ident`, `vals`, `scratch` as `DeviceBuffer[DType.float64]`).
- `kernels_aot/kernels_aot_gpu.mojo:537` (Float64 block sums) and its `parts` buffers.

**Change:** make the interpreter's word an Int64 (DECIMAL is already a scaled integer, so sums stay exact), with Float32
where a float is really needed. FLOAT64 columns already stay on the CPU everywhere (`query.mojo:426`, `has_float`): keep
that. **Proof:** the pipeline kernel compiles with `--target-accelerator metal:1`.

### 2. 64-bit atomics: Metal has no general 64-bit atomic add
- `pipeline_gpu.mojo:127-169`: `_atomic_add_f64`, `_atomic_min_f64`, `_atomic_max_f64`, `_atomic_add_i64`,
  `_atomic_add_bits`, `_atomic_min_bits`, `_atomic_max_bits` (raw `llvm.atomicrmw` on i64/f64), used for counts, sums,
  min and max.
- `kernels_aot/_atomic.mojo` (the same, plus float min/max via raw LLVM IR).

**Change:** on Apple, each block writes its partial results to its own row of scratch and a second small kernel (or the
host) merges them. The engine's modes 0, 3 and 4 already work this way. Choose by a capability check at compile time
(`CompilationTarget`) so NVIDIA keeps its atomic path. **Proof:** counts, sums, min and max equal pyarrow's on the
runner's GPU.

### 3. Shared memory sized for NVIDIA: 48 KB; Apple allows 32 KB
- `pipeline_gpu.mojo:954-964`: plans are checked against `48 * 1024`.
- `kernels_aot_gpu.mojo:248-249`: `SHARED_MAX_GROUPS = 12288` (48 KB), `SM_SHARED_BYTES = 96*1024` (sm_80/86).

**Change:** read the device's limit (or a per-target constant: 32 KB on Apple) and size plans to it, declining to the
existing fallback when one doesn't fit. **Proof:** omxcode's `scripts/gpu_audit.py` passes (it reads `mojo/` and
`kernels_aot/` and fails any kernel over 32 KB).

### 4. NVIDIA-only assembly (PTX)
- `kernels_aot/_atomic.mojo:148`: `red.relaxed.gpu.global.add.f32` with `cvta.to.global`.
- `kernels_aot/kernels_aot_gpu.mojo:331`: `match.any.sync.b32`.

**Change:** behind a `CompilationTarget` check, or left out of the Apple build of the package. **Proof:** the Metal build
links; `mojo/tools/mac_link_probe.mojo` gains a Metal case.

### 5. Grids sized from NVIDIA's numbers
- `pipeline_gpu.mojo:1012` `per_sm = max(1, min(8, (100 * 1024) // smem, 1536 // bsz))`.
- `mojo/omxcore/query.mojo:1764` `n_blocks = ctx.default_device_info.sm_count`; `kernels_aot_gpu.mojo` asks for
  `MULTIPROCESSOR_COUNT`.

**Change:** take these from the device (or per-target values) so scratch rows always equal blocks launched. **Proof:** a
test that compares the two.

### 6. The GPU switched off on the Mac
- `mojo/omxcore/gpu.mojo:32` `comptime HAS_GPU = CompilationTarget.is_linux() and not is_defined["MXFRAME_NO_GPU"]()`.
- `gpu.mojo:36` `gpu_available()` returns False off Linux. (omxcode asked for this, D-56, before MAX reached Apple GPUs.)

**Change:** true on macOS when MAX sees a GPU; keep the opt-out define. Add a call that returns the device's name and API
for the app's status bar. **Proof:** the CI job prints the engine's own `DEVICE: <name> · <api>` line.

### Check, not necessarily change
- Pinned staging buffers: `gpu.mojo:250` `enqueue_create_host_buffer[DType.int64]`. Results already come back by explicit
  `enqueue_copy` + `synchronize` (good: zero-copy reads were wrong on Apple, modular/modular #6145); run the staging path
  once on the runner to be sure.
- Raw `llvm.atomicrmw` and `addrspacecast` IR in `_atomic.mojo`: confirm the Metal backend lowers whatever stays.
- Already fine: 128–256 threads per block (Apple: 1,024), 32-lane warp code (Apple's SIMD groups are 32 wide).

## Later (speed everywhere, not needed for Apple)
- A stream per query and an event the app can poll, instead of a host thread waiting (`DeviceContext.create_stream`,
  `enqueue_record_event`).
- A CPU thread-count setting (the web host pins it).
- MAX's Apache-2.0 top-k, cumsum and gather kernels where they beat the engine's own.

## Licence rules (from the owner)
Call MAX's API and use its Apache-2.0 kernels. Read the MAX-licence parts of the source to understand them; copy,
vendor or reimplement nothing from them.

## Hand back
When it's stable, list the commit in `STABLE.md` as usual. omxcode then vendors it, switches the Mac build's queries to
`AUTO`, and shows "Apple … · Metal" in the status bar.
