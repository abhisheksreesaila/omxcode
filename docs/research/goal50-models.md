# Goal 50: ML models as functions inside the app (research, 2026-11-04)

Question: can a Mojo app call `detect(video, from_s, to_s)` and `classify(text_column, labels)` in its own process,
on the GPU, with no Python at run time and only MIT/Apache models?
Setup: worktree `mojo-ui-g49`, pixi env `max 26.6.0`, `mojo 1.1.0`, RTX 3090 x2 (probes on GPU 1, with
`CUDA_VISIBLE_DEVICES=1`). Probe sources are in `/tmp/g50probe/` (scratch, not committed): `build_mef.py`,
`run_mef.c`, `maxrt_probe.mojo`, `build_conv.py`, `bench_conv.py`, `bench_minilm.py`, `zs_minilm.py`.

## TL;DR

- **Yes, it works in-process today, verified.** A Mojo 1.1 binary linked to `libmax.so` loads a `.mef` (a MAX
  graph compiled once in Python), with weights from a `.safetensors` file, and runs it on the CPU and on the 3090.
  It gives the same numbers as Python. No libpython is loaded (`ldd`: 0 matches). It needs one environment
  variable, `MODULAR_MOJO_MAX_PACKAGE_ROOT`, which the app can `setenv` itself, plus about 200 MB of Modular
  `.so` files bundled with it (7 libraries, tested from a relocated copy). Latency: 2 to 8 ms to load and init,
  0.03 to 0.07 ms per call on warm small graphs, and 75 to 130 ms for the first GPU call.
- **Mojo has no API for building or loading graphs** (`max.engine` / `max.graph` don't exist on the Mojo side). The
  path is the C API through `external_call`, which is F-5 `mojoui.maxrt`. MAX's kernel libraries (`nn.conv`,
  `nn.nms`, `linalg.matmul`) do import from plain Mojo, as a fallback.
- **Trap: MAX's `conv2d` is a naive kernel on sm_86.** A 3x3 128->128 conv at 52x52 takes 20.8 ms (0.04 TFLOP/s).
  Writing it as im2col + matmul takes 0.18 ms (4.4 TFLOP/s), 115x faster (measured). omxconsole's ports found the
  same (D-31). Any detector port must use im2col.
- **Detector: YOLOX-Tiny** (Apache-2.0, 5.06M params, 6.45 GFLOPs, 32.8 mAP at 416). Choose it over Nano: Nano's
  depthwise convs are MAX's slowest path. Weights are Megvii's `.pth` release files, converted to safetensors once
  on the build side. Estimate: 4 to 6 days to a pack with parity, then about 1 day for `detect()` on top of
  `VideoSource`.
- **classify(): dedupe -> MiniLM-L6 embed on MAX (in-process MEF) -> nearest label -> small LLM only for
  low-margin rows.** Measured: 22k to 52k rows/s for embedding on one 3090 (fp32, batch 1024, 16 to 32 tokens).
  50M rows with roughly 10% unique: about 3 to 5 minutes total (estimate). Licences: MiniLM Apache-2.0, Qwen3-0.6B
  Apache-2.0, GLiClass and GLiNER2 Apache-2.0, **LFM2 is not** (LFM Open License, $10M revenue cap): keep it out.

## 1. In-process MAX from Mojo (verified)

### What's installed
- C headers: `.pixi/envs/default/lib/python3.13/site-packages/max/include/max/c/`: `common.h context.h device.h
  model.h safetensors.h tensor.h types.h weights.h` (1320 lines). Licence header: Apache-2.0 with LLVM exceptions.
- Library: `site-packages/modular/lib/libmax.so` (156 MB). It exports 70 `M_*` functions (`nm -D --defined-only`),
  including `M_compileModelSync` (loads a `.mef` path), `M_initModel`, `M_executeModelSync`,
  `M_captureModelSync`/`M_replayModelSync` (CUDA graphs), `M_loadSafetensors`,
  `M_newWeightsRegistryFromSafetensors`, `M_borrowTensorInto`, `M_copyTensorToDevice`, `M_getAcceleratorCount`.
