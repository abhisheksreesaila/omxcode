# The orders dashboard (goal 38, build D)

showcase-data/SPEC.md's dashboard in omxcode + omxcore: 100M orders read by MX frame, sorted by day at load, put on
the GPU once; every change recomputes the KPIs, the top-20 products and the newest 50 rows from the date range's rows
(mojoui.tableprep, mojoui.devgroup, mojoui.devrows). The window is GTK, mojoui components only, in omxqua.

```
scripts/build.sh dashboard linux                         # build/dashboard/linux/dashboard
pixi run build/dashboard/linux/dashboard --rows 100M     # the app (data/orders-100M.parquet; make it with showcase-data/make_data.py)
pixi run python showcase-data/omxcode/check_d.py         # correctness at 10M and 100M: "D: ok (10M)", "D: ok (100M)"
```

## Shortcuts and data-model choices (stated for the comparison)

- **Integer cents.** Amount and cost are converted at load from float64 to int64 cents (exact for this file: every
  value has two decimals, and the load checks each one comes back as the same float64). All filters and sums then run
  on integers: exact sums, and the integer GPU path. The margin is `(amount − cost) × 10^10 // amount` per row, summed
  in int64 (within 1e-10 of the float64 margin). This is a deliberate data-model choice, not something the SPEC asks
  for; a build on float64 does more work per row.
- **Rows sorted by day at load** (SPEC allows a reorder at load; ~1.3 s at 100M, counted in the load): a date range is
  a slice of rows found by two binary searches, and each change reads only that slice.
- **The newest-50 cut-off from a per-day histogram.** The one group-by pass groups by product × day, so it also yields
  how many matching rows each day holds. Walking those counts from the last day back finds the day where the newest
  50 begin, and only the rows of those last days are fetched and ordered (`mojoui.devrows.first_rows`). It is a
  hand-written shortcut for `ORDER BY day DESC, id LIMIT 50`, like build C's search, not a general row query (the
  engine has none on the GPU: docs/mxframe-needs.md #21).

## Driven from outside (the shared harness)

```
pixi run build/dashboard/linux/dashboard --scripted-external --rows 100M --out DIR
```

(or `DASH_EXTERNAL=1`; `--rows 10M` for the small file; run from the repository's root, where `data/` and
`showcase-data/steps.json` are.)

It speaks the harness's driver contract (docs/goals/38/README.md), one line each way:

1. It opens the file and shows the opening state (steps.json's step 0). Once that is drawn, stdout says
   `ready {"data_load_ms": …, "read_ms": …, "cents_ms": …, "sort_ms": …, "upload_ms": …, "first_dashboard_ms": …,
   "kpi_rect": [x, y, w, h], "results_rect": [x, y, w, h]}` (the load's own figures; `dashboard: first dashboard <ms>`
   comes just before it). `kpi_rect` is the KPI row and `results_rect` the chart and table beside it, in whole window
   points (logical pixels) measured from the window's top-left, as laid out at that moment (`mojoui.geometry.rect_of`
   on tagged views; GTK's `gtk_widget_compute_bounds` against the window). At 1280 × 800: `[2, 106, 1264, 115]` and
   `[2, 233, 1264, 553]`, checked against a screenshot.
2. Then it waits. Each line `step N` on stdin (N = 0 … 32, step 0 included) applies steps.json's full state N as if
   the controls had moved: the line is read on the GTK main loop as it arrives (`App.input_lines`, no polling), the work
   runs off the UI thread, and the next frames draw the new numbers. When the frame that draws them is painted, stdout
   says `shown N <ms> {"gpu_ms": …, "compute_ms": …}` (ms: the app's own change → that frame; gpu_ms: the group-by and
   the rows on the GPU; compute_ms: the whole job). Steps may come in any order and repeat. A line that isn't a step
   gets `error not a step: …` and changes nothing; a failed load or step prints `error <text>`.
3. `quit` (or closing stdin) writes `DIR/answers.json` (SPEC's format, one entry per step applied, in the order asked,
   step 0 first) and `DIR/timings.json` (the same in-app figures), once the last step asked for is on screen; then
   stdout says `bye` and it exits 0.

It stamps nothing beyond those in-app figures: the harness times change → pixels by watching the screen. User input
to the window is ignored in this mode. The data file and the window are the only things it opens; no child processes.

`--scripted --rows 100M [--steps S] [--out DIR]` is the self-driven mode check_d.py uses: it applies steps 1 … S on
its own, each once the last one's numbers are drawn, then writes the same two files and exits.
