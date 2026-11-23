# GOAL 80: the best 2D renderer, by borrowing what the best do (not by tuning for a benchmark)

**End goal (owner, 2026-11-22):** "Borrow the best practices, or the ones we lack (but should have considered), not
overfit to beat them. I want to be best, and performant." The rivals are nanoui (Zig, GPUI-style; raced with its own
`hillclimb` scenes) and through it GPUI. The first race (`bench/nanoui/RESULTS.md`, 445fa148): ahead on shapes, 2–8×
behind on text-heavy CPU work, no clip culling, no Gaussian shadow, a single-threaded CPU fallback.

Base: goal-79-pnote-lookalike 3686e45b (goal 75's gpu2d + goal 79's fonttext). Worktree ../mojo-ui-bench, branch
bench-nanoui. Decisions D-80xx in docs/decisions.md, attempts in docs/journal.md.
Checker: `scripts/check` → `docs/goals/80-check.py` (PASS / FAIL / BLOCKED per milestone, `scripts/check M2` runs one).

## Milestones
| # | Milestone | Proof (docs/goals/80-check.py) |
|---|---|---|
| M0 | The race, reproducible, plus held-out scenes | The checker builds nanoui at `cfe6000` (+ `bench/nanoui/nanoui-gl.patch`, Zig 0.17.0 fetched into build/g80) and `bench/nanoui/scenes.mojo`, runs nanoui's five scenes on both (headless GL, same GPU, nanoui's rules) and writes `docs/goals/80/race.md`. **Held-out scenes**, ours, never nanoui's: whiteboard (goal 75), Personal Note's 645-object canvas, a 200-node mind map, a long document page (wrapped paragraphs in several faces and scripts), a 10 000-row table scrolled. `docs/goals/80/baseline.json` holds every scene's omxcode numbers at the base commit, written once and committed before any renderer change. PASS: both run, every scene's last frame is saved and inked, baseline committed |
| M1 | Draw only what can show | `fill_batches` drops ops wholly outside their clip ∩ the canvas **before shaping text**. tests/test_gpu2d_cull: (a) the CPU executor's picture with culling equals the picture without, bit for bit, on goal 75's scenes and 200 random clipped/transformed scenes; (b) no built instance lies wholly outside its clip ∩ canvas; (c) a 1000-row clipped column builds exactly the instances of a scene holding only the rows that meet the clip (an oracle built by the test); `gpu2d cull: ok` |
| M2 | Text as cheap as a lookup | (a) a run cache keyed by numbers (style id, text hash), no String key built and no Run copied on a hit; (b) a simple-text fast path: per face and size, each printable ASCII glyph's id and advance and each pair's kerning, learned once from the full shaper; strings with a ligature or anything outside it go to the full shaper. tests/test_textfast: ≥ 2 000 strings × every bundled face × 4 sizes × 2 weights: fast path and full shaper give the same glyph ids, positions within 1/64 px, same width; `textfast: ok` |
| M3 | No per-frame waste on the GPU | GL2D counts texture uploads, buffer (re)allocations and render-target allocations per frame. tests/test_gpu2d_waste: the same scene drawn twice uploads no texture and allocates nothing on the second frame; a scene with one new glyph uploads only that glyph's rows; instance data goes up once per frame (one buffer, orphaned or persistently mapped). `docs/goals/80/race.md` shows each scene's GPU time split (upload, draw, resolve) with GL timer queries; `gpu2d waste: ok` |
| M4 | Gaussian shadows | `Painter.shadow(x, y, w, h, radius, blur, color)` on every painter; drawn on the GPU (GL and Metal) and by the CPU executor with GPUI's analytic formula (exact erf across, sampled along). tests/test_gpu2d_shadow: the CPU picture within 1 level (mean) of brute-force 2-D Gaussian convolution of the rounded box; GL within goal 75's bounds of the CPU (mean ≤ 1.5 levels, ≤ 0.5 % far) for blurs 0–32, radii 0–24, overlapping, clipped and in scaled layers (the Metal half is proven in M7). The race's boxes and dashboard then use real shadows. Components matrix regenerated |
| M5 | A CPU fallback that uses the machine | `execute_cpu` splits the frame into bands across cores. On every goal 75 scene and every race scene, the threaded picture equals the single-threaded one bit for bit; median speed-up ≥ 4× over the race scenes at 1800×1280 on this 12-core machine |
| M6 | The race, won honestly (Linux) | For each of nanoui's five scenes: omxcode's frame CPU median and p95, GPU median and p95, and CPU-fallback median each **≤ nanoui's**. **Not overfit:** every held-out scene ≤ 1.05× its baseline on frame CPU and GPU; `mojoui/` names no race scene or rival (`grep -iE 'nanoui|hillclimb|boxes|dashboard'` finds nothing new); test_gpu2d, test_gpu2d_gl, test_gpu2d_tiles and goal 75's M2–M6 still PASS |
| M7 | The race on the M4 (Metal) | Same as M6 on the owner's M4: nanoui's own hillclimb (Metal, its home ground) against `scenes.mojo` on gpu2d's Metal backend, timed the same way; test_gpu2d_metal passes, and Metal draws test_gpu2d_shadow's cases within the same bounds of the CPU. BLOCKED (with the SSH error) while the Mac can't be reached |

## Done means
80-check PASS for M0–M6, M7 PASS or BLOCKED only for reachability; a fresh reviewer passes it; `docs/goals/80-report.md`
with the race table (before and after), the held-out table and the decisions worth a second look; EXPERIMENTS.md entry.
Commit after each passing milestone. Never push; merging waits for the owner.

## Out of bounds
Pushing; scene-specific code (anything in `mojoui/` that knows a benchmark scene); lowering a bar, editing a proof to
pass, deleting a test, or changing nanoui beyond the GL timing patch; other worktrees (`../mojo-ui-g79` has someone's
uncommitted work, `../mojo-ui-apple-test` is frozen); pip; global settings (NVIDIA driver, Hyprland, macOS `defaults`);
nested compositors. Mac: only a scratch folder in the owner's home over SSH (Zig there in a folder, nothing system-wide).

## Assumptions (instead of asking)
- "Best" is measured on the rival's own scenes, by its own rules, on the same machine; "not overfit" is measured by
  held-out scenes from our apps that must not regress, and by fixes that live in the framework, not the bench.
- nanoui's frame CPU includes its flexbox layout and ours doesn't (no layout engine, ROADMAP decision 10); we race
  anyway and say so in the report. Adding a layout engine is not in this goal.
- Shadows match GPUI's look (Evan Wallace's analytic rounded-box shadow), which nanoui also uses.
- Linux first (RTX 3090, headless EGL); the M4 when reachable.
- Budget: 250 turns. Two failures on one approach → stop, attack the premise, log the pivot.
