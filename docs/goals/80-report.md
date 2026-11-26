# Goal 80 report: the best 2D renderer, by borrowing what the best do (2026-11-23)

**State: reviewed (fresh reviewer, 39bef8a3: PASS, three shoulds fixed); M7's bar not fully met.** M6: every part passes when run (the parts were run one by
one, not through one `scripts/check M6`): the race 25 of 25 ahead, held-out 10 of 10 at or under 1.05× (all ahead), goal 75's
M2–M6 PASS (real windows on the hidden test screen and on the M4), gpu2d tests pass, rival words 366 = base's 366. M7: run;
5 of 20 cells more than 3 % behind (Metal GPU on text-only scenes; proposed to the owner to accept). M1–M5's tests pass on
the final code (M0's and M3's checker runs are from before the background clear). Reviewer round 1: NEEDS WORK, answered (D-8172).

## Linux (RTX 3090, headless GL, the card held awake on both sides, one scene a process, lowest of 3 alternating runs, ms: ours / theirs; docs/goals/80/race-awake.json)
Frame CPU: theirs includes a flexbox layout, ours places by hand. All 25 cells ahead (p95s too). (list's frame CPU reads
0.043 here and 0.029 when the scenes share a process; theirs 0.059 both ways.)

| scene | frame CPU | GPU | CPU fallback |
|---|---|---|---|
| boxes | 0.055 / 0.086 | 0.197 / 0.219 | 15 / 41 |
| text | 0.071 / 0.168 | 0.071 / 0.096 | 0.86 / 2.4 |
| scroll (they also draw past the view) | 0.167 / 0.657 | 0.058 / 0.096 | 0.55 / 2.6 |
| list | 0.043 / 0.059 | 0.058 / 0.079 | 0.55 / 2.5 |
| dashboard | 0.024 / 0.027 | 0.116 / 0.151 | 4.4 / 33 |

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

## Our own scenes (base → now, 8 alternating rounds, the card held awake; docs/goals/80/held-ab.json)
Frame CPU: whiteboard 0.69 → 0.23 · Personal Note canvas 0.97 → 0.33 · mind map 0.33 → 0.18 · document 0.12 → 0.06 · table 0.68 → 0.09.
GPU: 0.69 → 0.66 · 0.36 → 0.29 · 0.319 → 0.294 · 0.110 → 0.081 · 0.127 → 0.093.
The first run under the side-by-side rule, with the clock left free, failed the mind map's GPU at 1.057× (D-8180,
held-ab-1-clocks-free.json); the earlier recorded-baseline gains on GPU (table 0.44 → 0.10) were partly the card's clocks.

## What was borrowed, and what changed on the way
Culling before shaping; learned ASCII text; a number-keyed run cache; GPUI's shadow, made exact along the straight middle;
row bands on threads. Found by our own held-out scenes and checks: M1's culling slowed ink (polygons keep their bounds now),
M3's mapped buffers slowed the whiteboard's GPU 26 % (written in place now), secure_getenv broke the iPhone link (reverted).

## Worth a second look
1. D-8180: the measuring method was changed (clock held, one scene a process) after one failed run; the bar wasn't.
2. D-8164: the text fast path is checked by pairs and triples, not proven for every system font.
3. D-8174, D-8167: in-place buffer writes measured on NVIDIA only; GTK's shadow node never run. pnote runs the clear and
   culling in real windows (goal 75 M2, M3), but none of its three scenes draws a Gaussian shadow.
pnote and sketch don't cross-build for Mac/iPhone from Linux at the base commit either; sketch's undefined symbols are the same list.

## 30-second demo
`pixi run mojo build -O3 -I . bench/nanoui/scenes.mojo -o build/g80/omxbench && pixi run build/g80/omxbench text dashboard`
