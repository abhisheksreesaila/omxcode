# VisionModel spike: OWLv2 and SAM 2.1 in process from Mojo (goal 39, M12 spike, 2026-10-30)

Question: can omxcode run a learned vision model on a video frame, in the same process, without files or HTTP, and
get rows back that the existing VideoTable / Analyzer pipeline already understands? Does it work on our generated
footage, and how fast?

Short answer: **yes, it works.** A Mojo test opens a VideoSource frame, hands its address to PyTorch, runs OWLv2 and
SAM 2.1, and gets boxes, masks and tracks back as VideoTable rows (`visionmodel: ok`). The hand-off costs 0.35–0.75 ms
from host memory and **0.06 ms with no copy** from a MAX GPU buffer. The models cost 20–30 ms per frame.
The catch is quality: OWLv2 matches what things *look like*, not what they *mean*. "a red splat" finds torn packages
(recall 0.98, precision 0.90 per keyframe), but "a torn package" doesn't (recall 0.02 when it competes with other
prompts; alone it fires on every box).

Everything below was measured on this machine (RTX 3090, GPU 1) unless marked **unverified**.

## What was built

| File | What it is |
|---|---|
| `pixi.toml` | a `models` feature and environment (`pixi run -e models …`): torch, torchvision, transformers, accelerate, safetensors from PyPI. The default environment and its lock section did not change (checked by comparing the parsed `pixi.lock`; D-941). |
| `mojoui/visionmodel.mojo` | the framework API: `VisionModel` (DETECT or SEGMENT: `detect`, `detect_on_device`, `stage`/`flush` batches, `segment`, `track_start`/`track_add`/`track_step`), `Detection`, `MaskBox`, and `ModelAnalyzer` (an `Analyzer`: keyframe stride, batching, links boxes into tracks across keyframes, fills the frames between by interpolation). No footage words in it. |
| `mojoui/visionmodel_torch.py` | backend (A): `Detector` (OWLv2 with GPU preprocessing: pad, resize, normalise in torch, not the CPU processor) and `Segmenter` (SAM 2.1 video, streaming). Frames come in as an address, or as a CUDA pointer. |
| `tests/test_visionmodel.mojo` | the in-process proof (below). |
| `scripts/vision_spike.py` | the Python-only baseline: annotated PNGs and timings. |

Run:
```
CUDA_VISIBLE_DEVICES=1 pixi run -e models python scripts/vision_spike.py owl   # or: sam
G39_MEDIA=../mojo-ui-g39/build/g39/media CUDA_VISIBLE_DEVICES=1 pixi run -e models mojo run -I . tests/test_visionmodel.mojo
```

## Numbers

**Install.** The `models` environment is 11 GB on disk. That includes the default environment's own packages (Mojo,
MAX, Rust, Node…), because the `models` env adds to the default feature. The torch part alone: nvidia CUDA wheels
3.0 GB, torch 1.1 GB, triton 1.0 GB. `pixi install -e models` took 25 s, but the wheels were already in pixi's cache;
a cold download of ~5 GB will take minutes (**unverified** here). torch 2.15.0+cu132, transformers 5.22.1,
torchvision 0.29.2. `torch.cuda.is_available()` is True on the 3090 (driver CUDA 13.3).

**Weights** (Hugging Face cache, `~/.cache/huggingface/hub`, downloaded in 12 s): OWLv2 base 620 MB, SAM 2.1 tiny
156 MB, SAM 2.1 small 184 MB.

| What | Time |
|---|---|
| `import torch` + `transformers` from Mojo, first use | ≈ 3 s |
| OWLv2 load (weights to GPU, fp16) | 0.9–1.5 s |
| SAM 2.1 tiny load / small load | 0.45–0.5 s / ≈ 0.6 s |
| OWLv2 fp16, 1 frame (960×960 input) | 28–30 ms |
| OWLv2 fp16, batch 4 / 8 / 16 | 21.8 / 20.9 / 20.3 ms per frame (≈ 49 fps at best) |
| SAM 2.1 tiny, video tracking, 1 object | 29.5–29.8 ms per frame (first frame 230 ms) |
| SAM 2.1 tiny / small, 3 objects | 64 / 67 ms per frame (transformers loops over objects) |
| Hand-off, host RGBA 1280×720 → GPU tensor (numpy view of the address, no copy → pinned buffer → GPU) | 0.35 ms (Python) / 0.74 ms median from Mojo |
| Hand-off, MAX `DeviceBuffer` → torch tensor (CUDA Array Interface, no copy) | **0.06 ms**; boxes identical to the host path |
| Whole `det.detect(...)` call from Mojo (hand-off + model + boxes back) | 31.7 ms (model 30.5 ms: interop overhead ≈ 1 ms) |
| `scan()` + `ModelAnalyzer`, 120 frames, stride 5, batch 8 | 24 model frames in 0.51 s; 639 rows; 77 frames/s end to end |
| The whole warehouse video (1140 frames), stride 5, batch 8, Python | 228 keyframes in 5.4 s |
| Peak GPU memory, OWLv2 batch 16 / OWLv2 + SAM tiny | 1.8 GB / 1.8 GB |

