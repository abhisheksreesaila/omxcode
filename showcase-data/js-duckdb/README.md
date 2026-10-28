# Build A: plain JS + DuckDB-WASM

The goal 38 dashboard (../SPEC.md) all in the browser. How it is set up and why: the top of `app.js`.

- Build: `./build.sh` (npm packages, esbuild bundle, DuckDB-WASM's workers and wasm into `dist/`).
- Check: `pixi run python showcase-data/js-duckdb/check_a.py` (10M and 100M, headless; prints `A: ok (…)`).
- Bench: `check_a.py --bench 100M` (JSON).

## Driven from outside (the shared harness)

```
pixi run python showcase-data/js-duckdb/external.py --rows 100M [--out DIR] [--control-port 0] [--headless]
```

Starts serve.py, opens Chromium (`/usr/lib/chromium/chromium`, check_a.py's flags: `--ozone-platform=x11
--enable-features=Vulkan --use-angle=vulkan --disable-vulkan-surface --ignore-gpu-blocklist`, …) at 1280 × 800 on
`$DISPLAY` (`--headless`: the repo's Xvfb display), the page at `?rows=…&scripted=external`. Nothing changes until
told to.

- stdout: `ready <json>` once step 0's dashboard is on screen (setup: bundle, threads, crossOriginIsolated, load and
  sort times, `control_port`); `shown N <ms> <json>` after the frame that shows step N's numbers (ms: the page's
  change → that frame); `error <text>`; `bye`.
- stdin: `step N` applies steps.json's step N through its control (the full state, so any order works); `quit` writes
  `answers.json` and `timings.json` (step 0 first, then the steps in the order applied) to `--out` (default
  `out/external/`) and closes Chromium. EOF is `quit` unless `--control-port` was given.
- HTTP (with `--control-port P`, 0 picks one and `ready` names it): `POST http://127.0.0.1:P/step/N` and `/quit`; the
  reply is the step's timing JSON, sent after the frame that shows it.

The step is applied in the page through CDP (`Runtime.evaluate`), so a harness timing from its own command to pixels
also counts that local hop (well under a millisecond).
