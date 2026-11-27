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

## Step 2b (2026-11-26): what moved after step 2
| Commit | What |
|---|---|
| d2b8746d | goal-81-quality 08197483: b9250c55's clock parts already in by D-8215; 08197483 = D-8210 (D-8216) |
| 70ed1d24 | goal 79 f6a3fa5b: D-8097's refresh-relative tie, rejudge.py (D-8217) |
| 4b8fbed3 | main a2652b13: view transitions start in goal 81's apply(); rebuilds keep goal 81's G_PRIORITY_HIGH, which already covers D-8412's starvation; main's idle_soon left out (D-8218) |
| dbf5349b | the step-2 race rejudged under D-8097 by goal 79's rejudge.py, unchanged: Linux 60 ✓ 0 ✗, Mac 52 ✓ 8 ✗ (D-8219) |
| ff99cff4 | **GTK fix (D-8220):** the content root wears mui-morph-root (transform + transition) only while a morph settles. Always on, it made pnote's stress redo miss a refresh in 8 of 13 runs (step 2's build: 3 of 21; fixed: 5 of 16); main's personalize_check PASS. docs/goals/79-merge/late-redo-ab.md |
| ad48b5f3 | goal 79 b6c78275: D-8098–D-8101 (prompt tick, lean input frames, undo/redo at the frame begun); prompt_tick's mode by the constant (D-8221) |
| b801cd0c | goal 79 a12e8326: D-8102 (every latency row at the frame begun), gaps 89/90, goal 82's draft (D-8222) |

### The races (records, docs/goals/79-merge/)
| Table | Commit | Result |
|---|---|---|
| race-linux-b42cd6d4.md, race-mac-b42cd6d4.md | b42cd6d4 (step 2) | judged then 60/60 and 60/60; rejudged under D-8097: Linux 60 ✓ 0 ✗, Mac 52 ✓ 8 ✗ (rejudge-b42cd6d4.md). **The last valid tables.** Goal 79 alone: Mac 57 ✓ 3 ✗ under D-8101 |
| race-linux-dbf5349b.md, -2.md | dbf5349b | 59 ✓ 1 ✗ twice (stress redo max 18.8 ms): led to D-8220. Mac BLOCKED (locked) |
| race-linux-ff99cff4-blocked.md | ff99cff4 | refused, not judged: the web's window at 58 Hz against 60 (not like-for-like) |
| race-linux-ff99cff4-disturbed.md | ff99cff4 | 50 ✓ 10 ✗, disturbed: the web's open script timed out (8 rows "not measured: the web"), both sides missed frames in one pan and one drag; the redo row passed. Mac BLOCKED (locked at a step) |
| — | ff99cff4 | a third run cut by the machine's hard stop at 15:27 |
| — | b801cd0c | the judged run under the exclusive quiet lock (ten idle minutes before, 17:21) cut by the hard stop at 17:39:18 |

**The Linux race after D-8102 is deferred:** two hard stops in a row came during a Linux M6 race (15:27, 17:39); the main session holds the race until the owner checks the hardware. The Mac race: `scripts/mac-unlocked --probe` passed twice, and both times the Mac locked itself within minutes (BLOCKED, nothing raced). Not a push blocker (the main session).

### Still open
- KEYS' Mac prompt-tick check (D-8099) at the merge: 2 of 7 runs had one step of twelve waiting 2.6–3.5 ms (the check's "p95" of twelve is the maximum); goal 79 alone 0 of 3 (maxima 0.4–0.7 ms). Cause not found (the hang monitor is off under MOJOUI_TEST).
- The redo row on Linux: step 2's own build is late in 14 % of runs; after D-8220 the merge is 31 % (5 of 16), not told apart at these numbers. The owner has closed speed work (main session): recorded, not chased.
