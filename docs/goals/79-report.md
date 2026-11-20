# Goal 79 report: Personal Note, native, the exact look of the web app, faster

Worktree ../mojo-ui-g79, branch `goal-79-pnote-lookalike` (base 654d9471). Not merged, not pushed. Decisions D-7900–D-7937
(docs/decisions.md), attempts in docs/journal.md. Checker: `scripts/check` → `docs/goals/79-check.py`, committed before
any feature work (f9ef3c70), since strengthened (D-7911, D-7929, D-7931) and fixed where its own bugs blocked a comparison
(D-7906, D-7908, D-7915, D-7917–D-7919: each logged with why it is not a weakening).

**Owner's ask (11-19):** "Rebuild Personal Note the exact way the web version looks with a better performance." Then
D-7900: framework first; every trick goes into mojoui; Linux and Mac count equally.

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
