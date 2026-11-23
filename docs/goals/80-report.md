# Goal 80 report: the best 2D renderer, by borrowing what the best do (2026-11-23)

**State: not done.** M0–M5 PASS on the code before the review fixes (their tests pass after them too). M6 not met by the letter. M7 blocked: the M4
doesn't answer (SSH times out, no Tailscale reply). Reviewer round 1: NEEDS WORK; its code and test findings are answered
(D-8022), a fresh review is still to come. Goal 75's M2–M6 regression check (2 h) has not been run: held back after two
hard stops of the machine (journal; memory pressure from other programs is the leading suspect, unproven).

## The race (nanoui's five scenes, RTX 3090, headless GL, lowest of 3 alternating runs, ms: ours / theirs)
From the checker's own run (docs/goals/80/race.md). Frame CPU: theirs includes a flexbox layout, ours places by hand.

| scene | frame CPU | GPU | CPU fallback |
|---|---|---|---|
| boxes | 0.055 / 0.086 | 0.207 / 0.207 | 15 / 41 |
| text | 0.069 / 0.170 | 0.091 / 0.092 | 0.88 / 2.3 |
| scroll | 0.164 / 0.668 (they also draw past the view) | 0.089 / 0.091 | 0.54 / 2.6 |
| list | 0.027 / 0.059 | 0.094 / 0.091 | 0.54 / 2.5 |
| dashboard | 0.025 / 0.027 | 0.137 / 0.140 | 4.4 / 33 |

Frame CPU and the CPU fallback are ahead on all five. The GPU is a tie: in the last two runs the cells that went over
differ (race c: boxes p95; race.md: list median and p95, text p95), all within 3 %.

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
3. D-8024, D-8017: in-place buffer writes measured on NVIDIA only; GTK's shadow node and Metal's shadow shader never run.

## 30-second demo
`pixi run mojo build -O3 -I . bench/nanoui/scenes.mojo -o build/g80/omxbench && pixi run build/g80/omxbench text dashboard`
