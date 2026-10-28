# Build C: Rust + Polars + egui/eframe (glow)

The goal 38 dashboard (../SPEC.md) as one native binary. The data side: `src/engine.rs` (Polars lazy; rows sorted by
day at load, so a date range is a slice; the group-by on Polars' streaming engine). The window: `src/main.rs`.

The table's "newest 50 matching rows" is a **hand-written optimisation**, not plain Polars: since the rows are sorted
by day, it searches a growing window at the slice's end for the 50 last matching rows, takes the earliest one's day,
and sorts only the matching rows from that day on. Build D has an equivalent shortcut (a per-day histogram that finds
the cutoff day), so C keeps its own (coordinator's fair-play decision, 2026-10-28). The plain Polars forms measured at
100M, for the record: sort + limit (top-k) median 96 ms, p95 2.3 s; filter + head(50) on a day-descending frame
median 65–91 ms, p95 466–711 ms.

- Build: `pixi run cargo build --release` **from this folder** (cargo reads `.cargo/config.toml` from the working
  directory: `target-cpu=native`, which D's Mojo compiler also uses by default; `ready` and timings.json say
  `target_cpu`).
- Check: `pixi run python showcase-data/rust-polars/check_c.py` (10M and 100M on the repo's Xvfb; prints `C: ok (…)`).
- Bench: `check_c.py --bench 100M` (JSON).
- Windowing: eframe with both the `wayland` and `x11` features; winit picks Wayland when `$WAYLAND_DISPLAY` is set
  (tested 2026-10-28 on a private headless Hyprland on the RTX 3090: `xwayland: false`), X11 only without it.

## Driven from outside (the shared harness)

```
WAYLAND_DISPLAY=wayland-2 showcase-data/rust-polars/target/release/dash --scripted-external --rows 100M --out DIR
```

(`--root` defaults to this repo; no `$DISPLAY` needed.)

- stdout: `ready <json>` once step 0's dashboard is on screen (rows, load_ms, cold_start_ms, target_cpu, `kpi_rect`,
  step 0's timing); `shown N <ms> <json>` after the end of the first frame that shows step N (ms: the change → that
  frame; json: `compute_ms`); `kpi <json>`; `error <text>`; `bye` when the window has closed.
- stdin, one command per line (no HTTP port): `step N` for N = 0 … 32 (0 = the opening state; the full state is set,
  so any order works, and a repeated state is recomputed); `kpi`; `quit` (or EOF): write answers.json and
  timings.json to `--out` (every step applied, in order, step 0 first) and close the window.
- KPI region (`kpi_rect`, window logical pixels = egui points, `[x, y, w, h]`): the row of three KPI cards. At
  1280 × 800 it is `[8, 80, 1264, 67.5]`; it follows the window's width (send `kpi` after resizing).
