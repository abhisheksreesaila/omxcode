# Build A: plain JS + DuckDB-WASM

The goal 38 dashboard (../SPEC.md) all in the browser. How it is set up and why: the top of `app.js` (the table is
stored day descending / id ascending at load, so zone maps prune date ranges; 100M uses the compressed in-memory
database and the threaded coi bundle, 4 threads; `ready` and timings.json record bundle, threads,
crossOriginIsolated and hardwareConcurrency).

- Build: `./build.sh` (npm packages, esbuild bundle, DuckDB-WASM's workers and wasm into `dist/`).
- Check: `pixi run python showcase-data/js-duckdb/check_a.py` (10M and 100M on the repo's Xvfb; prints `A: ok (…)`).
- Bench: `check_a.py --bench 100M` (JSON).

## Driven from outside (the shared harness)

Launch (run `./build.sh` once first):

```
DATA_BENCH_CHROMIUM=/usr/lib/chromium/chromium \
DATA_BENCH_CHROMIUM_FLAGS="--ozone-platform=wayland --enable-features=Vulkan --use-angle=vulkan --ignore-gpu-blocklist" \
WAYLAND_DISPLAY=wayland-2 \
pixi run python showcase-data/js-duckdb/external.py --rows 100M --out DIR [--control-port 0] [--warm-browser]
```

- Chromium: binary and flags from `$DATA_BENCH_CHROMIUM` / `$DATA_BENCH_CHROMIUM_FLAGS` (shell words; a bare `--app`
  is dropped, the driver adds `--app=<url>`). Unset: `/usr/lib/chromium/chromium` with the four Wayland flags above
  when `$WAYLAND_DISPLAY` is set. The driver always adds a private profile under `--out`, `--remote-debugging-port`,
  `--window-size=1280,800`, `--no-first-run`, `--no-default-browser-check`, `--password-store=basic`,
  `--disable-extensions` and the three no-throttling switches (unless the flags set them). Nothing reads `$DISPLAY`;
  `--headless` (checks only) uses the repo's Xvfb and check_a.py's X11 flags.
- Tested 2026-10-28 on a private headless Hyprland (screen_observer.HeadlessHyprland, RTX 3090): Chromium runs
  natively on Wayland (`xwayland: false`) with the four flags, WebGL on ANGLE/Vulkan; answers match the reference.
- stdout lines: `browser <json>` (only with `--warm-browser`: Chromium is up on about:blank; send `open` to load the
  page, whose cold start then excludes the browser's launch); `ready <json>` once step 0's dashboard is on screen
  (setup, `kpi_rect`, `control_port`, the Chromium command); `shown N <ms> <json>` after the frame that shows step N
  (ms: the page's change → that frame; json: `query_ms`, `fold_ms`, `render_ms`); `kpi <json>`; `error <text>`;
  `bye` last.
- Commands, one per stdin line, or HTTP with `--control-port P` (0 picks one; `ready`/`browser` name it):
  `POST http://127.0.0.1:P/step/N`, `/kpi`, `/open`, `/quit`, replying with the result's JSON after the frame.
  - `open`: with `--warm-browser`, load the page.
  - `step N`, N = 0 … 32: steps.json's state N (0 = the opening state) applied through its control (the full state is
    set, so any order works; step 0 re-runs the query without an event).
  - `kpi`: the KPI row's rect now (after the harness resizes the window).
  - `quit`: write `answers.json` and `timings.json` to `--out` (every step applied, in order, step 0 first), close
    Chromium and the server. EOF on stdin is `quit` unless `--control-port` was given.
- KPI region (`kpi_rect`, window logical pixels, `[x, y, w, h]`): the three KPI tiles (rows, sum, margin), not the
  query-time tile beside them, which changes every step. Measured in the page (getBoundingClientRect plus the window
  frame's offset; with `--app` on Wayland the frame adds nothing). It depends on the window's width; send `kpi` after
  resizing to 1280 × 800.

The step is applied through CDP (`Runtime.evaluate`), so a harness timing from its own command also counts that local
hop (well under a millisecond).