- There is no getter for a model's input or output names in the C API. Python's `input_metadata` shows them:
  graphs use `input0..N` and `output0..N`.
- Mojo side: the `max` Mojo package (`modular/lib/mojo/max.mojoc`) contains only `max.algorithm`, `max.benchmark`,
  `max.gpu`, `max.runtime` (from `mojo doc`). `from max.engine import ...` fails with "unable to locate module
  'engine'", and `from max import engine` fails with "package 'max' does not contain 'engine'". Kernel packages
  `nn` (conv, nms, resize, pool, attention, topk...) and `linalg` (matmul...) are present; `from nn.conv.conv
  import conv_gpu`, `from nn.nms import non_max_suppression` and `from linalg.matmul import matmul` compile and run.

### Probe: Python builds once, Mojo runs
1. `build_mef.py` builds `relu(x @ W + b)` (x [2,4], W baked in) and exports it with `CompiledModel.export_mef()`
   (`max/engine/api.py:423`). Python result: `[[7,0,8.5],[1,0,0.5]]`.
2. `build_conv.py` builds a GPU graph: conv2d 3x3/s2 with **external** `Weight`s `conv.weight`/`conv.bias` + SiLU +
   channel mean, input [1,64,64,3]. It writes the weights as safetensors (header written by hand, numpy only).
   Python result `sum 52.80604553`, which matches a numpy reference to 3e-8.
3. A C program (`run_mef.c`, gcc against the headers) and a Mojo program (`maxrt_probe.mojo`, `external_call` only,
   built with `mojo build ... -Xlinker -lmax`) run the `.mef` files from `env -i` (no pixi, no Python):

```
== tiny_cpu.mef          load+init 1.9 ms; execute 0.067 / 0.009 / 0.015 ms; result: 7.0 0.0 8.5 1.0 0.0 0.5
== tiny_gpu.mef gpu      load+init 4.0 ms; execute 74.3 / 0.10 / 0.042 ms;  result: 7.0 0.0 8.5 1.0 0.0 0.5
== conv_gpu.mef gpu + conv.safetensors
                         safetensors tensors: 2; load+init 3.9 ms; execute 0.23 / 0.033 / 0.026 ms
                         result: 0.099945165 0.14941247 ... (n=1024, sum=52.8060463629663)
```
   `ldd /tmp/g50probe/maxrt_probe | grep -c libpython` prints `0`.

### Gotchas found
- **Package root.** Without it, `M_initModel` fails: `init: setup for model tiny returned error: unable to locate
  compiler_rt /lib/libKGENCompilerRTShared.so`. Of the four variables `mojo/run.py` sets, only
  `MODULAR_MOJO_MAX_PACKAGE_ROOT=<root containing lib/>` matters (bisected). `MODULAR_MAX_PACKAGE_ROOT`,
  `MODULAR_DERIVED_PATH` and `MODULAR_MAX_LIB_PATH` don't help. Calling `setenv` from inside the Mojo program
  before the first `M_*` call works.
- **Bundle.** A copy holding only `libmax.so libMGPRT.so libAsyncRTMojoBindings.so libAsyncRTRuntimeGlobals.so
  libKGENCompilerRTShared.so libMSupportGlobals.so libnixl.so` (202 MB) in `<root>/lib` ran the CPU and GPU
  probes. The run used `LD_LIBRARY_PATH` and the package root pointed at the copy. `libNVPTX`, lldb and nvshmem
  aren't needed to *run* a precompiled MEF (they are needed to compile).
- **GPU inputs.** Host memory passed to a GPU model fails with `execute: input 'input0' on incorrect device`. Fix:
  borrow on the host, `M_copyTensorToDevice`, then borrow the device pointer (`M_getTensorData`) into a new map
  with a GPU `M_TensorSpec`. Outputs stay on the GPU; copy them back with `M_copyTensorToDevice(y, host)`.
