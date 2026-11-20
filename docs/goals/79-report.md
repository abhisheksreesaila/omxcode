# Goal 79 report: Personal Note, native, the exact look of the web app

Worktree ../mojo-ui-g79, branch `goal-79-pnote-lookalike` (base 654d9471). Not merged, not pushed. Decisions D-7900–D-7908
(docs/decisions.md), attempts in docs/journal.md. Checker: `scripts/check` → `docs/goals/79-check.py`, committed before any
feature work (f9ef3c70).

**Owner's ask (11-19):** "Rebuild Personal Note the exact way the web version looks with a better performance." Then
(D-7900): framework first, every trick in mojoui, Linux and Mac equally.

**Where it stands:** the reference, the text engine (Linux half) and the shell look are done and proven against the
web app's own pixels and DOM. The mind map screen is nearly there. Canvas, search, island card, settings, the step
script, IME, the race and the Mac are **not done**. This was a 300-turn budget and the goal is several of those.

## Milestones (checker output, 2026-11-19)
| # | Result | Commit | Checker says |
|---|---|---|---|
| M0 Reference | **PASS** | 3c7a5d97, fix 0651fc07 (D-7906) | 9 screens at 1.6× (2304×1440), 187 distinct names (476 boxes), 19 text widths, pn.db seeded |
| M1 Text | **FAIL (Mac half missing)** | 1c233990 | Linux: all 19 lines (9 faces, Hindi, Tamil, Arabic, Japanese, Chinese, Korean, emoji) equal Chromium's width to the device px (worst 0.00001), no .notdef, crisp 1.00. Fails on "fonttext doesn't call CTFont": the CoreText path isn't written |
| M2 Shell | **PASS (Linux)** | 808840ae | boxes ≤ 2 px, fills ≤ 4 levels, SSIM page+sidebar 0.973, page 0.983, Night 0.963, Crayon 0.973 |
| M3 Every screen | **FAIL** | 49a4c563 | mind map: every box ≤ 2 px, SSIM 0.984, 7 fills off; canvas 25/34 boxes (SSIM 0.972), search 18/67 (0.907), island card 19/63 (0.956), settings 29/78 (0.863) |
| M4 Works the same | **FAIL** | — | docs/goals/79/steps.json missing (not attempted) |
| M5 IME | **FAIL (not attempted)** | — | no GtkIMContext / NSTextInputClient wiring yet |
| M6 Race | **FAIL (not attempted)** | — | not run; OP_RUN text isn't on the GPU renderer yet (see Limits) |
| M7 Both machines | **FAIL (not attempted)** | — | Mac not run; goal 74/75 checks not re-run on this branch |

## Compare images (web │ native │ diff ×4)
- build/g79/page-sidebar-compare.png, build/g79/page-compare.png, build/g79/page-sidebar-night-compare.png,
  build/g79/page-sidebar-crayon-compare.png (M2, passing)
