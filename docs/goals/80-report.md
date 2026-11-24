# Goal 80 report: the best 2D renderer, by borrowing what the best do (2026-11-23)

**State: not done.** M1–M5's tests pass on the final code (M0 and M3's checker runs are from before the background clear).
M6: every race cell ahead on Linux; one held-out cell over its recorded baseline (mind map GPU 1.08×, bar 1.05×; level when
old and new alternate, D-8023: the owner's call). M7: run; 5 of 20 cells more than 3 % behind (Metal GPU on text-only
scenes). Reviewer round 1: NEEDS WORK, answered (D-8022); a fresh review of those fixes and of everything since (the
background clear, the Metal changes) is still to come. Goal 75's M2–M6 regression check (2 h) not run: held back after two
hard stops of the machine (journal; other programs' memory pressure is the leading suspect, unproven).

## Linux (RTX 3090, headless GL, lowest of 3 alternating runs, ms: ours / theirs; docs/goals/80/race-2026-11-23d.json)
Frame CPU: theirs includes a flexbox layout, ours places by hand. All 25 cells ahead (p95s too).

| scene | frame CPU | GPU | CPU fallback |
|---|---|---|---|
| boxes | 0.055 / 0.087 | 0.198 / 0.219 | 15 / 41 |
| text | 0.071 / 0.167 | 0.070 / 0.092 | 0.89 / 2.4 |
| scroll (they also draw past the view) | 0.169 / 0.662 | 0.069 / 0.092 | 0.54 / 2.7 |
| list | 0.029 / 0.058 | 0.071 / 0.091 | 0.55 / 2.6 |
| dashboard | 0.024 / 0.027 | 0.115 / 0.151 | 4.4 / 33 |

## M4 (Metal, private target on both sides, lowest of 3 alternating runs; docs/goals/80/race-mac-2026-11-23.txt)

| scene | frame CPU | GPU |
|---|---|---|
| boxes | 0.062 / 0.112 | 0.800 / 0.959 |
| text | 0.081 / 0.136 | 0.071 / 0.064 (12 % behind) |
| scroll | 0.190 / 0.518 | 0.060 / 0.051 (17 % behind) |
| list | 0.022 / 0.038 | 0.055 / 0.051 (8 % behind) |
| dashboard | 0.041 / 0.056 | 0.329 / 0.626 |

Into an IOSurface (what a window shows) ours costs more on text-only scenes (text 0.100). Metal's shadows match the CPU
executor on every case of tests/test_gpu2d_metal_shadow (and differ by 11+ levels without them); test_gpu2d_metal passes.

## Our own scenes (frame CPU, base → now)
whiteboard 0.70 → 0.21 · Personal Note canvas 0.99 → 0.34 · mind map 0.34 → 0.18 · document 0.13 → 0.06 · table 0.69 → 0.10.
GPU: none shown slower when old and new alternate (mind map alone, 8 rounds: 0.321–0.327 base, 0.318–0.325 now; the same
data by hash). M6's recorded baseline still reads the mind map 13–15 % over.

## What was borrowed, and what changed on the way
Culling before shaping; learned ASCII text; a number-keyed run cache; GPUI's shadow, made exact along the straight middle;
row bands on threads. Found by our own held-out scenes and checks: M1's culling slowed ink (polygons keep their bounds now),
M3's mapped buffers slowed the whiteboard's GPU 26 % (written in place now), secure_getenv broke the iPhone link (reverted).

## Worth a second look
1. D-8023: the held-out check compares with one recorded number on a card whose clocks move 2–3×.
2. D-8014: the text fast path is checked by pairs and triples, not proven for every system font.
3. D-8024, D-8017: in-place buffer writes measured on NVIDIA only; GTK's shadow node never run. The background clear was not yet reviewed or run in a windowed app.

## 30-second demo
`pixi run mojo build -O3 -I . bench/nanoui/scenes.mojo -o build/g80/omxbench && pixi run build/g80/omxbench text dashboard`