- **Dtype enum.** `M_FLOAT32 = 17 | 64 = 81`, `M_HOST = 0`, `M_ACCELERATOR = 1`.
- **The first GPU call costs 75 to 130 ms** (warm-up), so `maxrt` should warm a pack up at load time.
- **MEFs are device-specific** (MAX docs). Building packs per target (sm_86 here, Mac later) stays a build-side
  step. Compiling MiniLM from a Graph took 57.5 s in Python, so apps must ship or cache MEFs, never compile at
  start. Unverified: how long a large MEF (MiniLM) takes to load through the C API.
- The C API "is undergoing rapid development" (prior note). Keep it behind one file (`mojoui/maxrt.mojo`), with
  the M_ declarations in one place.
- MAX's fp32 matmuls run on TF32 with no opt-out (omxconsole D-30): im2col-vs-conv2d differed by 2e-3 to 6e-3 on
  N(0,1) data. Parity budgets must allow for TF32, or use omxconsole's 3xTF32 split.

### Platform reach (not tested here)
Linux x86 is verified. macOS should be the same API (libmax ships for Apple silicon) but is unverified; run it on
`scripts/mac-ci`. iPhone, Android and web don't have libmax, so they can't run packs in-process.

## 2. If not MAX: the fallback (not needed, kept for completeness)

MAX in-process works, so the fallback isn't needed. If the C API breaks in a release, the cheapest honest option
is to call MAX's own Mojo kernels directly (`nn.conv.conv`, `nn.nms`, `nn.resize`, `linalg.matmul`, all
importable). We would write the layer sequence by hand (about 30 conv blocks for YOLOX-Tiny), with weights from
safetensors through our own reader. Estimate: 1 to 2 weeks on top of the graph port, and we'd own buffer
planning and fusion. A from-scratch Mojo GPU CNN is about the same work plus writing a fast conv/matmul. Not
recommended.

omxconsole's existing ports (`~/Projects/mxstudio.worktrees/vision-porting/ports/vision/{resnet50,vit,segformer}`)
are classifiers and segmenters, not detectors. Their parts are reusable: `mxconsole/vision/fp32.py` (3xTF32
split, `resize_bilinear`), the im2col conv (D-31), depthwise-as-shifted-slices (D-47), BN folding (D-29), and the
parity harness. Today `mojoui/visionmodel.mojo` runs OWLv2/SAM through PyTorch over Python interop (backend A).
A pack backend slots in beside it.

## 3. Which detector

| Model | Licence (code / weights) | Size | COCO AP | Notes |
|---|---|---|---|---|
| **YOLOX-Tiny** | Apache-2.0 / Apache-2.0 (Megvii release) | 5.06M, 6.45 GFLOPs @416 | 32.8 | dense 3x3 convs: im2col-friendly |
| YOLOX-Nano | Apache-2.0 | 0.91M, 1.08 GFLOPs @416 | 25.8 | depthwise everywhere: MAX's slowest op |
| YOLOX-S | Apache-2.0 | 9.0M, 26.8 GFLOPs @640 | 40.5 | step up if Tiny is too weak |
| RT-DETR / D-FINE / DEIM | Apache-2.0 (per Roboflow pages, unverified at source) | larger | 53 to 56 | transformer decoder, deformable attention: a much bigger port |
| RF-DETR N to L | Apache-2.0 (XL/2XL: Roboflow PML) | | up to 60 | DINOv2 backbone + deformable attention: big port |
| Ultralytics YOLOv5/8/11 | AGPL-3.0 | | | excluded |

Sources: https://github.com/Megvii-BaseDetection/YOLOX (README tables, Apache-2.0). Weights:
`https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_{nano,tiny,s,m}.pth`.

Measured MAX costs on the 3090 that drive the choice (`bench_conv.py`, fp32, batch 1, 20 runs):
```
ops.conv2d 3x3 64->64 @104      5.700 ms  (0.1 TFLOP/s)
ops.conv2d 3x3 128->128 @52    20.821 ms  (0.04 TFLOP/s)
ops.conv2d 1x1 256->256 @26     0.171 ms  (0.5 TFLOP/s)
ops.conv2d dw3x3 128 @52        0.984 ms  for 0.006 GFLOP
im2col 3x3 64->64 @104          0.146 ms  (5.5 TFLOP/s)   max|im2col - conv2d| = 1.8e-3 (TF32)
im2col 3x3 128->128 @52         0.179 ms  (4.4 TFLOP/s)   max|d| = 6.1e-3
```
At about 4 TFLOP/s, YOLOX-Tiny's 6.45 GFLOPs work out to about 2 to 5 ms per 416x416 frame on one 3090
(**estimate, unverified**). With naive `conv2d` the same model would take more than 100 ms.

