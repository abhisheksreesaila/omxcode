# Goal 82 report: pnote at the web app's parity (integration of workers A, B, C)

Branch `goal-82` (from origin/main 902c5a7a, which holds goals 79, 80, 81), 2026-11-26. Not pushed. Decisions D-8500–D-8716
(the workers) and D-8900–D-8916 (the integration); the journal's "goal 82 A/B/C" and "goal 82 integration" sections.

## What was built

**Worker A (M1, M2, M4):** focus mode (mojoui.focusmode, PageSheet.focus, the island's focus strip), pictures on a canvas
(mojoui.mediastore with the web's storage rules, a plain-Mojo JPEG encoder, zlib by dlsym, pictures in the canvas layer),
paste of pictures and copied files (PASTE_FILE on GTK and AppKit), the system's dialogs from update (mojoui.systemask: file
picker, save, print, share, full screen), a vector PDF writer (glyph outlines, ToUnicode), print and PNG export.

**Worker B (M3, M7):** import and export of the web's backup, Obsidian vault (zip or folder) and JSON Canvas files
(mojoui.archive, examples/pnote/pnport.mojo), live updates from another app by file events (mojoui.filewatch: inotify on
Linux, kqueue on the Mac), three-way merge that keeps deletions deleted (mojoui.merge3).

**Worker C (M5, M6):** dictation (mojoui.dictation: Parakeet on Linux's GPU, Apple's recogniser on the Mac, the Mac
microphone), secrets in the system keyring, AI settings in the web's words, Jam on mind maps, agent edits with Show and Undo,
the settings form, scripts/mac-test, the Mac's permission texts.

**The integration:**
- One merged branch; each worker's checker kept whole (docs/goals/82/check_{a,b,c}.py), 82-check.py dispatching, each
  milestone in a process of its own (D-8900, D-8914).
- **One media store:** B's mediafiles folded into A's mediastore; both test sets pass against it (D-8902).
- **One drop target** on GTK and AppKit: a picture file goes on the open canvas, a backup, vault zip or folder, .canvas or
  .md file is imported (D-8903). Message numbers apart; scripts/msgs.py now reads the app's own modules, so the clash it had
  missed (A's 13/14 = B's 13/14) is caught by structure (D-8901).
- **Mac file drop** (web parity): MojoDrop in mojoui's AppKit host, files from Finder to a DropTarget's on_file, the same
  event GTK sends (D-8908). Pictures and imports both proven on the Mac.
- **Mac import** through A's file picker: Settings → Advanced → Import backup (both hosts) and the Mac's File → Import
  backup… (D-8910).
- **Review fixes (merge-79-81):** (a) AppKit's hidden-window branches watch again when something animates (D-8905);
  (b) GTK holds a pointer leave through a full rebuild's wait; (c) GTK holds Ctrl+V's paste with its key, plus two more paste
  losses the new test found (D-8906).
- Found on the way: pictures dropped while a canvas was still opening vanished silently (now they wait, D-8912); a system
  ask made outside update (a bench step's share) never reached the host once pnote had no idle timer (Runtime.refresh hands
  asks out, D-8915); C's libc.signal and a test's own signal declaration stopped test_saveattack compiling (libc.ignore_signal).
- **CoreText clusters (D-8907): built, measured, not kept (D-8916).** See "Mac typing" below.

## Check table (final tree)

Every row was run on the merged branch. Goal 82 (run3) ran without the later font-folder fix (D-8917); goal 79 and the
packages ran after it (its M1 measures every font on Linux and the Mac, KEYS runs pnote on both). Results kept in
docs/goals/82/run3-result.txt, g79-result.txt, g81-result.txt.

| Check | Linux | Mac | Notes |
|---|---|---|---|
| 82 INTEG (merge, one drop target, review fixes a/b/c, Mac drop, Mac import) | PASS | PASS | 0 lost of 160 bursts; drop places the picture and imports the .canvas on both; File → Import backup… through the picker |
| 82 M1 focus mode | PASS | PASS | SSIM 0.992 / 0.986 / 0.988 vs the web |
| 82 M2 pictures | PASS | PASS | drop vs the web 0.981; the web opening pnote's file 0.986 |
| 82 M3 import and export | PASS | PASS | backup, vault zip/folder, dropped zip, .canvas both ways |
| 82 M4 print and export | PASS | PASS | PDF 0.990, picture 0.990; Mac print/save panels, share picker |
| 82 M5 voice | PASS | **BLOCKED** | Linux WER 4/86 engine, 1/45 page, 1/13 canvas; Mac: "speech recognition is not allowed yet" (D-8919) |
| 82 M6 AI | PASS | PASS | keyring/keychain, Jam 18/18, settings, agent edit Show/Undo |
| 82 M7 live updates | PASS | PASS | another app's write on screen in 37–75 ms; both open 3 min, 0 lost, 8 deletions stay; kqueue 1.1–1.3 ms |
| 79 M0 reference | PASS | – | |
| 79 M1 fonts | PASS | PASS | worst 0.00 px Linux, 0.03 px Mac |
| 79 M2 looks | PASS | – | |
| 79 M3 looks | PASS | – | after D-8918 (first run FAIL: 1/78 boxes, the Voice row's machine state) |
| 79 M4 steps | PASS | – | 28 steps, worst SSIM 0.965 |
| 79 M5 input methods | PASS | PASS | |
| 79 KEYS | PASS | PASS | first run FAIL: no race notes in this worktree (copied from goal 79's build) |
| 79 PACKAGE | PASS | – | installer property (60 HOMEs), 43 mutants, the package in a scratch folder |
| 81 M1–M5, M8 | PASS | PASS (M8) | |
| tests/test_gesture_numbers.py | PASS | – | |
| tests/test_gtk_input_im.py | PASS | – | 0 lost of 1582, 134 commits held |
| tests/test_gtk_held_paste.py (new) | PASS | – | |
| tests/gtkapps/hiddenclock (new, via mac81 clock) | – | PASS | 0 frames hidden, 120 after the return (144/s) |
| components check | PASS | – | docs/components.md current |
| Mac typing guard for the CoreText fix | – | FAIL → fix reverted | below |

## Mac typing, before and after the CoreText cluster fix

The M4 (144 Hz screen), pnote's typing rows as worker A's TYPING runs them (80 keys on the race notes), the before build in its
own folder from the tree just before the fix, the after build with it; alternated, **median of 7 runs a side** (ms;
docs/goals/82/typing-mac.md, the raw runs in typing-mac.json; the first 3-run judgement in typing-mac-3runs.md):

| Row | key to paint p95/max | key to frame begun p95/max | frame gaps p95/max |
|---|---|---|---|
| 600 | 1.5/1.5 → 1.3/1.3 | 0.7/0.7 → 0.7/0.7 | 2.3/7.3 → 2.3/6.9 |
| 600 not warmed | 1.4/1.4 → 1.5/1.5 | 0.7/0.7 → 0.6/0.6 | 2.2/8.1 → 2.5/7.2 |
| stress | 1.5/1.5 → 1.6/1.6 | 0.7/0.7 → 0.8/0.8 | 2.5/7.0 → 2.6/7.5 |
| stress not warmed | 1.6/1.6 → 1.5/1.5 | 0.7/0.7 → 0.7/0.7 | 2.2/7.1 → 2.3/7.4 |
| page 20,000 chars | 1.9/1.9 → 1.8/1.8 | 0.9/0.9 → 0.9/0.9 | 4.1/11.2 → 3.9/10.5 |

Verdict: **some rows more than 3 % worse** (stress key to paint +6.7 %, key to frame begun +14 %, 600-not-warmed gaps p95
+14 %), so by the rule the fix was **reverted** (D-8916). Read with care: the Mac bench times only the last of 80 keys
(p95 = max in every run), each step is 0.1 ms, and same-side runs spread 1.2–2.4 ms; this is "not shown to be no worse",
not "shown worse". The Mac's FRAMEBENCH on Metal prints no frame times (p95/max 0.0 every run), so the judge uses the numbers
it does print (D-8911). No Linux timing was run (machine rules).

## Packages

| File | sha256 | Proof |
|---|---|---|
| dist/pnote-linux-x86_64.tar.gz (9.4 MB) | ac65f2be9862f644e1ed1a04f377cc2a22594cc39139cea3182e79858e83d337 | goal 79 PACKAGE: unpacked outside the checkout, installed into scratch HOMEs, run with real input, updated, removed; the notes stay |
| dist/pnote-mac-arm64.zip (8.3 MB) | 73134f9d5682e1445e40f285fe7b61ac5ebd22dae995d2fea6d6f83cc808f03d | built on the M4 (scripts/mac-package), ad-hoc signature verified, unzipped into a scratch HOME's Applications, started from /tmp: all fonts found, running after 15 s, its notes file made in the scratch HOME |

The first Mac zip of this session crashed exactly there (no fonts: D-8917); the one above is the fixed build.

## Still open

- **Mac speech recognition** (M5 Mac): BLOCKED after the owner's grant: "not determined" for pnote over SSH (D-8919).
- A Mac with no fonts at all has no system-font fallback (Linux has fontconfig's); the download ships its fonts, so only a damaged install meets it.
- **CoreText clusters / goal 80's fast path on the Mac:** reverted (D-8916). The Mac's typing bench times only the last key of
  80, so a 3 % bar can't be resolved; a bench that times every key comes first, then the same A/B (fix: commit 4ddd85e1).
- tests/test_ct_clusters.mojo passes on Linux and fails on the Mac until that fix returns (by design, documented in the file).
- Worker C's open items: an MCP server in pnote (agents use the web's CLI, D-8715), canvas Undo of an agent edit (D-8713).
- The hidden-window test (tests/gtkapps/hiddenclock) was shown green with the fix; it was not run red without it.

## What the owner must do

1. **Speech recognition on the Mac (M5).** After your grant, macOS still says "not determined" to pnote (com.mojoui.pnote) and to
   the check's program, both started over SSH (D-8919). Likely reasons: pnote is ad-hoc signed, so every rebuild is a new app to
   macOS's privacy settings, and a program started over SSH isn't the app you allowed. To try it for real: on the Mac, open
   `~/omxcode-g82i-pkgtest/home/Applications/pnote.app` (the installed download) **from Finder**, open a page, hold the mic
   button, and click **Allow** for Microphone and for Speech Recognition when asked; then say a sentence and check the words
   appear. A check run over SSH may stay BLOCKED even then; a signed build (a Developer ID) would make the grant stick.
2. **Decide on the CoreText cluster fix** (commit 4ddd85e1): reverted by the 3 % rule on one-sample numbers. Either accept a
   Mac typing bench that times every key first (recommended), or rule that one 0.1 ms step is within noise.
3. Review and merge `goal-82` (not pushed).