- build/g79/mindmap-compare.png (boxes and SSIM pass, fills don't)
- build/g79/canvas-compare.png, build/g79/search-compare.png, build/g79/island-card-compare.png,
  build/g79/settings-compare.png (not built: the native side shows the screen behind)

## The race
Not run (M6). No speed claims in this report.

## What the framework gained (D-7900)
| Component | What | Test | Runs on |
|---|---|---|---|
| `mojoui/fonttext.mojo` | real faces at device px: FreeType raster (light hinting), HarfBuzz shaping, fontconfig fallback, colour emoji (CBDT scaled), Chromium's advance rule (FreeType advance rounded, kerning added, rounded again: D-7905), `exact` mode for canvas/SVG text, Blink line metrics (`line_metrics`, `baseline_in`, MVAR-aware) | tests/test_fonttext.mojo (19 lines vs Chromium), tests/test_notesshell.mojo (metrics) | Linux ✅; Mac ❌ (CoreText half not written) |
| `Painter.run` / `OP_RUN` | a text run in a real face through Scene, SurfacePainter (with clips) and Scene.raster | via the above, M2 | CPU ✅; gpu2d GL/Metal ❌ |
| `mojoui/skin.mojo` | Paper, Night, Crayon as themes: tokens, CSS color-mix, shadow scale | tests/test_notesshell.mojo (values = the browser's computed styles) | any host (pure) |
| `mojoui/strokeicon.mojo` + `lucide_nodes.mojo` | Lucide 1.24 geometry (the web's version) parsed and stroked natively (paths, arcs, rects, circles) | tests/test_notesshell.mojo | Linux ✅ (CPU image path) |
| `mojoui/notesshell.mojo` | dotted desk, round islands (with hover), title island, floating notes panel (brand, Quick note, Inbox rows, PARA shelves, notebooks, skin dots), CSS shadows as layered rects, `Boxes` (named boxes = hit test + test oracle), tool dock, zoom island, hint | tests/test_notesshell.mojo, M2 | Linux ✅ |
| `mojoui/pagesheet.mojo` | a page note as the web draws it: host, toolbar, sheet, emoji tile, CodeMirror-look Markdown on CSS line boxes (1/64 px) | tests/test_notesshell.mojo, M2 | Linux ✅ |
| `mojoui/buzanmap.mojo` | the web map's geometry (attach, one-bend cubic, tapered ribbon capped by curvature, depth widths), cards, root card, fit, minimap | tests/test_buzanmap.mojo | Linux ✅ |
| `App.hovers()` + `HOVER` | apps opt in to pointer motion on their Canvases and draw hover states; `tapat:` moves the pointer first, as a real click does | M2 (the web shot shows the toggle hovered) | GTK ✅; AppKit ❌ |
| GTK host | `render:` steps show the test window (a canvas only draws when shown) | M2 | GTK ✅ |
| `blit` | straight-alpha images blend instead of overwriting | M2 | CPU ✅ |

pnote's own part is a thin composition: `examples/pnote/webshell.mojo` is **261 lines** (reading Personal Note's
database, which screen shows, taps). `examples/pnote/app.mojo` (902 lines) is mostly goal 74's look, kept so goal 74/75's
proofs still run (D-7907). The web app's `src/main.js` alone is 4,300 lines.

## The 3 decisions most worth a second look
1. **D-7901, fonts served from disk to the reference.** The web normally fetches Google's woff2 subsets; the shooter
   answers those requests with the same OFL families from `fonts/`. It's what makes 1-device-px text comparisons
   meaningful, but it means "the web" is measured with our font files, not Google's.
2. **D-7907, two looks in one pnote.** The web look runs when `PNOTE_DB` names a Personal Note database; otherwise
   pnote keeps goal 74's look so goal 74/75's checks still prove the editors and GPU path. Cleaner end state: move those
   checks onto the web look and delete the legacy branch.
3. **D-7905, the advance rule.** round(round(FreeType advance) + HarfBuzz kerning) matches Chromium on all 19 lines and
   on per-glyph positions, but it is inferred from measurements, not read from Blink's source.

## Limits and what to doubt
- **The GPU path doesn't draw `OP_RUN` text yet.** The checker's shots use `render:desk` (the app's own CPU
  SurfacePainter picture of its canvas, at device px). In the real window on the GPU renderer the new text and icons
  don't show yet. This is the most important gap: gpu2d needs a dynamic glyph atlas fed by fonttext (keyed by face,
  device size, subpixel x) and the image path for icons and emoji.
- **SSIM alone is a weak bar.** The canvas screen scores 0.972 with no canvas content drawn at all; the box test is
  what catches it.
- **Mac: nothing run.** No CoreText half, no AppKit HOVER, no Mac shots.
- **Not built:** canvas in the web's style (Leafer look), omnibar, island card, settings window, the step script, IME,
  the race.
- **Mind map fills:** the web's SVG filter regions leave light patches behind the add handles and around the root;
  the 1 px dock dividers anti-alias differently; the root label renders smaller than its 28 px attribute in Chromium
  (not understood). Dashed selection ring corners aren't drawn.
- The page toolbar's trailing 14 px gap and the hover state in the reference were matched from measurement; both are
  logged.

## Next (in order)
1. fonttext on the GPU: OP_RUN and icons in gpu2d (GL and Metal), then a GPU readback in the shots.
2. The CoreText half of fonttext and HOVER on AppKit; M2 on the M4.
3. Omnibar, island card and settings as mojoui components; canvas objects in the web's style.
4. steps.json and steps.mjs for M4; IME; the race.

## Run it
```
cd ../mojo-ui-g79
scripts/build.sh pnote linux
cp build/g79/ref/pn.db /tmp/pn-scratch.db      # a scratch copy (scripts/check M0 makes build/g79/ref/pn.db)
PNOTE_DB=/tmp/pn-scratch.db PNOTE_SKIN=paper build/pnote/linux/pnote
scripts/check M0 M1 M2 M3
```
