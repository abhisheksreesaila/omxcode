# mojo-ui experiments log

A dated record of what was tried, what happened, and what it means. Newest first.

---

## Experiment: goal 42, Jot: omxcode keeps your data (2026-10-30)
**Setup:** branch goal-42-jot from main 49cbd8d, autopilot, checker docs/goals/42-check.py (M0–M6), GTK headless (Xvfb, cairo), the web in headless Chromium, the Mac built only.
**Worked:** `mojoui.sqlite` (prepared statements, transactions, errors, FTS5; tests/test_sqlite.mojo); `examples/jot` keeps notes in SQLite with an FTS5 index kept by triggers and searches as you type (p95 0.3 ms for the query over 10,000 notes, counts equal Python's FTS5); 10,000 notes seeded by a job in ~150 ms while the window painted (longest frame gap 33 ms); `FileSaver` (GTK save dialog, web download), `DropTarget(on_file=)` (GTK GdkFileList, web file drop), `App.closing()` (GTK close-request and shutdown, web session end, Mac terminate/close); new GTK steps `save:`, `dropfile:`, `quit`, and `gaps:` now shows the window and asks for a frame each frame; drive.py learned `save:` and `dropfile:`. Gallery: a Database section.
**Broke and fixed:** `mojo run` can't resolve sqlite3_* (JIT) → dlopen; a Database closed after its last use under a live statement → a shared connection; dlopen declared twice across hosts (GTK vs the std's, used by the web's Python module) → called by address; `gaps:` counted 0 frames without MOJOUI_TRACE/SHOT; M4 first passed without closing the window (GTK ignores closing an unrealized window) → fixed and the checker tightened; the web's download marker needed an OOB append and an observer that doesn't need a body.
**Review round 1 (PASS with should-fixes, fixed) and M6, the race (PASS):** at 1,000,000 notes native mojoui.sqlite beat SQLite-wasm + OPFS (opfs-sahpool) in Chromium: search p95 64.6 vs 165.8 ms (2.6×), cold open 66 vs 435 ms (6.6×), build 35.9 vs 56.6 s; same counts on all 200 queries, the same SQLite 3.53.4 (docs/goals/42/race.json). Fixed: the GTK host held back a field change during a rebuild instead of dropping it (examples/fieldcheck, tests/test_field_queue.py); `gaps:` forces frames only for untraced runs, so goal 30 M1 passes again (it had failed at 66.7 ms) and a deliberate 300 ms stall reads 317 ms both ways; the web takes several dropped files in one upload, each in its own folder; GTK dialogs and drops answer by message; the save dialog honours accept; sqlite text keeps embedded NULs; Jot refuses non-UTF-8 and >4 MB imports and clears its error line.
**Means:** the framework now keeps data: a database, background writes that don't freeze, files in and out, nothing lost on quit; all as library pieces another app uses as-is.
**Not verified:** GTK's real save dialog and a real file-manager drag (the checks hand in the path / file list); the web's quit hook runs on session eviction and server stop (tried by hand), not when a tab closes; the Mac (built, not run; no save dialog or file drop there); Android and iPhone don't build mojoui.sqlite yet; goal 30's checker wasn't re-run after the `gaps:` change.
**Next:** run JotMojo.app on the owner's Mac; NSSavePanel/NSOpenPanel; a "save changes?" answer for closing.
## Goal 40: Sketch, omxcode draws (2026-10-30)
- **Setup:** branch `goal-40-sketch` from main b79fc66, worktree ../mojo-ui-g40; contract docs/goals/40-GOAL.md, checker docs/goals/40-check.py (written first). The yardstick: Personal Note's canvas (ink with pressure, pan/zoom).
- **Worked:** `mojoui/ink.mojo` (a stroke as one outline polygon through every point, width from pressure or speed, an eraser hit test); `Painter.polygon` and `Painter.layer_transform` (the CPU painter fills polygons with 4 sub-scanlines, non-zero; GTK fills a GskPath and moves the kept layer); `Event.pressure` from GDK_AXIS_PRESSURE, the web's pen, the Mac's tablet; generic GTK test steps `stroke:`, `render:` and `framebench:`; examples/sketch (pen, eraser, three inks, undo, clear, pan, zoom around the pointer). GTK's canvas equals the CPU render (0.0 levels). Linux, web and Mac build. Pressure: only injected on GTK, not tried with a real pen on GTK or the web; the Mac is built, not run.
- **Broke and fixed:** the Mac link wanted `_atan2` (the round ends turn by rotation now). The first honest bench was 32 ms a frame: cairo re-fills every path of a kept render node each frame, and GTK's paint phase hid it (~0 ms; it draws only damage). A kept, moved layer is now drawn once into a texture and moved: p95 2.0 ms pan, 2.6 ms zoom, 1.8 ms draw with 1,000 strokes / 101,000 points.
- **Review round 1 (NEEDS WORK, fixed):** a plain or two-finger scroll now pans a canvas that asks (`Canvas(scroll_pans=True)`, gesture WHEEL; ctrl+scroll and pinch zoom; other apps keep zoom-on-scroll); the host counts builds per layer key (no "ink" in it); a texture past its 4096 px cap was re-rendered every frame (deepzoom 108 ms p95 → 9–26 ms over five runs, 0 renders); the frame a stroke ends in and an eraser's frames rebuilt all 1,000 strokes (36 ms) and now add to or mend the kept layer (finish max 3–7 ms, erase p95 14–23 ms, run to run on a loaded machine); M3 also counts far-off pixels and runs a second session through those paths; the gallery shows a deliberate page with readable active buttons.
- **Means:** drawing is a framework feature now, shown in the gallery's Drawing section. Unmeasured: a real pen on GTK (only injected pressures), the web and the Mac with a pen, GTK's GPU renderers.
- **Next small step:** run Sketch on the owner's Mac (build in build/sketch/mac); a Metal host for the layer transform.

## The Mac stops freezing on long jobs: job threads on Apple (2026-10-30)
- **Setup:** branch `mac-job-threads` from main 0d09024, worktree ../mojo-ui-macjobs. The owner: "at least the Mac has to be fixed".
- **Worked:** the engine already had a switch (`-D MXFRAME_JOB_THREADS`) that gives Apple builds job threads; it reaches into the prebuilt omxcore package (with it the Mac objects call pthread_create/join; without, none). scripts/build.sh passes it to every Mac build; the Mac stub gained five libSystem symbols. examples/jobwake now measures a freeze (one 1.5 s job, the longest gap between frames) and runs on the Mac runner. GitHub's Macs, before → after: 1 frame and 1516–1527 ms without one → 28–38 frames, at most 71–83 ms (jobwake now fails past 500 ms). omxplorer (imports and column stats are jobs) and maccheck exit 0 on both macOS versions. Reviewer round 1: checking a cancelled job's thread still blocked on the Mac (no pthread_tryjoin_np): now read from the engine's reference count, no wait. Linux: 90 frames, 17 ms.
- **Broke and fixed:** the first threaded run crashed in performSelectorOnMainThread on the job's thread: I released the autoreleased string `ns_string` returns, so the modes array held a freed string (D-792's comment says so now). The link also wanted `_sched_yield` (omxplorer).
- **Means:** slow data work no longer freezes the Mac window. A job's end reaches update() in ~35 ms median on those virtual Macs, against 0.05 ms on Linux: unmeasured on a real Mac.
- **Next small step:** the iPhone (jobs still serial, UIKit has no wake) once it runs on hardware; measure the Mac wake on the owner's MacBook.

---

## Components hold to best practice: an audit, and accessible names on every host (2026-10-30)
- **Setup:** branch `components-practices` from main a818aa8, worktree ../mojo-ui-components. The owner asked for a component-level best-practice audit (threads, state, lifecycle) to show the world, then the gaps fixed.
- **Worked:** the audit (docs/component-practices.md): one UI thread by construction, effects and job wake off it (goal 33, D-771), one-way data, no closures on widgets, deferred rebuilds, keyed diffing, virtualised lists, frame pacing, native widgets, themes apart from behaviour. New: `View.label()` and mojoui.a11y (one naming rule, `audit()`), applied on GTK (GtkAccessible label), the web (aria-label, a canvas is an img named by its words), AppKit and UIKit (accessibilityLabel). scripts/check_a11y.py reads the names back from GTK's test backend and Chromium's accessibility tree: PASS.
- **Broke and fixed:** on the web a canvas's words (tooltip) only reached the page when a new frame arrived: a chart whose picture didn't change kept its old words (now after every swap, window.mojouiWords). The iPhone stub lacked _memset_pattern16 (Surface.fill on Apple; the Mac stub had it since c3c15eb).
- **Means:** the gaps left are listed in docs/component-practices.md: real hardware for iPhone and the Android tablet, jobs on Apple's main thread, a chart's numbers for screen readers, Android names, RTL.
- **Next small step:** CI/CD on the owner's MacBook, iPhone and Android tablet, so the 🔨 cells become ✅.

