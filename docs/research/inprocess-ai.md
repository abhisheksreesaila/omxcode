# In-process AI: how omxconsole could give omxplorer non-LLM models without HTTP (research, 2026-10-30)

Question: omxplorer will need detection, segmentation and OCR models on video frames. omxconsole should turn any
PyTorch/Hugging Face model into a MAX one. How does omxplorer call that model like a normal function, without
HTTP, and without omxconsole's weights living inside omxplorer's assets?
Status: research only. Nothing here was built. "Measured" means measured on this machine today; everything
else is from the sources linked, or marked **unverified**.

## The problem in 3 lines

- A 1280×720 RGB frame is 2.76 MB; as base64 it is 3.69 MB. Measured here (CPython): base64 encode + JSON
  dump + JSON load + base64 decode = **≈ 17 ms** per frame, before the socket, HTTP and a GPU→CPU→GPU round trip.
- The models themselves are faster than that: YOLO11n 1.5 ms, RT-DETR-R18 ≈ 4.6 ms (217 FPS), MobileSAM's image
  encoder ≈ 8 ms ([Ultralytics](https://docs.ultralytics.com/models/yolo11), [RT-DETR](https://huggingface.co/PekingU/rtdetr_r18vd), [MobileSAM](https://docs.ultralytics.com/models/mobile-sam); vendor numbers on T4/A100 GPUs).
- So HTTP+JSON costs 2–10× the model. At 30 fps (33 ms a frame) it eats half the budget on its own.

## Two facts that shape every option

1. **MAX has a C API, installed today.** `max/include/max/c/*.h` and `modular/lib/libmax.so` ship in our pixi
   env (MAX 26.6). It compiles or loads a model (`M_setModelPath`, `M_compileModelSync`, `M_initModel`), loads
   weights straight from safetensors (`M_newWeightsRegistryFromSafetensors`), and takes inputs by pointer
   (`M_borrowTensorInto`: "borrowed in place (zero-copy) only if input already resides on that device").
   It is opaque pointers and scalars only, which is exactly what our Mojo FFI rule allows. Docs:
   [MAX C API, model.h (v26.7)](https://max.modular.com/stable/api/c/model). The Python API can also write
   a compiled graph to a file: `CompiledModel.export_mef()` and `max.engine.read()` (in `max/engine/api.py`).
2. **MAX no longer imports PyTorch or ONNX files.** TorchScript was removed in 25.4 and the torch dependency
   in 25.5 ([v25.5 notes](https://docs.modular.com/releases/v25.5/)); the installed 26.6 has no ONNX or
   TorchScript code at all (checked: `grep -ri onnx` finds nothing). "Convert a PyTorch model to MAX" now means
   **porting**: rewrite the model in `max.graph`/`max.nn` (which has `conv.py`, ViT parts in `clip`, etc.),
   then check it against PyTorch. That is what omxconsole's porter already does for text LLMs; its own docs say
   vision models "haven't been tried through porting" (`~/Projects/mxstudio/docs/PORTING.md`).
   Also: the **Mojo** `max.engine` API is deprecated in favour of Python
   ([InferenceSession, Mojo](https://docs.modular.com/max/api/mojo/engine/session/InferenceSession)), so Mojo
   cannot call MAX natively except through the C API or Python.

So in every option below, omxconsole's job is the same: **port, check, compile, cache, publish a "model pack"**.
The options differ in where the pack runs.

## Option 1: model pack loaded in-process through MAX's C API (omxconsole = build tool + registry)

**How it works.** omxconsole ports the model to a MAX graph, checks it against PyTorch, compiles it, and writes a
pack folder. omxplorer never imports omxconsole; it only reads a pack by name from `~/.mxc/packs/`.

```
~/.mxc/packs/rtdetr-r18@1/
  pack.toml            # inputs/outputs (name, dtype, shape), MAX version, GPU, source HF repo@revision, licence, sha256
  model.mef            # the compiled graph (export_mef)
  weights.safetensors
```

A small generic mojoui component (`mojoui/modelpack.mojo`, not built) wraps the C API:

```mojo
var det = ModelPack.open("rtdetr-r18@1")          # dlopen libmax, M_compileModelSync(model.mef), M_initModel(weights)
var out = det.run(frame)                          # frame: a DeviceBuffer already on the GPU
# inside run(): external_call["M_borrowTensorInto"](inputs, frame.unsafe_ptr(), spec, status)
#               external_call["M_executeModelSync"](ctx, model, inputs, status)
```

- **Speed:** model time plus microseconds. No copy if the frame is already on the GPU (the header's promise; **unverified** with a Mojo-made buffer).
- **Cost to build:** the wrapper, 3–5 days. Each model needs a port (the big cost, like LLM ports: an agent run plus checks; vision is new ground for the porter).
- **Risks:** (a) **unverified** that `M_setModelPath` loads a `.mef` (the docs only say "path to your model"); (b) libmax and our Mojo binary must share one Mojo runtime: same MAX/Mojo versions in both, or two copies of the runtime in one process; (c) a pack is tied to a MAX version and GPU, so omxconsole must rebuild packs on upgrade (it already does this for ports); (d) Modular has deprecated other non-Python APIs before; ask whether the C API is long-term.
- **Variant worth keeping in mind:** the pack can carry its own tiny `libpack.so` with a 3-function C ABI (`open`, `run`, `close`, tensors passed as a [DLPack](https://dmlc.github.io/dlpack/latest/python_spec.html) `DLTensor*`). Then omxplorer doesn't even know MAX exists, and a pack could hold hand-written Mojo instead (Option 4). More decoupled, one more layer.

## Option 2: omxconsole runs the model as a sidecar; frames go through shared memory or CUDA IPC

**How it works.** omxconsole starts one process per model (it already supervises `max serve` processes). The
frame lives in memory both processes can see: a ring of frame slots in POSIX shared memory, or GPU buffers
shared with [`cudaIpcGetMemHandle` / `cudaIpcOpenMemHandle`](https://docs.nvidia.com/cuda/cuda-runtime-api/structcudaIpcMemHandle__t.html).
A Unix socket carries only tiny messages ("run slot 3 with these points", "slot 3 done").

```mojo
var sam = Sidecar.connect("mobilesam")    # /run/user/$UID/omx/mobilesam.sock
var slot = sam.ring.acquire()             # shared-memory slot (or CUDA IPC buffer)
slot.write(frame)                         # 2.76 MB memcpy, ≈ 0.3 ms (unverified estimate); zero for CUDA IPC
var masks = sam.call(slot, points)        # a 32-byte message each way; result lands in another slot
```

- **Speed:** ≈ 0.3–1 ms overhead per frame (copy + wake-up + host→GPU in the sidecar); near zero with CUDA IPC. Estimates, **unverified**.
- **Cost to build:** 1–2 weeks: the ring buffer, the protocol, lifetimes (who frees a slot), crash recovery.
- **Risks:** CUDA IPC is Linux only and needs care (freeing memory the other side still maps is undefined behaviour); Mac would need IOSurface instead. Two processes to keep in sync, but a model crash can't take omxplorer down, and the pack's Python/MAX world stays out of omxplorer. Note: in goal 39, frames come from an ffmpeg pipe into CPU memory, so plain shared memory is enough for now.

## Option 3: stop-gap: Mojo's Python interop calls MAX's Python API (or PyTorch) in-process

**How it works.** Mojo can import Python modules ([Mojo manual: Python](https://mojolang.org/docs/manual/python/)).
omxplorer embeds CPython and calls `max.engine` on the same pack (or `torch` directly, with no porting).

```mojo
from std.python import Python
var engine = Python.import_module("max.engine")
var model = engine.InferenceSession(devices=...).load("~/.mxc/packs/rtdetr-r18@1/model.mef")
var out = model.execute(as_numpy(frame_ptr, 720, 1280, 3))   # wrap our pointer, no copy (unverified)
```

- **Speed:** model time plus a Python call (tens of µs, plus the GIL); a copy if the pointer can't be wrapped.
- **Cost to build:** 2–3 days. Fastest way to see a real model in omxplorer.
- **Risks:** puts Python back into an app we made Python-free (Experiment 20); ships a Python env (PyTorch is gigabytes); no path to iPhone or Android. Good for a demo, a dead end for the product.

## Option 4: pure Mojo kernels for the small classic models

**How it works.** Write the forward pass of a few small models directly in Mojo GPU code (convolutions,
attention), loading weights from the safetensors file omxconsole publishes. omxconsole's role shrinks to
"download, convert weights to our layout, check outputs against PyTorch".

```mojo
from mojoui.models.rtdetr import RTDetr            # not built
var det = RTDetr.load("~/.mxc/packs/rtdetr-r18@1/weights.safetensors", ctx)
var boxes = det(frame, ctx)                         # our own kernels, our own DeviceContext
```

- **Speed:** depends on our kernels; likely slower than MAX's tuned ones at first (**unverified**).
- **Cost to build:** 2–4 weeks per architecture; it does not scale to "anything on Hugging Face".
- **Risks:** a lot of numeric code to keep correct. But it is the only option that can reach Mac (Metal), Android and iPhone the same way, because it needs only the Mojo compiler, not MAX's runtime.

## Option 5: batch mode on the command line; the interface is a file

**How it works.** For whole videos (the drone's hours of footage), no per-frame call is needed:
`mxc analyse drone_a.mp4 --model rtdetr-r18 --out detections.parquet`. omxconsole runs MAX at full speed on its
own; omxplorer opens the Parquet file with the MX frame engine it already has.

- **Speed:** best throughput (batches, no UI in the way), zero transfer cost; but not interactive (no "tap a pallet, segment it now").
- **Cost to build:** 2–3 days on top of a ported model. **Risks:** low; complements 1 or 2 rather than replacing them.

## Comparison

| | Per-frame overhead | Coupling to omxconsole | Effort | Mac | Android / iPhone |
|---|---|---|---|---|---|
| 1. Pack via C API, in-process | ≈ 0 (pointer) | a folder format + libmax | wrapper 3–5 d + a port per model | likely (MAX runs on Apple GPUs since 26.4, [forum](https://forum.modular.com/t/max-models-can-now-run-on-apple-silicon-gpus/3283)); C API there unverified | no (no MAX runtime) |
| 2. Sidecar + shared memory / CUDA IPC | 0.3–1 ms (est.) | a socket protocol | 1–2 weeks | yes with shared memory | no |
| 3. Python interop | µs + GIL | Python env | 2–3 d | yes | no |
| 4. Pure Mojo kernels | ≈ 0 | weights only | 2–4 weeks per model | yes | yes (CPU or GPU, unverified speed) |
| 5. CLI batch to Parquet | none (offline) | a file | 2–3 d | yes | n/a |

## Recommendation

**Recommendation: Option 1, the model pack loaded through MAX's C API, with Option 5 as its free companion.**
omxconsole becomes the build tool and registry (port, check against PyTorch, compile, publish `~/.mxc/packs/<name>@<version>`);
omxplorer gets a generic `ModelPack` component in mojoui and calls a model like a function, frames staying on the GPU.
It matches "in process, modular, not tied to omxplorer", needs no Python in the app, and the same packs feed `mxc analyse`.
Keep Option 2 as the fallback if two Mojo runtimes in one process prove impossible; keep Option 4 for the one or two models
that must run on phones.

**First step (one day):** prove the riskiest link with the smallest model possible.
1. In Python (`max.graph`), build a tiny graph (one `max.nn` conv plus a sum), compile it, `export_mef("tiny.mef")`, save its weights as safetensors.
2. `tests/test_modelpack.mojo` calls libmax through `external_call`: load `tiny.mef`, bind the weights, borrow a 1280×720 frame from a Mojo `DeviceBuffer`, execute, read the output.
3. It prints `pack load: ok`, `pack run: ok` (equals the Python result), `pack run ms: X` and `pack zero-copy: yes/no`.

**Ask or verify first:**
- Does `M_setModelPath` + `M_compileModelSync` accept a `.mef` from `export_mef`? (Five minutes in C or Python ctypes.)
- Can a Mojo 1.1 program link `libmax.so` from the same MAX 26.6 install without a runtime clash? Does a Mojo `DeviceContext` buffer count as "on that device" for `M_borrowTensorInto`?
- Ask Modular (forum) whether the C API is a supported long-term surface, given the Mojo engine API's deprecation.
- Licences, before picking models: Ultralytics YOLO is AGPL-3.0 or paid ([ultralytics.com/license](https://ultralytics.com/license)); RT-DETR ([PekingU/rtdetr_r18vd](https://huggingface.co/PekingU/rtdetr_r18vd)) and SAM 2.1 ([facebookresearch/sam2](https://github.com/facebookresearch/sam2): tiny 38.9 M params, 91 FPS on an A100) are Apache-2.0. MobileSAM and EfficientSAM licences: **unverified**, check their repos.
- Can omxconsole's porter handle a vision model at all? Try RT-DETR-R18 first (a ResNet plus a small transformer, 20 M params).
