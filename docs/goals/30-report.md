# Goal 30 report: the island, and 100 million rows that never freeze the window

**Why (owner, 2026-10-21):** "dynamic island 100M demo is the sexiest demo." At 100M rows a median held the window for
0.69 s and a month chart for 0.48 s. MX frame **23edc59** runs a query as a `Job` on its own thread, with progress and
cancel; the island shows that work while the window stays live.

## Result
- **M0–M5 PASS** (full run 9, 2026-10-22; M5 took 81 min): the engine is 23edc59 and every example builds for its platforms; 6 charts
  through a job equal the same charts in place; the island is a component with its own test; omxplorer wears it; the
  100M clip is recorded.
- **M5 (every earlier goal's checks):** pass. The last full run's only failure was a generated doc (llms-full.txt) written
  before the matrix it copies; regenerated, and `scripts/llms.py --check` says it's current. No code changed after the run.
  Goals 17, 24 and 27 read the island where they read the toast and the GPU chip (D-287).
- Reviewer: rounds 1–3 NEEDS WORK (detached threads, a stale open, orphans dropped while their thread still ran), round 4
  PASS; round 5 (the hang fix and the M1 check change) PASS, its three should-fixes in.
- Merged into main locally, not pushed (CLAUDE.md).

## What you see
![The island's faces: at rest, running, done, undo, error](goals/30/island-faces.jpg)

| At rest | Running | Done | Undo | Error |
|---|---|---|---|---|
| the document, its rows, the GPU | "Median of revenue by region · 43% · 1.4B rows/s", a progress line | "✓ 0.69 s on RTX 3090", 4 s | "Bold applied to 21 cells · Undo", 5 s | stays until seen |

The capsule grows to its new face over 320 ms on the calm curve (at once with less motion), and a running face never
shrinks while its numbers change. Tapping it opens a panel: the document, Recent (each operation, its time, Undo) and
Device (the GPU, the last 12 timings, p50 and p95). The document chip, the GPU chip and the toasts are gone.

![100M rows: the median by region landed, the window live throughout](goals/30/big-median-gtk.jpg)

The clip: `docs/img/clip-island-100m.mp4` (22 s, the native window over 100M rows: open, a median, a 3 s median by
month as a line). Through it the island changes in every frame for 3.6 s straight: the window never waits.

## What it costs (this machine, RTX 3090)
| 100M rows | the query | the longest gap between frames while it runs |
|---|---|---|
| open (Parquet, into memory) | 1.8 s | 17 ms |
| median of amount by region | 0.77 s | 33 ms |
| median of amount by month, as a line | 3.3 s | 17 ms |
| the status bar's sum and average of a column | 2.0 s | (with the open) |

Before: the window froze for the whole query. Now the longest pause is two frames (the hand-over of the result).

## Fixed on the way
- **Every host must send frames.** The agent host (MCP) never drew, so a job polled on frames never landed: it now
  settles after each action (D-283).
- **A cancelled job is kept until its thread ends.** Cancel marks the job at once, but its thread runs to its next
  check; dropping it then left a thread reading a table being freed. Orphans are joined with `pthread_tryjoin_np`, never
  judged by their state (D-284). Opening another file cancels and waits for the one still being read.
- **A test window that hung for 15 minutes** (goal 14's save run, twice, never alone): the test driver's waits turned
  GTK's main loop blocking, and once the island stopped asking for frames nothing woke it, so the deadline was never read.
  Every wait now pumps without blocking, and the check fails on a blocking turn (D-286).
- **Packages:** `scripts/package.sh omxplorer linux|mac` makes a Linux tarball (runtime libraries beside it, an install
  script with a launcher entry) and a Mac app zip, ad-hoc signed.

## Your test
```
cd ~/Projects/mxapp/mojo-ui
scripts/omxplorer.sh build/data/orders_100m.csv
```
Create table, Insert → Chart, then ask *median* and *by month, as a line*. Type in the ask field while it runs: the
cursor keeps blinking. Tap the island for Recent and Device.

## Not done
- The Mac runs jobs serially (inside the start call): the window waits there on big queries.
- Seen by the owner in the package: pivots placed over each other and the table, and the inspector's Combine control
  reads "Ave… Co… Me…". Both are in goal 31 (docs/goals/31-draft.md).
