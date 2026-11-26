# Merging goals 79, 80, 81 and main: steps 1 and 2 (2026-11-25/26)

Branch `merge-79-81` (from goal-79-pnote-lookalike 6640c47f), by docs/goals/79-merge.md. Step 1: goal-81-quality 25bae6d0
(goals 80 and 81). Step 2: main 0e4d0164. Step 3 (into main, the push) is the main session's. Nothing pushed; main and the
goal branches untouched. Decisions D-8200–D-8215 (docs/decisions.md).

## Commits
| Commit | What |
|---|---|
| 818d776e | step 1: goal-81-quality merged (D-8200–D-8206) |
| 66690e23 | tests/test_gtk_input_im.py: 81's M4 bursts with input-method commits |
| bee8aec9 | Metal clip test's picture nearest (D-8207); Mac stub gains chmod, opendir, readdir, closedir (D-8208); matrix |
| 953f2e82 | test_pnote_store reads pnote's refusal as written since ddabcd7c (D-8209) |
| 740eb11a | step 2: main merged (D-8210–D-8214) |
| 3cb5f057 | matrix regenerated |
| 46d2dcf5 | fix: pnote's desk canvas kept `.grow().fill().tag("desk")` (my step-2 edit had commented them out; 79's M2–M4 caught it) |
| b42cd6d4 | Apple hosts: the real common-modes constant everywhere, a hidden window looked at again (D-8215) |
| 1f3332db | goal 79's M6 tables for the merged code, docs/goals/79-merge/ |

## Checks
**Step 1 (818d776e–953f2e82), Linux:** BUILDS 45/45 · 79 M0–M5 PASS · KEYS PASS · PACKAGE PASS · judge_test, docbase 200,
wordsafe 60, outboxmodel 400, powercut 40, outboxkill 100+100 (0 bad) · 81 M1–M5 PASS · test_gtk_input_im (new) · 81 M8 PASS ·
81 M9: first FAIL (stale matrix, 4 Mac stub symbols, test_pnote_store), after bee8aec9/953f2e82: held-out worst 1.0376×, 30 tests, 16
builds, matrix · gpu2d_cull, boardtiles, bidi, textfast, scene, cpu_reference, binsinc, glstate, rectcorner, tilecull, pnote_store ·
first5 · bothopen seed 103 (244 words, 0 lost, 35 deletions, none back). **Mac:** 79 M1, M5 halves PASS; KEYS PASS; 81 M6 FAIL
then PASS (D-8207); 81 M8 Metal PASS; 3 AppKit apps run; 81 M7 BLOCKED (locked). **Not at step 1:** 79's M6 race (machine
busy for hours, D-8214; raced at step 2).

**Step 2 (46d2dcf5, Apple parts again at b42cd6d4), Linux:** BUILDS 52/52 · 79 M0–M5 PASS · KEYS PASS · PACKAGE PASS · the
CPU tests above (on the identical trial tree) · test_gesture_numbers (new) · 81 M1–M5 PASS · 81 M8 PASS · 81 M9: 30 tests,
16 builds, matrix; held-out 1.69× under load 10–12 (the base itself swung 0.12–0.23 ms), rerun quiet: **1.0246×** · 73 M1–M3
PASS · 76 M1–M2 PASS · 78 M1–M3 PASS, M4 every part PASS but BLOCKED by its own G78_SKIP_76 · 77 M7A–M7E PASS · pnote_store,
glstate, rectcorner, tilecull, first5, bothopen (247 words, 0 lost) · **79 M6 PASS, 60 ✓ 0 ✗** (b42cd6d4, ten idle minutes
before). **Mac (unlocked):** **79 M6 PASS, 60 ✓ 0 ✗** · mac-frames 143.9 / 144.3 a second of 144 · **81 M7 PASS, 144.03
ticks/s, hidden 0, idle 0, fallback 1** · 81 M6, M8 PASS · 79 M1, M5 halves PASS · KEYS PASS · 3 AppKit apps run, cross-link
adds no symbol.

**Not run:** 77 M0–M6, M7F (the real omx and its models); 73 M4 and 76 M3 (the 71→70→68→47 cascade: it rebuilt goal 47's 13
GB robot data in this worktree and installed the models and bagcheck environments, 16 GB, with the disk at 94 %: stopped,
removed); 79 M7; the packages of omxplorer and omxome over their released versions; Android and iPhone builds; ibus/Wayland
input methods; AppKit hover by hand.

## Proofs that changed (for the reviewer)
- tests/test_gpu2d_metal.mojo, clip scene: its picture `smooth=False` (D-8207).
- tests/test_pnote_store.py: the refusal's words, now for this very note id (D-8209).
- docs/goals/80-check.py, 80-report.md, 80/race.md: goal 80's decision numbers in comments and text only (D-8200).
- Added: tests/test_gtk_input_im.py, tests/test_gesture_numbers.py, the `burst:` value `iX` in the GTK host.
- No threshold changed, no test skipped or deleted.

## Riskiest merged areas
1. AppKit frame clock (D-8201, D-8215): 79's clock with 81's hidden-window rule, test runs kept on the screen's clock, an
   explicit dead mode. Passed M7, M6 and mac-frames once each, on one screen.
2. GTK held input with the input method (D-8202): keys offered to the IM before 81's hold; IM calls by shown_at; while a
   full rebuild waits an IM key is held and sent as a key.
3. Event numbers (D-8210): IME_COMMIT 16, IME_PREEDIT 17, PASTE 18; anything outside this repo that knew 79's 12–14 breaks.
4. fonttext (D-8203): 80's cache with 79's widths; declare() clears every cache.
5. gpu2d culling (D-8204): one region for clip, canvas and tile part.
6. Hover (D-8211): main's design; a leave held during a rebuild; AppKit hover only with Canvas(hover=True), unchecked by hand.
