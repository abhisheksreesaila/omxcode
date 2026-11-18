# Goal 74 report: Personal Note's editors, native in Mojo

Worktree ../mojo-ui-g74, branch `goal-74-personal-note` (base main cc33c9d7), its own pixi env. Not merged, not pushed
(see "Merge"). Decisions D-7401–D-7432 (docs/decisions.md). Checker: `pixi run python docs/goals/74-check.py`.

**Owner's question (11-17):** can we build Personal Note natively in Mojo, no JS? **Answer: yes for the editing heart.**
A native text editor, Markdown edited in place, free objects with arrows and ink on a canvas, and a mind map are now
generic `mojoui` components, drawn through a Painter (no toolkit text widget, no CodeMirror). A small Personal Note
(`examples/pnote`) composes them with SQLite search and a Ctrl+K palette, and survives a relaunch.

## Milestones (2026-11-18)
| # | Result | Commit | Proof |
|---|---|---|---|
| M0 Audit, today | PASS | 6a6d52f8 | 53 features: 19 have, 23 partial, 11 missing (base cc33c9d7, before this goal's components); every row has `native` and existing files; no `have` rests on JS |
| M1 Undo | PASS | b65e3531 | mojoui.history: Undoable steps, merged typing, redo branch dropped, exact cap |
| M2 Text editor | PASS | 6a6d52f8, 19b24a97 | mojoui.textedit: edit, caret/words (Ctrl and Alt), wrap, hit both ways, undo, clipboard; 1M characters (ordinary paragraphs) open in ~4 ms, a key + paint 0.07 ms p95, Enter/join 0.15 ms p95 (into a Scene) |
| M3 Markdown | PASS | 827478ca | mojoui.mdedit: headings, bold, italic, code, links, strike, lists, tasks, quotes, code blocks, rules; marks hidden off the caret's line; a click ticks a task; Enter continues lists |
| M4 Objects | PASS | f1385dc7, 5076c588 | mojoui.objectlayer: 7 kinds, select/marquee/8 handles/rotate/z/lock/duplicate, connectors that follow, one undo per operation, 3,000 random ops undo/redo exactly; Personal Note's own 645-object note: pan paint 0.1–0.3 ms p95, hit 0.005 ms; save_text/load_text |
| M5 Mind map | PASS | f1385dc7 | mojoui.mindmap: 500 random topics, no overlap, 0.3 ms cold layout; Tab/Enter/F2/Escape/arrows/Space/Delete; undo; outline text |
| M6 The app | PASS | 5076c588, 77b18372 | GTK headless, real steps: a page typed, a box and a sticky connected, a stroke drawn and undone and redrawn, 3 map topics, FTS search, palette; relaunch kept all three notes; shots below |
| M7 The race | PASS (both ran) | 1317531d, 77b18372 | docs/goals/74/race.md, with caveats |
| M8 Nothing regressed | **FAIL (environment)** | 777a9d45 | matrix lists the five components (✅ GTK), goal 40 M0–M2 pass; goal 71 M5 fails only at goal 47 M8's SLOW frames in omxplorer, which also failed with main's GTK host under the same load (D-7432) |

Reviews: reviewer round 1 NEEDS WORK (5 must, 6 should: clipboard, Alt moves, tabs lost on save, a hollow fallback,
race caveats…), all fixed in 19b24a97; round 2 **PASS** on M1–M7, with M8 to be reported as an environment failure.

## The race (same machine, same seeded content; numbers under load 14–19 from other sessions)
| | pnote (native Mojo, GTK) | Personal Note (CodeMirror / Leafer in Chromium) |
|---|---|---|
| Open a 1M-character page | **35 ms** (stored in SQLite and opened) | 2,939 ms (dev-server page load) |
| A keystroke on that page | 2.1 / 3.1 ms p50/p95, whole frame incl. software raster | 2.0 / 3.4 ms main-thread only (no paint/raster) |
| Pan the 645-object note | 12.4 / 18.6 ms of work a frame (Cairo software, no GPU) | 0 dropped frames at 60 Hz |
| Zoom it | 9.4 / 22.0 ms | 0 dropped frames |

Read it honestly: **opening is far faster, typing is level, panning a dense canvas is slower** than Personal Note's
Leafer in Chromium on this headless machine. Our canvas cost is the GTK Cairo software renderer rastering the whole
canvas each frame (raster p95 ≈ 12 ms; the app's own paint is ~0.3 ms). Caveats in race.md: the two sides measure
different things (frame work vs frame intervals).

## Shots (build/g74/m6/)
- `page.png`: Groceries, a heading, task boxes drawn as shapes, bold/italic with marks on the caret's line
- `canvas.png`: a text box and a sticky joined by an arrow, a pressure stroke
- `map.png`: Central topic → Milk, Eggs, Bread on tapered coloured branches

## Limits and debt (all logged)
- **No paste from other apps** (D-7427): no host can read the system clipboard yet; Ctrl+V pastes the editor's own copy, and copies do reach the system.
- One 1M-character *paragraph* costs ~27 ms a key: it re-wraps whole (D-7428). Fix: re-wrap from the edited line.
- Turned text and pictures draw upright (no Painter rotate, D-7416); pictures save their box, not pixels (D-7423).
- No IME (CJK composition); fonts are the baked Inter/JetBrains Mono atlases (106 glyphs: no •, ✓, emoji).
- Canvas pan on software rendering (above): GPU presenter or cached object tiles are the lever.
- Web: pnote builds for the web host, never run in a browser. Mac: not attempted.
- Sidebar rows all show the page icon (the kind's icon isn't reaching the row); the mind map has no motion yet.

## 30-second demo
```
cd ../mojo-ui-g74
scripts/build.sh pnote linux && build/pnote/linux/pnote          # New page / New canvas / New map; Ctrl+K
pixi run python docs/goals/74-check.py M6                         # the scripted session + relaunch, shots in build/g74/m6
```

## Merge
Not merged into main: M8's regression check isn't green (load-sensitive, D-7432), and goal 73 is merging into main from
its own worktrees. Merge when the machine is quiet and `docs/goals/74-check.py M8` passes, or on the owner's word.

## Next
Paste from the system clipboard (a host read), incremental re-wrap, Painter rotate, a GPU path for the canvas, then
ink anchored to words and secure notes (the audit's next gaps).
