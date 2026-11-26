# omxcode vs nanoui: nanoui's own benchmark scenes, same machine (2026-11-22)

**Machine:** Linux, AMD Ryzen 9 5900X, NVIDIA RTX 3090 (driver 615.78.08), both headless (EGL, no window).
**Rules (nanoui's `hillclimb`):** 900×640 points at 2x (1800×1280 px), 30 warm-up frames, 300 measured, 3 runs, the
run with the lowest median frame kept. Medians in ms; lower is better.

- **nanoui:** commit `cfe6000` (justrach/nanoui), Zig 0.17.0, ReleaseFast. On Linux their harness only has a CPU
  raster, so `glrun.zig` (+ `nanoui-gl.patch`: two exports in `ui.zig`, one switch in `main.zig`) times their own
  OpenGL renderer (the one GtkGLArea windows use) in a headless EGL context, as their `tests_opengl.zig` does.
- **omxcode:** `bench/nanoui/scenes.mojo` on goal 79's `gpu2d` (GL backend), `mojo build -O3`.

| scene | frame CPU nanoui | frame CPU omxcode | GPU nanoui | GPU omxcode | instances n / o |
|---|---:|---:|---:|---:|---:|
| boxes (600 shadowed boxes) | 0.088 | **0.053** | 0.228 | **0.158** ¹ | 1201 / 1201 |
| text (300 changing labels) | **0.171** | 0.627 | **0.092** | 0.103 | 1201 / 1201 |
| scroll (1000-row column, clipped) | **0.674** | 5.101 | **0.091** | 2.445 | 1221 / 24791 |
| list (100 000-row virtual list) | **0.065** | 0.117 | **0.076** | 0.416 | 813 / 583 |
| dashboard (12 cards) | **0.027** | 0.102 | 0.140 | **0.137** ¹ | 325 / 325 |

CPU fallback (no GPU), same frames: nanoui's multi-threaded raster 2.4–41 ms; omxcode's single-threaded
`execute_cpu` 25–540 ms.

frame CPU: nanoui = view build + flexbox layout + paint; omxcode = Scene build (positions by hand, no layout engine) +
`fill_batches` + `merge_runs`. GPU: draw + glFinish wall time, both.

¹ Not like for like: mojoui's Scene has no Gaussian shadow; ours are one flat translucent rect each (same instance
count, cheaper pixels). Fonts differ: nanoui found Noto Sans; "Noto Sans" fell back to mojoui's default face.

## What it says

1. **Shapes: we're ahead** on CPU (0.053 vs 0.088) and level on GPU, with the shadow caveat.
2. **Text: we're 3–4× slower on CPU.** `fill_batches` shapes every run every frame through `fonttext.shape`'s
   string-keyed cache (key built, Dict lookup, Run copied; changing numbers miss, and the cache clears at 8,192). Not
   yet profiled. nanoui places glyphs from a glyph cache.
3. **Clipped content: no culling.** The scroll scene sends all 1000 rows; nanoui's paint drops what the clip hides
   (1,221 instances), ours shapes and draws all of them (24,791): 7.5× CPU, 27× GPU.
4. **CPU fallback:** theirs is 10× faster (threads; ours is a single-threaded reference).

Generic fixes, every app gets them (no benchmark-specific code): cull runs and rects outside the current clip
before shaping; a glyph-run cache keyed by (style id, text hash) without per-frame string keys or Run copies; a
Gaussian shadow primitive (GPUI's analytic shadow); threads in `execute_cpu`. Then rerun this and the M4 (Metal) race.
