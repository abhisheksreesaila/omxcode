# GOAL 41: the claim, answered in two minutes (and nothing freezes)

**End goal (owner, 2026-10-30):** warehouse safety as the first wedge, with documents: "pick a digital PDF, run it through
an actual OCR, a good OCR, hook it up to a video, highlight and show". "The functionality has to be real, the data can be
fake", reproducible by anyone. Multimodal cards connect only through **explicit links** ("you cannot auto join and hope it
works"); OCR is "just a machine learning model where you plug in". Before that (owner, same day): "take the latest [UI-thread
work], see what extra components you need, and contribute back to the app framework… don't overfit the app, the app is just
a showcase." Look: Liquid dark (its own deep cool palette, every region bordered; owner 2026-10-30, D-1240), dim-not-blur peek, link UI = drag (A) + Links panel (C)
+ hold-to-peek (approved prototypes docs/goals/41-prototypes/links.html, hold.html).

Base: `goal-41-claims` = main b79fc66 (UI-thread rules, docs/ui-threads.md) + goal 39 merged (a48edcb), goal 39's checks
re-run green on it. Framework first: every piece goes in `mojoui/` (or `themes/`) with its own test; omxplorer only composes.

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | Claim data + truth | `scripts/claims_data.py OUT` writes dock.mp4 (goal 39's warehouse scene), shipments.csv (+ status, claim_usd), forklift_log.csv (t, speed, brake), bol/BOL-*.pdf (one digital PDF per delivered shipment: shipment no., carrier, pallets, exceptions, signature), truth.json (each BOL's field values and their boxes in page points; `disputed`: shipments damaged on camera whose BOL says no exceptions; the damage frame per shipment; the log's clock offset); two runs: CSVs, truth.json and every PDF's text byte-equal |
| M1 | Slow-frame watchdog (mojoui) | with `MOJOUI_BUDGET_MS=N` every host prints `SLOW: <update\|view\|draw> <name> <ms> ms` for any update, view or canvas draw over N ms after the first second; `examples/slowcheck` (a button whose update sleeps 80 ms, one that doesn't): a headless GTK run at 50 prints a `SLOW: update` line after tapping slow and none after tapping fast; the web build prints the same line through its host; `examples/jobwake` still prints PASS |
| M2 | Media never blocks the UI thread | opening a video or picture (ffprobe), seeking, decoding, filmstrip thumbnails and the editor's preview (GPU context, redaction plan) run off the UI thread; `tests/test_player.mojo` prints `player async: ok` (open returns before the probe ends; a seek returns at once and the frame lands later); a headless omxplorer session at `MOJOUI_BUDGET_MS=50` (open dock.mp4, 20 scrubs across the bar, play 2 s, Edit, blur chip on, insert a picture) prints 0 `SLOW:` lines and `GAPS:` longest < 120 ms over the scrubs; goal 39's M6, M7, M11 (docs/goals/39-check.py) still PASS |
| M3 | Data work as jobs, one analysis path | SQL query, Export CSV, Insert > Table, compare and model scans run through `start_ui_job` (wakes the UI, no per-frame polling); `mojoui/videojobs.mojo` and `mediatimeline_jobs.mojo` share one analysis job; `examples/omxplorer/app.mojo` calls no `start_job(`; a headless session at 50 ms (a 1,000,000-row CSV inserted, a GROUP BY query, Export CSV, Analyze) prints 0 `SLOW:` lines and the query's `JOB:` line; goal 39's M7 still PASS |
| M4 | Extracted and named | `MediaTimeline.open_with(...)` used by both examples/media and omxplorer (no duplicated editor setup), the video card's Analyze / Make a reel / Edit flow lives in mojoui (`mojoui/videocard*.mojo`), `video_for_log` in trackcard; `a11y` on omxplorer's video card, editor and table card prints `A11Y: 0 unnamed`; `scripts/components.py` matrix fresh |
| M5 | Liquid dark mode | `themes/` Liquid dark mode (liquid_dark, its own palette): Liquid's islands, radii, type and springs over deep cool tonal surfaces, one accent with Liquid's tints, a 1 px hairline around the sidebar, toolbar, sheet, inspector, status bar and every card (GTK and web); omxplorer opens in Liquid dark; on the GTK and web shots (1742×876) the page's mean luminance is 0.10–0.30 and every region boundary of `build/g41/m5-regions.json` (written by the run's `regions:` step) has a luminance step ≥ 0.04 along ≥ 80 % of its length; `examples/gallery` shot in Liquid dark written (owner 2026-10-30: "we need liquid design, apply graphic colors if you want. no compromise on the liquid.. in fact we can do Liquid dark mode." and "you can design a new liquid dark - i am not too keen on graphite or whatever" → D-1240, D-1241; the proof's numbers are unchanged) |
| M6 | Links and selection (omxcode) | `mojoui/links.mojo`: `Link` (key, time with offset, place), a sheet's `Links`, `match_count`, the SQL `JOIN … ON` a link implies, `Selection` + per-card `react`; agent tools `link`, `unlink`, `links`; `tests/test_links.mojo` prints `link: ok`, `match: ok` (12-of-14 style counts against a hand table), `join: ok` (the join's rows equal DuckDB's on the same CSVs), `follow: ok` (a row selection seeks a linked video and highlights a linked page box), `time: ok` (offset maps t both ways), `tools: ok` |
| M7 | Documents become rows (plugin) | `mojoui/pdfsource.mojo` (pages → pictures), a document card (page, zoom, pan, `highlight(box)`), an OCR model behind the model slot (docTR in the `models` env, run as a job), rows with a `text` column (word, box, page, confidence) and fields by geometry (label → value); `tests/test_documents.mojo` (models env) prints `documents: ok`; on M0's BOLs ≥ 98 % of truth's fields read exactly, field boxes IoU ≥ 0.5 with truth's; on 20 FUNSD test forms word recall ≥ 0.70 (printed `funsd recall: X`) |
| M8 | The link UI | drag a column header onto another card → a confirm popover with the match count → Link; the Links panel in the inspector (list, unlink, time offset); hold a card ≥ 350 ms → the peek: unlinked cards dim, linked ones lift with a spring, ghost lines labelled with their columns; release settles back. A headless GTK run prints `LINK: shipments.shipment_id = dock.mp4 · code (12 of 14)` style lines, `PEEK: lit=[…] dim=[…] lines=N` matching the links, shots for the drag, the panel and the peek; same steps on the web build; 0 `SLOW:` at 50 ms |
| M9 | Time links paint | forklift_log linked by time to dock.mp4 with truth's offset: its lane draws under the video and the shared cursor agrees with the video within one frame at 3 seeks (`PLAYER:`/`CURSOR:` lines) |
| M10 | The claim, end to end (agent tools only) | `scripts/scenario.py claims` drives omxplorer only through its agent tools: open the video, the sheet and the BOL folder, Analyze, read the documents, make the two key links, ask "damaged pallets whose BOL says no exceptions"; the answer table's shipments equal truth's `disputed`; selecting each answer row seeks the video to within ±15 frames of truth's damage frame and highlights the page's Exceptions box (IoU ≥ 0.5); Export claim pack writes per shipment a PDF (≥ 2 pages, contains the shipment ID, the BOL page and a frame) and a reel that passes goal 39's reel check |
| M11 | Cover + reproducible bundle | `clip-claims.mp4` (≥ 8 s, recorded from omxplorer in Liquid dark through agent tools) on the omxplorer cover and deck in ~/Projects/omxlabs; `examples/claims-data/README.md` says how to regenerate and replay; regenerating gives truth byte-equal; every cover: no overflow at 1440 and 390, no console errors |

## Done means
`scripts/check` PASS for M0–M11, the reviewer passes it, and the claim clip plays on the cover.

## Out of bounds
Pushing, merging into main, deploying, paid services, sign-ups, secrets; the frozen `../mojo-ui-apple-test`; other threads'
branches (goal-40-sketch: read or copy with a decision line, never commit to it); patching Mojo; lowering a proof.

## Assumptions (instead of asking)
- Data is generated (owned, exact truth); FUNSD is downloaded for evaluation only, never committed (research licence).
- OCR = docTR (Apache-2.0, word boxes, same PyTorch as goal 39's models env); Unlimited-OCR is a later swap of the plugin.
- PDFs are written and rendered with PyMuPDF (pixi, conda-forge); the claim pack is HTML printed to PDF by the Playwright
  already in the default env.
- Time links only paint (cursor and lane); a real as-of join waits for a question that needs it.
- Headless Xvfb draws on the CPU, so the budget in checks is 50 ms (the guide's 16 ms is for real displays).
- Near-miss safety, audio, a model shop and robotics formats are out of this goal.

## Budget
One night (≈ 8 h). Cut order if short: M11's clip, M9, the web half of M8.
