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

## Driver contract (what the harness needs from each build)

The four builds expose an external-drive mode; the harness launches it with a command and speaks lines:

| | needed | A (2026-10-28) | B | C | D |
|---|---|---|---|---|---|
| launch | a command with `--rows`, `--out` | `external.py` ✓ | – | – | – |
| `ready <json>` | after step 0's dashboard is on screen | ✓ | | | |
| `shown N <ms> <json>` | after the frame that shows step N; ms = the build's own change → frame; json may carry its compute figure | ✓ (`query_ms`) | | | |
| `step N` | **N = 0 too** (the opening state: the harness re-applies it, untimed, between passes so every pass makes the same 32 changes) | ✗ steps 1–32 only | | | |
| `quit` | answers.json for every step applied, in order, step 0 first; then `bye` and close everything it started | ✓ | | | |
| Chromium (A, B) | the protocol's binary and flags from `DATA_BENCH_CHROMIUM` and `DATA_BENCH_CHROMIUM_FLAGS` (`--ozone-platform=wayland --enable-features=Vulkan --use-angle=vulkan --ignore-gpu-blocklist`, headed, `--app`) | ✗ check_a's X11 flags (`--disable-vulkan-surface`) | | | |
| `--warm-browser` (A, B) | start Chromium on about:blank, print `browser <json>`, open the page on stdin `open` (cold start without the browser launch) | ✗ | | | |
| `kpi_rect` | in `ready`'s json, `[x, y, w, h]` of the KPI row in window logical pixels at 1280 × 800 (else `calibrate` and BUILDS[…]["kpi"]) | ✗ | | | |

The harness passes `MOJOUI_HEADLESS=0`, `WAYLAND_DISPLAY=wayland-1`, `DISPLAY=:0`, floats each window to exactly
1280 × 800 logical pixels (Hyprland 0.56's Lua dispatchers, always naming the window), observes its KPI row, and reads
the browser's real command line back from /proc to prove A and B ran the same one.

## Before the full run
1. Every build's driver meets the contract above (B, C, D: their READMEs; A: step 0, the flags, `--warm-browser`,
   `kpi_rect`), then `BUILDS[…]["cmd"]` filled in from each README.
2. The fairness review in `docs/goals/38/fairness.md` (m5 requires it, and that it didn't change after the run).
3. `screen_observer.py selftest --headless` passes with no missed flips (it does now); one `calibrate` per build on
   the headless display, looking at its pictures. Browser builds must run Chromium on Wayland (there is no DISPLAY).
4. The scheduled full regression (22:00) finished: the quiet gate (load < 0.5, else < 2 after 15 minutes, recorded;
   GPU < 5 %; no other GPU process above 16 MiB) holds the run until then anyway.
