# GOAL 75: silky on the GPU, Linux and Mac (whiteboard, canvas, mind map)

**End goal (owner, 2026-11-18):** "I want a native Linux and Mac running on GPU with super speed… I will judge with
whiteboard and canvas and mindmap… personalnote.app has a Tony Buzan mind map and silky smooth." And: "the mac is
connected to the env, so you can test instead of relying on CI."

Base: goal 74's branch (a2a91071, not yet on main). Worktree ../mojo-ui-g74, branch goal-75-gpu-canvas. Decisions
D-75xx. Checker: `scripts/check` → `docs/goals/75-check.py`. Goal 74's contract is archived as docs/goals/74-GOAL.md.

**What we found first (D-7501):** on the RTX 3090 desktop with GTK's Vulkan renderer, pnote's 645-object canvas pans at
0.7 ms a frame (p50) but spikes to 120–230 ms whenever a layer is rebuilt: GTK fills our ink outlines as vector paths on
the CPU. The Mac host rasterizes every canvas on the CPU at Retina size. So: our own GPU renderer for the Scene.

## The three judged scenes (pnote, `PNOTE_SCENE=`)
- **whiteboard:** 1,000 pressure strokes (~100k points) on a canvas note; pan, zoom, and a pen drawing a new stroke.
- **canvas:** Personal Note's own 645-object benchmark note (300 text boxes, 240 ink paths, 60 rects, 45 arrows).
- **mindmap:** a 300-topic map; pan, zoom, and topics added and collapsed while it animates.
A scene is **silky** on a machine when, over the steps below, frame work is p95 ≤ 8.3 ms (120 Hz) and no frame passes
16.7 ms (one 60 Hz frame), measured by the host's framebench on the real GPU (not a virtual display).

## Milestones
| # | Milestone | Proof (`docs/goals/75-check.py`; PASS, FAIL or BLOCKED each) |
|---|---|---|
| M0 | Baselines, both machines | pnote's PNOTE_SCENE (three scenes); framebench on the AppKit host (pan, zoom, draw, type, as GTK's); scripts/mac-ssh passes app env (MAC_ENV); docs/goals/75/baseline.md generated: each scene's pan/zoom (and draw / grow) numbers on the Linux desktop GPU and the M4 Mac, today's renderers |
| M1 | The renderer's core | `mojoui/gpu2d.mojo` (backend-free): a Scene → batches: instanced rects, rounded rects and circles (distance in the shader), lines, glyph quads from the baked font atlases, images, filled polygons (non-zero, stencil-and-cover fans), clips, layer transforms; plus a CPU executor of the batches. tests/test_gpu2d: `gpu2d batches: ok` (op counts and order kept per layer), `gpu2d cpu: ok` (the CPU executor's picture vs SurfacePainter's for each primitive and for the three scenes: mean ≤ 1.5 levels, ≤ 0.5 % of pixels more than 40 off) |
| M2 | Linux on the GPU | a GL backend (mojoui.present's context): batches → an MSAA texture (stencil polygons, the glyph atlas as a texture), shown by GTK as a GdkGLTexture; canvases opt in (`Canvas(…).gpu()`), CPU fallback when GL is missing. Readback vs the CPU executor within M1's bounds; on the desktop (GTK on the real Wayland display): all three scenes silky |
| M3 | Mac on the GPU | a Metal backend (same batches; instanced pipelines and the stencil fill built once at start), shown through a CAMetalLayer (or the IOSurface the host has); readback vs the CPU executor within M1's bounds; on the owner's M4 over scripts/mac-ssh: all three scenes silky |
| M4 | A Buzan mind map, silky | mojoui.mindmap: one-bend organic branches as ribbons tapering by depth (thick at the root), a colour per main branch, branch-style labels resting on their branch below the root's children, and motion: topics glide on springs (mojoui.spring) when added, removed, collapsed or relaid, branches following each frame; less-motion jumps. test_mindmap's proofs still pass plus `mindmap motion: ok` (positions converge, no overshoot past 8 %, still frames stop asking for frames); the grow step (20 topics added one per 100 ms, collapse/expand) silky on both machines; a side-by-side shot with Personal Note's map (build/g75/compare.png) |
| M5 | Whiteboard ink, silky | the wet stroke on its own layer drawn each frame on the GPU; framebench draw (a 300-move stroke) and finish (strokes landing) silky on both machines with 1,000 strokes on the page |
| M6 | Nothing regressed | goal 74's M1–M7, goal 40's M0–M2, the component matrix (gpu2d listed; ✅ where a check runs it), decisions lint |

## Done means
75-check PASS for M0–M6 (BLOCKED names exactly what is missing); a fresh reviewer passes it; docs/goals/75-report.md with
the numbers on both machines and shots; EXPERIMENTS.md. Commit after each passing milestone; not merged, never pushed.

## Out of bounds
Pushing; the owner's global macOS settings (`defaults`); other worktrees (goal 73's); pip; a third-party 2D library
(Skia, Vello, wgpu) in the path: the renderer is ours, in Mojo, over GL and Metal; lowering a proof or deleting a test.

## Assumptions (instead of asking)
- Windows open on the owner's desktop (Linux, a few seconds each) and on the Mac (a minute per run) for the GPU timings;
  the owner said go. Each check run says so before it opens one.
- GL through GTK's GdkGLContext on Linux (mojoui.present already makes one and hands textures to GTK, under the Vulkan
  renderer too); Metal through the Objective-C runtime the AppKit host already uses; shaders compiled once at start.
- The virtual Xvfb display keeps the CPU path (no GPU there); its checks stay as they are.
- Text stays the baked atlases (sharp at 1× and 2×; huge zooms blur until a later SDF atlas).
- Budget: 250 turns.