Plan and parity (estimate):
- Build side, one-off, in a separate env with torch: `torch.load(..., weights_only=True)` (never unpickle code),
  fold BN into the conv weights in float64, save safetensors. The reference outputs come from Megvii's own
  `yolox` code on fixed images (CC0 test images, as in omxconsole D-23).
- Graph: Focus (space-to-depth = slices + concat), BaseConv = im2col/1x1 matmul + SiLU, CSP blocks, SPP (max
  pools 5/9/13), PAFPN (nearest 2x upsample = reshape/broadcast), decoupled head. Decode grids and strides in the
  graph. NMS with `ops.non_maximum_suppression` or in plain Mojo.
- Parity check: raw head outputs max |d| under 1e-2 (allowing for TF32), and identical boxes after NMS (IoU >= 0.99,
  same class) on the fixtures.
- Work: graph + parity 3 to 4 days (reusing omxconsole's im2col/BN/resize helpers), `mojoui/maxrt.mojo` (F-5)
  1 day (the probe above is most of it), `detect(video, from_s, to_s)` 1 day. That last step is `VideoSource`
  frames -> RGBA to NCHW/NHWC letterbox -> batch -> pack -> rows, the same shape as `ModelAnalyzer` in
  `visionmodel.mojo`. Note: frames still come from an `ffmpeg` child process (`mojoui/video.mojo`). That is not
  Python, but it is not in-process decoding either.

## 4. classify(): the decision model

### What MAX 26.6 ships (installed `max/pipelines/architectures/`)
Embedding architectures (`task=PipelineTask.EMBEDDINGS_GENERATION`):
- `bert/` `BertModel`: `sentence-transformers/all-MiniLM-L6-v2`, `all-MiniLM-L12-v2`
- `mpnet/` `MPNetForMaskedLM`: `sentence-transformers/all-mpnet-base-v2`
- `qwen3_embedding/` `Qwen3ForCausalLM`: `Qwen/Qwen3-Embedding-0.6B/4B/8B`
Small text-generation ones: `qwen3/` (Qwen3 family), `lfm2/` (`LiquidAI/LFM2.5-350M`), `granite`, `phi3`, `olmo*`,
`llama3`, `gemma3/4`. No DeBERTa, so GLiClass/GLiNER2 (DeBERTa-v3 encoders) would be our own port. The
`/v1/decisions` endpoint is in 26.7, not in the installed 26.6 (no route in `serve/router/`).

### Licences
| Model | Licence | Source |
|---|---|---|
| all-MiniLM-L6-v2 | Apache-2.0 | model card (not re-fetched today) |
| bge-small-en-v1.5 (cached locally) | MIT | model card (not re-fetched today) |
| Qwen3-0.6B, Qwen3-Embedding-0.6B | Apache-2.0 | https://huggingface.co/Qwen/Qwen3-0.6B |
| GLiClass small/base/large v1.0 | Apache-2.0 (small checked; check each card) | https://huggingface.co/knowledgator/gliclass-small-v1.0 |
| GLiNER2 (code, gliner2-base-v1) | Apache-2.0; other checkpoints: check each card | https://github.com/fastino-ai/GLiNER2, https://huggingface.co/fastino/gliner2-base-v1 |
| LFM2 / LFM2.5 | **LFM Open License v1.0**: Apache-based, but commercial rights end above $10M annual revenue | https://www.liquid.ai/lfm-license |

LFM2 fails the "permissive for an MIT app" rule. Leave it out.

### Measured: MiniLM-L6 on MAX, 3090 (`bench_minilm.py`)
The installed `bert/graph.py` builder was used with the cached HF safetensors. A copy of the file was needed
because `max.pipelines` imports `huggingface_hub`/`transformers`, which this env doesn't have. fp32:
```
compile+load 57.5s
B=256  L=32: 11.70 ms/batch -> 21,886 rows/s
B=1024 L=32: 39.94 ms/batch -> 25,640 rows/s
B=1024 L=16: 19.50 ms/batch -> 52,503 rows/s
```
bf16 failed to build: the LayerNorm weights must stay fp32. A mixed-dtype state dict would probably fix it
(untested). Parity with sentence-transformers wasn't checked: no torch or tokenizers in this env.
Zero-shot sanity check (`zs_minilm.py`, a 20-line WordPiece written for the test, 6 UNSPSC-style segment titles):
7 of 8 lines landed sensibly. "Dell Latitude laptop" went to Computer equipment, margin 0.16. "nitrile exam gloves"
went to Medical, margin 0.16. "USB-C docking station" went to Office furniture with **margin 0.01**: exactly the
kind of row to send to the LLM.

### Recommended path for 50M rows
1. **Dedupe** the normalised text (lowercase, collapse whitespace and digits) with the frame engine's group-by.
   Seconds. Purchase lines repeat heavily, but the ratio depends on the data (assume 5 to 20x, unverified).
2. **Embed the unique rows** with all-MiniLM-L6-v2 as a MEF pack through `maxrt`. This needs a WordPiece
   tokenizer in Mojo (about 150 lines; vocab.txt ships with the pack). At about 25k rows/s, 5M unique rows take
   about 3.5 min and 50M (no dupes) about 33 min.
3. **Nearest label.** Embed the label texts once. For UNSPSC, use the hierarchy (segment -> family -> class ->
   commodity, about 50 to 150 candidates per level) or one matmul against all commodity titles. Either is
   GPU-cheap: about 0.1 to 0.3 GFLOP per 1k rows against 70k labels, well under the embed cost (estimate). Keep
   the top-2 margin.
4. **Uncertain rows** (margin under a threshold tuned on a labelled sample, perhaps 5 to 15% of uniques) go to
   Qwen3-0.6B (Apache-2.0), scoring the top-k candidate codes. Rough guess: 1k to 3k rows/s on a 3090 with a
   shared prefix (prefill-only scoring), **unverified**. An LLM in-process through a MEF isn't realistic (KV cache
   and the scheduler are Python in `max serve`), so this step goes through `max serve`, the named exception in
   `docs/plans/omxconsole-native.md`. That keeps the hot path (steps 1 to 3) all-Mojo.
