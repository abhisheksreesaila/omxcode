# Build B: plain JS page + FastAPI/uvicorn + Polars

The goal 38 dashboard (../SPEC.md) as the common web stack. How the server works and why: `server.py`'s docstring
(data in memory once, sorted by day descending so a date range is a slice and the table is the first 50 matching
rows; the group-by on Polars' streaming engine; orjson when installed; uvicorn with httptools and uvloop; /api/meta
says which). The page: `web/app.js` (one GET per change; timings split server compute, serialise + transfer =
fetch − compute, draw and paint).

- Check: `pixi run python showcase-data/py-polars/check_b.py` (10M and 100M on the repo's Xvfb; prints `B: ok (…)`).
  Chromium: build A's binary and flags (check_b.py FLAGS), through Playwright.
- Bench: `check_b.py --bench 100M` (JSON).
- Missing from the pixi env: **orjson** (FastAPI's ORJSONResponse needs it; `pixi add orjson` is the owner's call,
  this build doesn't touch pixi.toml). Until then responses use the standard JSONResponse and `json` in timings says
  `json (orjson not installed)`. httptools 0.9 and uvloop 0.22 are installed and used.

## Driven from outside (the shared harness)

```
DATA_BENCH_CHROMIUM=/usr/lib/chromium/chromium \
DATA_BENCH_CHROMIUM_FLAGS="--ozone-platform=wayland --enable-features=Vulkan --use-angle=vulkan --ignore-gpu-blocklist" \
WAYLAND_DISPLAY=wayland-2 \
pixi run python showcase-data/py-polars/external.py --rows 100M --out DIR [--control-port 0] [--warm-browser]
```

The same driver as build A's (`external.py`, the same Chromium handling and protocol), except the app is server.py,
started as its own process (a child of the driver, so the process tree's PSS includes it). With `--warm-browser` the
server starts on `open`, so that cold start covers the data load but not the browser's launch.

- Chromium: binary and flags from `$DATA_BENCH_CHROMIUM` / `$DATA_BENCH_CHROMIUM_FLAGS` (shell words; a bare `--app` is
  dropped, the driver adds `--app=<url>`); unset: `/usr/lib/chromium/chromium` with the four Wayland flags above when
  `$WAYLAND_DISPLAY` is set. Always added: a private profile under `--out`, `--remote-debugging-port`,
  `--window-size=1280,800`, no first-run UI, no extensions, no throttling. Nothing reads `$DISPLAY`.
- Tested 2026-10-28 on a private headless Hyprland (RTX 3090): native Wayland (`xwayland: false`), answers match.
- stdout: `browser <json>` (`--warm-browser` only), `ready <json>` (file, load_ms, json/http/loop libraries,
  polars threads, `kpi_rect`, `control_port`), `shown N <ms> <json>` (`server_compute_ms`, `fetch_ms`,
  `serialise_transfer_ms`, `draw_ms`, `paint_wait_ms`), `kpi <json>`, `error <text>`, `bye`.
- Commands (stdin lines, or `POST http://127.0.0.1:P/step/N`, `/kpi`, `/open`, `/quit` with `--control-port P`):
  `open`; `step N` for N = 0 … 32 (0 = the opening state; the full state is set, any order works); `kpi`; `quit`
  (answers.json + timings.json to `--out`, step 0 first, then close Chromium and the server). EOF = `quit` unless
  `--control-port` was given.
- KPI region (`kpi_rect`, window logical pixels, `[x, y, w, h]`): the three KPI tiles, not the "Server · round trip"
  tile (it is written a frame after the numbers). It depends on the window's width: send `kpi` after resizing.
