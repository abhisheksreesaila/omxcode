# Goal 38 M5: the shared measurement harness

`scripts/data_bench.py` measures the four builds with one protocol (its docstring is the full protocol);
`scripts/screen_observer.c` is the external screen observer; `scripts/check.py` m5 checks the results. Results land
here as `results.json` + `results.md` (generated from the JSON); the observer's self-test as `observer.json`.

```
pixi run python scripts/data_bench.py plan          # the schedule and its expected length (~1.5 h at N = 20)
pixi run python scripts/data_bench.py selftest      # headless: the harness on a fake build (--full: protocol shape, ~9 min)
pixi run python scripts/screen_observer.py live     # is the desktop live (unlocked)? opens a probe window ~1 s
pixi run python scripts/screen_observer.py selftest # the observer against the compositor's presentation feedback
pixi run python scripts/data_bench.py calibrate B   # one build on the desktop: its window and KPI region, as pictures
pixi run python scripts/data_bench.py run           # the measurement (waits at the quiet gate)
```

## The display: a separate headless Hyprland (default since 2026-10-28)

The owner is travelling and their session is locked (a locked session presents no window: the probe's commits were
all discarded), so `run` starts **its own Hyprland** (`screen_observer.HeadlessHyprland`) and stops it after:
- as the owner's user, no root: libseat's `noop` backend (logind is never asked, so the owner's session 2 is never
  touched), `AQ_DRM_DEVICES=/dev/dri/card1` (the RTX 3090 at 2f:00.0, which has no monitor; the owner's monitor is on
  card2), `HYPRLAND_NO_SD_VARS` (their systemd/dbus environment is left alone), Xwayland off, no autostart (so no
  lock or idle daemon), the cursor invisible (a headless output has no cursor plane: it was drawn into the frames);
  the input devices aren't readable by this user, so it sees no keyboard; its DRM backend finds no connected
  connector on card1, so it never modesets;
