# Goal 38: fairness review (before the measurement)

GOAL.md M5: "a fairness review of every build first (performance mistakes fixed, each build given the same chance)".
This file records what the review found, what each build received, the coordinator's calls, and the one protocol the
measurement uses. **Frozen before the run:** scripts/check.py m5 requires results.json to carry this file's SHA-256,
so any edit after the measurement makes M5 fail until it is measured again.

## Rounds
- **Round 1 (2026-10-28, after M1–M4):** each build checked for performance mistakes against its stack's idiomatic
  best; every build offered the same levers (sort the rows at load, read only the date range, the stack's fastest
  engine path, its fastest JSON or render path), each measured before kept.
- **Round 2 (2026-10-28, NEEDS WORK → fixed):** shortcuts made equal across builds (the newest-50 search), every
  shortcut stated in its README and in results' caveats; the harness fixed (below).

## What each build received

### A · JS + DuckDB-WASM (showcase-data/js-duckdb)
- Sort at load: the table stored day descending / id ascending (10M: ORDER BY in CREATE TABLE; 100M compressed:
  re-inserted in 10 day ranges, newest first, CHECKPOINT after each, so wasm's 4 GB holds it); DuckDB's zone maps then
  prune the date range and the newest-50 top-N stops after the first row groups. 100M median 709 → ~109 ms (74cf051).
- KPIs and chart folded into one statement (two connections measured slower: the worker runs one query at a time).
- Bundle and threads by file size (10M: eh bundle, 1 thread; 100M: coi bundle, 4 threads, compressed storage);
  recorded with crossOriginIsolated and hardwareConcurrency in `ready`.
- Driver: external.py (83d721b): step 0, Chromium from DATA_BENCH_CHROMIUM(_FLAGS), --warm-browser, kpi_rect / `kpi`.

### B · JS + FastAPI + Polars (showcase-data/py-polars)
- Sort at load: the frame day descending, so a date range is a slice; Enum region/product.
- Group-by on Polars' streaming engine (C's lever, 5c1a182); orjson (ORJSONResponse, ad7d5a6); uvicorn with
  httptools + uvloop.
- Newest 50: a hand-written growing-window search at the date slice's start (bdd07a3, round 2: the equivalent of C's
  and D's shortcuts, granted by the coordinator); server compute median 26 → 19 ms at 100M.
- Driver: external.py (A's protocol), server.py as its own child process (counted in PSS).

### C · Rust + Polars + egui (showcase-data/rust-polars)
- Sort at load (ascending, by day), Polars lazy, group-by on the streaming engine; `target-cpu=native` (D's Mojo also
  targets the host CPU), recorded as target_cpu.
- Newest 50: the hand-written tail-window search over the day-sorted rows. Round 1 replaced it with plain Polars
  (14b480b; the plain forms measured slower: sort + limit p95 2.3 s, filter + head p95 466–711 ms at 100M); the
  coordinator restored it (59f59b5) because D keeps an equivalent shortcut.
- eframe on Wayland (winit picks it with WAYLAND_DISPLAY), `--scripted-external`, kpi_rect / `kpi`.

### D · omxcode + omxcore (examples/dashboard)
- Sort at load by (day, id) on every core (mojoui.tableprep, D-766); amounts and costs as integer cents at load
  (a deliberate data-model choice: the others keep float64; exact sums), counted in its load.
- Each change reads only the date range's rows on the GPU: mojoui.devgroup (group-by product × day over a slice,
  D-767, D-768), mojoui.devrows (reused buffers, copies back only the rows found); the cut-off day for the newest 50
  comes from the per-day histogram the group-by already makes (D's equivalent of C's search).
- Job wake (D-771, 144100f): a finished background job wakes the UI at once (a framework feature for every mojoui
  app, not a dashboard hack: GTK, web, Mac); before it, the result waited for the next display frame's poll.
- `--scripted-external` (D-770), kpi_rect / results_rect in `ready` (D-772).

## Coordinator decisions (2026-10-28)
- C's hand-written newest-50 search is restored (59f59b5): D has an equivalent shortcut (the per-day histogram).
- B gets an equivalent search too (bdd07a3), so A's zone-map top-N, B's and C's searches and D's histogram are the
  same kind of shortcut, each stated.
- D's job wake is a framework feature (mojoui.jobs), allowed: every mojoui app gets it.
- The owner's session is locked (travelling): the measurement runs on a separate headless Hyprland on the GPU (not
  the physical monitor), stated in results.

## The one protocol (frozen)
scripts/data_bench.py's docstring is the protocol; the points that make it one for all builds:
- Same display for every build: a separate headless Hyprland 0.56 (screen_observer.HeadlessHyprland), RTX 3090 at
  2f:00.0 through EGL/GBM, HEADLESS-1 1920 × 1080 @ 60 Hz, every window floating at exactly 1280 × 800 at (320, 140)
  from the moment it maps (a window rule), animations off, cursor invisible, no Xwayland, no DISPLAY.
- Same Chromium for A and B: /usr/lib/chromium/chromium `--ozone-platform=wayland --use-angle=vulkan
  --ignore-gpu-blocklist` (+ the drivers' common profile/no-throttling switches), read back from /proc per run and
  compared. `--enable-features=Vulkan` (in the first protocol) is dropped: on Wayland Chromium refuses Vulkan
  compositing and its window never updated on screen (1 distinct frame in 1 s with it, 21 without; WebGL is ANGLE on
  Vulkan on the RTX 3090 either way).
- Input-to-pixels: CLOCK_MONOTONIC just before the harness writes `step N` → the compositor timestamp of the first
  frame whose KPI row shows the settled new numbers (scripts/screen_observer.c, its own self-test recorded); a
  second region (everything below the KPI row: chart and table) timed the same way, and whether both land in the
  same composited frame; the build's own stamp kept beside.
- Quiet gate before every run (load < 0.5, else < 2 after 2 minutes, recorded; GPU < 5 %; no other GPU process
  above 16 MiB), interleaved runs (ABCD, BCDA, CDAB), fresh launch, 2 warm-up + 20 measured passes at 100M (10 at
  10M), 300 ms idle before every step, step 0 between passes, reference.compare on every pass.
- Cold start screen-stamped: the whole window watched from before exec (its rectangle is fixed by the window rule);
  3 cold runs with the data file evicted from the page cache; A and B also with the browser already running.
- Memory: PSS of the whole process tree every 50 ms (servers, every Chromium process; the measurement drivers left
  out), GPU memory per pid outside timed steps.
- Effort counted by the script from git.
