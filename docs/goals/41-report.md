# Goal 41 report: the claim, answered in two minutes (and nothing freezes)

**End goal (owner, 2026-10-30):** warehouse safety plus documents, "functionality real, data fake", cards connected only by
explicit links, OCR as a plug-in model; first, "take the latest [UI-thread work], see what extra components you need, and
contribute back to the app framework… the app is just a showcase". Contract: docs/goals/41-GOAL.md, docs/goals/41-check.py.
Branch `goal-41-claims` (goal 39 + goal 41, main merged in at f2dcb42).

## Result: M0–M11 all PASS (reviewer: round 1 NEEDS WORK, fixed; round 2 PASS)
```
M0: PASS  17 BOLs, 3 disputed; two runs byte-equal (PDF text too)
M1: PASS  SLOW: update msg=1 80.07 ms; web too; jobwake PASS
M2: PASS  player async; session 0 SLOW at 50 ms, scrub gaps 17 ms; goal 39 M6/M7/M11 still PASS
M3: PASS  no start_job; 1M-row insert, query, export, analyze: 0 SLOW; goal 39 M7 still PASS
M4: PASS  open_with in both apps; videocard + video_for_log in mojoui; A11Y 0/0/0 unnamed; matrix fresh
M5: PASS  Liquid dark; gtk mean 0.16, web mean 0.17; every region bordered
M6: PASS  link; match; join; follow; time; tools
M7: PASS  fields exact 119/119, boxes IoU≥0.5 117/119; FUNSD word recall 0.81
M8: PASS  1 link(s) shipments.shipment_id (14 of 18); peek lit [...]; web too; 0 SLOW
M9: PASS  time link paints; cursor within one frame at 3 seeks (0 ms worst)
M10: PASS answer = truth (3 disputed); seeks ±15 frames and Exceptions boxes; claim packs (PDF + reel) each
M11: PASS claim clip on cover + deck; bundle regenerates; 6 covers clean at 1440/390
```
(build/g41-final.txt before merging main; after the merge M4 crashed once (exit -11, a Mojo-level crash, not reproduced)
and M11 timed out once on the omxconsole cover; both PASS on re-run.)

## What the framework gained (mojoui/, themes/; omxplorer only composes)
- **Never freezes:** a slow-frame watchdog (`MOJOUI_BUDGET_MS` → `SLOW:` lines, every host through the runtime);
  `framefeed.mojo` (a decoder thread per video/still: open ≈ 40 µs, seek ≈ 6 µs, newest seek wins); queries, Export CSV,
  Insert > Table, compare and model scans as `start_ui_job` jobs (`tablejobs.mojo`); one analysis path (`videocard.mojo`);
  `MediaTimeline.open_with`; screen-reader names on every media canvas.
- **Links:** `links.mojo` (key/time/place, match counts, the quoted JOIN a link implies, Selection followed to each linked
  card), `linkdrag.mojo` (drag a column onto a card → "Link these?"), the Links panel, `peek.mojo` (hold a card: the rest
  dims, linked cards lift, labelled ghost lines), `timelane.mojo`, `asksql.mojo` (`JOIN LINKED`).
- **Documents:** `pdfsource.mojo`, `documentcard.mojo`, `documentset.mojo` (a folder as one card), `ocrmodel.mojo`
  (docTR in process behind a reader slot; 0.15 s/page, ≈ 570 MB VRAM on the 3090), `texttable.mojo`, `formfields.mojo`
  (labels are data), `documentjobs.mojo` + `pygil.mojo` (Python on a job's thread), `packpdf.mojo`/`pack.mojo` (claim pack).
- **Look:** Liquid dark (`liquid_dark_palette`, `dark_tint`; owner: "no compromise on the liquid… we can do Liquid dark
  mode", then "design a new liquid dark"); omxplorer opens in it; Settings → Appearance Light/Dark/System.

## Demo
```
pixi run python scripts/claims_data.py build/g41/data
pixi run python scripts/scenario.py claims --media build/g41/data --out build/g41/claims    # agent tools only
OMX_DOCUMENTS=build/g41/data scripts/omxplorer.sh                                          # by hand
```
Clip: ~/Projects/omxlabs/assets/img/clip-claims.mp4 (40 s, on the omxplorer cover and deck; site commits cdaaee2, 47a4db0, not pushed).

## Worth a second look
1. **D-1266:** truth.json's shipment ids are text so M10's proof (written for "S-5012"-style ids) compares like with like.
2. **D-1200:** a 0.1–0.7 s UI stall came from the analysis job pinning host memory (`cuMemAllocHost`) while the UI thread
   allocated; the video scan now uses ordinary memory (~300 frames/s still).
3. **D-1260/D-1344:** Python on job threads: the lock is lent to a job only while it runs; bare Python calls on the UI
   thread meanwhile now fail loudly (`python_guard`) instead of deadlocking.

## Not done or unverified
- Mac/iPhone/Android: the watchdog is wired in AppKit/Android but not run; framefeed's pthread calls aren't in the Apple stubs.
- The web host can't pick a folder (documents by hand on GTK only); `timelink` not run on the web.
- The peek's GTK label text isn't centred in its pill; only table-card headers start a link drag.
- Generated footage and digital PDFs only (no scans, handwriting or real footage).