- its own socket (`wayland-2`, never `wayland-1`) and instance signature; every `hyprctl` names that instance; apps get
  `WAYLAND_DISPLAY` of it and **no `DISPLAY`** (nothing reaches the owner's X server);
- a virtual `HEADLESS-1` output, 1920 × 1080 @ 60 Hz, scale 1; GPU-rendered: "NVIDIA GeForce RTX 3090", OpenGL ES 3.2
  NVIDIA 610.57.04, EGL/GBM on renderD128 (from its log, recorded in results.json);
- results.json's `desktop` block says it is a headless GPU compositor, not the physical monitor, and a caveat says so
  (no scanout: the 60 Hz is the compositor's timer). `--display desktop` measures on the owner's live desktop instead.

## The observer

A small wlr-screencopy v3 client (`scripts/screen_observer.c`, ~400 lines of C, built by `screen_observer.py` with
the system's `cc`, `wayland-scanner` and libwayland-client into `build/observer/`; the protocol XML is vendored beside
it). It captures **only the KPI row's region** of the compositor's output (`capture_output_region`) with
`copy_with_damage`: the compositor hands it one copy per composited frame that has damage, so it runs at display rate
without a polling timer. Each frame comes with the compositor's timestamp ("the time at which the presentation took
place") and is hashed (FNV-1a over the region's pixels); the harness matches frames to injected changes by hash.

Why this one (Hyprland 0.56 on Omarchy, checked 2026-10-28): grim is one process and a full-output PNG per shot
(tens of ms each); wf-recorder and wl-screenrec aren't installed; gpu-screen-recorder, OBS and the PipeWire portal
encode video (frames delayed and lossy) and the portal asks for a selection; `ext-image-copy-capture-v1` is offered
too, but it copies whole outputs or windows, where a region copy is 1/10 the readback.

Measured so far (the session was locked, so on the lock screen's own 60 Hz repaint; region 1280 × 120 logical =
2048 × 192 pixels):
- frames every 16.67 ms median (p95 16.72, 180 of 180 frames in 3 s): every composited frame, at display rate;
- the timestamps are CLOCK_MONOTONIC (they agree with ours to a few ms), so they compare with the harness's injection
  stamp directly;
- each frame reaches the observer 4.3 ms (median; p95 4.4) after its timestamp: the copy's cost, which the harness
  does **not** add to latencies (it uses the timestamp).

On the headless Hyprland (`screen_observer.py selftest --headless`, 2026-10-28 16:20, load 13.7 from other agents;
region 120 × 40 px; docs/goals/38/observer.json): **120 of 120 probe flips seen**, each found by the expected pixel
hash of its new colour; the observer's timestamp is **0.50 ms before** the compositor's own `wp_presentation` time
for the same commit (median; p95 0.36 ms before, worst 6.8 ms before: the copy is taken while the frame is rendered,
just before it is presented); it reaches the observer 0.07 ms after that presentation (p95 0.21); frames every
16.66 ms under continuous change (p95 17.2). So latencies are reported to the observer's timestamp, about half a
millisecond earlier than presentation, the same for every build.

The self-test itself: `screen_observer.py selftest` flips a probe window's colour 120 times
at random phases and compares the observer's timestamp for each flip with the compositor's own `wp_presentation`
feedback for that commit (the observer's error, which should be 0 when both name the same frame), its delivery
delay, missed flips, and the probe's commit → present latency with the observer off and on (its cost to the
compositor). `run` repeats the self-test first and records it in results.json.

Resolution: one composited frame (16.7 ms at this monitor's 59.97 Hz). Every build pays the same wait for the next
frame; a latency is the time to the compositor's presentation of the first frame that shows the step's settled KPI
row, so differences below a frame are noise.

## Driver contract (what the harness needs from each build): all four meet it (2026-10-28)

| | needed | A | B | C | D |
|---|---|---|---|---|---|
| launch (direct, no `pixi run`) | `--rows`, `--out` | `python external.py` | `python external.py` (server.py its child) | `target/release/dash --scripted-external` | `build/dashboard/linux/dashboard --scripted-external` |
| `ready <json>` | after step 0's dashboard is drawn | ✓ | ✓ | ✓ | ✓ |
| `shown N <ms> <json>` | the build's change → frame; its compute figure | ✓ `query_ms` | ✓ `server_compute_ms` | ✓ `compute_ms` | ✓ `compute_ms`, `gpu_ms` |
| `step N`, N = 0 … 32 | step 0 re-applied (untimed) between passes | ✓ | ✓ | ✓ | ✓ |
| `quit` → answers.json, `bye` | every step applied, in order | ✓ | ✓ | ✓ | ✓ |
| KPI row | `kpi_rect` in `ready` or a `kpi` command after the resize | ✓ both | ✓ both | ✓ both | ✓ `kpi_rect` (+ `results_rect`) |
| Chromium (A, B) | `DATA_BENCH_CHROMIUM(_FLAGS)` | ✓ | ✓ | – | – |
| `--warm-browser` (A, B) | `browser` line, page on `open` | ✓ | ✓ (server starts on `open`) | – | – |

Calibrated 2026-10-28 on the headless Hyprland at 10M (`data_bench.py calibrate X`, pictures in
build/data_bench/calibrate-X-10M/): every window at 1280 × 800, the KPI rects frame the three KPI tiles (A, B leave
out their timing tile), the region below them holds the chart and the table.

## Shortcuts each build takes (stated in results' caveats too)
- All four sort the rows by day at load (SPEC allows it; the time counts in each load).
- A: the table stored day desc / id asc, so DuckDB's zone maps prune the date range and its top-N stops early; KPIs
  and chart in one statement.
- B: the date range is a slice of the day-descending frame; the newest 50 by a hand-written growing-window search at
  the slice's start (round 2); group-by on Polars' streaming engine; orjson.
- C: the newest 50 by a hand-written tail-window search (not plain Polars; its README has the plain forms' numbers).
- D: the cut-off day for the newest 50 from the per-day histogram its GPU group-by makes; amounts as integer cents
  (a deliberate data-model choice; the others keep float64); a finished job wakes the UI at once (mojoui.jobs, a
  framework feature).

## Measuring changes after the first runs
- Chromium's flags: `--enable-features=Vulkan` dropped (Chromium can't composite with Vulkan on Wayland: the window
  never updated on screen); A and B both run `--ozone-platform=wayland --use-angle=vulkan --ignore-gpu-blocklist`.
- Windows open at their final place and size (a window rule in the headless compositor's config), so the cold start
  is stamped by the screen: the whole window watched from before exec.
- A step counts only after its KPI row changes on screen (a build's `shown` line can come before the compositor
  presents that frame).

## Before the full run
1. Done: every build's driver meets the contract; `BUILDS[…]["cmd"]` filled in from each README.
2. Done: `docs/goals/38/fairness.md`, frozen (m5 requires it unchanged after the run).
3. `screen_observer.py selftest --headless` passes with no missed flips (it does now); one `calibrate` per build on
   the headless display, looking at its pictures. Browser builds must run Chromium on Wayland (there is no DISPLAY).
4. The quiet gate (load < 0.5, else < 2 after 2 minutes, recorded;
   GPU < 5 %; no other GPU process above 16 MiB) holds the run until then anyway.