So for the 38 s warehouse video: every frame through OWLv2 would be ≈ 23 s; with stride 5 it is ≈ 5 s plus the
decode. SAM tracking is **not** cheaper than detecting here (30 ms per object per frame vs 21 ms per frame for any
number of objects), so the "detect on keyframes, track between them" trick should interpolate boxes (what
`ModelAnalyzer` does) and call SAM only when someone asks for masks (D-947).

## Quality on our footage (look at the images)

Annotated frames are in `build/g39e/out/` (not committed; `scripts/vision_spike.py owl` / `sam` rewrites them).

- `owl_warehouse_420.png`, `owl_warehouse_200.png`, `owl_warehouse_800.png`: with the brief's prompts ("a cardboard
  box", "a torn package", "a person's face", "a barcode label") at 0.2, only the barcode labels (0.23–0.31) and one
  box come out. The boxes are tight where they appear. OWLv2's scores on this cartoon-style footage are low
  (0.05–0.4), and prompts compete: each box goes to the prompt that scores best.
- Prompt wording matters more than anything else (`/tmp` probe, frame 420, top scores):
  "a box on a conveyor belt" 0.37 / 0.27 / 0.25 on the three pallets (and the belt itself, 0.23, and the blue floor
  crates); "a cardboard box" 0.11 at most; "a red splat" 0.23 on the tear; "a torn package", "orange damage on a box",
  "a person's face", "a face": nothing. Heads: "a head" 0.05–0.12, "a person" 0.12–0.15 (whole bodies). Cartoon faces
  are weak.
- Damage over the whole video (228 keyframes, truth = `damaged_frames` in truth.json, a keyframe counts when a damaged
  pallet is on screen):
  - "a red splat" (with three other prompts) > 0.15: **recall 0.98, precision 0.90**; > 0.1: recall 1.00, precision 0.88;
    > 0.2: recall 0.44.
  - "a torn package" with the others: recall ≤ 0.02. Alone > 0.08: recall 0.85 but precision 0.56, which is just
    the base rate: it fires on any box.
- One example instead of words (OWLv2 image-guided detection, a crop of one tear as the query):
  `owl_guided_tear_800.png`: the two tears on frame 800 come out at 1.00, ahead of everything else (the scores are
  normalised per image, so it needs a "top score" rule, not a fixed threshold). On the drone,
  `owl_guided_burn_175.png`: the burn mark (19×19 px) comes out at 1.00, where text prompts got 0.04.
