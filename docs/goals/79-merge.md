# Merging goals 79, 80 and 81 with main: the plan (continuation 24; nothing is merged)

Read only: `git merge-tree` of the branches as they stood on 2026-11-25, 00:40. Branches:

| Branch | What | Based on | Ahead of 79 |
|---|---|---|---|
| goal-79-pnote-lookalike | this one | main's cc33c9d7 (11-16) | — |
| bench-nanoui | goal 80, the race against nanoui | 79's 3686e45b (11-22) | 23 commits |
| goal-81-quality | goal 81; **contains all of goal 80** | the same | 41 |
| main | shipped since: omxplorer's ribbon, free canvas, omxome, releases | cc33c9d7 | 179 |

Goal 80 needs no step of its own: it comes with 81.

## Before anything
- Every one of these commits is on one disk of a machine that has stopped five times. **A backup push of the three branches needs the owner's yes; it should come first.**
- Review 6's fixes reviewed (PASS), 79 frozen at one commit, its M0–M6, KEYS, BUILDS, PACKAGE run there, 81's and 80's own checks run once on their branches as the "before" (81's M7, the Mac's frame clock, has never run on a visible window).
- Work on a new branch, `merge-79-81`, in a worktree of its own; the three branches stay as they are. One step, its checks, a commit; no step starts on a red one.