---

## Goal 38: the 100M-row dashboard benchmark, merged into release 2026-10-29 with engine omxcore 834ef9a (2026-10-28/29)
- **Setup:** RTX 3090, 100M rows (a 4 GB table), four builds of one dashboard: A JS + DuckDB-WASM, B JS + FastAPI + Polars, C Rust + Polars + egui, D omxcode + omxcore; an external observer times input to pixels (scripts/data_bench.py; fairness rules docs/goals/38/fairness.md).
- **Worked:** D fastest to the screen: 30.3 ms median of medians, 49.1 ms pooled p95 (A 104.9, B 44.2, C 37.0); every pass equal to DuckDB's answer. New in mojoui for any app: job wake (D-771: a finished job reaches update() in 0.05 ms median instead of the next frame poll) and App.input_lines (D-770: an app driven over stdin). Full table: docs/data-benchmark.md.
- **Broke and fixed:** the job-wake pipe could block a job after 64 KB undrained (now non-blocking; tests/test_jobs.mojo hangs without the fix); a second fcntl signature broke httpcheck, agentchat and console (now http_socket's variadic form; lessons); after the engine merge the dashboard still said `from mxframe` (renamed, D-788); devgroup asked for 36,864 B of shared memory, over Apple's 32 KiB (now 3584 slots, D-789, tested at the edge).
- **Means:** omxcode wins the time to the screen at 100M rows; Rust wins memory and narrow-range changes (docs/benchmarks.md). The 100M numbers were measured on engine 3d2455d with 4096 shared slots, before the release's engine and devgroup changes; on the release only a provisional 10M run exists. Goal 30's M1 (open 100M in 3.5 s) failed twice under heavy machine load and needs a quiet rerun.
- **Next small step:** re-measure the 100M dashboard on the release build on a quiet machine.

---

## omxcore 834ef9a in omxcode (2026-10-29)
- **Setup:** branch engine-834ef9a from release-2026-10-29, its own pixi env; the package built from a clean `git archive 834ef9a` with Mojo 1.1; RTX 3090; GitHub Mac runs 40957099769 and 40959478762.
- **Worked:** the engine under its own name (vendor/omxcore.mojoc, `from omxcore`, D-783); the engine tests; omxplorer on GTK and the web at 1M (sample) and 100M rows, equal to pyarrow; goals 20 M1–M2, 29 M0–M4, 30 M0–M4, 32 M6 and goal 36's non-measured milestones PASS; the Mac GPU build runs omxplorer on the runner's Apple GPU; a fresh clone follows the README to a working app.
- **Broke and fixed:** an undone formula could come back (the engine logs formula steps since 2585dc9: D-784); gpu_audit couldn't size kernels bounded by the engine's new named limits (D-785); a fresh clone's `pixi install` failed on a committed `.pixi` symlink (D-786); mac-ci's GPU build had failed since goal 34b on a file its tarball lacked (D-787).
- **Result:** chart times equal 3d2455d's (1M: sum 0.5 ms, median 6.4 ms, month 5.8 ms). Report: docs/goals/engine-834ef9a/report.md.
- **Next small step:** the owner replaces the Mac release asset (report) and re-measures goal 36 when it suits.

## Goal 36 re-measured on the final regression sources (2026-10-29)
- **Setup:** branch particles-remeasure from regression-2026-10-28 with D-767's particles change (imports only mojoui), its own pixi env; RTX 3090, Mojo 1.1, Hyprland 0.56.2 (owner's desktop, D-735, the monitor turned on for the desktop runs and off after, owner's call), Chromium 152.
- **Worked:** results.json (Xvfb, 11779 s, gated), results-desktop.json (3800 s, gated), present-desktop.json (659 of 660 frames from the GPU, 0 readbacks), the page regenerated; goal 36 M0–M8 PASS; goal 5 M9 and goal 3 M6 PASS (no app imports outside mojoui/themes).
- **Broke and fixed:** goal 36 M6 allows exactly D-767's lines beside the GPU-canvas line (D-768). On the desktop JS + Rust/wasm's headed Chromium was capped at one refresh (16.674 ms at 1M–5M, every run; published 1.86/3.51 ms at 1M/2M), on an empty workspace too after one uncapped probe; not chased further (owner): the page labels it "capped (compositor)" and reads its speed from the virtual display (D-769).
- **Result (desktop frame ms 1M/5M/20M):** omxcode 1.28/1.63/3.13 (published 1.23/1.57/3.13), JS + WebGPU 1.29/1.33/3.01, Rust + wgpu offscreen 0.34/1.53/6.01. Scoreboard winners and ties unchanged except JS + Rust/wasm's "60 fps up to" cell (2M → capped).
- **Next small step:** the owner updates the site's scoreboard (list in the session report) and decides whether B-wasm's desktop cap is worth a hunt.

## Night regression (2026-10-28 → 29)
- **Setup:** a fresh worktree on origin/main b233357, its own pixi env; goal 36's check and every archived check back through goal 3 (via 35 → 34b → 34 → 33 → 32 → 30), three passes; GitHub Mac runs 40829521876, 40836799290, 40872704059.
- **Worked:** after fixes, goals 33 (M0–M8, the whole chain to goal 3), 34, 34b, 35 and goal 36's M0–M3, M5, M6b, M6c, M8 PASS.
- **Broke and fixed:** a web drag that lost moves (D-761); a stale matrix and three web rows lost with goal 34's CSS move (D-758, D-765); apps importing std (D-767); checks that needed older checkouts' files (D-755, D-762–D-766); goal 33's moving reference (D-760). D-579 and goal 33's round-2 should-fixes done.
- **Still failing:** goal 36 M4/M6/M7 (re-measure on the desktop), goal 32 M3–M5 (never passed), goal 32 M6 (an MX frame kernel can ask for 48 KB of shared memory on Apple's 32). See docs/goals/regression-2026-10-28.md.
- **Next small step:** the owner re-measures goal 36 with regression-particles-imports merged.

## Goal 36b: zero-copy presentation, measured on the real desktop (2026-10-28)
- **Setup:** RTX 3090 ×2, driver 610.57.04, GTK 4.22.4, Mojo 1.1, Hyprland 0.56.2 (owner's desktop, D-735), Chromium 152.
- **Worked:** a GPU Canvas picture reaches GTK with no GPU→CPU readback: CUDA copies it GPU→GPU into a GL texture (or blends into one), handed over as a GdkGLTexture; GTK's GL renderer (its Vulkan renderer downloads GL textures on NVIDIA). Generic in mojoui (mojoui/present.mojo, Surface's gpu fields, PointCloud, the GTK host); the particle app is unchanged. Hardware-blended points and lines from the app's own Mojo place/tint, equal to the compute splat byte for byte; a two-atomic splat.
- **Broke and fixed:** CUDA dmabuf export unsupported (801); GBM dmabuf into GTK's Vulkan aborts on the second GPU; GL stalls ~4.7 ms when it starts behind queued CUDA work (the host now waits once a frame); a blending/splat choice made on the first frames picked wrong (now the splat first, measured later).
- **Result (desktop, gated, frame ms 1M/5M/20M):** omxcode 1.20/1.57/3.10 (goal 36 on Xvfb: 5.33/5.74/7.63); JS + WebGPU 1.23/1.37/3.01; Rust + wgpu offscreen 0.34/1.52/5.98 (in a window: compositor-paced, 16.7). Zero-copy saved 4.4–4.8 ms, the packed splat up to 0.78, blending never won here. Goal 36's guess that the gap was GTK's software renderer was wrong: goal 36's path still costs 5.61 ms at 1M on the GPU-rendered desktop.
- **Next small step:** a fused step + draw pass (offered to every stack alike, fair play) is the lever left at 5M+.

## Experiment 35 (2026-10-27): AG-UI, agents that build the screen (goal 35)
- **Setup:** this worktree's own pixi env gained the official AG-UI Python SDK (ag-ui-protocol 1.0.0), anthropic, jsonpatch and jsonschema (the last two only as the checks' independent oracles).
- **Worked:** streams in mojoui.http (each SSE event its own Event, then the end; cancel; idle timeout; Transport.stream is the seam); mojoui.jsonpatch (RFC 6902, 37 cases agree with the jsonpatch library); mojoui.agui (every listed AG-UI event, five SDK-recorded streams read into the same conversation and state as an independent Python reading; RunAgentInputs valid by the SDK's models); mojoui.genui (one catalog → the render_ui JSON Schema, the validator, the native renderer; 24 cases agree with jsonschema); examples/agentchat on GTK and the web: streamed words, a chart and a form built by the agent, a button as the tool result, edits as state, refused UI reported to the agent. The live backend speaks the OpenAI-compatible API (the OMX Console by default, Claude optional) and repairs small models' tool JSON.
- **Broke and fixed:** a sparkline drew black on the web (fill the card first), the web capped a filling text field at 70vw (D-713), agent cards centred; Mojo aliasing errors in JDoc (copy a list element before a `mut self` call).
- **Means:** an agent can build native UI in a mojoui app as validated data, never code, through an open protocol. Unverified: a run against a real model (the checks use a stand-in server); the Mac.
- **Next:** the reviewer; a live run against the OMX Console by hand.

## Experiment 34 M3 (2026-10-27): the widgets app on GTK, each JS widget in a WebKitGTK view (goal 34)
- **Setup:** WebKitGTK 6.0 (GTK 4) isn't on conda-forge and needs root to install here: Arch's signed package, pinned by SHA-256, unpacked into build/ and laid over /usr/lib by a bubblewrap launcher (scripts/webkitgtk.sh, D-608).
- **Worked:** each WebComponent gets its own WebKitGTK view loading the web's bundles byte for byte and the same mojoui-widgets.js from mojoui://app with the web's CSP. Real typing (XTest) in CodeMirror reaches update(); the view survives partial and full rebuilds (one mount, keyboard kept); Load sample shows Mojo's text; counter clicks, props and a command's reply work; the boxes match the web's within goal 32's tolerance. eval, inline script, remote and file loads, popups and navigation are blocked; non-JSON or forged messages are refused.
- **Broke and fixed:** scripts didn't run (the response headers dropped the content type, and nosniff blocked them); JavaScriptCore took SIGUSR1 from the live report; a focused view lost the keyboard when a full rebuild moved it.
- **Means:** one widget runs unchanged on the web and on Linux. The cost is a 130 MB engine and one web process per widget.
- **Next:** the reviewer; then 34b (the Mac's WKWebView).

---

## Experiment 30 (2026-10-21/22): the island, and 100M rows that never freeze the window (goal 30)
- **Setup:** MX frame 23edc59 (`start_job`/`Job`: a query on its own thread, with progress and cancel); the island (D-255, direction B) in place of the document chip, the GPU chip and the toasts.
- **Worked:**
  - At 100M rows on GTK the window keeps drawing while the file opens (1.8 s), a median (0.77 s) and a median by month (3.3 s) run: the longest frame gap 33 ms. Each answer equals the in-place one; a second pick cancels the first; a removed chart or another file drops the old jobs.
  - `mojoui/island.mojo`, a component with its own test: five faces, a 320 ms morph on the calm curve, hit areas; GTK and the web draw it alike. omxplorer's panel shows Recent and Device (p50, p95).
  - The 100M clip (docs/img/clip-island-100m.mp4): the island changes in every frame for 3.6 s straight.
  - `scripts/package.sh`: a Linux tarball and a Mac zip; the owner ran the Linux one (screenshots: pivots and the inspector).
- **Broke and fixed:**
  - The agent host sent no frames, so jobs polled on frames never landed (D-283). Cancelled jobs were dropped while their thread still ran; three reviewer rounds to "kept until joined" (D-284).
  - A test run hung 15 minutes, twice, never alone: the GTK test waits turned the main loop blocking, and once the island stopped asking for frames nothing woke it. /proc showed it (ptrace isn't allowed here): main thread in poll, zero wake-ups in 20 s. `pump()` and a check that fails on a blocking turn (D-286).
  - Earlier goals' checks looked for the toast and the GPU chip: they read the island now (D-287). omxplorer had imported the engine directly: Job comes through mojoui again (goal 5's rule).
- **Means:** background work changes when a window sleeps; every wait in a test needs a deadline it can actually read.
- **Next:** goal 31: tiles that snap (charts and pivots, never over the table), inspector labels that never truncate, bars that switch without a jitter; then the omxcode rename goes public (owner's yes, 2026-10-21).

---

## Experiment 29c (2026-10-21): clips, two ask fixes, the public alpha
- **Setup:** the launch needed moving pictures of omxplorer; the owner approved the posts and the name omxapp.
- **Worked:** `scripts/clips.py` records two clips over 1M rows: the native window (ffmpeg on the private headless display, real XTest typing through `scripts/live.py`) and the browser (Chromium's screencast). Stills beside them. Release `v0.1.0-alpha` on GitHub with both clips attached.
- **Broke and fixed:** recording found the ask's reply still saying "by month of day", and "every month" not understood; the first fix for the second broke "amount every month" (caught by the reviewer, round 2 PASS). Tests first in tests/test_chartask.mojo.
- **Means:** recording a real session is a test too: it found two bugs no check had.
- **Next:** the owner posts the X thread and the forum post (no access from here); goal 30, background queries and the island.

---

## Experiment 29b (2026-10-21): polish from goal 29's screenshots
- **Setup:** the owner's five notes on goal 29's shots (docs/next.md §2).
- **Worked:** "by month" without the column's name when there's one date column; an ask's reply said once (status bar); a chart's time once (its card); the "$" note was a column without a currency format (now a guard test).
- **Broke and fixed:** a chart filling its row broke goal 15's chart-and-pivot layout: reverted, left to the owner. A `pgrep -f` cleanup killed its own shell: stop-check now stops the displays.
- **Means:** small text fixes stay cheap because every earlier goal re-runs; layout changes run into old goals' pinned positions.
- **Next:** clips and screenshots of omxplorer for the launch; the owner's yes on the posts.

---

## Experiment 29 (2026-10-20): charts that ask the new engine more (goal 29)
- **Setup:** MX frame 321870f (STABLE.md: SQL, expressions, median and quantiles per group), vendored by the engine job.
- **Worked:**
  - The sentence says Median and p90 ("median by region", "p90", "90th percentile"); number conditions ("only paid and over 5,000", "qty between 2 and 4", "at most 10") from the ask and the Rows page; a date's month, quarter or weekday ("by month of day"), every month of the span in calendar order.
  - 6 + 8 + 4 specs equal pyarrow's; dates before 1970 and centuries away read right; documents keep it all and refuse what they can't use.
  - At 1M rows every chart kind fits a 60 Hz frame (≤ 6.2 ms); at 100M a median takes 0.67 s and a month chart 0.48 s.
- **Broke and fixed:** a fraction on a whole-number column was rounded; a second number condition replaced the first quietly; a full run built a half-edited file.
- **Means:** the chart sentence now covers what people ask a dashboard first; the slow cases at 100M rows need the engine's background queries.
- **Next:** goal 30: MX frame 23edc59 (background queries, range aggregates, block reads): a UI thread that never waits.

---

## Experiment 28 (2026-10-19): editing a chart by its sentence (goal 28)
- **Setup:** the owner's pick from the chart prototypes: "the title is the query: ask, then tap any word".
- **Worked:**
  - A chart's title is its settings as a sentence of tappable words (mojoui.sentence); each opens its choices; an ask field rewrites several at once (mojoui.chartask: keywords and the table's own names); inspector pages (NavRow, InspectorPage); bars move to a new spec; Undo per chart change, in order with table edits; GTK and the web, sheet charts and Report tiles.
  - 12 specs equal pyarrow's; real input (XTest) clicks a word, picks with the keyboard, types an ask, Ctrl+Z.
- **Broke and fixed:** Undo after Add row crashed (old); picking scrolled the sheet; popovers had no keyboard; a plain line read cents; message ranges overlapped; typing rebuilt the sentence and lost Return; a new document kept the old one's chart edits.
- **Means:** the sentence is a small query language a person can read and an agent can write; the next step is MX frame 321870f (median per group, months, ranges).
- **Next:** goal 29: vendor MX frame 321870f, move chart/report/pivot queries onto its builder.

---

## Experiment 27 (2026-10-19): the core sheds its themes; polish; the Scene by default (goal 27)
- **Setup:** owner: "the best looking, best polished UI… components native by default; themes opinionated, on top; anybody can add their own; don't tightly couple… then a list of what you need from MX frame".
- **Worked:**
  - `mojoui/` names no theme: an app hands its hosts a `Theme` (classes, palette, GTK and web style sheets) built by `themes/` (Liquid, the skins, Fluent, Omarchy, Paper). No theme = libadwaita / the system's web look, light or dark with the system (`App.appearance`).
  - 42 screens pixel-identical across the move (proven from a build of the move's own commit). Paper, a theme written outside the core, switches live in examples/themes.
  - Polish: 12 findings fixed (web dialog, sidebar rows, one GPU chip, neutral charts without tracks, one-line report toolbar, titled inspector, the web's primary picker, compact labels).
  - The Scene is GTK's default; `docs/mxframe-needs.md` lists 19 operations, ranked.
- **Broke and fixed:** layout rules hidden inside a theme sheet (D-262); a dialog's width on its scrim; native kept a forced dark scheme; archived checks read theme code from the hosts (D-263); goal 5's import rule (D-264).
- **Means:** the framework is a language plus native widgets; a look is a module anyone can write. Next: chart editing (goal 28) on this base, and MX frame's off-thread queries for smoothness on big files.
- **Next:** owner reviews the MX frame list (file the issues?), runs scene-bench.sh; goal 28.

---

## Experiment 26 (2026-10-19): the grid on the GPU as a display list; the owner's four; the brand (goal 26)
- **Setup:** owner: "super fast… liquid… or else Rust guys will win". Bar: 120 fps, ≤ 2 ms main-thread work a frame, no grid repaint when only the ring moves; plan B is our own renderer, never a lower bar.
- **Worked:**
  - The Scene (`mojoui/scene.mojo`): one `Painter` interface, pixels or a display list with layers. GTK replays it as GskRenderNodes and reuses unchanged layers; text through Pango, cached.
  - 2800×1400, 1M rows: scroll 15 ms → 0.8 ms p95 a frame; glide 15.5 ms → 0.2 ms; 0 cells rebuilt while the ring moves; 0 textures uploaded. Pixel-identical to the pixel path (non-text).
  - The owner's four (drag follows the cursor, preview scroll bar, inspector hairlines, ✕ on hover) and the brand (Logo 1, indigo / green / red per screen).
  - M0–M5, M7, M8 PASS; reviewer PASS on round 3.
- **Broke and fixed:** the selection's tint inside the cells layer rebuilt every cell per glide (own layer now); fills blended (OP_FILL); bench windows weren't presented without MOJOUI_SHOT; the web drew the logo SVG at 100 px and hid the File menu (sized SVG, M8 fit check).
- **Means:** the grid's frame cost is no longer the bottleneck on GTK. The same list maps to Metal/Core Animation and the web canvas; the other drawn views (charts, preview) can move next.
- **Next:** owner runs scripts/scene-bench.sh (M6); goal 27 chart editing ("the title is the query"); goal 28 the glass-pill island.

---

## Experiment 25 (2026-10-19): omxplorer feels native: partial rebuilds, the window's size, calm motion (goal 25)
- **Setup:** the owner used goal 24's build on a 3440×1440 screen at 1.6× (window 1742×876): multi-select unreliable, toolbar not straight, bottom bar off screen, "not smooth", "is it implementation?".
- **Worked:**
  - Measured first (MOJOUI_TRACE, real XTest input via scripts/live.py): every shape change rebuilt the whole window and killed drags.
  - A reconciling diff (pairs children by kind/style/tag) and GTK partial updates with stable widget ids: a column change builds 1 widget in ~1 ms; stacks, grids and Boards update in place.
  - App.resize on GTK and the web; size patches; omxplorer fills any window. Inline toolbar tools; calm motion; controlled fields.
  - M1–M7 PASS (with every earlier goal); reviewer PASS (round 3 + a final pass).
- **Broke and fixed:** the window grew 8 pt per resize (the layout asked for exactly its width); spacers expanded across their stack; the inspector's grow took half the width; alerts weren't closed by partial updates; the cell editor on the Board rebuilt the grid and lost the keyboard (goal 14); iOS and Android links got getenv/clock symbols from the runtime's trace; goal 9's formula field kept its text (controlled fields); a list built during a partial update was refreshed at once (goal 4's row count).
- **Means:** smoothness was the update model, not Mojo or GTK. The next lever is rendering (goal 26: a display list on the GPU, layers for motion).
- **Next:** goal 26, the Scene spike on GTK.

---

## Experiment 24 (2026-10-18/19): omxplorer polished: Liquid, motion, blocks of cells (goal 24)
- **Setup:** the owner's screenshots of the real app ("looks like an intern app"); Stitch and Claude drafts of a Liquid skin; the owner picked Stitch's.
- **Worked:**
  - Liquid as a framework design on GTK and the web: glass islands, one type scale, spring transitions and arrivals.
  - The selection ring glides (`Surface.again`, about 12 frames of 5 ms on GTK).
  - Blocks of cells: drag, Shift+click, Shift+arrows, Cells/Count/Sum/Average, Bold as one Undo step, Copy through a new `Clipboard` view.
  - Stitch's details: menu-bar chips, yes/no pills, stat cards, tile footers.
  - M1–M7 PASS; reviewer PASS on round 3 (`docs/report.md`).
- **Broke and fixed:**
  - A submenu row was a GtkMenuButton that picked up the skin's bordered button rule.
  - Same-specificity CSS lost to later rules.
  - The web's grid columns weren't equal.
  - Message 41 fell inside the Recent range.
  - A status bar whose item count changed rebuilt the screen on every move.
  - A whole-number column before a decimal one summed in the wrong units.
  - Earlier goals' checks counted canvases and read the report's subtitle exactly: kept compatible (D-241).
- **Means:** what the screen looks like and how it moves now come from the framework, so the next apps (AG-UI, a video editor) start polished. GTK can't blur behind glass; the Mac's own glass waits for its host.
- **Next:** AG-UI generative interfaces on this baseline. Goal 25 (MX frame dc1a722, SQL) belongs to the mxapp-e6 session.

## Experiment 23 (2026-10-18): the GPU for streamed files (goal 23, MX frame 1889b7f)
- **Worked:** streamed sheets ask for AUTO; the GPU's answers over a streamed file with edits equal the CPU's; on 12 cores AUTO keeps the CPU (faster here: 100M total 0.21 s vs 0.35 s). Text order pinned (case ignored, bytes break ties). M1–M3 PASS (`docs/report.md`).
- **Broke and fixed:** a streamed column's cached total survived a switch to the GPU (now keyed by device); a failed chart's error was overwritten; the inspector always said "the GPU".
- **Next:** a usability and smoothness goal for omxplorer (asked the owner), then MX frame's SQL and joins when vendorable.

---

## Experiment 22 (2026-10-18): files bigger than memory become editable; Distinct and Median tiles (goal 22, MX frame 7cbcc04)
- **Setup:** MX frame 7cbcc04 (F-147 editing over a scan, F-148 count distinct / median / percentile / top-k, F-145/F-149 faster streaming), vendored from `git archive`.
- **Worked:** a streamed sheet is the package's `Frame(scan)` (goal 20's own row-group cache deleted): typing, emptying, rows, formulas, Undo, totals and charts with the edits, a streamed Save (100M rows in 6 s, 0.27 GB peak), big documents reopen streamed; sort, median and distinct guarded by memory; Report tiles for Distinct and Median from the engine. 100M streamed: open 0.2 s, total 0.21 s, group-by 0.55 s. M1–M4 PASS (`docs/report.md`).
- **Broke and fixed:** a "file changed" warning cleared by cached reads (now only a fresh read clears it); Count tiles of text lost on reopen; Undo didn't take back formula columns (the sheet logs them now), then took one from under a chart (now refused, saying what reads it); M4 found the README's link to `docs/report.md` dangling while the goal ran.
- **Means:** omxplorer has no read-only mode left; the engine's memory costs (sort, median, distinct) are now the limits users meet, and they say so.
- **Next:** goal 23 on MX frame 1889b7f: the GPU for streamed files.

---

## Experiment 21 (2026-10-18): omxplorer's formatting, tabs at the bottom, a toolbar per tab (goal 21)
- **Setup:** the owner tried a 1M-row Parquet file and asked for Excel's formatting, renamable tabs along the bottom, and controls that follow the tab.
- **Worked:** cell and column styles (bold, italic, underline, strikethrough, eight text and fill colours, alignment) drawn by the grid on every host, kept in `.omx`, undone in order with edits; Currency/Percent/decimals in the toolbar; bottom tabs renamed in place; the Report's tiles and filter in its own toolbar. omxapp gained `cellstyle`, `swatches`, `Toggles`/`ICON_ON`, `BottomTabs`, an italic slant. M1–M4 PASS (`docs/report.md`).
- **Broke and fixed:** Inter Medium as "bold" was invisible at 13 px (drawn twice now); GTK named icon toggles by their tooltip (goal 17's parity check caught it); after a screen change the web left the keyboard on a stale button, not the grid (goal 14 caught it); the page outgrew 900 px.
- **Means:** the old checks' GTK-vs-web comparisons keep catching real host differences: keep them.
- **Next:** goal 22 on MX frame 7cbcc04: editing a streamed file, count distinct and median in the Report.

---

## 2026-10-18 · Experiment 20: omxplorer on what MX frame can do now: Parquet, files bigger than memory, no Python (autopilot, night)

**Goal:** owner: "once its in main, please continue with tickets that depends on mxframe - and proceed on autopilot." After F-138 put omxplorer on the MX frame Mojo package, build what `docs/plans/needs-mxframe.md` waited for that the package can now serve.

**What worked:**
- **Parquet files open** in omxplorer through the same Import step as CSV (the package's `read_parquet`), checked against pyarrow through the agent host: rows, kinds, empty cells, sum and average.
- **Files bigger than memory:** a Parquet file whose table is over a quarter of memory opens *streamed* (MX frame F-140's `scan_parquet`): the grid reads row groups from disk as they're shown (the last few kept, capped by bytes), totals, charts, pivots and the Report run as `Query(scan)`. 100,000,000 rows open in about 4.5 s and the process peaks at 0.16 GB for a 4 GB table; rows 73 million down, the sum, the average, a chart and a pivot equal pyarrow's. Read-only, and it says so.
- **No Python left in the framework:** the Workbook's files go through the package and `mojoui.json` (a workbook pyarrow saved still opens), and the analytics showcase's "MX frame" engine is a package `Query`.
- An agent reads a chart's numbers (`App.describe` for chart canvases).

**What broke and how it was fixed:** see docs/journal.md: the package built from a clean `git archive` (MX frame's checkout had unfinished work); three review rounds (a streamed column looked like a formula; a trait method without a default broke two test stand-ins; a failed disk read was drawn as zeros and not shown); goal 3/5's "apps import only the framework" check had been failing on main since F-138, fixed in the app.

**Not verified:** the Mac and iPad builds of the streamed path (Linux and web only here; the package's scan is CPU code, nothing platform-specific); a real file from outside (the checks use pyarrow-written files).

**What it means:** omxplorer can open a file bigger than the machine's memory and answer questions about it in seconds, with no Python anywhere in the app. What still waits is the engine's: SQL and joins, a second table, versions, distinct/percentile operators, the GPU for streamed files, faster Parquet decode (F-141).

**Update, same night:** MX frame 581250b (F-141–F-143) re-vendored: 100M streamed rows open in 0.4 s (was 4.3 s), a streamed group-by takes 0.58 s (was 7.5 s).

**Next small step:** the GPU for a streamed file (one row group at a time on the device), or editing over a scan, both in MX frame first.

---

## 2026-10-17 · Experiment 19: the agent host: every omxapp app as MCP tools (autopilot, evening)

**Goal:** the owner asked how omxapp becomes agent-native. The answer: the agent is a fifth host. `mojoui/hosts/agent.py` is an MCP server over the same `mojoui_app` module the web host serves; the screen's tree becomes tools (tags, tooltips, menu paths), plus `screen`, `act`, `read` and `render`. Contract: `GOAL.md` (goal 19). Report: `docs/report.md`. Artboards: `docs/design/agent/boards.html`.

**What worked:**
- **The kit and omxplorer, driven by a scripted MCP client** (`scripts/agent_client.py`): File > Save by name, a dialog's radios and checkboxes as tools while it is open, a `secondary` gesture that opens the context menu whose items become tools, a PNG of any canvas, omxplorer's grid rows as text through the new `App.describe` (a default on the trait: no other app changes).
- **The tool list follows the screen:** `notifications/tools/list_changed` after every call; disabled items are not tools. An agent can do nothing a person couldn't.
- **One command for Claude Code:** `scripts/agent.sh <app>` prints `claude mcp add …`. The matrix has an Agent column.

**Not verified:** no LLM has driven it yet (the checks never call one); the next session points Claude Code at omxplorer.

**What it means:** every app written with omxapp is agent-driveable the day it is written, on every platform, with no per-app work. AG-UI (generative UI, shared state) waits for MX frame: the operations log is its state.

**Next small step:** a real agent session on omxplorer; tag the untagged buttons it stumbles on.

---

## 2026-10-17 · Experiment 18: omxapp on the iPad: the kit app, the UIKit and AppKit hosts (autopilot, evening)

**Goal:** the owner's definite target is iPadOS; MX frame is still cooking. So: the kit app (`examples/kit`, every component on one screen) runs on GTK and the web, and the UIKit and AppKit hosts catch up with everything omxplorer's screens use: menus and shortcuts, context menus, popovers, dialogs, toasts, checkboxes, tooltips, Board, Overlay, button styles, tones, the canvas gestures and hardware keys, the skins and the bundled fonts. Contract: `GOAL.md` (goal 18). Report: `docs/report.md`.

**What worked:**
- **The kit app** on Linux and the web, driven by the check (menus, Ctrl+S, a right-click menu, a dialog, a toast with Undo, a popover, checkboxes, a Board drag, a skin switch), identical dumps, light and dark.
- **The UIKit host** builds every kind, links, bundles and signs for iPad with only the allowed symbols; Info.plist allows every iPad orientation and multitasking; the fonts ship in the .ipa.
- **The AppKit host** builds every kind, with the app's menus in the system menu bar and ⌘ shortcuts; links, bundles and signs.

**Not verified:** none of the Apple builds has run. Every Apple cell in `docs/components.md` is 🔨 (built, never run). The owner runs them at the weekend; `docs/journal.md` lists what to look at first.

**What broke and how it was fixed:** see `docs/journal.md` (a `ref` invalidated by building a child; file IO that doesn't compile for Apple targets; the archived checker's ROOT).

**What it means:** the day the Apple builds run, omxplorer's screens have their native pieces on the iPad; what's left for omxplorer there is MX frame (no Python) and D-151's own-drawn chrome.

**Next small step:** the owner's weekend run; then fix what it shows, and goal 16's polish.

---

## 2026-10-17 · Experiment 17: omxplorer's universal theme and the components it needs (autopilot, afternoon)

**Goal:** one fixed look for omxplorer on every platform (Claude's Ledger by default, Graphite and Blueprint as skins; `docs/design/universal/kit.html`), and the components the kit showed were missing: a menu bar, menus and context menus, keyboard shortcuts, dialogs, toasts, popovers, tooltips, checkboxes, grid badges. Contract: `GOAL.md` (goal 17). Report: `docs/report.md`.

**What worked:**
- **Skins:** `Palette.ledger/graphite/blueprint` with the kit's exact tokens; GTK CSS and web CSS generated from the same palette; a live switch from Settings (the hosts reload their CSS when `design()` changes); the skin kept in `settings.txt`.
- **Fonts:** Inter and JetBrains Mono vendored (OFL), baked for canvases, handed to fontconfig on GTK and served to the browser: the same type everywhere.
- **Menus:** `MenuBar`, `Menu`, `Item`, `Submenu`, `ContextMenu` (mojoui.menus) on GTK (popovers of flat buttons) and the web (positioned divs); shortcuts (Ctrl+S…) from anywhere; a right-click gesture (SECONDARY) on canvases.
- **Overlays:** `Dialog`, `Toast`, `Popover`, `Checkbox`, `.tooltip()` (mojoui.overlays) on both hosts; omxplorer's Settings, About, sort toast with Undo, toolbar tooltips, ƒx help.
- **Grid:** a type badge per column and a corner mark on edited cells, read back from pixels.
- **Start screen** in the Ledger with the menu bar.

**What broke and how it was fixed:** hx-vals inheritance (again) sent a menu's close instead of its item; a message number collided with the recent-files range; a test step iterated the view it was replacing; `H4` unimported. See `docs/journal.md`.

**What it means:** the kit's "in the app" screens exist for real on Linux and the web, from one Mojo model; the remaining gap is the command palette, the Import dialog's streaming (MX frame), the filter popover and the phone sheets.

**Next small step:** goal 16's polish (sheet tabs left, hairlines between toolbar groups, the Σ total row), then own-drawn controls on Mac/iPhone/Android (D-151) once the Apple builds run on hardware.

---

## 2026-10-17 · Experiment 15: omxplorer's charts, pivots and Report (autopilot, night)

**Goal:** Stitch 05 and 06. Charts and pivots go on the sheet, and a Report is built from scratch. Contract: `GOAL.md` (goal 15). Report: `docs/report.md`.

**What worked:**
- **Charts and pivots:** Chart and Pivot place a GPU group-by beside the table in the column's format, and a tapped bar reads its total. Objects move and resize, and the inspector regroups or restyles them.
- **The Report:** Sum, Average, Count and chart tiles, with one filter that recomputes every tile.
- **Documents:** `.omx` keeps the objects and the Report, checked by kind on open.
- **Checks:** every number on both hosts is checked against Python's csv module.

**What broke and how it was fixed:**
- Free-space placement scanned in steps and missed the spot that fit.
- Two buttons were both named "Chart".
- Mojo can't move single fields out of a struct here.
- Two review rounds caught:
  - an Average tile rounded to whole numbers
  - a Count check the inspector could satisfy
  - documents naming wrong-kind columns
  - pivot rows hidden by sum
  - ID collisions
  - a clear that didn't refresh the tiles
  - a test that couldn't fail

**Next:** more Report filters (quarter, product), a column chart and a date axis, and Stitch 05's type picker and inspector tabs. Then rung 2, data in 3D.

---

## 2026-10-17 · Experiment 14: omxplorer, the data app from scratch (autopilot, night)

**Goal (owner's words):** "I should be able to install this Linux app, load some data from CSV… use it from scratch"; "follow [Stitch], the classic design"; "this product will be called [omxplorer]… all small case"; "load one million… then try 10, 50, 100 million". Contract: `docs/goals/14-omxplorer.md` once archived. Report: `docs/report.md`.

**What worked:**
- **The flow:** omxplorer (`examples/omxplorer`) goes Start → choose a CSV → review its columns → a Numbers-classic sheet. The sheet has a toolbar, sheet tabs, formula bar, grid, format inspector and status bar. Formats are currency, percent, compact and dates, with decimals, separators and negatives. You can add formula columns and rows, sort, and save and open `.omx` files (one Parquet file).
- **New omxapp components:** TOOL buttons, FilePicker, Inspector, sheet chrome, number formats, the CSV reader, `.omx` files and `mojoui.files`.
- **Scale:** 100M rows: import 106 s on a loaded machine, sort 3.7 s, format change 54 ms, GPU sum 19 ms.

**What broke and how it was fixed:**
- **Mojo 1.1 gaps:** there's no `memcpy` (libc's is used), and its `mkdir` declaration clashes with the stdlib's (`std.os.makedirs` is used).
- **Layout:** a `Board` needs its own height, or the grid doesn't show.
- **A formula column's GPU sum read garbage** until `Frame.flatten` inlined formulas into stored-column steps.
- **Memory at 50M+ rows:** custom date parsers and numpy temporaries thrashed memory (the owner's other work had 32 GB in swap). The fix: default parsers, Arrow kernels, and one column at a time.
- **Three review rounds** made weak checks real and validated `.omx` files before they reach memory. They also fixed averages, formatting edges, upload and dialog hygiene, and a failed open that left the sheet on freed memory.
- **A stuck System UI dialog on the emulator** is now closed by the Android driver.

**What it means:** the component library carries a real product. The app is wiring, and the next screens (charts, pivots, Report) reuse what's there.

**Next:** goal 15. Insert a chart and a pivot onto the sheet (Stitch 05), and build a Report page from scratch (Stitch 06).

---

## 2026-10-16 · Experiments 11–13: MX Studio's Sheet and Report, and spreadsheet keys (autopilot, night)

**Goal (owner's words):** "the killer app is the data transformation app… primarily focused on Linux and Web"; "ask yourself, okay, what component do I need, then build the component… then go back and build the app"; "go for it and make me proud". Contracts: `docs/goals/11-mxstudio-sheet.md`, `12-mxstudio-report.md`, `GOAL.md` (13). Reports: `docs/goals/11-report.md`, `12-report.md`, `docs/report.md`.

**What worked:**
- **Goal 11, MX Studio's Sheet:** a 2M-row planted ledger. DataGrid, PivotTable and ChartView came out of the Workbook into `mojoui/`. A finding merges three spellings of Acme in one undoable step.
- **Goal 12, the Report:** KpiView, FindingCard, line markers and Heatmap. A GPU anomaly finder (heavy parcels in the West lost 7.66 margin points after Jul 14, Carrier A's freight to $14.20) checked against the CPU. One engine with the Sheet: merges reach the Report, and "Open the rows" filters the Sheet.
- **Goal 13, keys:** `KEY` events on any `Canvas(keys=True)`, `TextField(on_cancel=)`, `.echo()`, and DataGrid's Excel keyboard. It runs on both apps and both hosts. Fast data entry works even against a slow server.

**What broke and how it was fixed:**
- **Goal 12's regressions:** MX Studio's local imports broke goal 3's purity rule (they moved into mojoui), and with no theme file the accent wasn't Tokyo Night's.
- **Goal 13's review, five rounds:** the typed text lived in two places and keys raced between them. The fix gave the grid sole ownership (D-132), plus a page-wide event queue on the web.
- **Checks that couldn't fail:** a slow test server and real GTK focus on the private display made them able to fail.
- **A worktree's own Android debug key:** the emulator refused its APKs, so the worktree uses the main checkout's key.
- **Process mistakes, both now in `docs/lessons.md`:** running an archived checker directly, and `pgrep -f` killing my own shell (now `scripts/stop-check`).

**What it means:** the component library carries the apps. The grid, its keyboard, KPIs, findings and charts are framework pieces with their own tests, and both apps are mostly wiring. Everything MX Studio still needs that isn't in MX frame is listed in `docs/plans/needs-mxframe.md`.

**Next:** MX Studio's Explore and Query (they need MX frame's Mojo API), cell formatting (`docs/plans/formatting.md`), or keys and the new components on Android.

---

## 2026-10-16 · Experiment 10: the Workbook (autopilot, overnight)

**Goal (owner's words):** "a spreadsheet where you can edit rows… but also a report and a dashboard built on the same engine"; Numbers-style, "you can place tables and you can place charts, everything is free flowing"; columns instead of Excel's cells, on purpose. Contract `GOAL.md`, report `docs/report.md`, walkthrough `docs/morning.md`.

**What worked:** `mojoui/frame.mojo` (typed columns shared per process, a session's edits as a sparse overlay, formula columns compiled to a small bytecode with a column-level dependency graph, tombstones, sort permutations, undo); `mojoui/frame_gpu.mojo` (group-bys whose key, value and filters are chosen at run time, 0.8–1.9 ms on 20M rows, exact; pivots; edits applied as deltas); the Workbook app (`examples/workbook`): a table grid over 20M rows, a pivot, two Flint charts with crossfiltering, a note, all on a `Board` (a new container: absolute positions, drag by the header, resize by the corner, snap to 8 pt; a list on narrow windows), identical on GTK and the web; workbook files (JSON + Parquet); `App.init_shared()` so every web tab shares one GPU copy of the rows (the analytics app too). The wasm spike: Mojo's LLVM IR retargeted to wasm64 plus a 25-line C shim runs List/String/print code in Chromium (`docs/wasm.md`).

**What broke and how it was fixed:** a `SIMD` vector used as an interpreter stack segfaults the compiler (stack_allocation instead); the first GPU interpreter took 23 ms (a row vector in local memory) until columns were read directly and the stack moved to registers; GTK test taps landed on a 0×0 canvas before the first layout (the steps now wait for layout and the first draw); Mojo has no global variables (the shared registry lives in the process environment); a struct holding a Frame can't be partly moved (out-parameters). See `docs/journal.md`.

**Next:** the MX frame Mojo API (`docs/mxframe-mojo-api.md`, items 13–22) so the workbook runs on the Mac; a real allocator for wasm and a client-side host; AI column types; the drag-and-drop chart editor.

---

## 2026-10-15 · Experiment 9: the analytics showcase (autopilot)

**Goal (owner's words):** "the analytics part… the poster child… really polished"; Flint as the common chart language; MX frame; a gallery on GitHub. Contract `GOAL.md`, report `docs/report.md`.

**What worked:** Contoso Retail (`examples/analytics`): 20M rows re-aggregated per click (GPU 5.9 ms, MX frame 114 ms, CPU loops 746 ms; equal to the cent); charts declared as Flint specs, drawn natively by mojoui and also valid through Flint → Vega-Lite → SVG; crossfiltering by tapping charts, identical on GTK and the web; Fluent 2 controls; fits 1440×900 and 1280×800. New in mojoui: canvas text (baked Noto Sans), drawing + charts, Flint specs, exact GPU group-by, an MX frame engine. Gallery page; MX frame Mojo API spec.

**What broke and how it was fixed:** misread Flint as Fluent (corrected, D-76); GPU atomics contention (shared-memory totals); GTK picture natural size; dark-theme cards; hinted glyph advances; cents in Flint's chart. See `docs/journal.md`.

**Next:** Flint island on the web; Mac after the MX frame Mojo API; notebook editor; Ask your data.

---

## 2026-10-15 · Experiment 8: Android (autopilot)

**Goal (owner's words):** "one code compile and you get for everything"; the Java listener approved; SDK installed and licences accepted by the owner. Contract `GOAL.md`, report `docs/report.md`.

**What worked:** Mojo drives Android's own views through JNI (function-table slots from jni.h); one 78-line framework Java file; signed APKs for arm64 phones and x86_64 emulators. On the Android 16 emulator, with real input: hello, gallery and todo end in the same state as GTK; goal 5's layout rules hold; the Data Lens runs (CPU, 2M trips) and a real swipe pans it like GTK.

**What broke and how it was fixed:** the root's fixed width; slider taps on the thumb; Apple-only clock symbol; option-id collisions; edge-to-edge drawing on Android 15+; MAX release functions pulled in by freeing the app. See `docs/journal.md`.

**Next:** a real phone; goal-4 components on Android; MX frame.

---

## 2026-10-15 · Experiment 7: GPU Data Lens (autopilot)

**Goal (owner's words):** "a real fancy app which takes advantage of GPUs… same code base which builds a web and a Linux and later a Mac app." Contract `GOAL.md`, report `docs/report.md`.

**What worked:** a Canvas view (the app paints it in `draw()`, gestures and per-frame events come back as events) on GTK, web, AppKit and UIKit; `mojoui.gpu.PointCloud` bins 20M points into a 1080p frame in 1.48 ms on the RTX 3090 (CPU 132 ms, identical pixels); Data Lens runs at 59.2 fps on GTK and streams at 59.9 fps to Chromium; Mac/iPhone build and sign on the CPU path (not run).

**What broke and how it was fixed:** web readiness probe started 20M-point sessions; web fps measured through a start-up gap and unpaced pulls; GTK first draw before the window manager tiled the window; empty test steps didn't report; the lens imported std.math (now `mojoui.maths`). Probes: no wasm target in Mojo 1.1; `std.atomic`; Apple GPU code compiles out; CGPoint returns in d0/d1. See `docs/journal.md`.

**Next:** MX frame columns into PointCloud; galaxy/deep-zoom showcases; Android (Java shim, after the owner accepts Google's SDK licence); Apple GPU.

---

## 2026-10-15 · Experiment 6: layout as a thin layer (autopilot)

**Goal:** flexbox-named layout settings mapped onto each platform's own layout (ROADMAP decision 10). Contract `GOAL.md`, report `docs/report.md`.

**What worked (`scripts/check` 11/11):** padding, width/height, min/max width, grow, fill, align and justify on every view, measured on GTK and in Chromium (same geometric relations within 1.5 pt). Pocket Expenses and todo use them; field and list widths measured equal to their columns. Apple: NSStackView/UIStackView + Auto Layout (builds and signs; not run).

**What broke and how it was fixed:** web grow wrapped rows; web Scroll was a row; GTK fixed width was only a minimum (AdwClamp); wrapping labels squeezed; built-in control widths fought app layout on every host (now preferences that yield, direction-aware); a test window caught the owner's keystrokes (test windows ignore input). See `docs/journal.md`.

**Next:** the owner's Apple results; Android route.

---

## 2026-10-15 · Experiment 5: components real apps need + Pocket Expenses (autopilot)

**Goal (owner's words):** "continue with 2–4, 8, then … until 9 … and build a fancier app for all platforms." Contract: `GOAL.md`; report: `docs/report.md`.

**What worked (`scripts/check` 11/11):** Segmented, Radio, TextArea, Alert, Tabs, NavBar, DatePicker, Icon, Grid and LazyList, on GTK, web, AppKit and UIKit (Apple ones build and sign; not run on hardware). Kitchen-sink and Pocket Expenses examples are identical on GTK and in Chromium. A 10,000-row list keeps 30 rows in the web page.

**What broke and how it was fixed:** Mojo frees buffers after their last use (GtkTextIter); htmx attribute inheritance (twice); same-named radio groups; GTK `items_changed` refresh ignored; GTK alert Escape; web alert keyboard. See `docs/journal.md`, `docs/lessons.md`.

**Next:** the owner's Apple results; bottom tab bar and push navigation on iPhone; controls inside list rows.

---

## 2026-10-15 · Experiment 4: web, components, a real todo, GPU, Android (autopilot, overnight)

**Goal (owner's words):** "render the web… build all the components… a todo list… the same declarative code in Mojo runs on all of them… try Android… an app that's great on GPUs." Contract: `GOAL.md`; report: `docs/report.md`.

**What worked (`scripts/check` 9/9):**
- **Web:** FastHTML + HTMX host; the Mojo app runs inside Python as an extension module (`PythonModuleBuilder`). Plain HTML controls; htmx vendored. Tested in headless Chromium (Playwright + system Chromium).
- **Components:** `Event(message, text, number)`; TextField, Toggle, Dropdown, Slider, ProgressBar, Divider, Scroll, Image on GTK, web, AppKit and UIKit (iOS dropdown = menu button with a hand-built Objective-C block; images via a PNG encoder written in Mojo).
- **Todo app:** one `app.mojo`; the same 13 test steps on GTK and in Chromium end in identical states; builds and signs for Mac + iPhone.
- **GPU:** `mojoui/gpu.mojo` runs a plain Mojo function per pixel as a GPU kernel (MAX 26.6): 480×320 Mandelbrot on an RTX 3090 in ~0.1 ms vs ~15–80 ms CPU, pixel-identical; degrades gracefully with no GPU.
- **Android:** apps compile for aarch64-linux-android; the todo app links into a 37 KB `libmojoui.so` (NativeActivity entry, only libc + liblog).

**What broke and how it was fixed:** GTK re-entrancy vs Mojo's exclusive `mut self` (busy flag moved into GTK); rebuilding inside a signal handler (deferred to idle); web lost a task on instant Return (shared HTMX queue + submit carries the text); htmx inherits hx-vals (typing counted as Return); no-GPU crashed in DeviceContext (device count first). Details: `docs/journal.md`.

**Not verified yet:** Mac and iPhone on real hardware; Android drawing/taps (needs a decision + Google's SDK licence: `docs/android.md`).

**Next:** run on Mac/iPhone; choose the Android route.

---

## 2026-10-15 · Experiment 3: declarative Mojo UI, rendered natively (autopilot)

**Goal (owner's words):** "All I want is Mojo declarative code and then it's rendered natively on all the platforms." Contract: `GOAL.md`.

**What worked (`scripts/check` 7/7):**
- `mojoui`: `VStack`/`HStack`/`Text`/`Button`/`Spacer` build a flat node tree; `App` trait (`view()`, `update()`); a diff turns each update into in-place patches or a rebuild.
- Three native renderers from the same tree: GTK4 + libadwaita (Linux), AppKit (Mac), UIKit (iPhone). One `app.mojo` per example, importing only `mojoui`.
- **Linux runs here:** the checker taps the real GtkButtons and reads the real GtkLabels; screenshots rendered by GTK (`docs/img/`).
- Mac and iPhone: compile, link and sign from the identical app file; only Apple system functions; entry `_mojo_entry`.

**What broke and how it was fixed:** recursive `View` not allowed → flat nodes; `App` needs `Deinitable`; borrow checker caught a held reference during recursive builds; a new runtime function (`KGEN_CompilerRT_fprintf`) → Mojo stand-in. Details in `docs/journal.md`.

**Not verified yet:** running on a real Mac and iPhone.

**Next:** run on hardware; then text input, scrolling lists, images; web host.

---

## 2026-10-14 · Experiment 2: Mac and iPhone apps written only in Mojo (autopilot)

_Later moved: `apple/objc.mojo` and `apple/mojo_rt.mojo` now live in `mojoui/hosts/`; the hand-written apps were replaced by the declarative hosts (Experiment 3)._

**Goal (owner's words):** "Create a Mojo app for macOS which I can test, then do it for iOS. Mojo all the way." Contract: `GOAL.md`; decisions: `docs/decisions.md`; step-by-step: `docs/journal.md`.

**Setup:** Linux x86-64, Mojo 1.1.0 via pixi (`pixi.toml`), `ld64.lld` from conda-forge, `rcodesign`, xtool (not signed in).

**What worked (all verified on Linux by `scripts/check`, 6/6 PASS):**
- Mojo drives AppKit and UIKit directly through the Objective-C runtime: `apple/objc.mojo` casts `objc_msgSend`'s address to a typed C function per call (the same trick Mojo's own `_DLCallable` uses). Button handlers are `abi("C")` Mojo functions added as methods to classes created at run time.
- No Swift, C or Objective-C anywhere in `apple/`. Entry point via the linker's `-e _mojo_entry`; the three Mojo runtime functions are written in Mojo (`apple/mojo_rt.mojo`), so no Modular runtime library ships.
- Linked on Linux with `ld64.lld` + `.tbd` stubs (`apple/sdk/`). Mac app ≈ 70 KB, loads only AppKit, libobjc, libSystem; iPhone app loads only UIKit, libobjc, libSystem.
- Machine code checked: rects travel in d0–d3 like Apple's NSRect-by-value; no x18, no thread-locals, no static initialisers.
- Ad-hoc signatures verified by our own hash checker (`scripts/verify_signature.py`), since `rcodesign verify` fails on ad-hoc signatures.

**What broke and how it was fixed:** see `docs/journal.md` (runtime functions must be in their own Mojo file; `@export("main")` is refused; printing floats pulls in `KGEN_CompilerRT_fprintf`; linker's own signature left stray bytes).

**Not verified yet:** running either app. Needs the owner's Apple Silicon Mac (copy `build/mac/HelloMojo-mac.zip`) and iPhone (`apple/install_iphone.sh`). See `apple/README.md`.

**Next:** run both on real hardware and record the result here.

---

## 2026-10-14 · Prep for M5 step 3: iPhone from Linux via xtool (not yet run)

**Why:** xtool (github.com/xtool-org/xtool) builds, signs and installs Swift-package iOS apps from Linux, WSL or Windows onto a real iPhone. Combined with a SwiftUI skin, it removes the need for a Mac and for porting SDL3 to iOS.

**What was prepared (all on Linux):**
- `bridge/mojoui_bridge.c` now keeps the last text Mojo sends, readable via `mui_last_text()` / `mui_last_text_len()`. Desktop M0 still passes (`scripts/m0_linux.sh`, clean build, all 5 steps).
- `ios-xtool/Mojo/ios-device/libmojoapp.a`: `app_entry.mojo` for iPhone (`platform ios`); `ios-simulator/libmojoapp.a` for the simulator (`platform iossimulator`). Built with `mojo build --target-triple … --emit object` + `llvm-ar rcs --format=darwin`.
- Exports: `_mojo_app_init`, `_mojo_app_event`, `_mojo_app_quit`. Still needs from outside: the two `KGEN_CompilerRT_Aligned*` functions (covered by `kgen_shim.c`), our `_mui_echo`, and standard C (`memcpy`, `write`, `fflush`, `fdopen`, `fclose`, `dup`).
- `ios-xtool/` Swift package: `MojoBridge` C target (bridge + shim, links `libmojoapp.a` via `-L` + `linkedLibrary`) and a `HelloMojo` SwiftUI target.
- The C glue passes a syntax check on Linux.

**Not verified yet:** the Swift package itself (needs Xcode.xip's iOS SDK via `xtool setup`), xtool's expected package shape, linking through SwiftPM, and running on an iPhone.

**Next:** follow `ios-xtool/README.md` on the owner's machine with an iPhone attached; record the result here.

---

## 2026-10-14 · Experiment 1: Mojo ↔ C both ways, and the first iOS measurement

**Setup:** Linux x86-64, Python 3.13, `pip install mojo` → Mojo 1.1.0 (8189361e).

### M0 · Mojo calls C — ✅ worked first try
- `bridge/mojoui_bridge.c` exports `mui_version()` and `mui_echo(ptr, len)`.
- `m0_call_c.mojo` calls both with `external_call`, passing a Mojo `String` as `s.unsafe_ptr()` + `s.byte_length()`.
- Built with `mojo build m0_call_c.mojo -Xlinker -Lbuild -Xlinker -lmojoui_bridge`.
- Output: `mui_version() = 1`; C received the 15-byte string correctly.

### M0 · C calls Mojo, Mojo keeps state — ✅ worked after two fixes
- `app_entry.mojo` exports `mojo_app_init`, `mojo_app_event`, `mojo_app_quit` with `@export … abi("C")`; app state is a heap struct handed to C as an `Int` address.
- `bridge/host_main.c` owns the loop: init, three simulated clicks, quit. Each click updates Mojo state and Mojo calls back into C.
- Output: "Hello, Ada! (click 1/2/3)", clean exit.
- **Fix 1 (API drift):** Mojo 1.1 deprecated `UnsafePointer` for `Pointer`; `alloc` now takes a `Layout` and returns an owning `Allocation`. Working pattern: `alloc(Layout[App].single())` → `allocation^.unsafe_leak()` → `p.unsafe_write(App())`; free with `unsafe_deinit_pointee()` + `unsafe_free()`; rebuild from C's address with `Pointer[App, MutUntrackedOrigin](unsafe_from_address=app)`.
- **Nice surprise:** the compiler *refused* to let the allocation go out of scope unconsumed and suggested `unsafe_leak()`. Handing memory to C has to be explicit.
- **Fix 2 (linking):** Mojo stamps its runtime folder into the library's `RUNPATH`, which makes the loader ignore the executable's `rpath` for the library's own dependencies. Adding `-Xlinker -rpath -Xlinker '$ORIGIN'` to the Mojo build fixed it.
- The Mojo app library depends on exactly **one** Mojo runtime library: `libKGENCompilerRTShared.so`.

### M5 steps 1–2 · Can Mojo target iPhone? — ✅ promising, run entirely on Linux
- `mojo build tiny.mojo --target-triple arm64-apple-ios17.0 --emit object` → `Mach-O 64-bit arm64 object`, `LC_BUILD_VERSION platform ios, minos 17.0`. Same for `arm64-apple-ios17.0-simulator` → `platform iossimulator`.
- `tiny.o` (`mojo_add`) has **no undefined symbols**.
- The M0 app code compiled for iOS needs:
  - standard C: `memcpy`, `write`, `fflush`, `fdopen`, `fclose`, `dup` (all in iOS's libSystem)
  - our bridge: `mui_echo`
  - Mojo runtime: **only** `KGEN_CompilerRT_AlignedAlloc` and `KGEN_CompilerRT_AlignedFree`
- From x86 call sites: `AlignedAlloc(align, size)`, `AlignedFree(ptr)`.
- `spike/kgen_shim.c` implements both with `posix_memalign` / `free` (10 lines).
- Linked the Linux build of the same app **statically with no Mojo runtime**: only `libc` remains. Ran correctly. Clean under AddressSanitizer + UBSan. Binary size: **25 KB**.

### What it means
- The Flutter-style plan is real at this scale: Mojo produces proper iOS objects, and a small app needs almost nothing from Mojo's runtime.
- Not yet proven: linking and running inside an actual Xcode app on a simulator or phone (M5 steps 3–4 need a Mac), and how the runtime needs grow as `core/` gets bigger (lists, dicts, more strings, GPU).
- The stand-in is unofficial; signatures were inferred and could change between Mojo releases.

### Next small steps (pick one, no rush)
- **M1:** write the real `core/` (`State`, `update`, `view`, `ViewTree`) with tests, then re-run `llvm-nm -u` on its iOS object to see if the runtime list grows.
- **M5 step 3** (when on a Mac): drop `app-ios.o` + `kgen_shim.c` into a blank Xcode app and call it from Swift.
