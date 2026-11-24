# GOAL 81: an app layer that never loses, repeats or stalls (what the GPUI study found)

**End goal (owner, 2026-11-23):** the study's "real quality" and "moderate" rows; "skip the marginal and unproven and
none". Why: omxcode draws fast, but a list that stops updating or a lost click reads as a broken framework.
Study: docs/research/gpui.md (faults F1–F4, F6, F9; borrow list B7, C10, C12, A4).

Base: bench-nanoui 2571778d. Worktree ../mojo-ui-bench, branch goal-81-quality. Decisions D-81xx in docs/decisions.md,
attempts in docs/journal.md. Checker: `scripts/check` → docs/goals/81-check.py (PASS / FAIL / BLOCKED per milestone).

## Milestones
| # | Milestone | Proof (docs/goals/81-check.py) |
|---|---|---|
| M1 | Patched screen = fresh screen, tested at random | tests/test_diff_random: ≥ 5,000 random pairs of screens (seeded; every container kind; inserts, removals, moves, texts, sizes, tags). A model host that applies a Diff exactly as the hosts do (kept, resync, patches) must equal a fresh build, and no widget may be used twice. A mutant (one patch dropped, one resync dropped) must be caught. tests/test_gtk_random: a headless GTK app steps through ≥ 300 random screens by partial updates; after each, the widget tree's dump equals the dump after a full rebuild of the same screen |
| M2 | Long lists compare fast and keep their widgets | tests/test_diff_long: adding a row on top of 600, 2,000 and 10,000 tagged rows keeps every old row's widgets; an unchanged 499-row list compares ≤ 0.25 ms and 10,000 rows grow no worse than linearly (≤ 1.5× per row of 500 rows, medians); on 2,000 random lists under 60 children the pairs kept are as many as the old table's (exact longest common run) |
| M3 | Two long lists both keep updating | tests/test_gtk_lists: two LazyLists, one scrolled to 500, "Flip" then "Again": every visible row of both shows the newest words, read from the widgets (labels), not the screenshot; the scroll positions stay; a third run with three lists and one removed and added back. Fails on the base commit (recorded) |
| M4 | No lost input | tests/test_gtk_input: clicks, keys, scrolls and field edits arriving while a partial or full rebuild waits (two in one turn, 200 random bursts) each reach update() exactly once, in order, unless their view is gone from the new screen; events fired by the host's own widget writes never do. Fails on the base commit (recorded) |
| M5 | A hang monitor, always on | Every host run (Linux, Mac) keeps a ring of what its UI thread is doing; a watcher thread says so **while** it hangs (over 500 ms: what, which message, how long) and again when it ends; hangs.log in the app's state folder, at most 200 lines kept. tests/test_hang: a 1.2 s update() is reported during the hang and after it with its message; a 100 ms one isn't; ≤ 1 µs per event marked (measured); nothing personal in the line (no text typed, no paths). `MOJOUI_HANGS=0` turns it off |
| M6 | A new letter on the Mac sends only itself | tests/test_gpu2d_metal_glyphs (on the M4): one new glyph uploads ≤ its own rows (counted by Metal2D), not every used row; 100 random frames with new glyphs equal the CPU reference within goal 80's bound; test_gpu2d_metal, test_gpu2d_metal_clear still pass. BLOCKED only while the Mac can't be reached |
| M7 | The Mac draws at its screen's rate | Frames are paced by the display's own clock (display link; the 60 Hz timer stays as the fallback when no link tick comes for 100 ms, D-560), and stop when the window is hidden or covered. On the M4: ticks/s during an animation within 3 % of `NSScreen.maximumFramesPerSecond`; 0 ticks over 2 s hidden; idle 0 ticks. BLOCKED only while the Mac can't be reached or its screen is locked |
| M8 | Pictures smooth and not copied | Pictures scaled down or up are filtered (bilinear, with a mip chain below half size) on GL, Metal and the CPU executor, within 2 levels mean of a box-filter oracle at 0.25×, 0.5×, 0.8×, 1.7×; unscaled ones stay bit for bit. A rebuilt frame with an unchanged 1920×1080 picture copies and hashes none of its pixels (counted) and uploads none. tests/test_gpu2d_image (+ _metal) |
| M9 | Nothing got slower or broke | Goal 80's held-out scenes ≤ 1.05× of 2571778d (D-8030's method), goal 80's tests and the M1–M4 tests pass, pnote and omxplorer build on Linux and their existing GTK tests pass, AppKit examples build and run on the Mac, components matrix current |

## Done means
81-check PASS for M1–M9 (M6, M7 and the Mac half of M8 BLOCKED only for reachability), a fresh reviewer passes it, docs/goals/81-report.md (short), EXPERIMENTS.md entry.
Commit after each passing milestone. Never push; merging waits for the owner.

## Out of bounds
Text spacing, contrast, snapped borders (unproven, owner skipped); drawing-speed tricks and layout/state systems (marginal,
none); keeping widgets across shape changes on Mac/iPhone/Android/web (F5), F7, F8: not chosen. Pushing; lowering a bar,
editing a proof to pass, deleting a test; other worktrees; pip; global settings. Mac: `~/omxcode-g81` only, batches under
`flock ~/.cache/omx-mac.lock`. Machine: it hard-stopped three times on 11-23, each with another project's model job running:
builds on ≤ 4 cores (`taskset`, `nice`), no GPU run while another process holds > 4 GB of a GPU or an omx-*/speed_study/llama job runs.

## Assumptions (instead of asking)
- "Plan real quality and moderate" = go for those rows, skip the rest.
- M4's lost input and M3's lists are GTK faults; the Mac rebuilds whole screens synchronously, so its input isn't held.
- Budget: 80 turns.
