# Goal 75 report: silky on the GPU, Linux and Mac

Worktree ../mojo-ui-g74, branch `goal-75-gpu-canvas` (base: goal 74's a2a91071, itself not on main). Not merged, not
pushed. Decisions D-7501 onward (docs/decisions.md), attempts in docs/journal.md. Checker: `pixi run python docs/goals/75-check.py`.

**Owner's ask (11-18):** "a native Linux and Mac running on GPU with super speed… I will judge with whiteboard and canvas
and mindmap… personalnote.app has a Tony Buzan mind map and silky smooth."

**Answer:** pnote's three judged scenes now run on our own GPU renderer, written in Mojo over GL (Linux) and Metal (Mac),
with no third-party 2D library. They are silky on the RTX 3090 desktop and on the owner's M4. Silky means p95 ≤ 8.3 ms and
no frame over 16.7 ms, counted honestly on both hosts. Before this goal the worst frames were 120–230 ms on Linux, and the
Mac drew on the CPU at 15–34 ms a frame.

## Milestones
| # | Result | Main commits | Proof |
|---|---|---|---|
| M0 Baselines | PASS | 2d4ecc70, adfd5e9d | docs/goals/75/baseline.md, generated on both machines |
| M1 Renderer core | PASS | 5611510b | mojoui.gpu2d: a Scene → instanced batches, plus a CPU executor matching SurfacePainter to ~0 levels |
| M2 Linux GPU | PASS | 559e08e3, e77419b8, 2ce48e40 | GL backend, draw-ahead, GTK graphics offload; readback within bounds |
| M3 Mac GPU | PASS (5 of 5 in a row) | 226d3a26, dfd145fb, f7796b05 | Metal backend; the main thread never blocks on the GPU; labels change without a relayout; wall clock gated |
| M4 Buzan map, silky | PASS | c3734869, e77419b8 | ribbons, a colour per branch, words on branches, springs; grow silky on both machines; build/g75/compare.png |
| M5 Whiteboard ink | PASS | 2ce48e40 | pen draw and strokes landing silky on both machines with 1,000 strokes |
| M6 Nothing regressed | PASS | 82b33694, 2ae7e1fd | goal 74 M1–M7, goal 40 M0–M2, matrix lists gpu2d (✅ Linux and Mac), decisions lint |

Reviews:
- **Round 1: NEEDS WORK** (1 must, 4 shoulds). The Mac's timing left out a main-thread GPU wait. Fixed: the Mac stopped
  blocking, and the checker requires wall clock and cpu_frames=0 (D-7554..D-7556).
- **Round 2: PASS** (8 shoulds, all fixed in 2ae7e1fd).

## Numbers (p50 / p95 / max ms)
Linux: RTX 3090, Hyprland. Final runs are on the hidden 1.6× test screen (see "How it was measured").

| Scene | Step | Before (GSK, Vulkan) | Now |
|---|---|---|---|
| Whiteboard (1,000 strokes) | pan | 0.8 / 73.5 / 96.0 | 1.2 / 3.5 / 4.7 |
| | zoom | 0.8 / 35.1 / 106.2 | 1.6 / 4.0 / 4.5 |
| | pen draw | 2.0 / 6.5 / 13.7 | 1.9 / 4.1 / 7.4 |
| | strokes landing | 1.5 / 4.1 / 5.3 | 1.6 / 2.5 / 3.9 |
| Canvas (645 objects) | pan | 1.0 / 125.9 / 137.2 | 1.2 / 1.9 / 3.4 |
| | zoom | 1.0 / 56.0 / 180.3 | 2.1 / 2.5 / 2.6 |
| Mind map (300 topics) | pan | 1.1 / 1.4 / 2.0 | 1.4–1.7 / 1.8–2.3 / 2.7–3.5 |
| | zoom | 1.1 / 1.4 / 1.5 | 2.1–2.4 / 2.5–3.9 / 6.8–7.5 |
| | grow | 83.9 / 111.6 / 141.3 | 2.5–2.9 / 2.9–4.0 / 3.0–4.6 |

Mac (M4). Frame work is p50 / p95 / max; wall clock is p95 / max. Last of 5 passing M3 runs (f7796b05), taken while
another project's GPU training job was running on the Mac:

| Scene | Step | Before (CPU), p50 / p95 / max | Now: work | Now: wall |
|---|---|---|---|---|
| Whiteboard | pan | 29.7 / 32.4 / 37.1 | 1.3 / 3.2 / 10.1 | 2.7 / 9.0 |
| | zoom | 31.3 / 33.4 / 74.0 | 1.6 / 6.0 / 8.1 | 4.1 / 6.3 |
| | pen draw | 33.0 / 34.0 / 34.4 | 0.9 / 2.6 / 5.6 | 1.6 / 3.8 |
| | strokes landing | 33.6 / 34.8 / 76.4 | 1.6 / 5.7 / 7.7 | 3.9 / 5.9 |
| Canvas | pan | 15.5 / 17.2 / 28.6 | 1.2 / 2.3 / 2.6 | 1.9 / 2.4 |
| | zoom | 19.4 / 27.5 / 55.2 | 1.8 / 3.4 / 3.7 | 2.9 / 3.4 |
| Mind map | pan | 4.7 / 5.9 / 14.3 | 1.3 / 2.0 / 2.7 | 1.4 / 2.2 |
| | zoom | 4.1 / 10.9 / 27.8 | 1.9 / 4.8 / 7.1 | 4.3 / 6.6 |
| | grow | 6.5 / 9.4 / 27.9 | 2.0 / 4.0 / 8.5 | 3.4 / 7.9 |

Across the 5 runs, wall p95 / max ranged 2.9–4.6 / 3.4–8.6 for canvas zoom, 3.4–4.2 / 5.7–7.9 for mind map grow, and
3.0–3.4 / 4.2–5.1 for whiteboard landing. An earlier batch under the same training job passed 2 of 5: the failures
were the other job's GPU queue and shared GPU time, which the per-frame breakdown (D-7584) names.

Readback, GPU vs the CPU executor (mean levels / % of pixels > 40 off):
- Linux: within M1's bounds in every run.
- Mac: whiteboard 0.0006 / 0 %, canvas 0.0208 / 0.0144 %, mind map 0.0004 / 0 %.

## What made it fast (all in the framework, any app gets it with `Canvas(…).gpu()`)
- **One renderer, two backends.** gpu2d turns the Scene into a handful of instanced batches:
  - quads with distance-field corners;
  - glyphs from one atlas;
  - analytic or stencil polygons;
  - per-instance clips.
  GL and Metal execute the same batches. A 300-topic map went from ~490 draw calls a frame to ~100.
- **Layer cache per canvas.** A layer that only moved is reused, and a finished stroke is appended, not rebuilt. Text
  layers are kept through a pan at the zoom they were built at (this was 4× of the map's cost at 1.6×).
- **Never wait on the GPU on the main thread.**
  - Mac: up to two frames in flight, with Metal's completion handler handing the IOSurface to Core Animation.
  - Linux: fences, and GTK graphics offload. The frame goes to Hyprland as a dmabuf subsurface carrying its own fence, so
    GTK neither composites it nor waits on it.
- **Draw ahead.** An animating canvas draws its next frame right after the paint, while the GPU is idle. That frame is
  dropped if anything changed in between.
- **Mac labels and uploads.** A label whose new words fit its old size redraws without a window layout pass (D-7582).
  Layer uploads no longer wait for frames in flight (D-7583).
- **The fault found on the way:** the stroke triangle strip started at the wrong point, covering 35× the stroke's area.

## How it was measured, and what to doubt
- **Same rule on both hosts.** Frame work is CPU + our GPU time + the host's paint of the frame that shows it. The Mac
  also gates on wall clock. Frames that fell back to the CPU fail a GPU step (cpu_frames=0 / gpu_frames=n).
- **D-7571: the measuring tool's own check.** For offloaded frames on Linux, framebench's own render-to-texture check is
  printed but not added. GTK never composites those frames, and an on/off A/B showed it doesn't change the other parts.
  Counted in, the pen steps would read ~10 ms p95. Review round 2 judged this honest.
- **The hidden test screen (D-7573, D-7574).** At the owner's request, desktop runs open on a hidden headless Hyprland
  output: same GPU, same compositor, same size and scale as the monitor (3440×1440 at 1.6×). GOAL.md said "not a virtual
  display". The only visible-vs-hidden comparison was at the old 1× screen, where hidden flattered by about 2×. A 1.6×
  visible comparison waits for the owner's OK. Visible runs on the final pen build passed too (draw 4.1–4.6, landing
  4.3–4.8 p95).
- **Time to screen.** About 31 ms from a finished frame to it showing (two 60 Hz refreshes), with or without offload. It's
  gated on visible runs against a GL-texture baseline (D-7576) and not gated on the hidden screen.
- **Low GPU clocks.** NVIDIA drops to P8 (210 MHz) during these steps, and that's where every Linux failure lived. We
  didn't touch the global driver setting that would keep the GPU fast.

## Limits and debt
- **Canvas inset.** At 1.6×, the offloaded canvas sits on whole pixels: inset up to 4 px per edge, filled with its own
  background, with input forwarded (D-7577).
- **The `offload=` column** reads GTK 4.14–4.24's private struct, guarded. On other GTK versions it reads 0.
- **Two GPU canvases on one screen:** fine up to 8 (per-canvas cache). The renderer is chosen at start through
  `App.GPU_2D` (D-7562).
- **Text** is still the baked atlas: blurry at big zooms, 106 glyphs, no IME. That's the next goal.
- **Mac runs** were taken with the Mac's screen locked over SSH, and the final five while another project trained on
  its GPU. A pass under a heavy GPU neighbour is likely, not guaranteed: Metal has no public queue priority.

## Next
1. Text: system fonts, shaping, sharp at any zoom, IME, paste from other apps.
2. The GPUI race on both machines.
3. The vibrancy sidebar's native screenshots, side by side.
4. Merge goals 74 and 75 into main once the machine is quiet and the owner agrees.
