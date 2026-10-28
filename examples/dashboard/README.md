# The orders dashboard (goal 38, build D)

showcase-data/SPEC.md's dashboard in omxcode + omxcore: 100M orders read by MX frame, sorted by day at load, put on
the GPU once; every change recomputes the KPIs, the top-20 products and the newest 50 rows from the date range's rows
(mojoui.tableprep, mojoui.devgroup, mojoui.devrows). The window is GTK, mojoui components only, in omxqua.

```
scripts/build.sh dashboard linux                         # build/dashboard/linux/dashboard
pixi run build/dashboard/linux/dashboard --rows 100M     # the app (data/orders-100M.parquet; make it with showcase-data/make_data.py)
pixi run python showcase-data/omxcode/check_d.py         # correctness at 10M and 100M: "D: ok (10M)", "D: ok (100M)"
```

## Driven from outside (the shared harness)

```
pixi run build/dashboard/linux/dashboard --scripted-external --rows 100M --out DIR
```

(or `DASH_EXTERNAL=1`; `--rows 10M` for the small file; run from the repository's root, where `data/` and
`showcase-data/steps.json` are.)

1. It opens the file and shows the opening state (steps.json's step 0). Stdout says `dashboard: first dashboard <ms>`
   when that is first drawn.
2. Then it waits. Each line `step N` written to its stdin applies steps.json's full state N (0 … 32) as if the
   controls had moved: the line is read on the GTK main loop as it arrives (`App.input_lines`, no polling), the work
   runs off the UI thread, and the next frames draw the new numbers. Steps may come in any order and repeat. A line
   that isn't a step is refused on stdout and changes nothing.
3. `quit` (or closing stdin) writes `DIR/answers.json` (SPEC's format, one entry per step shown, in the order asked)
   and `DIR/timings.json` (the app's own timings: change → frame, compute, group-by, rows), once the last step asked
   for is on screen, and exits 0.

It stamps nothing else: the harness times change → pixels by watching the screen. User input to the window is
ignored in this mode.

`--scripted --rows 100M [--steps S] [--out DIR]` is the self-driven mode check_d.py uses: it applies steps 1 … S on
its own, each once the last one's numbers are drawn, then writes the same two files and exits.
