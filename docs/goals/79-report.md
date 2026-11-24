# Goal 79 report: Personal Note, native, the exact look of the web app, faster

Worktree ../mojo-ui-g79, branch `goal-79-pnote-lookalike` (base 654d9471). Not merged, not pushed. Decisions D-7900–D-7955
(docs/decisions.md), attempts in docs/journal.md. Checker: `scripts/check` → `docs/goals/79-check.py`, committed before
any feature work (f9ef3c70), since strengthened (D-7911, D-7929, D-7931) and fixed where its own bugs blocked a comparison
(D-7906, D-7908, D-7915, D-7917–D-7919: each logged with why it is not a weakening).

**Owner's ask (11-19):** "Rebuild Personal Note the exact way the web version looks with a better performance." Then
D-7900: framework first; every trick goes into mojoui; Linux and Mac count equally.

## For the reviewer (standing list)
Places where a proof, a checker or a test of this goal changed, or where a claim was wrong and corrected:
- **tests/test_binsinc.mojo (continuation 17).** The whole-grid equality (grid and cells equal a fresh build) became conditional when the op index learned to patch itself in place (D-7999): a patched index keeps its old grid by design. The old strict equality still runs, in the same test run, with the in-place path off (`MOJOUI_BINS_INPLACE=0`'s code path). The patched one is held to: every box equal, 240 rects of every size equal to a fresh build, and equal to a brute-force scan of every op's box measured from the scene. 20 far moves were added after a mutant (an index that forgets its extra ops) survived the first version; it now fails.
- **79-check.py, Mac run A (continuation 18).** Reran up to three times when it kept no view (5a3ad824). Cause found and fixed (D-8016); the rerun is gone and a run without a kept view FAILs: stricter than before.
- **Two mistakes of mine this round, both caught before the final runs:** the first close-time save wrote a file of one tile (found by reading the run's log; test_viewsnap `closing_keeps` now compares the whole file); viewsnap and docstore imported the vendored job package, which broke every test built without it (found by M7, fixed in 29ee729b: D-8015 amended).
- **Note switch and omnibar rows are with idle warming** running in the bench's own pauses: the numbers without it are in the report's continuation 18.
- **The race's drags (D-8000)** time the lift and the drop (they never did): a strengthening; older drag rows are understated. Since D-8018 (continuation 18) the lift happens in the first moving frame instead of the press frame; all 62 frames are timed either way, so the press's handling and the lift are now two timed frames where they were one. The row's max isn't comparable with earlier runs for that reason too.
- **Note switch and omnibar (D-8001)** are raced against the web and have a max; they had only a silky p95.
- **The Mac's start-up runs (D-8002, corrected by D-8003).** D-8002 said they shared one settings folder: wrong. mac-ssh had always replaced the checker's folder with a fresh one; what was fixed is that the checker's own choice of folder now takes effect. No earlier Mac start-up number was helped by a shared folder.
- **M1's Mac reference (D-7991)** switched from macwidths.py to the live page: the main session's ruling.
- **Wrong claim, corrected (continuation 17):** "each undo step moves 40 objects back" in continuation 16's report and journal. It walks one 6×4 px one-object move back.
- **Attribution:** D-7976, D-7977, D-7991, D-7992 and D-7998 are the main session's, not the owner's; d59ebc57's commit message still says otherwise.
- **The Apple Color Emoji rule (D-7998)** was derived from Chrome's whole-size table (31 sizes, 10–40 px). Verified since on the Mac (D-8004): 63 sizes, 6–96 px, whole and fractional, no disagreement with the Mac's Chrome; zoomed, Chrome keeps the layout advance (as pnote does) or follows the rule at the used size.
- **"0 of 20 kept" (D-8016, continuation 18) overstated it.** Of those 20 boards and views, 7 are big enough to be tiled, the only ones a view is kept of. Before the fix none of the 7 was kept; after it all were (15 of 15 with more sizes).

## Continuation 22 (2026-11-24, 11:13–14:50): the Mac unlocked, review round 4 fixed

**Final code: 2e198b04** (later commits: tables and documents).

| | Linux (RTX 3090) | Mac (M4, 144 Hz external screen, scale 1.0) |
|---|---|---|
| M0–M5 | PASS, all six, at 2e198b04 | M1 and M5 halves PASS |
| M6 | **FAIL: 58 ✓, 2 ✗**, each one frame: 600 redo max 18.6 (web 17.2), stress undo not warmed max 18.9 (web 17.0); p95 better on both | ~~PASS, 60 ✓~~ **not like-for-like, superseded (review 5, M3: the web headless at 2× and 60 Hz, native at 1× and 144 Hz)**; unlocked and in front at every step, 12:18–12:42 at dfca9816. Locked since: not raced again |
| M7 | not a Linux milestone | nine looks PASS (.987–.998) at 2e198b04 |
| Tests | 84-test wide run at dfca9816's code: all that can run here pass (9 need data, a server or a library this worktree hasn't; the ones that didn't build are below); reruns at the end | at be45d39f: pnnotes pnshell savelater saveattack review4 opendoc longpara pageedit pagegrow graphemes jsonedit mapmarks boardedit pans tickchanges canvasload; at 2e198b04: opendoc framebudget |
| Attacks | savekill (40 random kills), the reviewer's two processes on one file, the walk native → web → native: ok at 2e198b04's parent | — |

**What differs between the Mac's race (dfca9816) and the final code:** the restored JSON files, docstore's lock-file clean-up, App.bench's name, FrameBudget.input (D-8070). Nothing in the Mac's frame path.

### A. The Mac's 15 frames a second: real, ours, fixed (D-8060)
Not the bench. Each drawn frame left the canvas idle, the host threw its timer away, and the next event made a new one: 16.7 ms plus macOS's coalescing (24 ms typical, 57 worst), for 1.2 ms of work. The display link that "never fired" since 10-22 was in a run-loop mode nobody runs: we passed a string reading "kCFRunLoopCommonModes", and Core Foundation knows the mode by its address.
- Now the screen's own clock: pan, zoom, drags, pen and typing 6.9–7.2 ms between frames on both notes (27.8 typical and 61 at p95 before), undo 8–18 ms, and 144 new pictures a second, counted apart from the bench by a display link of its own and the window server's use of our surfaces.
- Two things in the log were the bench's: a 45 ms stall every 450 ms (the report's window picture, taken inside measured steps) and "tests/test_canvasload fails" (the script never ran it there).
- Check: `scripts/mac-frames`, 144 of 144 on both notes; the old timer gets 60 and FAILs.
- Goal 81's M7 (../mojo-ui-bench) has the same idea and passes `ns_string("kCFRunLoopCommonModes")`: its link probably sits in the dead mode too. Not touched; for that session.
- Opens load 2.5 ms a frame instead of 0.5 (D-8061): complete in 44–60 (600) and 105–192 ms (stress), web 199 and 603.

### B. Review round 4
| Finding | State | Proof |
|---|---|---|
| M1 two windows delete each other's held edits | fixed (D-8064) | test_opendoc two_windows, test_review4, the reviewer's two.py |
| M2 a new canvas text isn't saved while written, nor in exports | fixed (D-8065) | test_review4 new_text |
| M3 delete/Undo, Save a copy, rescue | fixed | test_review4 new_text, locked_note |
| M4 words typed while a save is in flight, note deleted elsewhere | fixed | test_review4 gone_in_flight |
| M5 a long paragraph | fixed (D-8067) | test_longpara (the old algorithm as reference; its mutant: a page drawing all its lines, found by the new race row) |
| M6 the paper | fixed (D-8068) | test_pagegrow (pages.js's own cases), test_review4 paper |
| Warning on the wrong note; spill of only the first waiting save; the 25 s close; locked elsewhere; a gesture interrupted; a notebook-only change reopening; rename ignored in silence; a map's ring; WordsEdit 15 s; a broken held file hiding others | fixed (D-8066) | test_review4, test_opendoc, test_longpara |
| S11 a mouse's 1,000 points a second | once a frame, every point (D-8063) | test_pans |
| S12 CPU load on Linux | a rule, both sides (D-8069); the last race: at most 0.48 cores busy before each of 34 runs | the checker |
| S13 generic parts in webshell | **not moved**: about 600 lines tied to the open document, a round of its own. Listed in the debt table as NoteFile and CanvasNote | docs/components.md |
| Right-to-left caret and selection | **open**, now in the gaps (81) | — |
| Nits: backup twice in a second, a broken board queued, saveattack's run line, race.md's "run again" | fixed | — |

**Not in the review, found here and mine:** mojoui/jsonpatch.mojo (goal 35's JDoc, JSON Patch) had been overwritten by this goal in continuation 20, its test with it, and an earlier JSON reader of this goal took Json.keys and kids away: agui, genui, agentui and the console app didn't compile. Restored; ours is mojoui.jsonedit; every Linux example builds again, test_jsonpatch passes on its own fixtures, `mojo package mojoui` is clean (lesson written).

### The race's rule
Not changed. The two Linux rows are each one frame 1.6–1.9 ms late in one run; in continuation 21's 24 runs the same undo row was over in 4. **The 25.6 ms undo** was step 0, the first key after the thirty set-up moves; that step takes 1.5–2.4 ms in every other run here, and it still isn't explained.
**The reviewer's fair rule, as a proposal only (the owner decides):** judge a row's maximum on the median of five runs' maxima, the web's taken the same way, and keep p95 and missed frames as they are. Today the web's opens are the worst of five and native's are of one run.

### For the reviewer
Proofs and checks changed: M6 gains a row (webtype.mjs) and the Linux CPU rule (a noisy race is BLOCKED); judge_test has the new row's cases; scripts/mac-unlocked runs mac-frames and test_canvasload; scripts/mac-frames is new; MacReport takes no picture inside measured steps; first5 unchanged this round; tests/test_jsonpatch.mojo is goal 35's again (ours is test_jsonedit). RowSaver waits 3 s at a close, not 10. No bar lowered.
The Mac's locked runs of the last two M6s are in build/g79/locked, not in race-mac.md.

**Risk, most first:** docstore.SaveOutbox (locks, take-over at a start) and webshell's save queue, spill, rescue, secure and feed paths; AppKit's frame clock (screen's link, 1 s linger, stand-in timer, prompt tick, hidden windows) for every Canvas app on the Mac; queue_pan's order against other events; pagesheet's incremental layout; ObjectLayer.draft and shift_frame (undo, export); pagegrow on real notes whose grid doesn't match their content (the first edit settles it, as the web's does); json consumers after the API repair (built, agui's suites not all rerun); fonttext and gtk draw-ahead as before.

## Continuation 21 (2026-11-24, 06:17–10:40): the save thread attacked, two proofs sharpened, the last everyday gaps

**The judged commit is 3a3886bd** for both machines (later commits: the race's tables and documents only).

| | Linux (RTX 3090) | Mac (M4, screen locked) |
|---|---|---|
| M0–M5 | PASS, all six | M1 and M5 PASS |
| M6 | **FAIL**: 57 passing marks in race.md, 2 rows over | **BLOCKED**: locked, so no frames judged; work rows in race-mac.md (they finished 4 min after caffeinate ended, the Mac still awake) |
| M7 | not a Linux milestone | nine looks PASS, .987–.998, with the ink check and live fonts. Its whole-milestone verdict needs the rest of the Mac |
| Tests | 49 of the 51 touched CPU and GPU tests pass; the other two are Metal tests, which only link on the Mac (wide run at c1aaf958; pnnotes again at 3a3886bd) | 4 at 3a3886bd (pnnotes, pnshell, savelater, saveattack), 10 at 656df2fe |
| Walk | real input, web reads it, native reads it back: ok, on a binary checked newer than its sources | menus driven by the menu step (Night, New note, exports, zoom, Fit) |

**M6's two Linux rows, not passed.** Stress undo max 25.6 ms (web 17.0, p95 better: 16.8 against 17.0), and stress typing not warmed max 21.5 ms with one missed frame (web 16.8, p95 equal). The first race of this round had three undo rows over, at 18.9–19.1.
- 24 diagnostic stress runs at 3a3886bd (build/rerace.py: the race's own steps, printed, never judged): undo's worst was 16.8–17.4 in 20 and 18.3–18.9 in 4 (limit 17.5). Typing not warmed was 16.9–17.2 in 8 of 12 and 17.4–18.9 in 4 (limit 17.3).
- What is in those late frames: the wait for the frame to start (18–19 ms), not the app's work (event 0.1–0.2, draw 0.4–0.6, paint 0.2–0.3; no timer tick between, with MOJOUI_TRACE). A few undo steps carry a 2.5 ms paint instead.
- **The 25.6 ms undo is not explained**: its frame did 12.2 ms of work, of which draw was at most 3.8 and nothing else was recorded. It didn't recur in 24 runs. Either row can pass or fail on a given run; the judge is unchanged and no run was picked.

**What was built.** The save thread attacked (D-8050, D-8052), undo drawn ahead (D-8051), proofs sharpened (D-8053), then D-8054–D-8059: sticky shadow's corner (72), double tap (54), the map's marks (68), the emoji picker (10), line keys (24), Quick note's menu (4), the Mac's menu bar (52), a database copy and Markdown files (14, 50 partly), the AppKit paced race and `scripts/mac-unlocked`.

**Caught on the way, by running it:** a page's icon scrolled under the tools took the press on Write (my emoji commit); a menu bar in a column gave the Mac an empty window; the first final walk had run on an app an hour old (void; the walk refuses that now); `mojo build` crashed once with no message and built the next time.

**Gaps left.** 36 pictures, 39 typography card, 51 focus mode; rest of 14 and 50 (JSON, zip, Obsidian vault, PNG, import, print, picture, link); 25 (the web has none of its own); L rows as told: 13, 15, 16, 29, 40, 41, 45, 49, 56; S: 55. Within built rows: arrow keys in Quick note's menu; map pictures are placeholders and map marks can't be edited; sticky shadow is stepped (ten layers); on a full disk the app opens to an error; the Mac menu bar has no Help.

**Not seen by a person or a real hand:** nothing on the Mac's own screen (locked): the AppKit close hooks, the menu bar's clicks, strokes with coalescing off, the paced race. `scripts/mac-unlocked` needs the Mac unlocked and left alone for about 35 minutes; its probe refused correctly (active=0 key=0 locked=1).

**For the reviewer: proofs, checks and tests changed this round.** None loosened a bar.
- ref.mjs: the page's live fonts by default, cached (D-8053); M0 requires them; macref.py ships the cache.
- 79-check.py: `ink_wrong` added to M2, M3, M7 (stricter); `mac_live` refuses to judge the Mac's frames when locked, and m6_mac gains paced, unwarmed and open rows; `race_table(live=)`. judge_test.py gained cases. No judge threshold changed.
- test_pnshell `held`: adapted to the save queue (the old text assumed one save at a time).
- GTK draws ahead after input by default, for every GPU canvas app (`MOJOUI_DRAW_AHEAD=frames` is the old way).
- first5.py: a Quick note menu step in `back`; it refuses a stale app. first5web.mjs unchanged.
- gpu-free saw `omarchy-agent-usage-ollama` (a usage reader whose name contains "llama") for an instant and voided M6's first start. Not touched; for the main session to rule on.

**Where the risk is, most first:** webshell.mojo's save queue, rescue and hold (what happens to a person's edits); rowsaver.mojo and docstore.mojo (threads, give-up, kill points); `App.may_close` on GTK and, unrun unlocked, on AppKit; GTK's draw-ahead default; buzanmap/mapmarks (a web map drawn and saved back); fonttext's declared faces (every text app); scene/gpu2d's rect_hole_corner; AppKit paced bench, mouse coalescing and the hidden menu bar view.

## Continuation 20 (2026-11-24, 00:03 on; autopilot overnight): review round 3 fixed, the owner's ruling, the everyday gaps

**M6 has no numbers for HEAD.** See "D" below for what ran. Everything in `docs/goals/79/race.md` and `race-mac.md` that isn't
labelled with a commit of this round is older: Linux 51a26d08, Mac 51a26d08. Continuation 19's changes (below) and this
round's have **not been judged by M6 or M7**.

### Review 3, each finding

| Finding | State | The proof | Commit |
|---|---|---|---|
| MUST 1 canvas A's picture and words in canvas B (F5, F5b, F7) | fixed | test_twodocs, test_twodocs_gl (GL, run once at 00:1x when the GPUs were free), test_pnshell `switches` | cf8daea7, e5230fde, ef73eb3b |
| MUST 2 a stale `empty` mark hid promoted tiles (F3) | fixed | test_tileempty; each of 4 mutants fails | b97f7866 |
| MUST 3 a failed read opened as an empty editable note (F1) | fixed | test_opendoc, test_canvasload, test_pnshell `broken` | e3a0934f, ddabcd7c |
| MUST 4 kept view without a notes file's identity; the grid saved from it (F2) | fixed | test_pnshell `kept views`; the choice is D-8030 | ddabcd7c |
| MUST 5 unsupported nodes, edges' labels, unknown keys lost on save (F8) | fixed | test_canvasround (35 documents), test_jsonpatch, test_noteround | 97418fab, 9d3e4b19, 12ad33be |
| MUST 6 é and Backspace (F9) | fixed | test_graphemes; corrected in 72501a4e (D-8036: an old proof, test_webpieces, had begun to fail) | 6f41f0ce, 72501a4e |
| MUST 7 kept pictures: never removed, 0644, shared .tmp, no cap (F4) | fixed | test_privatefiles, test_viewsnap, test_pnshell `kept pictures` | e3a0934f, ddabcd7c |
| SHOULD 1 the race's reopen wasn't the app's open (F7) | fixed | bench:reopen calls open() and forgets nothing | d666de27 |
| SHOULD 2 D-7958 changed a judged row and wasn't listed | settled by the owner's ruling: the first open ever is a judged row now (D-8025, D-8026); listed for the reviewer | judge_test.py | bbf8c644 |
| SHOULD 3 the report had nothing for HEAD | fixed: this section and continuation 19's | | this file |
| SHOULD 4 the Mac's web runs weren't voided under load | fixed (mac_web: quiet before each, void and again 3×) | read; **not run on the Mac** | bbf8c644 |
| SHOULD 5 switch and omnibar: different spans | fixed: both to the frame after; the one difference left is said in race.md | **not run on a GPU** | bbf8c644 |
| SHOULD 6 kept views written before the notes at close | fixed (D-8034) | read in both hosts; test_pnshell | d666de27 |
| SHOULD 7 failing and conflicting saves | fixed: held through switches and restarts, Retry; a conflict offers "Save a copy" | test_pnshell `held saves`, test_pnnotes `another app` | ddabcd7c, 99bda11e |
| SHOULD 8 rect_corner on the Mac | off until it has run there | `corner_quads`; **test_rectcorner not run on the Mac** | d666de27 |
| SHOULD 9 everyday gaps | listed (79-gaps.md: 63), S and most M built | test_pageedit, test_pageink, test_pnnotes, test_pnstore, test_boardedit, test_mapedit | b22bcfb4 … 64d09fb3 |
| SHOULD 10 component rows | fixed | scripts/components.py | ed498794, 801d1b7f |
| SHOULD 11 waits | bounded: 50 ms for a view, 5 s for an adoption | test_viewsnap, test_canvasload | d666de27 |
| NIT webswitch.mjs's header | fixed | | bbf8c644 |

**Speed cost of the fixes: not measured** (no GPU run this round).

### The owner's ruling (2026-11-24)
"yandong have a bar,  it sjust need better than web (sind its antive) if tis very close its ok". The reading (the main
session's): native better than the web on every row, or within 3 %; no absolute bar. GOAL.md M6 is amended under its row, which
is left as written. The check's judge compares the same span on both sides and prints the old marks on every row (D-8025,
D-8026); a GPU-free test holds it (docs/goals/79/judge_test.py: fails on one worse row, one missing number, one CPU frame, more
missed frames; passes a row over the old marks that beats the web). The Mac's frame rows say "work only, not like-for-like" and
are not passed: its AppKit host has no paced run, and its screen is locked.

### C: the gaps
[79-gaps.md](79-gaps.md). What was drawn before is drawn the same: on the fixture's ten screens the app's 86,180 lines of draw
operations (kinds, colours, words, numbers) are identical to c761a99f's, checked after each batch, but for a quote's `>` and inline code's ticks, both moved to what the reference picture shows (D-8042). The new pieces' look is ours
from the web's CSS; **nobody has seen them on a screen**.

### For the reviewer, this round
- **The M6 judge changed, by the owner's ruling only** (D-8025): what fails that passed before: a row slower than the web over the same span, more missed frames than the web, the first open ever, the un-warmed rows. What passes that failed: rows over 8.3/16.7 ms of work that beat the web.
- **D-7958**: changed what D-7951 judged (the process's first open) and wasn't listed. It is judged again.
- **tests/test_canvasload** (ddabcd7c): its broken documents now expect an error and a read-only board where they expected an empty one; exports compared with objects_json_canvas.
- **tests/test_pagedesk, test_graphemes** read renamed fields (line_top → tops, lines → ed.paras, caret_col → ed.caret.byte, edit_words → words.text()); the assertions are the same. test_graphemes' नि row moved to the sign-at-a-time case (D-8036).
- **tests/test_privatefiles** uses a folder of its own per process (a second run failed on what the first left).
- **A page's marks saved by this app before today counted bytes** where the web counts UTF-16 units, and stayed behind edits (D-8040). No migration: such a file is the reference copies' only.
- **scripts/gpu-free** was narrowed once (51d18dc6: a `.lock` path in a command isn't a job).

### Part two: a person's first five minutes (2026-11-24, from 02:30)
`docs/goals/79/first5.py` drives the app with real X pointer and key events on a headless display (drawn on the CPU; no GPU): a
first start with no notes file, a page typed with lists, code and a link, select, copy, paste, undo, a long page, marks, rename,
file, delete and Undo, search with é, a canvas (words, shapes, sticky, colours, ink, marquee), a mind map (made, dragged,
written, undone), notebooks, a restart. `first5web.mjs` opens a copy of the same file with the web app's own code, edits it, and
`first5.py back` opens that. All steps pass; pictures in `build/g79/first5-*.png`. What it found, each fixed with a test first
unless marked:

| Found | Fix |
|---|---|
| No words at all without a GPU | D-8043 |
| Spaces typed through the input method dropped in search, titles, ideas; no caret in search | e6a9af49 |
| Ink lost points in slow frames; translucent strokes darkened on themselves; eraser missed fast strokes | 4894e37d, D-8044 (not on the Mac) |
| Canvas opened zoomed out, page without its caret; words being written lost when another note opened | 0a8dfa70, D-8045 |
| **Emoji 8–16 px too high on Linux, since M2, which passed it** | 03ced5bc, D-8046 |
| Web texts with a CSS family list drawn in the sans; "bold" read as regular | 03ced5bc, D-8046 |
| The open note's notebook not marked; New note ignored it; opened notebooks closed at a restart | 03ced5bc, 77f78bff, D-8047 |
| A real map: sizes, wrapping, emoji, font ignored; no caret while an idea is written, the centre's new words not shown; ring without corners; wrong shadows | e3e75b34, 77f78bff, D-8048 |
| Rows don't answer the pointer; a notebook's + and … missing | 5673d226 |
| The software raster drew past a clip (the GPU was right) | 5673d226 |
| A sticky's shadow ignores its round corner | **open** (79-gaps 72): needs a renderer change, not made before a race |

Draw operations against c761a99f on the fixture's ten screens: the same but for emoji's baseline, the map's ring, shadow and
highlight, the search's caret, a quote's `>` and code ticks.

**For the reviewer, this part:**
- **M2's check passed emoji 8–16 px off**: its region compare isn't enough for a glyph that small. It wasn't changed this round.
- **The reference isn't quite the real web** (D-8048): its fonts are whole families (D-7901), so its map's centre is weight 700; the real page loads 400 and 600 only. Native follows the reference.
- test_webpieces and test_notesshell now hold the Mac to the Mac's reference (D-8049): the Linux numbers are untouched.
- test_pnnotes (mine, this continuation): one claim turned round: a row dragged onto a folded notebook leaves it folded, as the web does (D-8047). It had passed on Linux only because an earlier test left that notebook open; the Mac run showed it. The test now folds the notebook itself.
- D-7912 (the map centre's 20 px) was wrong as a rule and is replaced by the web's (D-8048).
- The first run of the Mac half at 03:57 waited on its own lock for 8 minutes (my mistake: the lock taken twice); killed and run again.

### D: the final run (05:00–05:37, once, commit 9bda0f2b)

| | Linux (RTX 3090) | Mac (M4, screen locked) |
|---|---|---|
| M0 | PASS 9bda0f2b | — |
| M1 | PASS 9bda0f2b: 19 lines, worst 0.00 px | PASS 9bda0f2b: worst 0.03 px |
| M2 | PASS 9bda0f2b: SSIM 0.976–0.986 | (M7) |
| M3 | PASS 9bda0f2b: SSIM 0.982–0.993 | (M7) |
| M4 | PASS 9bda0f2b: 28 steps, worst 0.965 | — |
| M5 | PASS 9bda0f2b | PASS 9bda0f2b |
| M6 | **FAIL** 9bda0f2b: 13 judged rows (race.md) | **BLOCKED** 9bda0f2b: work only, not like-for-like, no row judged (race-mac.md) |
| M7 looks | — | nine PASS 92495bf7 (the app's code at 9bda0f2b), 0.986–0.998 |

**M6's failing rows on Linux** (native against web, p95 / max): drag 40 600 16.7 / 76.8 vs 16.7 / 16.8; pen 600 16.7 / 72.2 vs 16.8 / 16.8;
typing 600 16.7 / 60.9 vs 16.7 / 16.8; pen stress 16.7 / 163.3 vs 16.8 / 133.3; typing stress 16.8 / 152.2 vs 16.7 / 16.8; each also not
warmed (ten rows, one cause: one long frame a row, the autosave). Undo 600 17.0 / 18.9 vs 16.9 / 17.1, warm and not, and undo stress
not warmed 17.4 / 19.1 vs 16.9 / 17.1 (three rows: p95 passes or is within a refresh, the worst frame is 1.8–2.0 ms over the tie's
18.3). The rest passes, opens by 3 to 13 times, starts by 2 to 2.7, memory by 3.9.
**Reruns** of the paced race on the same binary (race-reruns.txt): zoom 16.7–17.0 every time; undo's worst 16.9, 18.9, 19.0, 18.7,
17.0 (600) and 17.2, 17.1, 19.0, 21.8 (stress): noise on both sides of the line.

**After D** (a6766837, 0fe1ed14, D-8050): the save moved to its own thread and the export cut; on the app's thread 600 69 → 1.1 ms, stress
187 → 4–5 ms (CPU probe). **No race, no GPU run and no Mac run has judged it**: M0–M5 above are of 9bda0f2b, not HEAD.

**For the reviewer, D:** the paced judge found what every earlier race missed, because they timed the work inside frames: the report's
old "0 missed, max 5 ms" pen and typing rows were true of the frames' work and wrong about what a person saw. race-reruns.txt isn't
judged and changes no verdict.

## Continuation 19 (2026-11-23, evening; Linux only; not judged by M6 or M7)
D-8019…D-8024, b3cb79c6…933bc1f5. Aimed at the old bar's last Linux rows; kept because they are correct and tested, not judged
since. Measured in the race's own sequence on the desktop before the third power-off: stress zoom's worst frame 18–21 → ~7 ms,
undo p95 8.6–8.9 → 7.4–7.6 (3 runs each). Built: zooming out finds its edges rastered (D-8019), a fallback must cover what it
stands for (D-8020: a blank-block bug since D-7940), a sticky's body without stencils (D-8021; off on the Mac), a raster builds
only its part (D-8022), first-time work counted out of the first open (D-8024), and probes for the Mac's first frame, written
and **not run** (D-8023). Tests: test_zoomreach, test_rectcorner, test_tilecull. Linux M0–M5 at c761a99f printed PASS (Linux
halves, 22:23–22:33); M6 was stopped by the power-off at 22:55 and gave no numbers.

## Continuations 14–17 (2026-11-22 to 11-23, autopilot)
Decisions D-7976–D-8002; journal "continuation 14" to "continuation 17"; EXPERIMENTS likewise. In short:
- **Mac:** NSTextInputClient (M5 PASS), the Mac's own Chrome as reference and the race on the Mac's GPU, AppKit bench steps, PingFang and kern-round rules, the tracking table (`trak`), Menlo fallback; raster tiles and kept views on Metal (D-7993, D-7994); the launcher's lower bound (D-7996).
- **Linux:** the incremental op index (D-7987), a patch-in-place index, real re-routes only in the change log and bulk replay (D-7999); the glyph warm-up (D-8002).

## Continuation 18, final table (2026-11-23; all code at 51a26d08)
Every run below is of 51a26d08's code (later commits are only these results and this report). Mac: 20:30–21:26 (load 1.8–3.0 at each start; Spotlight back on one core during some runs, printed in race-mac.md). Linux: 20:52–21:24 (load 0.3–1.8).

| # | Linux | Mac (M4, AppKit, Metal) |
|---|---|---|
| M0 | PASS | — (no Mac half) |
| M1 | PASS (worst 0.00 px) | PASS (worst 0.03 px) |
| M2, M3, M4 | PASS | pass inside M7 |
| M5 | PASS | PASS |
| M6 | **FAIL, two rows**: stress zoom max, stress undo | **FAIL**: first open (both notes), stress press; omnibar not settled |
| M7 | — | **PASS** |

**Rows whose verdict is the reruns' median, range in brackets** (the checker judges its own single race and its bar was not touched; the numbers here are the report's, as ruled):

| Row (bar) | Race | Reruns: median [range] | Verdict |
|---|---|---|---|
| Linux stress zoom max (16.7) | 18.2 | 18.0 [15.4–19.1], 6 | **fails** |
| Linux stress undo p95 (8.3) | 9.0 | 8.75 [8.5–9.7], 6 | **fails**; not settled before, now settled as a fail at idle GPU clocks |
| Mac 600 first open of the process (8.3) | 10.7 (9.3 at 29ee729b) | 6.2 [6.1–6.7], 3, but those are the first open *after* others in the process | **fails** as the process's first open |
| Mac stress first open (8.3) | 9.4 (10.3) | 11.0 [9.4–11.1], 3 | **fails** |
| Mac stress press during an open (8.3) | 9.3 (8.8) | 9.2 [7.0–11.1], 3 | **fails** |
| Mac 600 press during an open (8.3) | 7.8 (8.4) | 7.8 [7.8–9.1], 3 | passes, **not settled** |
| Mac stress redo p95 / max (8.3 / 16.7) | 8.3 / 12.6 | 7.8 [7.1–7.9] / 16.0 [12.4–16.8], 3 | passes, max **not settled** |
| Mac stress drag 40 max (16.7) | 14.3 (18.6) | 13.8 [13.6–15.5], 3 | passes |
| Mac note switch p95 (8.3) | 6.3 (6.8) | 7.3 [6.3–8.7], 3 | passes, **not settled** |
| Mac omnibar p95 (8.3) | 6.0 (8.7) | 8.8 [7.1–8.9], 3 | **fails** by the reruns; the race passed |

(In brackets in the race column: the same race at 29ee729b, the code before D-8018.) The checker can't take a rerun median without a change to what it judges, so this is in the report only; flagged to the main session.

### What still costs what, and can it reach the bar
**The machine first (D-8017).** tests/probe_coldpaint.mojo times one board paint. On the M4 the same code takes 168 µs back to back and 1,165 µs after the thread slept 8 ms: 7×; Linux 2×. Interactive QoS changes nothing, the Mach time-constraint policy nothing. Every row below that fails on the Mac is the first frame after a pause, and is timed at that speed whatever the framework. That isn't proof it can't pass: less work still passes.
- **Mac first open, stress (9.4–11.1).** Event 1.2–2.2, scene 1.7, batch 0.6, Metal 2.5–3.4 (kept view: read 0, decode 1.3–1.8, upload 0.7–2.0), GPU 0.9–2.6. The same open warm: 2.4 ms. Left to do: two small head reads in the event (~0.5), page chrome kept (962 ops), the 10 tiles' decode (a second copy costs what it saves). Can reach 8.3: about 25 % less work is needed.
- **Mac first open of the process, 600 (9.3–10.7).** Same split, and its first use of the canvas path. Not split further this round.
- **Mac press during an open (9.2).** Event 3.7–5.6 on a process's first press against 1.6–1.8 on the later ones, same work; the frame 3–5 against 1.4. Bound by the cold clock on the first press; can reach 8.3 only with less first-press work.
- **Mac omnibar (7.1–8.9).** Event 1.2, scene 1.3, batch 1.2, rest 0.8, GPU 2.5–3.4 (the page under it 2.4, then scrim and panel). Can reach it: GPU overdraw is the largest part left.
- **Mac drag 40 (13.8).** Lift patch 3–5, tile batches 5–7, GPU 2–6, all in the first moving frame.
- **Linux stress undo (8.75).** GPU p95 5.7–5.9 of it, at idle clocks (P8). In a run on a warmer GPU (18:52) the same binary's predecessor gave 5.5 and 7.6. What is left: ops per damaged rect and GPU state changes (not done this round).
- **Linux stress zoom max (18.0).** One frame: 5 tiles a zoom-out uncovers with nothing kept under them, 5,758 ops: plan 1.1, fill 3.2, raster calls 2.7, CPU 7.0, GPU 3–4, scene 1.2. The same max at P5 and P8 (13–15 in a short run): not the clock. Can reach it by keeping the last zoom's tiles under the view or bounding what a frame rasters; not built.
- **No row is marked impossible.**

### B, item by item
- **Omnibar, note switch (D-8007, D-8008, D-8011–D-8014).** Before (f5e9bdb9, Mac): omnibar 17–19, switch 22–25. Idle warming readies the omnibar, the title card, settings and the 12 newest notes (≤ 64 KB), 4 ms at a time, none within 300 ms of input; one screen's painting is not sliced (≤ ~6 ms cold). **The race's rows are with it**, warming in the bench's own pauses (0.5 s before, 0.3 s between steps; no wait was added). **A switch before the warming finishes** (both warm-ups off, 3 starts each): Mac switch 24.2, 21.3, 22.0; Mac omnibar 32.7, 35.0, 34.3; with it 7.3, 8.7, 6.3 and 8.8, 7.1, 8.9. Linux off: 6.4–6.6 and 7.0. Every frame is whole either way: nothing is drawn blank.
- **Open first frame, press (D-8015).** Read on a second thread while the frame is laid out; the outgoing board freed off the main thread (2.7 ms). Splitting the restore (visible tiles first) was not built: the restore already shows only the view's tiles.
- **Tile bursts.** Zoom frames no longer walk the board (D-8010): Mac stress zoom p95 8.4 → 4.1–5.5, max 13.5–15.4 → 5.6–8.0. A drop was measured, not rebuilt: 5.5–5.7 on the Mac, so the keep-the-lifted-layer plan was not needed. A drag lifts at its first movement (D-8018): drag 40 16–18.6 → 13.6–15.5.
- **Clocks (D-8017).** Proven for ordinary frames (GPU p95 3.5–3.7 ms at P8/210 MHz, 0.7–2.7 at P5), dropped for the worst one (max 13.1–13.6 cold, 13.9–14.7 warm). No clock setting changed, no work invented.

### C
- **A with no kept view was a product bug, found and fixed (D-8016).** A frame that rastered the last tile asked for nothing more, so the frame that would have kept the view came only by chance. test_viewsnap: driven by the renderer's `more` alone, none of the 7 tiled boards tried was kept before; every tiled one is now (15 of 15). A window closing sooner than the save's 750 ms keeps its view at the close (Linux 16.6 ms; the next open 3.4 ms instead of 98). Race A no longer reruns: a run that keeps no view is a FAIL.
- **Undo is settled as a fail on Linux.** Table above.

## Continuation 17, final table (2026-11-23; every number labelled with its commit)
Code measured: Linux M0–M6 at b86e4ce0 (its code is 1c8de571's); Mac M1 at f96c5dbf, M5 at 1c8de571, M7 at 97129b6c, M6 at 1c8de571 (race-mac.md) with three reruns of the failing rows (build/g79/c17-mac-reruns.txt).

| # | Linux | Mac (M4, AppKit, Metal) |
|---|---|---|
| M0 | PASS (f0093bd5) | PASS |
| M1 | PASS (1c8de571) | **PASS** (f96c5dbf: worst 0.03 device px, emoji included) |
| M2, M3, M4 | PASS (1c8de571) | pass inside M7 |
| M5 | PASS (1c8de571) | PASS |
| M6 | **FAIL, one row**: stress zoom max 19.0–19.6 (bar 16.7), 3 reruns and both binaries alike; quiet (load 0.3–1.3), GPU at idle clocks (P8) | **FAIL**: see below |
| M7 | — | **PASS** (97129b6c) |

**Mac M6 rows that fail** (quiet-checked, load 1.6–3.0, Spotlight on one core throughout; native bar p95 ≤ 8.3, max ≤ 16.7, faster than the web):
600 note: first open of the process 9.8 (three reruns of the cold opens 6.7–8.0 ✓); press during an open 8.7–9.8 (bar 8.3). Stress: first frame 9.3–12.2 (14.5 in the race), press 12.1–15.2, drag 40's max 16.7/18.2/20.0, redo p95 8.5–10.5. Note switch p95 24–27 and omnibar 18–19 against the web's 66 and 34: faster than the web, not silky. Everything else in the two note's rows passes.

**What moved it (D-7999, D-8005, D-8006):** an edit's and a drag's frame cost what changed, not the board: undo 8.0 / 8.4, drag one's max 17.4 → 11.8–14.5, drag 40's max 20.4 → 16.7–20.0, redo's max 17.5 → 15.0–16.5.

## Continuation 13 (2026-11-22, evening, autopilot): the retained-scene patch, the open's spike; Linux M6 down to one row
Decisions D-7974–D-7975; journal "continuation 13". The race (18:04–18:11) and the reruns ran on a quiet machine (goal 77
idle in all 14 samples, load ~1).

- **Retained-scene patch (D-7974).** An edit now re-paints only the objects it changed and replays everything else's kept
  ops, for any board. tests/test_keptpatch runs 40 random edits: commands identical to a full walk, frames identical. It
  didn't move undo: the edit path's cost is the damage compare over every object and the renderer's op-bin rebuild,
  not the walk.
- **The open's spike (D-7975).** It was one frame per open rastering 5 ring/extension tiles under a too-large per-frame
  budget. The budget is now 800 ops; frames-during max went from 17.2 to 9.8 in the race.

**Race (race.md 18:11, quiet):** every 600 row passes. Every stress row passes except **undo**:
- open first frame 7.7 (first open, kept view in 30 of 30 cold opens)
- frames during 5.1 / 9.8
- press 4.7
- complete 417 / 503 ms (web 1,124)
- zoom 5.8 / 14.4
- redo 6.8 / 7.1
- undo **9.6 / 9.9**; reruns p95 12.3 / 9.5 / 9.7 (median 9.7)

**Linux M6 is one row from passing.** The levers left for undo are named: an id-level change log in ObjectLayer, so an
edit doesn't compare all ~5,300 objects, and incremental op bins in the renderer. Neither is built. M2, M3, M4 **PASS**
(rerun).

## Mac half, first contact (2026-11-22, late evening)
The Mac came online (arm64, macOS 27.2, its screen at backing scale 1.0). I changed no `defaults` or privacy settings and
installed nothing system-wide. Status per milestone on the Mac:

| # | Mac | why |
|---|---|---|
| M1 | **FAIL** | Web faces, CJK and emoji match exactly; the fallback scripts (Hindi, Tamil, Arabic, Korean) use Apple's faces where the reference (Chromium on Linux) used Noto. The decision is open: ship the Noto faces, or judge those lines against the Mac's Chrome (macwidths.py measures them; Chrome's own web-face widths differ per platform too) |
| M5 | **FAIL** | The AppKit host has no NSTextInputClient yet (struct-returning methods to solve on arm64) |
| GPU | present | gpu2d draws on Metal (Apple M4) |
| M6 | **FAIL / BLOCKED** | Native: zoom p95 9.2 / max 12.9 on Metal; every other row n=0 (the AppKit framebench lacks those bench kinds). Web race: needs node + Playwright on the Mac (not installed: the main session's call, since given: D-7977) |
| M7 | **FAIL** | The shots come back now (render step, PNOTE_BOXES, fetched {out}). Open: renders at 1× (the screen's scale) vs the 2× reference; the notes panel rows come out in another order; goal 75's compare.png; components.md fonttext ✅ on the Mac |

## Continuation 12 (2026-11-22, evening, autopilot): where undo's GPU time goes, shadows thinned
Decisions D-7971–D-7973; journal "continuation 12". The race ran on a quiet machine (17:34–17:41; goal 77 idle in all
14 samples, GPUs P8), and so did the reruns.

**The split (D-7971), stress undo frames:** quads 1.1–2.4 ms (the 10-layer shadows), glyphs 0.2–0.5, stencil paths
0.2–0.55, clears 0.03–0.14, tile composite ~0.37. Two framework fixes, both pixel-identical by test:
- **D-7972:** each quad's and glyph's box is cut to its clip and the scissor before its triangle is built. Two triangles
  were tried and refused: their shared seam blends twice under coverage modulation.
- **D-7973:** shadow layers under an opaque sticky are drawn as four clipped bands round the middle the sticky hides.
  Undo frames' quad GPU time went 1.16 → 0.78 ms. M2/M3 still pass.

Undo/redo went from ~10 to ~7–9.5 ms.

**Zoom:** the worst settle frame rasters tiles the old tiling doesn't cover (revealed edges). The per-frame budget doesn't
move it, and deferring those tiles would show blanks. Its max stays 13.4–14.1 in quiet runs, under the 16.7 bar.

**Race (race.md 17:41, quiet) and reruns (3×, quiet):**
| note | row | before (c11) | now | |
|---|---|---|---|---|
| stress | open: first frame (first open 8.1; kept view 30 of 30) | 7.8 ✓ | 8.1 | ✓ |
| stress | open: frames during | 4.1 / 14.7 ✓ | 5.1 / **17.2** · reruns (cold-open row) max 10.2 / 12.5 / 13.4 (median 12.5) | ✗ in race.md |
| stress | open: a press during it | 6.2 ✓ | 6.9 · reruns 4.6 / 5.1 / 5.1 | ✓ |
| stress | zoom from 30 % | 6.9 / 20.7 ✗ | **4.6 / 14.1** | ✓ |
| stress | undo | 10.6 / 11.3 ✗ | **8.8 / 9.2** · reruns p95 9.5 / 9.4 / 6.5 (median 9.4) | ✗ |
| stress | redo | 11.3 / 11.5 ✗ | **6.8 / 8.5** · reruns 7.2 / 7.0 / 6.8 | ✓ |
| 600 | every row | ✓ | ✓ | ✓ |

**Milestones:** M0 PASS · M1 BLOCKED (Mac) · M2, M3, M4 **PASS** (rerun after the shadow change: 0.974 / 0.984 / 0.972 /
0.974; canvas 0.992; 28 steps, worst 0.964, notes equal) · M5 BLOCKED · M6 **FAIL** (stress undo p95; stress frames during
max 17.2, reruns pass) · M7 BLOCKED.

## Continuation 11 (2026-11-22, evening, autopilot): the 44 ms frame bisected, the open's frames pass
Decisions D-7968–D-7970; journal "continuation 11".

**Machine state.** The race (16:53–17:00) and its reruns ran with one goal 77 process busy at ~130 % CPU throughout (its
voice/web check; c11-quiet.log 16:24–16:52 never quiet). The GPUs were idle (P8, 0 %) in almost every sample, and the
load was 0.8–2.6. Treat the race as under light load.

**The ~44 ms undo frame (D-7970).** The bisect (3 runs of each build, same probe, same window) put it on 94a218fc,
continuation 10's press change: max 43.2 / 43.6 / 44.5 there, ≤ 13.4 on 5ff9ae3a and on 4f4cabdb (the GL state cache:
clean). I reverted 94a218fc; undo max is 10.6 / 11.6 / 11.0 since.

**Undo's work (D-7968).**
- (a) Partial rasters already encode only the ops whose exact bounds meet the damaged part.
- A shared frame per partial raster cut uploads by 42 % but doubled GL calls and raised renderer CPU, so I dropped it.
- The undo frame's renderer CPU is ~1.7 ms of ~10; the rest is GPU raster time at idle clocks (2.4–5 ms) and the scene.
  So (b), resident geometry, would save ≤ ~1 ms, and (c), spreading the re-raster, can't remove the old position's
  re-raster from the frame that shows the undo. Neither was built.
- Undo/redo stay ~10 ms at idle clocks; at P2 they measured 7.8 / 6.0.

**The open's frames and the press (D-7969).**
- BoardLook walks nothing while holding.
- Its kept ops survive adoptions outside its cull rect.
- `Painter.layer_ops_version` lets the renderer keep its op bins (it rebuilt ~20k ops' bins every slice).
- pnote's open slice is capped at 500 µs (A/B 1500 / 700 / 400).

The "first press one-time cost" wasn't one: the first press of a row landed on an ordinary during-open frame.

**Race (17:00) and reruns (3×, under light load):**
| note | row | before (c10 race) | now | |
|---|---|---|---|---|
| stress | open: first frame (first open 7.2, kept view in 30 of 30 cold opens) | 18.8 ✗ (spike) | **7.8** | ✓ |
| stress | open: frames during | 11.4 / 35.8 ✗ | **4.1 / 14.7** | ✓ |
| stress | open: a press during it | 10.7 ✗ | **6.2** | ✓ |
| stress | open: complete | 200 / 250 | 417 / 467 (web 1,688 this run) | ✓ |
| stress | zoom from 30 % (max) | 21.6 | 20.7 · reruns 15.2 / 15.4 / 17.3 (median 15.4, worst 17.3) | ✗ |
| stress | undo / redo (p95) | 12.5 / 9.3 | 10.6 / 11.3 · reruns 11.4–11.6 / 10.5–12.0 (load 2.3–2.6); at load ~1: 10.2 / 10.0 | ✗ ✗ |
| 600 | every row (open first frame 5.3, during 3.4, press 3.7) | ✓ | ✓ | ✓ |

**Milestones:** M0 PASS · M1 BLOCKED (Mac) · M2, M3, M4 **PASS** (rerun: 0.974 / 0.984 / 0.972 / 0.974; canvas 0.992; 28
steps, worst 0.964, notes equal) · M5 BLOCKED · M6 **FAIL** (stress zoom max, undo, redo) · M7 BLOCKED.

## Continuation 10 (2026-11-22, autopilot): counting GL, the premise tested
Decisions D-7965–D-7967; journal "continuation 10". The machine was quiet at 14:28 and the race started then, but goal 77
woke mid-race (busy in 5 of 14 samples). Polling 14:50–15:50 found no quiet window again (load up to 46, GPU bursts to
100 %; build/g79/c10-quiet.log). The reruns at 15:50 ran under goal 77 load and are labelled so (c10-reruns2.txt).

**Counts (MOJOUI_GL_COUNT, D-7965), stress:**
- An undo frame (4 partial tile rasters): 4,407 calls · 377 draws · 351 program · 496 VAO · 530 buffer binds · 1,029
  attribute calls · 395 stencil · 625 KB in 62 uploads.
- An open-slice frame: 311 calls · 37 draws · 6.9 KB.
- The press frame: ~5.8k calls · 744 draws · 1.1 MB.

**The fix and the premise (D-7966).** Run state is now set only when it changes, and draws use base instances (the GLES
extension included; pnote's context is GLES), with each vertex array keeping its attribute pointers. That cuts GL calls
by about a third (attribute calls 1,964 → 8 in a 6-tile frame), pixel-identical (tests/test_glstate). **Undo/redo didn't
move** (A/B ×3, 9.3–10.1 either way), so GL call cost isn't what makes them slow. The GPU's undo work is ~2.4 ms at idle
clocks, and the bench adds it to the CPU draw. A rerun while goal 77 held the GPU at P2 gave undo/redo 7.8 / 6.0. The
one-burst ordering wasn't needed: the GPU query no longer spans the CPU's issue.

**The press (D-7967).** A press that hasn't moved no longer lifts, and a no-op release no longer saves. Both are correct
and tested, but neither moved the row (10.2–10.4). The row's max is always the first press; later presses run ~6.5 ms.
Next: warm that first use in the framework.

**Race (14:28, race.md) and reruns under load (15:50, 3×):**
| stress row | race | reruns (each run: goal 77 busy) | |
|---|---|---|---|
| open: first frame (first open from the kept view) | cold max 18.8 (first open 7.9) | first open 8.8 / 7.2 / 7.9 · cold max 7.6 / 5.2 / 5.4 | ✗ in race.md |
| open: frames during (p95) | 11.4 / 35.8 | 8.6 / 8.5 / 8.4 | ✗ |
| open: a press during it | 10.7 | 8.8 / 10.5 / 10.3 | ✗ |
| zoom from 30 % (max) | 21.6 | 14.5 / 14.9 / 15.1 (pass) | ✗ in race.md |
| drag 40 (max) | 19.5 | 7.4 / 19.0 / 18.2 | ✗ |
| undo / redo (p95) | 12.5 · 9.3 | 7.8 · 6.0 (GPU at P2) / 12.3 · 10.3 / 11.3 · 9.4 | ✗ |
| undo max | 43.4 | 15.9 / 43.5 / 44.1 | new: a ~44 ms undo frame, not reproduced with tracing; open |

Every 600 row passed in the race. **Milestones:** M0 PASS · M1 BLOCKED (Mac) · M2, M3, M4 **PASS** (rerun: 0.974 /
0.984 / 0.972 / 0.974; canvas 0.992; 28 steps, worst 0.964, notes equal) · M5 BLOCKED · M6 **FAIL** · M7 BLOCKED.

## Continuation 9 (2026-11-22, autopilot): undo/redo settled, retained ops
Decisions D-7963 and D-7964; journal "continuation 9". The quiet probes ran first (13:28: load 1.5, both GPUs P8 at 0 %).
The race waited for a quiet window (13:43–13:51, build/g79/c9-quiet.log) and ran 13:51–13:58 from load 0.5. Goal 77 was
busy in 5 of the 14 samples taken during it (c9-m6-samples.txt). The Mac was not tried.

**Undo/redo, settled (D-7964).** I built 69b9ae2d (before continuation 8) in a scratch copy and probed it alternately
with a841a377 in the same quiet window. Both measure ~10 ms, so this round's code didn't cause it. The row depends on
the steps before it and on the GPU's clocks:
- After `drag40`, the same tile work costs ~2 ms more GL issue time.
- Continuation 7's 5.7 / 6.3 ran while goal 77 kept that GPU at P2.

The reported "GPU time" is mostly the GPU waiting while the CPU issues the frame. Per pass the GPU works 0.5–1.5 ms, and
the elapsed query tracks the CPU's span inside it (+0.2 ms). No clear, full-surface blit, sync or read-back showed up.
Not fixed yet; the next lever is to issue a frame's GL work in one burst.

**Retained ops (D-7963).** `Painter.ops_mark/ops_capture/ops_replay` and `KeptOps`: BoardLook replays the board's last
ops while its token holds. tests/test_keptops shows op-for-op equality, pixel-identical frames, and invalidation on an
edit, a pan, a zoom and a lift. Stress probe: pan 3.8–4.6 → 2.0–2.1 ms p95, typing 4.7 → 3.6.

**The press during the open** stays ~10 ms. Most press frames are ~6.5 ms; the first press of each row costs ~4 ms
more, a first-use cost not found yet.

**Race (race.md 13:58) and reruns (3×, median / worst, build/g79/c9-reruns.txt):**
| note | row | race | reruns | |
|---|---|---|---|---|
| 600 | every row | open first frame 5.1, during 4.0 / 4.4, press 4.4, undo 5.5 / 7.6, redo 5.5 / 7.2 | — | ✓ all |
| stress | open: first frame (from the kept view, 30 of 30 cold opens; first open 8.2) | 8.2 | — | ✓ |
| stress | open: frames during | 8.9 / 11.9 | p95 8.4 / 9.3 (max ≤ 11.4) | ✗ (just over) |
| stress | open: a press during it | 10.0 | 10.3 / 10.4 | ✗ |
| stress | zoom from 30 % (max) | 21.7 | 14.3 / 14.8 | ✗ in race.md (a spike; reruns pass) |
| stress | drag one (max) | 20.1 | 6.6 / 7.1 | ✗ in race.md (a spike; reruns pass) |
| stress | undo / redo (p95) | 13.1 · 9.1 | 10.2 / 10.5 · 9.6 / 9.8 | ✗ ✗ |
| stress | pan 30 % / 100 % | 3.7 / 5.9 · 3.4 / 5.5 | — | ✓ |
| — | printed, not judged: first open ever 25.0 / 103.6; MOJOUI_SNAP=0 cold first frame 12.4 / 116.2 | | | |

**Milestones:** M0 PASS · M1 BLOCKED (Mac) · M2, M3, M4 **PASS** (rerun on this build: 0.974/0.984/0.972/0.974; canvas 0.992; 28 steps, worst 0.964, notes equal) · M5 BLOCKED (Mac) · M6 **FAIL** (stress: frames during, press, undo, redo; zoom and drag one on spikes) · M7 BLOCKED (Mac).

## Continuation 8 (2026-11-22, autopilot): edits mid-open, fill damage, quiet snapshot reads
Decisions D-7959–D-7962; journal "continuation 8". The Mac was not tried (still offline). I waited an hour for a quiet
machine (12:12–13:12, every 2 min, build/g79/c8-quiet.log), but goal 77's checker ran throughout (a process over 50 % CPU,
GPU bursts of 97–100 % on either GPU). The race ran at 13:12–13:19 with both GPUs idle at the start and end (P8) and load
1.1–1.6. One mid-race sample showed GPU 1 at 63 % (build/g79/c8-m6-samples.txt).

**What changed (framework; pnote only composes):**
- `OpenBoard.near(rect)`: an edit during the open loads what it touches, not the whole board. The open reserves the
  document's ids. An edge whose end was deleted joins that delete's undo step. pnote's press, drag, release and tap load
  only the pointer's neighbourhood.
- Damage from adopted objects only (`ObjectLayer.adoptions`, `DamageSnap.append`).
- The restore is prewarmed: `viewsnap.expect_snapshots()` makes the buffer and textures after the first screen.
- The open's slice target is 3000 µs.
- Snapshot reads wait for a view that has held still for 750 ms. Before, they were starting between bench frames, each
  frame paying a synchronous read.

**Race rows that moved (race.md 13:19; before = continuation 7's run):**
| note | row | before | now | |
|---|---|---|---|---|
| 600 | open: first frame (from the kept view) | 7.8 | 5.1 | ✓ |
| 600 | pan 100 % / redo | 3.9 / 53.6 ✗ · 9.4 / 11.3 ✗ | 4.2 / 6.2 · 5.8 / 7.7 | ✓ ✓ |
| stress | open: first frame (from the kept view; 30 of 30 cold opens) | 11.7 ✗ | **8.1** (first open 7.1) | ✓ |
| stress | open: frames during | 12.6 / 16.6 ✗ | **8.1 / 14.4** | ✓ |
| stress | open: a press during it | 60.6 ✗ | **10.3** (reruns 9.9 / 10.6 / 10.6: median 10.6, worst 10.6) | ✗ |
| stress | open: complete | 167 / 232 | 333 / 450 (web 1,336) | ✓ |
| stress | zoom from 30 % | 4.6 / 13.9 ✓ | 6.7 / 23.1 (one spike; reruns max 13.7 / 13.0 / 12.8: median 13.0, worst 13.7) | ✗ in race.md |
| stress | undo / redo | 5.7 / 6.2 · 6.3 / 8.9 ✓ | 10.1 / 10.5 · 9.7 / 10.1 | ✗ ✗ |
| — | printed, not judged: first open ever 26.0 / 109.8; MOJOUI_SNAP=0 cold first frame 14.1 / 62.1 | | | |

**Read it honestly.** On the kept-view path, D-7946 (a) now passes on both notes: 5.1 ms and 8.1 ms, the latter with
0.2 ms to spare. The stress open's frames during now pass as well. Three things still fail:
- *The press during the stress open* is ~10.5 ms, every time. The press itself costs 1.2 ms; the frame that shows it costs
  ~9: the lift re-emits the board and its damage is rastered.
- *Stress undo/redo* run ~10 ms in every probe this round (8.1–10.6). The tile work is 1–1.8 ms of CPU. The frame's GPU
  time is 4.8–5.7 ms under graphics offload, against 1.3 ms when GTK composites. That points at the offloaded frame
  (dmabuf export or implicit sync), not at tile ops, so "ops per damaged tile" wasn't built.
- *Zoom*'s race row failed on a single spike. Its reruns are 12.8–13.7 ms, but the row in race.md stays ✗ as generated.

The first open of a note ever, with no kept view, is unchanged at 26 / 110 ms (printed, D-7958).

**Milestones** (`scripts/check`): M0 PASS · M1 BLOCKED (Mac) · M2, M3, M4 **PASS** (rerun 13:2x on this build: SSIM
0.974/0.984/0.972/0.974; canvas 0.992; 28 steps, worst 0.964, notes equal) · M5 BLOCKED (Mac) · M6 **FAIL** (4 rows:
stress press during the open, zoom (one spike), undo, redo) · M7 BLOCKED (Mac unreachable).

## Continuation 7 (2026-11-22, autopilot): the kept view, the deferred open, a fast restore
Decisions D-7956–D-7958; journal "continuation 7". The Mac was still unreachable. The machine was **not quiet**: another
session's goal 77 apps ran in bursts (15–21 GB and up to 92 % on GPU 1, 100–270 % CPU). The M6 run (11:31–11:37) started
at load 2.25 and ended at 2.4–2.75; clocks are in build/g79/c7-m6-start.txt / -end.txt; GPU 0 sat at P8 throughout.
Treat its single-spike rows as suspect, not as proof.

**What changed (all in mojoui; pnote only composes it):**
- `mojoui.viewsnap` is now wired into pnote. A canvas's settled view is kept on disk, keyed by note, revision, skin, zoom,
  view, size, GPU and build. The next open shows it in its first frame. The page grid travels in the file's note.
- `OpenBoard.open_later(TextSource)` reads and skims the note on a job thread (`SqlText`, `start_ui_job`). The view's
  objects, and both ends of every edge crossing it, come in by parallel slices, and `holding()` stays true until they are in.
- The restore went from 7.6–19 ms to about 2 ms (4–8 ms the first time in a process). It does one read, decodes every tile
  in parallel into a mapped pixel-unpack buffer that is kept between restores, then uploads from that buffer.
- A cold open now restores in its own frame. The restored tiles become real tiles once the hold ends, so nothing is
  rastered again to replace them.
- `mojoui.framebudget.FrameBudget` sizes the open's slices to what is left of the frame.
- The checker labels which path each open took, counts restores, and prints the no-snapshot runs beside the table.

**Race rows that moved (race.md, this run; before = review round 2's final run):**
| note | row | before | now | |
|---|---|---|---|---|
| 600 | open: first frame (judged: from the kept view, 30 of 30 cold opens + the first open) | 25.7 ✗ | **7.8** | ✓ |
| 600 | open: frames during / press / complete | 3.4/4.7 · 3.2 · 50 | 8.1/8.8 · 5.0 · 53/69 | ✓ ✓ ✓ |
| 600 | pan 100 % | 3.8 / 6.1 ✓ | 3.9 / **53.6** | ✗ (one spike; p95 unchanged) |
| 600 | redo | 7.5 / 8.2 ✓ | **9.4 / 11.3** | ✗ (composited run 20.6 / 39: GPU contention) |
| stress | open: first frame (judged, from the kept view) | 105.9 | **11.7** | ✗ |
| stress | open: frames during | 9.2 / 10.2 | **12.6 / 16.6** | ✗ (worse) |
| stress | open: a press during it | 11.1 | **60.6** | ✗ (worse: waits for the job and the whole parse, D-7952) |
| stress | zoom from 30 % | 5.4 / 21.3 ✗ | 4.6 / 13.9 | ✓ |
| stress | undo / redo | 10.1 / 10.7 ✗ | 5.7 / 6.2 · 6.3 / 8.9 | ✓ ✓ (no change aimed at them: run-to-run) |
| 600 / stress | first open ever, no kept view (printed) | — | 27.7 / 112.7 | not judged |
| 600 / stress | cold opens with MOJOUI_SNAP=0 (printed): first frame | — | 15.1 / 74.4 | not judged |

**Read it honestly.** Where the kept view can be used, the first frame meets D-7946 (a) on the 600 note (7.8 ms). On the
stress note it comes close (11.7 ms; ~9.6 ms p95 in quieter probes). The first open of a note ever, with nothing kept,
still parses: 27.7 and 112.7 ms. If the main session rules that this is the open D-7946 (a) judges (D-7958), (a) can't pass on
the stress note. The cost of the new path is a press during the open: it must finish the whole load (D-7952), which now
includes waiting for the job, so it takes 60 ms. The stress frames during the open (12.6 / 16.6) are the paint walk plus
damage tracking over ~5,000 objects each slice, plus slices. Next: edits on a partial board (attack D-7952's
finish-first), damage from adopted objects without a walk over all of them, lever 3 (undo/redo ops per damaged tile).

**Milestones after this round** (`scripts/check`): M0 PASS (unchanged inputs) · M1 BLOCKED (Mac) · M2, M3, M4
**PASS** on this build (rerun 11:38–12:0x: SSIM 0.974/0.984/0.972/0.974; canvas 0.992, map 0.986; 28 steps, worst 0.964, notes
equal) · M5 BLOCKED (Mac) · M6 **FAIL** · M7 BLOCKED (Mac unreachable).

**Review round 2 (11-20, 07:0x–08:2x): a fresh reviewer's NEEDS WORK at 256035e0, and the main session's cold-start
decision.** Every number here comes from the final M6 run (08:05–08:2x, build/g79/final-check5.log; docs/goals/79/race.md),
started after waiting 15 minutes for a quiet machine (load 1.3 at the start, 1.5 at the end; no program over 1 GB on
either GPU: another session's goal 77 app had been holding 19 GB on GPU 0 on and off). M2, M3 and M4 were rerun on this
round's build (07:23–07:40): PASS (0.974/0.984/0.972/0.974; canvas 0.992; 28 steps, notes equal). The Mac stayed
unreachable (port 22 timed out each time).

## Review 2: each finding
| # | Finding | Outcome | Proof |
|---|---|---|---|
| Must 1 | "cold" opens found the note's tiles kept | **held, fixed (D-7951)**: tiles dropped before each cold open, the first timed open comes from another note, the process's first open timed too (PNOTE_FIRST) and judged | race.md: first frame 600 **25.7** ms, stress **105.9** ms (were 7.9 / 25.4 with kept tiles) |
| Must 2 | open frames lacked GPU time | **held, fixed (D-7953)**: each frame's draw + own GPU + own paint + raster when composited + sync | race.md: frames during 600 3.4 / 4.7, stress 9.2 / 10.2 |
| Should 3 | an edit during the open blocks, unmeasured; finish before the chrome hit-test | **held, fixed (D-7952)**: chrome hit-tested first; framebench `openpress` times the frame showing a press made during the open, judged under (b) | race.md: 600 3.2 ms, stress **11.1** ms |
| Should 4 | the gate was 9 pnote call sites | **held, fixed (D-7952)**: `mojoui.canvasload.OpenBoard` (layer / edit() / take() / step()), `pagedesk.board_rect` | tests/test_canvasload case 7 (edit mid-open through OpenBoard, undo) |
| Should 5 | tile damage tests missed edit kinds | **fixed (D-7955)**: resize, z-order, ink added/erased, connector re-routed, rotation, zoom out over kept tiles, 10 open slices over kept tiles | tests/test_boardraster: all tiled == direct (worst 6 levels) |
| Should 6 | "shown" always 0.0 / 0.0 (0) | **fixed (D-7955)**: printed "shown: not measured" when n = 0 (reading presentation times on the hidden screen not fixed) | race.md |
| Should 7 | GDK_DISABLE / GSK_RENDERER leaked to launched programs | **held, fixed (D-7954)**: taken back once GTK read them | test step `env:` prints both empty after start; cold start unchanged |
| Nits | hash, duplicate ids, header, web open label, SIGBUS note, dead line, PNOTE WEB on start runs | **all fixed (D-7955)** | test_canvasload case 6 (duplicate id), checker |
| Decision | cold start like with like | **logged (D-7950), checker changed**: judged against PN's desktop launcher cold and a fresh Chromium; warm page load printed, not judged | race.md: native 270 ms vs launcher 736 ms and fresh Chromium 559 ms: **✓ ✓** (warm load 239 ms, not judged) |

Mistakes caught on the way and fixed: the first M6 run of this round crashed on the checker running testscreen by a
relative path (500f180d); the next ran the "process's first open" on the page the app started on (2.9 ms, a page; fixed in
8cbefc34, that run's race.md kept as its record). A run in between, with the load average at 5–6, showed stress
undo/redo at 18–20 ms; probes of the same build at load 2.8 gave 6.1 / 5.9.

## Milestones (this round)
| # | Result |
|---|---|
| M0 | PASS (earlier this session; nothing it reads changed) |
| M1 | BLOCKED (Mac); Linux half passes |
| M2, M3, M4 | **PASS** (rerun on this round's build) |
| M5 | BLOCKED (Mac); Linux half passes |
| M6 | **FAIL** (below) |
| M7 | FAIL/BLOCKED: the Mac is unreachable; goal 75's M4 needs that goal's build (not in this worktree) |

## The race (final run, docs/goals/79/race.md only)
| note | row | web | native work p95 / max | |
|---|---|---|---|---|
| 600 | open: first frame (cold opens and the process's first open) | 1,271 (page load) | **25.7** (first open) | ✗ |
| 600 | open: frames during / a press during it / complete | — / — / 1,271 | 3.4 / 4.7 · 3.2 · 50 ms | ✓ ✓ ✓ |
| 600 | pan, zoom, drags, undo, redo, pen, typing | 16.7–17.1 | p95 3.6–7.5, max ≤ 10.6 | ✓ (all 9) |
| stress | open: first frame | 1,167 | **105.9** (first open) | ✗ |
| stress | open: frames during | — | **9.2** / 10.2 | ✗ |
| stress | open: a press during it | — | **11.1** / 11.1 | ✗ |
| stress | open: complete | 1,167 | 96 ms | ✓ |
| stress | pan 30 % / 100 % | 16.7 / 16.8, 16.8 / 33.2 | 5.0 / 5.1, 4.5 / 5.1 | ✓ ✓ |
| stress | zoom from 30 % | 16.8 / 299.9 | 5.4 / **21.3** | ✗ |
| stress | drag one / drag 40 | 16.8 / 16.8, 16.7 / 66.7 | 6.5 / 16.7, 6.0 / 7.7 | ✓ ✓ |
| stress | undo / redo | 17.1 / 17.1, 17.1 / 17.3 | **10.1 / 10.1, 10.7 / 10.7** | ✗ ✗ |
| stress | pen / typing | 16.8 / 150, 16.8 / 16.8 | 4.5 / 6.9, 5.5 / 6.9 | ✓ ✓ |
| | cold start vs PN's desktop launcher / fresh Chromium | 736 / 559 ms | 270 ms | ✓ ✓ |
| | warm page load (not judged) | 239 ms | 270 ms | — |
| | RSS | 814 MB | 202 MB | ✓ |
| | note switch / omnibar p95 | — | 6.55 / 7.35 | ✓ ✓ |

**Read it honestly:** with the measurement fixed, the open is far from rule (a): a first open rasters every visible tile
and, in a new process, the glyphs at that zoom (600: 22 ms of draw; stress: ~113). Stress undo/redo (GPU time of partial
tile rasters, varying with the GPU's clock) and the zoom's worst frame flip between runs: 5.9–10.7 and 14–21 ms across
this session's quiet runs. The next framework lever for (a) and the open's frames: draw a fresh layer's missing visible
tiles directly in the first frame and raster tiles over the following frames under the budget.

## What the framework gained this round
- `mojoui.canvasload.OpenBoard`: a board and its progressive open as one value; edits and whole-board reads finish first.
- `pagedesk.board_rect` (the paint's cull rect), `BoardLook.forget()` (a new picture: the renderer drops the layer's tiles),
  an FNV-style `_obj_key`.
- canvasload binds duplicate ids as the whole import does.
- GTK host: framebench open frames with GPU, own paint and raster; `openpress`; `env:` step; GDK_DISABLE / GSK_RENDERER
  taken back after GTK reads them.
- Tests: test_canvasload cases 6–7, test_boardraster's nine new edit/open cases.
- The race: docs/goals/79/webcold.mjs + desktop_cold.py (web cold starts, like with like).

---

**Continuation 5 (11-20, 05:2x–06:5x): the progressive open, zoom, cold start.** Everything below comes from the final
run (`scripts/check`, 06:34–06:53, log build/g79/final-check.log; docs/goals/79/race.md generated by it). Conditions,
recorded: the load average was under 2.5 when the run was started (waited for it), 4.3 a moment later and 3.0–3.5 during
the run (no other heavy process seen in top; other agent sessions and the desktop shell were running); both GPUs idle.
The Mac was unreachable all round (ssh port 22 timed out at the start, between items and before the run).

## Milestones (final run)
| # | Result | Checker says |
|---|---|---|
| M0 Reference | **PASS** | 9 screens, 187 names, 19 text widths |
| M1 Text | **BLOCKED (Mac)** | Linux: 19 lines, worst 0.00 device px, no .notdef, crisp 1.00 |
| M2 Shell | **PASS** | rerun first on 4af660ef, and again here: 0.974 / 0.984 / 0.972 / 0.974 |
| M3 Every screen | **PASS** | canvas 0.992, mind map 0.986, search 0.983, island card 0.981, settings 0.982 |
| M4 Works the same | **PASS** | 28 steps, worst SSIM 0.964, saved notes equal through the web API |
| M5 IME | **BLOCKED (Mac)** | Linux PASS |
| M6 Race | **FAIL** | 4 rows: stress open's first frame (25.4 ms), cold start (290 vs 168 ms), note switch p95 (8.34, bar 8.3), 600 pan 30 % max (26.1: one frame; not reproduced in 3 reruns, max 2.1–3.5) |
| M7 Both machines | **FAIL/BLOCKED** | the Mac is unreachable; goal 75 M4 found no build/g75/compare.png (that goal's own build isn't in this worktree: not run); the matrix's fonttext isn't ✅ on the Mac (it hasn't run there) |

## The race (final run, from docs/goals/79/race.md only)
The open row is judged by D-7946 (set by the main session): (a) first frame ≤ 8.3 ms, (b) every frame during the open
silky, (c) complete sooner than the web's open, (d) tests/test_canvasload passes (it did).

| note | step | web | native work p95 / max | before this round (05:13) | |
|---|---|---|---|---|---|
| 600 | open: first frame | 1,250 (cold page load) | 7.9 / 7.9 | 29.1 (whole parse) | ✓ |
| 600 | open: frames during (60) | — | 3.1 / 4.1 | — | ✓ |
| 600 | open: complete | 1,250 | 50 ms wall | — | ✓ |
| 600 | pan 30 % / 100 % | 16.7 / 33.4, 16.7 / 16.8 | 4.0 / **26.1**, 5.4 / 12.6 | 5.3 / 8.1, 5.4 / 7.4 | ✗ ✓ |
| 600 | zoom, drags, undo, redo, pen, typing | 16.7–17.1 (max to 66.6) | 1.9–5.4 p95, max ≤ 8.5 | ≤ 5.8 / 7.6 | ✓ (all) |
| stress | open: first frame | 1,198 | **25.4 / 25.4** | 129 | ✗ |
| stress | open: frames during (134) | — | 7.1 / 8.9 | — | ✓ |
| stress | open: complete | 1,198 | 83 ms wall | — | ✓ |
| stress | pan 30 % / 100 % | 16.8 / 16.8 | 3.5 / 5.5, 2.9 / 3.7 | 5.0 / 6.9, 4.4 / 6.1 | ✓ ✓ |
| stress | zoom from 30 % | 33.4 / 116.6 | 5.6 / 15.5 | 7.7 / 28.0 | ✓ (was ✗) |
| stress | drag one / drag 40 | 16.7 / 16.8, 16.8 / 66.7 | 3.2 / 4.9, 3.2 / 3.7 | 5.5 / 7.4, 6.0 / 8.0 | ✓ ✓ |
| stress | undo / redo | 16.8 / 22.2, 16.7 / 16.8 | 5.7 / 6.1, 6.6 / 7.5 | 9.9 / 9.9, 9.8 / 9.9 | ✓ ✓ (were ✗) |
| stress | pen / typing | 16.8 / 150, 16.7 / 16.8 | 4.5 / 5.9, 5.5 / 7.0 | 5.0 / 7.3, 5.0 / 7.2 | ✓ ✓ |
| | cold start to first screen | 168 ms (browser running) | **290 ms** from exec | 400 | ✗ |
| | RSS after a note of each kind | 806 MB | 220 MB | 256 | ✓ |
| | note switch / omnibar p95 | — | **8.34** / 7.82 | 7.46 / 7.46 | ✗ / ✓ |

**Read it honestly:**
- **Stress undo/redo passed in this run but not by a fix of mine:** probes before it measured 9.3–11 ms, ~5 ms of it GPU
  time for 2–5 partial tile rasters, with the GPU at its idle clock between bursts (D-7940's note). Expect them to flip
  with the GPU's clock state; the lever (fewer ops per partial raster) is not built.
- **Note switch** measured 7.5–8.2 in five reruns at load 2.6: a narrow margin, missed under load.
- **The open:** the renderer keeps raster tiles across opens when the picture is the same, so the race's repeated cold
  opens find the visible tiles; a process's first open rasters them (stress: 24 tiles, ~27 ms). The stress first frame's
  25 ms is the row read (5–6 ms), the skim and key reads (~3), the visible half parsed on 24 threads (~7–8) and the draw
  (~6). Its slices and completion meet the bars.
- **Cold start:** the web's number starts in a running Chromium. Ours: exec → GTK application 50 ms, → activate 105, →
  first view 140, window GL realize in gtk_window_present ~100–140, first frame ~10 (D-7948).

## What the framework gained this round
| Component | What | Test | Runs on |
|---|---|---|---|
| `mojoui/canvasload.mojo` (new) | progressive JSON Canvas open: SIMD skim (11.8 MB in 1.1 ms), read_keys, visible nodes and crossing edges' ends first on every core, slices by measured rate, finish() gate; result equals the whole import | tests/test_canvasload (skim vs reader, progressive = whole on 3,400 objects, pan and edit during the open; two mutations caught) | any (max.algorithm.parallelize) |
| `mojoui/json.mojo` | Eisel–Lemire long decimals (mojoui/pow5.mojo from scripts/pow5_table.py), `parse_bytes`, `reparse` | tests/test_json (1M decimals bit-equal to strtod_l; fuzz counts = HEAD's) | any |
| `objectlayer` | `canvas_node_obj`/`canvas_edge_obj` (pure builders), `adopt_as`, `order_by_z`; the importer on the same path | test_objectlayer, test_pagedesk, test_canvasload | any |
| `mojoui/sqlite.mojo` | `map_reads()` (mmap), text()/blob() by memcpy | test_sqlite | any |
| `gpu2d_tiles` | `_extend`: kept tiles grow by strips (D-7947); per-tile raster reasons in MOJOUI_TILE_TRACE | test_gpu2d_tiles, test_boardraster | GL ✅; Metal ❌ (tile raster still unwritten) |
| GTK host | GDK_DISABLE=vulkan for GPU 2D apps (D-7948); STARTUP marks at µs; framebench open: frames during and completion, each draw logged | M6 | GTK ✅ |

**Line counts:** pnote's web look is `examples/pnote/webshell.mojo` 1,123 lines (incl. the progressive open's wiring and
two trace lines) + `pnlook.mojo` 303 = **1,426 lines**, against the web app's `src/main.js` alone at **4,300 lines**.

## Limits and debt (this round)
- **Metal tile drawing is not written** (item 5 not reached); nothing of this round has run on the Mac.
- **Stress open first frame** 25 ms vs 8.3: no cheap step left (per-thread parse ~50 MB/s at 24 threads).
- **Cold start** 290 vs 168: GTK/libadwaita start and the window's GL realize are most of it.
- **Undo/redo** GPU cost of partial rasters (above). **Note switch** margin.
- pnote's whole() covers every edit path I found (keys, press/release unless the hand tool, taps, bench spots, saves,
  opening another note); test_canvasload proves the framework contract, not each pnote route.

---

Earlier rounds below, kept as written then.

**Continuation 4 (11-20, 03:5x–05:2x): big boards in the framework, M4's rule.** Everything below comes from the final
race (docs/goals/79/race.md, 05:13, load 1.7 at the start and 4.5 at the end: another session's goal 77 crashloop held one
core; both GPUs idle). The baseline before this round is build/g79/race-baseline-0351.md.

## Milestones
| # | Result | Checker says (11-20) |
|---|---|---|
| M0 Reference | **PASS** | unchanged |
| M1 Text | **BLOCKED (Mac)** | Linux half passes (unchanged) |
| M2 Shell | **PASS** | not rerun this round (no shell drawing changed except the page frame's bands, drawn the same) |
| M3 Every screen | **PASS** | not rerun this round (the map's fixture ideas have no fontSize: drawn at 20 as before) |
| M4 Works the same | **PASS** | D-7942's rule (set by the main session): 28 steps, worst whole-frame SSIM 0.964, saved notes equal; self-test caught (gain −0.323) |
| M5 IME | **BLOCKED (Mac)** | Linux half passes (unchanged) |
| M6 Race | **FAIL** | 15 of 20 interaction rows silky and ahead; open, stress zoom max, stress undo/redo, cold start miss |
| M7 Both machines | **BLOCKED** | the Mac was unreachable all session (ssh port 22 timed out at the start, between items, at the end) |

## The race (final run, from docs/goals/79/race.md only)
Units as race.md states: web = frame-to-frame gaps in Chromium (floored at 16.7 ms); native = each frame's own work.

| note | step | web p95 / max | native p95 / max | baseline 03:51 (before) | silky and ahead? |
|---|---|---|---|---|---|
| 600 | open (cold) | 1,259 | 29.1 | 150.9 | ✗ (43× faster than the web, not the 8.3 bar) |
| 600 | pan 30 % / 100 % | 16.8 / 16.8, 16.8 / 16.8 | 5.3 / 8.1, 5.4 / 7.4 | 6.7 / 8.7, 6.8 / 10.3 | ✓ ✓ |
| 600 | zoom from 30 % | 16.8 / 49.9 | 4.6 / 5.8 | 11.9 / 13.5 | ✓ |
| 600 | drag one / drag 40 | 16.8 / 33.4, 16.8 / 16.8 | 5.7 / 6.2, 4.3 / 5.9 | 10.8 / 11.1, 7.7 / 8.7 | ✓ ✓ |
| 600 | undo / redo | 16.8 / 16.9, 16.8 / 16.9 | 5.2 / 7.3, 5.5 / 7.2 | 7.9 / 8.4, 7.6 / 7.7 | ✓ ✓ |
| 600 | pen / typing | 16.8 / 16.8, 16.8 / 16.8 | 5.3 / 7.6, 5.8 / 7.0 | 7.1 / 10.0, 7.5 / 8.6 | ✓ ✓ |
| stress | open (cold) | 1,153 | 129.0 | 731.7 | ✗ (9× faster than the web) |
| stress | pan 30 % / 100 % | 16.7 / 16.8, 16.7 / 16.8 | 5.0 / 6.9, 4.4 / 6.1 | 12.1 / 13.8, 14.1 / 15.6 | ✓ ✓ |
| stress | zoom from 30 % | 16.8 / 283.4 | 7.7 / 28.0 | 44.8 / 50.7 | ✗ (p95 silky; one 28 ms frame as zoom-out reveals edge tiles) |
| stress | drag one / drag 40 | 16.7 / 16.8, 16.7 / 66.7 | 5.5 / 7.4, 6.0 / 8.0 | 23.3 / 24.8, 22.2 / 31.9 | ✓ ✓ |
| stress | undo / redo | 16.9 / 17.0, 16.9 / 17.0 | 9.9 / 9.9, 9.8 / 9.9 | 20.4 / 21.6, 20.5 / 21.3 | ✗ ✗ (ahead of the web, not silky) |
| stress | pen / typing | 16.7 / 133.4, 16.8 / 16.8 | 5.0 / 7.3, 5.0 / 7.2 | 12.8 / 15.1, 11.3 / 12.8 | ✓ ✓ |
| | cold start to first screen | 170 ms (browser already running) | 400 ms from exec | 400 | ✗ (not worked on this round) |
| | RSS after a note of each kind | 806 MB | 256 MB | 238 | ✓ |

**Read it honestly:** GPU time per frame follows the GPU's clock state (idle P8 clocks; the same layers measured 1.3 ms or
0.07 ms in different runs, D-7940), and the stress undo/redo rows varied 5.7–10 ms between probes; the judged numbers are
this run's. The "composited" column of race.md (GTK compositing the canvas) adds ~4 ms to each row.

## What the framework gained this round
| Component | What | Test | Runs on |
|---|---|---|---|
| `Painter.layer_tiles` / `layer_damage`, `mojoui/gpu2d_tiles.mojo` | a layer kept as raster tiles: plan, damage, partial raster, zoom stretch then settle, ring prefetch, op budget, empty tiles skipped | tests/test_gpu2d_tiles, tests/test_boardraster | GL ✅; Metal ❌ (plan shared, tile raster/composite not written: debt) |
| `mojoui/damage.mojo` `DamageSnap` | damage by comparing items' keys and painted boxes; lines as chunks | test_boardraster | any |
| `Painter.stroke` (OP_STROKE) | a polyline as one op, pixel-identical (GPU and CPU) | test_gpu2d_tiles stroke_same | GL ✅, CPU ✅, GSK ✅ |
| `pagedesk` | board tiled with damage; drags lifted into their own layer; shadow bands as rings; hug_routes | test_boardraster, test_pagedesk, M4 | Linux ✅ |
| `objectlayer` | grid kept when only boxes move; route_widths; import_json_canvas_doc | test_objectlayer, M4 | any |
| `mojoui/json.mojo` | 4× faster on PN's documents, same grammar | test_json (fuzz counts identical) | any |
| `notesshell.draw_inner_ring`, `buzanmap.idea_size` | the web's focus ring; ideas at their own size | M4 | Linux ✅ |
| GTK host / GPU2D | `more` (tile work left: draw again), MOJOUI_TILE_TRACE, MOJOUI_GPU2D_LAYER_TIMES | — | GTK ✅ |

**Line counts:** pnote's web look is `examples/pnote/webshell.mojo` 1,026 lines + `pnlook.mojo` 303 = **1,329 lines**, against
the web app's `src/main.js` alone at **4,300 lines** (on top of CodeMirror, Leafer and its modules).

## Limits and debt
- **Mac:** nothing of this round (tiles, stroke, json) has run on the Mac; the Metal tile raster/composite isn't written.
- **Open:** 29 ms / 129 ms cold. Designed, not built: parse-then-tile on the UI thread with a `complete()` gate that every
  reader needing the whole document (save, export, bench spots) calls, so nothing races (D-7926's failure, D-7941).
- **Cold start:** 400 ms vs 170 ms; not profiled this round.
- **Stress undo/redo** (9.9 ms) and the zoom-out spike (28 ms): next levers: prefetch two rings while zooming out, fewer
  full-screen passes (GPU clock state).
- **M4:** the undo step's last difference is the web's hover state on the button after the click.

---

Earlier rounds below (continuation 3), kept as written then.

**Continuation 3 (11-20): a fresh reviewer's NEEDS WORK, Linux half.** Every finding was checked in the code first; all
held but half a nit (PN indexes a page's Markdown itself). The biggest one: the last report's race never timed the
rebuilt app. Its native rows ran goal 74's canvas, so its "native wins every interaction row" claim is withdrawn. The race
now runs the web look on notes stored by the web app's own API, and what it shows is below.

**In one paragraph (11-20, 03:4x):** on Linux pnote still looks like the web app on all nine screens (M2, M3 PASS after
Personal Note's names and labels left the framework). It now saves the way the web app saves: on the revision it read,
650 ms after the last edit, never touching a secure note. M4's strengthened check catches a skipped step and found real
differences, some fixed (undo of a delete, the map's selected-branch controls) and some open, so M4 now FAILS on 8 step
regions. The honest race: on the 600-object note, with a quiet machine, every interaction step but zoom is silky and
memory is 3.4× lower; on the 5,296-object note most interaction steps are slower than the web; cold start and open miss
their bars. The Mac stayed unreachable.

## Milestones
| # | Result | Checker says (final runs, 11-20) |
|---|---|---|
| M0 Reference | **PASS** | unchanged this round (9 screens, 187 names) |
| M1 Text | **BLOCKED (Mac)** | Linux: 19 lines, worst 0.00 device px, no .notdef, crisp 1.00 (rerun after D-7932) |
| M2 Shell | **PASS** | page+sidebar 0.974, page 0.984, Night 0.972, Crayon 0.974 (after D-7928's renames) |
| M3 Every screen | **PASS** | canvas 0.993, mind map 0.986, search 0.983, island card 0.981, settings 0.982 |
| M4 Works the same | **FAIL** | strengthened (D-7931): saved notes equal with positions and marks; the skipped-step self-test caught (0.177); 8 step regions under 0.80: 1 (0.749), 4 (0.709), 7 (0.516), 8 (0.772), 18 (0.775, was 0.424), 22 (0.648), 23 (0.680), 24 (0.261) |
| M5 IME | **BLOCKED (Mac)** | Linux PASS (rerun with the debounced saves) |
| M6 Race | **FAIL** | see the race below; also run under contention (recorded) |
| M7 Both machines | **BLOCKED** | the Mac is unreachable; decisions lint ok; components matrix regenerated |

## Compare images (web │ native │ diff ×4), the window's GPU frame
- **Passing (M2):**
  - build/g79/page-sidebar-compare.png
  - build/g79/page-compare.png
  - build/g79/page-sidebar-night-compare.png
  - build/g79/page-sidebar-crayon-compare.png
- **Passing (M3):**
  - build/g79/canvas-compare.png
  - build/g79/mindmap-compare.png
  - build/g79/search-compare.png
  - build/g79/island-card-compare.png
  - build/g79/settings-compare.png
- **M4, a shot pair after each of the 28 steps:** build/g79/m4/web/NN.png and build/g79/m4/native/NN.png
- **M4's per-step regions:** build/g79/m4/regions.txt (area, native after / before), crops of the flagged steps in
  build/g79/m4/crops/, the skipped-step self-test in build/g79/m4/selftest.txt

## The race (docs/goals/79/race.md, generated by the check, read only from it)
**Conditions, recorded:** the generated race.md (11-20 03:17) ran while other work shared the machine: another session's
goal 77 check (a `mojo build`, then its own app at ~190 % CPU with 19 GB on GPU 0), another project's pytest runs, and
Omarchy's screensaver (two terminals at ~90 % CPU each, the second GPU at 47 %). Load average 5–7, later 12. None of it
was stopped. Presentation times didn't come back in that run (shown n = 0), so the "shown" column is empty there.
An earlier run of the same build at 02:56 had a quiet machine (both GPUs at 0 %) for the 600-object note up to redo; it
was stopped at the pen step by the framebench bug D-7937 (its pen row would have timed nothing). Its rows are printed
beside, labelled.

| note | step | web p95 / max | native, race.md 03:17 (contended) | native, quiet run 02:56 (600 only) | silky (≤ 8.3 / 16.7)? |
|---|---|---|---|---|---|
| 600 | open (cold) | 1,247 | 248.6 | 148.5 | ✗ (beats the web 5–8×, not the bar) |
| 600 | open again, kept parsed (not judged) | — | 21.5 | 14.3 | — |
| 600 | pan 30 % | 16.7 / 16.8 | 5.9 / 14.1 | 4.3 / 6.3 | quiet ✓ |
| 600 | zoom from 30 % | 16.8 / 33.3 | 15.4 / 15.6 | 9.8 / 10.1 | ✗ |
| 600 | pan 100 % | 16.8 / 16.8 | 15.3 / 19.1 | 7.0 / 8.4 | quiet ✓ |
| 600 | drag one / drag 40 | 16.8 / 66.5, 16.8 / 16.8 | 9.0 / 10.2, 11.2 / 12.8 | 7.3 / 9.0, 6.8 / 8.4 | quiet ✓ |
| 600 | undo / redo | 17.0 / 17.2, 16.8 / 16.9 | 11.1 / 11.2, 10.4 / 10.6 | 7.5 / 7.5, 7.0 / 7.2 | quiet ✓ |
| 600 | pen | 16.7 / 16.8 | 12.1 / 18.5 | (void, D-7937; a fresh probe after the fix: 5.9 / 7.4) | — |
| 600 | typing | 16.8 / 16.8 | 7.7 / 8.4 | — | ✓ |
| stress | open (cold) | 1,116 | 871 | — | ✗ |
| stress | pan 30 % / pan 100 % | 16.8 / 16.8 | 17.8 / 19.9, 12.9 / 14.9 | — | ✗ (pan 30 % slower than the web's p95) |
| stress | zoom from 30 % | 16.8 / 133.3 | 54.5 / 57.7 | — | ✗ (p95 3× the web's; max lower) |
| stress | drags, undo, redo | 16.7–16.8 (max to 66.6) | 31.5–44.3 | — | ✗ (slower than the web) |
| stress | pen / typing | 16.7 / 150.0, 16.7 / 16.8 | 13.2 / 19.7, 15.8 / 17.5 | — | ✗ |
| | cold start to first screen | 253 ms (browser already running) | 470 ms from exec | — | ✗ |
| | RSS after a note of each kind | 817.5 MB | 239.3 MB | — | ✓ (3.4× less) |
| | note switch / omnibar open p95 | — | 7.95 / 8.29 ms | — | ✓ / ✓ (by 0.01 ms) |

**Read it honestly:**
- **Different units** (stated in race.md): the web's numbers are frame-to-frame gaps, floored at 16.7 ms; ours are
  each frame's own work. A native frame reaches the screen after its work plus its presentation wait (~15 ms on the
  60 Hz test output when measured, 11-20 02:21).
- **The 600-object note, quiet machine:** every interaction step except zoom (9.8 ms) is within the silky bar; open is
  148 ms cold (8× faster than the web's cold page load, far from the 8.3 ms bar) and 14 ms when kept.
- **The 5,296-object note loses** most interaction rows to the web, contended or not: the GPU draws every object on
  every pan frame and drags/undo rebuild the whole board layer (D-7933). The last report's "native beats the web on
  every interaction row" came from goal 74's canvas and is withdrawn.
- **Cold start** is ours to lose (470 ms vs 253 ms); its breakdown is under limits.
- **Memory** is the clear win: 239 MB vs 818 MB.

## The reviewer's findings, one by one
| # | Finding | Outcome | Proof |
|---|---|---|---|
| Must 1 | the race timed goal 74's canvas, not the web look | **fixed** (D-7929): notes seeded through PN's API, the race on PNOTE_DB, a run without `PNOTE WEB:` fails | race.md, docs/goals/79/seedrace.mjs |
| Must 2 | secure notes could leak and be corrupted | **fixed** (D-7927): `secure` read, a locked cover, every save/rename/FTS write refused | tests/test_pnote_store.py (row and search byte-for-byte unchanged) |
| Must 3 | PN's UI in the framework | **fixed** (D-7928): generic names + `Boxes.alias`, `PanelConfig`, skins and labels in examples/pnote/pnlook.mojo | test_notesshell builds a second app; M2/M3 PASS |
| Should 4 | M4 couldn't tell a step that did nothing | **fixed** (D-7931): region check, positions and marks, GPU shots, a skipped-step self-test (caught: 0.177) | build/g79/m4/regions.txt, selftest.txt; M4 now FAILS on 8 regions (see milestones) |
| Should 5 | no revision check, a write per keystroke | **fixed** (D-7927): `mojoui.docstore` (`WHERE revision = ?`, conflicts shown as the web shows them), 650 ms debounce, one row updated | tests/test_docstore.mojo, test_pnote_store (conflict, 8 keys → 1 revision) |
| Should 6 | glyph atlas holes | **fixed** (D-7930): OP_RUN zoom-bound, a reset epoch, mid-frame rebuild, one shared `layer_traits` | test_gpu2d_gl glyph_holes, each check failing with its fix undone; Metal case written, unrun |
| Should 7 | the report claimed more than the race showed | **fixed**: M6 rerun on an idle GPU with this build; the claims below come from the new race.md only | race.md |
| Should 8 | race.md didn't say what it measures | **fixed** (D-7929): units stated, a composited run's work and time-to-screen printed beside | race.md |
| Also | worse-of-two web rows against one native run | **fixed** (D-7929): pan at 30 % and 100 %, undo and redo, each its own row | race.md |
| Nit | search index projection | **fixed for canvas and map; disputed for pages**: PN's own page_text indexes the Markdown itself (page_note.py:44) | D-7927 |
| Nit | mind-map reminders | **kept in step** (D-7927), and ideas now keep their `due`/`done` through a native save | test_pnote_store, M4 notes equal |
| Nit | getenv per glyph | **fixed** (D-7932) | test_fonttext |
| Nit | colour emoji converted each frame | **fixed** (D-7932): `GlyphPages.straight` | test_gpu2d_gl (fonttext runs) |
| Nit | hairline_color test | **added** (D-7932) | docs/goals/79/test_hairline.py |

## What the framework gained (D-7900)
| Component | What | Test | Runs on |
|---|---|---|---|
| `mojoui/fonttext.mojo` | real faces at device px: FreeType light hinting, HarfBuzz shaping, fontconfig fallback, colour emoji, Chromium's advance rule (D-7905), `exact` mode for canvas/SVG text, Blink line metrics, a shaped-run cache (D-7916); a CoreText path (CTLine, CGBitmapContext, fvar from the file) | tests/test_fonttext.mojo (19 lines vs Chromium), test_notesshell | Linux ✅; Mac 🔨 (written, never run) |
| `gpu2d` OP_RUN + GlyphPages | fonttext glyphs in the atlas's dynamic rows, sampled 1:1 by the existing glyph pipeline; colour emoji and icons as blended images (D-7910) | tests/test_gpu2d_gl (fonttext and icons at 1× and 4×: mean 0.001 levels, 0 px), tests/test_gpu2d_metal (same case added) | GL ✅; Metal 🔨 (never run) |
| `mojoui/skin.mojo` | Paper, Night, Crayon as themes; CSS color-mix | test_notesshell | any |
| `mojoui/strokeicon.mojo` + `lucide_nodes.mojo` | Lucide 1.24 geometry stroked natively | test_notesshell | Linux ✅ |
| `mojoui/notesshell.mojo` | desk, round islands with hover, title island, notes panel, Boxes, CSS shadows as layers, tool dock, zoom island, hint, `draw_radial_steps` | test_notesshell, test_webpieces | Linux ✅ |
| `mojoui/pagesheet.mojo` | a page as the web draws it, plus editing (caret, insert, newline, backspace, preedit underlined, caret rect) | test_notesshell, test_webpieces, M5 | Linux ✅ |
| `mojoui/buzanmap.mojo` | the web map's geometry, cards, fit, minimap | tests/test_buzanmap.mojo | Linux ✅ |
| `mojoui/omnibar.mojo`, `islandcard.mojo`, `settingswin.mojo` | the web's omnibar, island card and settings window; time words | tests/test_webpieces.mojo | Linux ✅ |
| `mojoui/objectlayer.mojo` `import_json_canvas` | JSON Canvas 1.0 with PN's extras | M6 (the 5,296-object note) | any |
| `mojoui/pagedesk.mojo` (new, 11-20) | a whiteboard on pages: the opening view, page frame (shadow bands, edge, folds, "Page N"), the board in the paper look (Fabric text metrics, Markdown in CSS line boxes, stickies with their dog-ear and shadow, arrows); `BoardTools`: select/move, text and sticky written in place, pen, connect, delete, undo/redo, zoom steps, the web's view moves; the editor's selection look | tests/test_pagedesk.mojo (rules against PN's own functions run on node; islands against the web's DOM boxes), M3, M4 | Linux ✅ |
| `objectlayer` additions | per-object type (face, weight, line height, Markdown, sticky ink), the centre-ray connector rule, `export_json_canvas` with PN's pn extras, ink in and out, `set_words`/`restyle` (an object and its first words: one undo step), `paint_shape`, `unsaved`/`mark_saved` | test_pagedesk, test_objectlayer, M4 | any |
| `notesshell` additions | `draw_dock` (active tool, colour dot, accent button), history island, page zoom island, selection bar, shelves that fold, dark-skin map controls | test_pagedesk, M3, M4 | Linux ✅ |
| `pagesheet`, `islandcard`, `buzanmap` additions | page taps by the web's onText rule, caret keys, Delete, Draw mode with pen marks in PN's ink form; an editable name field; map ideas by makeNode, writing them, a fit kept from opening | test_pagedesk, M4 | Linux ✅ |
| `strokeicon` inline specs | an app's own icon elements through the same stroker | test_pagedesk | any |
| CPU painter clips (D-7922) | every primitive honours push_clip (the GPU's scissor did already) | M4 | any |
| `mojoui/procstat.mojo` | process age and RSS | M6 | Linux ✅ |
| `App.hovers()` + `HOVER` | hover states on canvases | M2 | GTK ✅, AppKit ❌ |
| `IME_COMMIT`, `IME_PREEDIT`, `PASTE`, `App.caret()` | a GtkIMMulticontext per key-taking canvas, the candidate window placed at the caret, Ctrl+V from the system clipboard | M5 | GTK ✅, AppKit ❌ |
| `App.bench()` + GTK framebench (dragone, drag40, undoredo, open), `firstscreen:` `noteswitch:` `omnibar:` `openall:` `rss:` `gpushot:` `imepreedit:` `imecommit:` `clipboard:` | measurement and test steps any app can use | M2, M5, M6 | GTK ✅ |
| GTK host | `render:`/`gpushot:`/race steps show the test window; startup trace | M2, M6 | GTK ✅ |
| `mojoui/docstore.mojo` (new, 11-20) | documents kept as rows with a revision: `SaveTimer` (save debounce), `RowSave`/`save_row` (written only on the revision the editor read, follow-ups in one transaction, CONFLICT otherwise), `KeptDocs` (parsed documents reused while the file holds their revision) | tests/test_docstore.mojo (a made-up table), tests/test_pnote_store.py | any |
| `Boxes.alias` + generic names | every box a piece records has a generic name; an app maps them to its own (PN's DOM ids live in pnote) | tests/test_notesshell (a second app's panel and settings) | any |
| `PanelConfig`, `Shelf`, `SkinChoice`; `SettingsWindow(title, hint)`; `skin_cards(choices)`; `Skin.accent_flat`, locked tokens | the notes panel and settings filled by the app | test_notesshell | any |
| `notesshell.draw_locked_cover` | a locked document's cover | test_pnote_store | Linux ✅ |
| `pagedesk` hand tool, `scroll`, `zoom_at`, `visible_objects`; versioned board and page-frame layers | the web's view moves; a pan reuses the kept pictures | M6, test_pagedesk | Linux ✅ |
| `objectlayer.reading_text`, `buzanmap.map_text`, `Topic.extra`/`node_extra` | search projections as PN's; an idea's other fields survive a save | test_pnote_store, M4 | any |
| `gpu2d.layer_traits` (shared GL/Metal), GlyphPages reset epoch, `GlyphPages.straight` | runs re-rasterized at a new zoom; layers rebuilt after the pages restart, mid-frame too; colour glyphs converted once | tests/test_gpu2d_gl glyph_holes (each check fails with its fix undone), test_gpu2d_metal (unrun) | GL ✅; Metal 🔨 |
| GTK host `appbench:`, framebench `undo`/`redo`, `scene_p95`/`batch_p95` | race steps any app can use; where a frame's draw goes | M6 | GTK ✅ |
| fonttext: environment read once | (not per glyph) | test_fonttext | any |

**Line counts:**
- pnote's web look: `examples/pnote/webshell.mojo` **1,018 lines** (state, Personal Note's schema for three kinds,
  screens, routing input to the pieces) plus `examples/pnote/pnlook.mojo` **303 lines** (PN's own names, panel, skins
  and tool island, moved out of mojoui this round).
- `examples/pnote/app.mojo` is **~1,020 lines**, mostly goal 74's look, kept for goal 74/75's proofs (D-7907).
- The web app's `src/main.js` alone is **4,300 lines**, on top of CodeMirror, Leafer and its modules.

## The 3 decisions most worth a second look
1. **D-7931, M4's region check and its 0.80 bar.** New this round, set before the first measurement and not lowered
   after it failed. It catches a skipped step (0.177) and real differences (undo, a focus ring, map controls), but text
   regions read 0.70–0.78 where only glyph smoothing differs (Skia's gamma isn't copied). A reviewer should judge whether
   0.80 asks for more than M4's "M2's SSIM bar" does; we kept it rather than tune it to pass.
2. **D-7934, the open row judged cold.** Reopening a note kept parsed at its revision is near-free, but the web's number
   is a cold page load, so the judged row is our cold open (row read, JSON Canvas parsed every time).
3. **D-7920, the dividers, settled by a checker fix** (unchanged from the last round, now with test_hairline.py proving
   a missing or doubled line still fails).

## Limits and debt
- **Mac:** none of the Mac code has been compiled or run (CoreText, Metal GlyphPages and this round's layer_traits and
  reset handling, AppKit HOVER/IME). SSH timed out at the start, between items and at the end of this round.
- **Big boards:** on the 5,296-object note a kept frame at 30 % still costs ~9 ms (the GPU draws every object each pan
  frame); drags and undo rebuild the whole board layer. Next lever (framework): an unchanged layer kept as a texture and
  moved, and moving objects in their own layer during a drag (D-7933).
- **Open, cold:** bound by parsing JSON Canvas (2.6 MB for the 600 note, 11.8 MB for the stress note).
- **Cold start:** 470 ms (race, contended) vs the web's 253 ms. Traced once (with M4 beside it): GTK's activate at
  ~110 ms, the window presented at ~140 ms, the first draw attempt once the compositor maps it at ~290 ms, the first
  picture at ~500 ms; the frame itself is ~3 ms of batches and GPU, so most of the gap is the app's first paint (font
  engine start, first shaping and rasterizing). Not fixed this round.
- **The race needs a clean rerun:** `scripts/check M6` on an idle machine (no other project's checks, no screensaver).
- **M4's remaining region differences:** glyph smoothing in text regions (steps 1, 4, 8: Skia's gamma isn't copied), the
  web's focus ring inside the title island after a rename (step 7: measured, not built; a first try drawn outside was
  removed), the renamed map idea's words ~6 % narrower than the web's (24) and the map's add steps (22, 23), and the undo
  step's last differences (18, 0.775).
- **Page marks** are written in PN's form but not read back natively (D-7925). **Canvas** reads JSON Canvas text,
  stickies, ink and edges; other kinds come in as plain boxes.

## Run it
```
cd ../mojo-ui-g79
scripts/build.sh pnote linux
cp build/g79/ref/pn.db /tmp/pn-scratch.db          # a scratch copy (scripts/check M0 makes build/g79/ref/pn.db)
PNOTE_DB=/tmp/pn-scratch.db PNOTE_SKIN=paper build/pnote/linux/pnote
scripts/check M0 M1 M2 M3 M4 M5 M6
# M4 by hand: pixi run python docs/goals/79/make_steps.py (writes steps.json); docs/goals/79/steps.mjs plays the web half
```
