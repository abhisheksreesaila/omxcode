# What waits for MX frame (the core engine, being built in its own project)

Owner, 2026-10-16: "use the existing [engine] for whatever your need is, but for things that you absolutely need MX
frame to support, log it or mark it and move on to the next feature."

The stand-in is `mojoui/frame.mojo` + `frame_gpu.mojo`: one table of typed columns, column formulas, a sparse
edit overlay with undo and value merges, GPU group-by/pivot with filters, radix sort, header histograms. That
covers MX Studio's Sheet and Report. These need MX frame and are skipped or stubbed until it lands
(the Mojo API wish list is `docs/mxframe-mojo-api.md`):

| Feature (MX_STUDIO.md) | Needs from MX frame | What the app does meanwhile |
|---|---|---|
| Query mode (A3, C4, C8): SQL cells, EXPLAIN | a SQL front end compiling to the plan IR; joins; HAVING; CTEs | mode switch says "next"; not built |
| Explore mode (A4, C3): pipelines of input → join → clean → formula → summarize → output, per-step previews, cached steps | joins, multi-table plans, step caching, fuzzy name matching as an operator | not built; the Sheet's merge is the one "clean" step, done in the stand-in |
| Reading real files (E2): CSV, Parquet, Arrow, XLSX | readers with type inference and bad-row reports | CSV and Parquet: done (the package's readers, omxplorer and the Workbook); Arrow and XLSX wait |
| A second table (Sheet's Insert → Table) | multiple tables and joins in one workbook | Insert Table explains it comes with Explore (D-116) |
| Versions, branches, diff, the time machine (C1, X) | versioned column chunks shared between versions | one undo log per session (edits and merges) |
| Data bigger than GPU or host memory (E8) | chunked, streamed execution (`docs/mxframe-mojo-api.md` §7a) | Parquet: done, streamed and editable (goals 20 and 22, `Frame(scan)`), on the GPU where AUTO finds it faster (goal 23, F-146); CSV still loads whole |
| The DuckDB test oracle and TPC-H (P3–P5, E5) | the engine those tests are for | the stand-in is checked against its own CPU path (GPU = CPU exactly) |
| Count distinct, percentiles, top-k, binning as engine operations (E5, C5) | aggregate operators | omxplorer: the Report's Distinct and Median tiles are the engine's `count_distinct` and `median` (goal 22); MX Studio's own histograms and top customers still use its stand-in engine; binning waits |
| CSV, Parquet, Excel and JSON readers (omxplorer's import, `mojoui/csvio.mojo`) | streaming typed readers | CSV and Parquet: the package's readers (F-138, goal 20); Excel and JSON wait |
| More than 16 columns in a table | wider row vectors / columnar GPU frame | done (F-138: 4,096) |
| Blank (null) numbers and dates: Delete on a number cell, empty cells in imports | nulls per column | done (F-138, D-170) |

## Done with the package (F-138, goal 20)

- omxplorer runs on the MX frame Mojo package (F-138: `vendor/mxframe.mojoc`): CSV import, nulls, BOOL columns, more
  than 16 columns, `.omx` files as Parquet.
- **Parquet files open** (goal 20, D-183): the package's `read_parquet`, through the same Import step as CSV.
- **Files bigger than memory** (goal 20, D-184, D-185): a Parquet file whose table is over a quarter of memory opens
  streamed with F-140's `scan_parquet`: the grid reads row groups from disk as they're shown, totals, charts, pivots
  and the Report are `Query(scan)` on the CPU, and the sheet is read-only. With MX frame 581250b (F-141–F-143: bulk,
  parallel and prefetched decode), 100M rows open in 0.4 s (a streamed total 0.44 s, a group-by 0.58 s) and peak at 0.18 GB.
- **no Python** in the framework (goal 20): the Workbook's files and the analytics showcase's engine are on the package.
- **Files bigger than memory are editable** (goal 22, MX frame 7cbcc04, F-147): a streamed sheet is `Frame(scan)`; typing,
  emptying, rows, formulas and Undo work, totals and charts include the edits, and Save streams the edited file out
  (`Frame.save`, 100M rows in 7 s at 0.25 GB); a document too big for memory reopens streamed. Sorting holds ~50 bytes a
  row, so it's refused when that wouldn't fit a quarter of memory. Measured at 100M rows: open 0.3 s, a total 0.29 s,
  a group-by 0.70 s.
- **Count distinct and median** (goal 22, F-148): the Report's Distinct tile (any column, text too) and Median tile are
  the engine's `count_distinct` and `median` (the mean of the two middle values), through the Report's filter, in
  memory and streamed. Percentile and top-k tiles aren't built yet.
- **The GPU for a streamed file** (goal 23, MX frame 1889b7f, F-146): a streamed sheet asks for AUTO, and the GPU's
  totals, charts and pivots over a streamed file with edits equal the CPU's. On this 12-core machine AUTO keeps the
  CPU, which is faster here (100M rows: a total 0.21 s on the CPU, 0.39 s on the GPU; a group-by 0.34 s and 0.44 s).
  The package picks the GPU when a plan's kernel instructions per row exceed 3 × columns read × cores (a plain total:
  on 2 cores; this app's group-by: not even there). Text sorts ignore case, bytes breaking ties (the owner's rule, MX frame's
  order everywhere).

## Still waiting (the package has none of these yet)

Query mode (SQL, joins, HAVING), Explore mode (multi-table plans), a second table, versions and the time machine,
Excel and JSON import, the DuckDB oracle. The package doesn't log formula columns in its undo history: the sheet does
(goal 22). The table above says what the app does meanwhile. MX frame's order (its session, 2026-10-18): M8, SQL and
joins (F-150 onwards: SQL over one table, the `mx` CLI, joins, a planner, FLOAT64, CTEs), then CSV streaming, versions. Ask it for things with a GitHub issue on
abhisheksreesaila/mxframe labelled `omxplorer`.

When MX frame's Mojo API is ready, the switch is one layer: `GridSource`, the ops modules
(`mojoui/orders_ops.mojo`, `orders_report.mojo`) and the Workbook's compute() call the engine; the components
(DataGrid, PivotTable, ChartView, KpiView, FindingCard) don't change.

**Wanted from goal 24 (2026-10-19):** a standard deviation (and variance) aggregate, CPU and GPU, streamed too: the
Report's Average tile would show "σ = …" in its footer as Stitch drew it (D-240); until then it reads "of N values".
Not filed as an issue yet (goal 24 stays inside this repo).
- (goal 49, 2026-11-04) Scalar `ROUND`, `FLOOR`, `CEIL` (and `ABS`): a script joining a 15 Hz log to a video's frames wants `ROUND(t * 15)`; today `CAST(x AS INT)` rounds to the nearest (as Postgres/DuckDB do), which is the workaround. Model functions (UDFs) callable from SQL would let `detect(frame)` sit inside a SELECT instead of its own statement.