5. Write the labels back by joining on the dedupe key.

End to end, 50M rows with 5M unique and 10% of those uncertain: about 3.5 min embed + about 3 to 8 min LLM
(**estimate**). Overall that is roughly 50k to 150k input rows/s after dedupe. Without dedupe, the embed step
alone is about 25k rows/s.

Why not GLiClass/GLiNER2 first: both are Apache-2.0 and likely more accurate than raw embedding similarity. But
they are DeBERTa-v3 cross-encoders (label tokens and text in one pass). The cost grows with the number of labels,
so they don't fit 70k UNSPSC codes, and MAX has no DeBERTa (disentangled attention would be our own port, about
1 week, unverified). Good second step: rerank the top-10 candidates for uncertain rows instead of the LLM.

## Unverified / open
- macOS libmax in-process (run on `scripts/mac-ci`); load time of a large MEF through the C API.
- YOLOX-Tiny MAX latency and parity (estimates above); NMS op speed on the GPU.
- MiniLM numeric parity vs sentence-transformers; bf16 build; Qwen3-0.6B scoring rows/s; the real duplicate ratio
  and uncertain share on purchase data; zero-shot accuracy on real UNSPSC titles (8 lines is a sanity check, not a
  measurement).
- D-FINE/DEIM/RT-DETR licences were taken from Roboflow pages, not checked at the repos.
- Shipping about 200 MB of Modular libraries in an MIT app: they are under Modular's licence, so add a NOTICE (see
  the MIT-always memory). Check that redistribution terms allow bundling.