- Drone (`owl_drone_a_100.png`, `owl_drone_a_255.png`): "an electrical insulator" puts boxes on the crossarms and
  insulator strings, at 0.05–0.09: right places, at the noise floor. "a burn mark" finds nothing (marks are ≈ 18 px
  in a 1280 px frame, ≈ 13 px after OWLv2's resize to 960). Tiling the frame, or one example image, are the fixes.
- SAM 2.1 (`sam_track_200.png` … `sam_track_259.png`): seeded with OWLv2's box for pallet 2872, the mask fills the
  pallet (area 32.5k px in a 204×163 box) and follows it for 60 frames until it leaves the frame on the right
  (x 736 → 1167, the box shrinking at the edge). A second seed on a pallet already leaving the frame went to area 0 at
  once (lost, correctly). A third seed was OWLv2's false positive (a floor crate) and SAM tracked that too: SAM follows
  whatever it is given.

## What broke and how it was fixed

- `[system-requirements] cuda` is refused when the workspace declares per-platform virtual packages. A second
  platform with `cuda = "12"` worked but re-solved the **default** environment for that platform too (a different
  package set): rejected. Fix: torch from PyPI wheels, which carry their own CUDA, on the existing `linux-glibc-234`
  platform (D-941).
- A conda `ffmpeg` in the feature shadowed the system one and rejected `-vsync`; removed it so the `models` env decodes
  exactly like the default env (D-942).
- SAM 2 video in transformers: adding several objects one call at a time before the first frame fails with
  "maskmem_features in conditioning outputs cannot be empty". Adding them all in one call works (`add_boxes`, D-946).
- `VideoTable.intervals()` assumes the scan started at frame 0 (`frames` is a count, not an end frame): a scan that
  starts at frame 400 gets no intervals. Not fixed (outside the spike); the test counts rows instead. Worth a fix.

## How it maps onto omxconsole (later)

`VisionModel(name, task)` takes a Hugging Face id today and reads HF's cache. A model pack is the same call with a
folder: omxconsole fetches the weights (HF id @ revision), records licence and sha256, and writes
`~/.cache/omx/models/<name>@<rev>/` (or `~/.mxc/packs/`, docs/research/inprocess-ai.md) with `pack.toml` (task: detect
or segment; inputs; backend: torch or max; the default prompts or example crops). omxplorer never imports omxconsole;
it reads the folder. For backend (A) the pack is just the HF snapshot plus `pack.toml`; for (B) it adds the compiled
MAX graph. `from_pretrained` already accepts a local folder, so (A) needs no code change to read a pack (D-948).

## The path to backend (B), native MAX

Verified today:
- MAX's C API is in the `models` env: `libmax.so` exports `M_setModelPath`, `M_compileModelSync`,
  `M_newWeightsRegistryFromSafetensors`, `M_borrowTensorInto` (70 `M_` symbols).
- A MAX `DeviceBuffer` made by Mojo and a torch tensor share the CUDA context in one process: torch read the MAX
  buffer through its pointer with no copy, and the boxes matched the host path exactly. So a frame decoded into a GPU
  buffer once can feed MAX kernels, our own kernels and torch with no copies.
- MAX 26.6 ships a `clip` architecture (`max/pipelines/architectures/clip`). OWLv2 is a CLIP ViT-B/16 plus two small
  heads (class and box), so its port is "CLIP + two MLPs".

Not verified:
- that a port of OWLv2 to MAX gives the same boxes (nothing was ported);
- that `M_setModelPath` loads an exported `.mef`, and that libmax and our Mojo binary share one runtime (the risks in
  inprocess-ai.md);
- SAM 2: Hiera and the memory attention have no MAX counterpart; it is a bigger port, and stays on (A) for longer.

## Recommended next milestone

**M12: a sentence finds things in a video through a learned model, in process.** The sentence goes through a
generic "what does it look like" step (the agent turns "torn packages" into visual prompts such as "a red splat", or
the user taps one example and the model uses that crop), then `ModelAnalyzer` (OWLv2, stride 5, batch 8) and, for the
clips, SAM 2.1 masks on the found frames. No colour presets.

Acceptance check for GOAL.md:

> M12 | `tests/test_visionmodel.mojo` prints `visionmodel: ok` (in-process hand-off ≤ 1 ms from host, a MAX GPU
> buffer with no copy, OWLv2 boxes and SAM 2.1 masks as VideoTable rows). Then `scripts/check.py m12` runs the
> warehouse video through `ModelAnalyzer` with the prompts the agent produced for the sentence "torn packages" (no
> ColourRange in the path) and scores keyframes against truth.json's `damaged_frames`: **recall ≥ 0.95 and precision
> ≥ 0.85**, the whole 1140-frame scan in **≤ 15 s** on the 3090 (decode included); the damaged-pallet reel cut from
> those rows has the right 3 stretches (each within 15 frames of truth); and the drone's burn marks are found from
> **one example crop** in ≥ 4 of truth's 5 marks on flight A.

Today's numbers already meet the warehouse part with a hand-written prompt ("a red splat": 0.98 / 0.90, ≈ 5.4 s of
model time). What M12 adds is the sentence-to-prompt step, the example-crop path in `VisionModel`, the reel from model
rows, and the drone check (unmeasured; one image-guided frame looked right).

Cons to weigh before M12: the `models` env is 11 GB and puts Python and PyTorch back in the process (fine for a demo
and for omxplorer on a Linux box with a GPU, a dead end for iPhone/Android: that is backend B's job); OWLv2's scores
on stylised footage are low, so thresholds per prompt are fragile; SAM tracking costs ≈ 30 ms per object per frame.