## The order, and why
**1. 81 into 79.** Same code lived in both for three days (renderer, fonts, hosts); whoever merges needs both goals' checks, and they exist on these branches. Main knows none of it.
**2. Main into the result.** Four code conflicts, one of them a trap (gesture numbers). Main's apps are then rebuilt with everything.
**3. The result into main** (a fast-forward, the owner's), one release at a time after it.

## Step 1: goal 81 into 79
| File | The conflict | Take |
|---|---|---|
| hosts/appkit.mojo (6) | two frame clocks: 79's CADisplayLink in NSRunLoopCommonModes itself (by address), lingering 1 s, a prompt tick after input, a stand-in timer, chains of looks counted; 81's has the link in a string that only reads like the mode (it never ticks, its own report says so), a hidden-window check, `MOJOUI_FRAME_CLOCK=timer` for test runs | 79's clock whole; into it 81's `clock_mode` (timer for tests and unshown windows) and `seen_on_screen`. 81's hang observer gets the real constant (`common_modes`) |
| gpu2d.mojo (6) | two cullings: 79's `part` (a rect a tile needs: D-8022), 80's `cull` (what the clip and, for moving layers, the canvas can show; text tested before it is shaped) | one region: clip ∩ canvas (when the layer isn't fixed) ∩ `part` when given; 80's bounds and 2 px pad for all of it; 79's `rect_corner` bands tested against that region. `content_k > 0` (tiles) never culls by the canvas |
| fonttext.mojo (3) | two run caches: 79's by (style, text) with `exact`, `widths`, `styles_seen` (glyphwarm) and declared faces (D-8053); 80's two generations by hash, an ASCII fast path learned per style | 80's cache and fast path; its key gains 79's `exact` and the declared faces' state (a style declared later must not answer with a run shaped before); 79's `widths` and `styles_seen` stay; `said_none` and the system fallback stay |
| scene.mojo (3) | 81's Bitmap (shared, hashed once, filtered) against 79's images by value; 79's `stroke_outline`, `text_of` for a holed rect's corner in the comparison | Bitmap; 79's emoji and icon pictures made into Bitmaps once (they are drawn at their own size: sampler nearest, or M1/M2's pictures move); the corner line kept |
| hosts/gtk.mojo (3) | 79's input method (`im_wanted`, `im_key`, `im_follow`) against 81's waiting rebuilds (`shown_at`, REBUILD_PRIORITY); on_im_commit: 81 finds the canvas by its widget | both: an IM call asks 81's `shown_at(c.node)` and not `c.node` (while a rebuild waits the widgets are numbered as the old screen); a key is offered to the IM before 81's "busy" test; pastes by canvas as 81's review asked |
| app.mojo (1) | a field list: `pan_*` and the hang marks | both |
| scripts/check | each goal's own | both checkers by name; 79's gpu-free line for both |

**Re-check after step 1** (Linux, then the Mac): 79's M0–M6 (the picture and the race), KEYS, BUILDS, PACKAGE, judge_test; test_docbase, wordsafe, outboxmodel, powercut, outboxkill; 81's M1–M6, M8, M9 (and the 81-check's random screens); goal 80's held-out scenes within its bar; test_gpu2d_cull, test_gpu2d_tiles, test_boardtiles, test_glstate, test_rectcorner, test_bidi; first5 and bothopen. On the Mac: M1, M5, M7 looks, tests; unlocked: mac-unlocked **and** 81's M7.
**Where it can go quietly wrong:** a run from the fast path a hundredth of a pixel off (M1 says); a culled op that comes into view in a pan (test_gpu2d_cull draws every step whole and culled); a picture filtered that wasn't (M2/M3 fills); a key during a waiting rebuild lost or doubled (81's M4, run with words being written too: it has never run with an input method).

## Step 2: main into that
| File | The conflict | Take |
|---|---|---|
| view.mojo | **gesture numbers**: 79 HOVER 11, IME_COMMIT 12, IME_PREEDIT 13, PASTE 14; main BOARD_LIVE 11, BOARD_ZOOM 12, BOARD_VIEW 13, HOVER 14, BOARD_PICK 15. Keeping both sides compiles and is wrong: a board's live drag would be a hover | **main's stay** (shipped apps, web pages and saved test steps know them); 79's become IME_COMMIT 16, IME_PREEDIT 17, PASTE 18, HOVER is main's 14. A test asserts that no two of the numbers are the same |
| hover | 79 asks the app (`App.hovers()`), main the view (`Canvas(hover=True)`, and −1, −1 when the pointer leaves, skipped while an update runs) | main's; `App.hovers()` goes, pnote's canvas says `hover=True`; the pointer's place through 79's `at_canvas` (the snap box). pnote's hover must forget its row on −1, −1 |
| hosts/gtk.mojo (2) | the motion controller's widget: 79 puts it on the snap box (`pw`), main on the picture (`w`), plus main's cursor names | `pw`, with main's leave signal and cursors |
| app.mojo (1) | an import line | both |
| hosts/appkit.mojo, web | merge by themselves; main's AppKit hover and 79's are two ways | one (main's message), checked by hand |
| GOAL.md, docs/lessons.md | each branch's own goal; two lists of lessons | main's GOAL.md (79's is in docs/goals); both lists of lessons, in order of date |
| scripts/components.py, docs/* | tables and logs | both sides' rows; `components.py` run again |

Also from 79, for main's apps: `App.takes_text` is False unless an app says words are being written (review 6, M2). Main's own text canvases (omxome, any TextEdit on a Canvas since 11-16) get KEYs as they do today; one that wants an input method says so. PASTE and KeyUp are asked for too.

**Re-check after step 2:** everything of step 1 again (the race too: main changed Board and the hosts); main's `scripts/check` for goals 73, 76, 77, 78 (omxplorer's autocomplete, ribbon, free canvas, omxome's Stage); tests/realkeys.py with main's apps in it; the packages of omxplorer and omxome installed, updated and removed in a scratch HOME **over their released versions** (install_test's old layout, with the real tarballs: the new installer takes ~/.local/bin/<app> for its own when it links into ~/.local/lib/<app> or the old ~/.local/share/<app>, the launcher entry by its Exec in either, the icon and the old uninstaller by their bytes; a released version whose files differ from these is refused by name, and nothing is changed: try every released version once); the Mac's and Android's builds.

## Step 3: into main
Fast-forward by the owner. Then, one at a time: pnote's download, omxplorer's, omxome's, each installed from its real file and looked at.

## Not decided here (the owner's)
The race's rule for one late frame (FAIR_RULE is off). Whether pnote's first public build waits for the Mac's table. Whether the old `install.sh` of released downloads (omxplorer, omxome, omxconsole, gallery apps), which removes ~/.local/share/<app> before it installs and when it is removed, is replaced on the release pages now: **a search of main's sources finds no app that writes into its own ~/.local/share/<app>** (cloudlane and todo use …/mojoui, plugins …/omxcode, jot ~/.config/jot), so only a file a person put there by hand is at risk. Not run, only searched.
