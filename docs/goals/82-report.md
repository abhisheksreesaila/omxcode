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

RUN3_TABLE

## Mac typing, before and after the CoreText cluster fix

TYPING_TABLE

## Packages

PACKAGES

## Still open

- **Mac speech recognition** (M5 Mac): BLOCKED on macOS's permission until the owner allows it (below).
- **CoreText clusters / goal 80's fast path on the Mac:** reverted (D-8916). The Mac's typing bench times only the last key of
  80, so a 3 % bar can't be resolved; a bench that times every key comes first, then the same A/B (fix: commit 4ddd85e1).
- tests/test_ct_clusters.mojo passes on Linux and fails on the Mac until that fix returns (by design, documented in the file).
- Worker C's open items: an MCP server in pnote (agents use the web's CLI, D-8715), canvas Undo of an agent edit (D-8713).
- The hidden-window test (tests/gtkapps/hiddenclock) was shown green with the fix; it was not run red without it.

## What the owner must do

OWNER_STEPS
