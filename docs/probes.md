# Probes: battle-testing omxcode against what the web can do

Status as of 2026-10-30. Each probe is a small app built to answer one question: **can omxcode do something the web
can't, measured against the web's best?** If it can't, we don't bother. Personal Note (`~/Projects/personalnotev2`, Python +
JS) is the yardstick: its gap audit is `personalnotev2/docs/research/omxcode-gap-audit.md`.

## The recipe (repeat it for the next probe)
1. **Contract first:** `docs/goals/NN-GOAL.md` + `docs/goals/NN-check.py` (`GOAL.md` and `scripts/check.py` belong to
   other goals). Write both before any work and commit them so every milestone fails at the start. After that the checker
   may only gain additions or tightening, never weakening.
2. **A race with a verdict:** the same data, model and GPU on both sides. Side B is the web's best: WebGPU,
   SQLite-wasm on OPFS, the File System Access API, tried every way it loads, with every failure recorded. A loss is a FAIL.
3. **Framework first:** reusable parts go into `mojoui/`, each with its own test. The example app only puts them together.
   Slow work runs off the UI thread (`docs/ui-threads.md`).
4. **Build it in its own worktree** (`../mojo-ui-gNN`, branch `goal-NN-<name>`). Then review with the `reviewer`
   subagent, run a fix round and re-review. When the agent that did the work wrote the checker, the reviewer checks
   the checker too.
5. **Merge into local main** (never push). Add a gallery section with a screenshot, and update `docs/components.md`
   (`scripts/components.py`), `docs/llms.txt` and `EXPERIMENTS.md`.
6. **Show the owner:** launch the Linux app on the desktop. A plain shell has no display, so set
   `WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000`, then confirm the window exists with `hyprctl clients`
   (`HYPRLAND_INSTANCE_SIGNATURE` comes from `/run/user/1000/hypr/`).

## Results
| Goal | Probe | Question | Result vs the web | Library parts | State |
|---|---|---|---|---|---|
| 40 | **Sketch** | Can it draw? | Not raced. Pan, zoom and draw each p95 ≤ 3.5 ms with 1,000 strokes (101k points) | `mojoui.ink` (pressure strokes, eraser), `Painter.polygon`, layer transforms, GTK texture cache | merged |
| 42 | **Jot** | Can it keep data? | SQLite at 1M notes vs SQLite-wasm on OPFS: search p95 64.6 vs 165.8 ms (**2.6×**); cold open 65.8 vs 435.3 ms (**6.6×**) | `mojoui.sqlite` (FTS5), FileSaver, file drop, `App.closing()` quit hook | merged |
| 43 | **Dictate** | Speech to text on the GPU | whisper-large-v3-turbo in process vs transformers.js on WebGPU: **140 vs 912 ms** per clip (6.5×), same WER 0.034. A runs fp16, B fp32 encoder + q4 decoder (no shader-f16 here) | `mojoui.audio` (microphone), `mojoui.speech` (+ `speech_torch.py`), `speech` pixi env | merged |
| 45 | **Keeper** | Works with the window closed? | Read 100k files 2.2 s vs the web's best 18.3 s (it reads; native also indexes). Noticing a change: both sub-ms (noisy, no ratio claimed). With the tab closed the web runs no code for a file change, and has no notification and no tray | `mojoui.watch` (inotify), App background mode, tray item (SNI), notifications | merged |
| 44 | **Recall** | Search by meaning | M0–M2 done: GPU top-10 over 1M × 384 in 2.2 ms, query embedding 1.4 ms (CUDA graph), 7.7 ms p95 as you type over 1M, SciFact nDCG@10 0.76. The race vs transformers.js on WebGPU is running | `mojoui.vectors` (GPU top-k), `mojoui.meaning` (bge-small in process) | in progress |

## What we learned
- **The case for omxcode:** the UI and the heavy computing are one program in one language and one process, with no
  boundary in between (no JSON, no HTTP, no second process). On top of that, it can reach things the browser never can:
  running with the window closed, folders, the tray, a global hotkey, the Neural Engine on a Mac, a lot of GPU memory.
- **"I have WebGPU, I'll keep JS"** was the opponent in Dictate and Recall, and it lost. WebGPU here has no fp16, has
  buffer and allocation walls and no CUDA libraries, and does the CPU work in JS.
- **The stronger opponent is next:** a JS UI plus a native helper process (Tauri, or Personal Note's own design with a
  llama.cpp server over loopback HTTP). Later races should include it as side B2.
- **Honesty catches:** reviewers found two strawman web baselines (B in fp32 vs fp16, a serial file read) and one noisy
  ratio. All were redone or dropped. Ask the reviewer to look for these on purpose.
- **Not where omxcode should compete:** forms, CRUD, dashboards over APIs, marketing sites. JS wins those, and omxcode
  embeds JS widgets when they're the better tool.

## Open items
Fixes are run by `scripts/probe_fixes.py` (one step per item, results in `docs/goals/probe-fixes/results.json`) and noted
in each probe's gallery section (`scripts/probe_fixes_gallery.py`).

- **Mac:** every probe builds, none has run (it needs the owner's Mac).
- **Sketch:** erase takes 14–23 ms p95. A real pen or touchpad and GTK's GPU renderer are unverified.
- **Jot:** all three fixed 2026-10-30 (web drop leaks, D-1704; the field queue's stale write, D-1703; the goal 30 flake, two causes in the GTK
  test host: a fixed pause raced the 100M-row open, D-1701; `pause:` slept 10 ms per main-loop turn and skipped frames, D-1702.)
- **Dictate:** B at fp16 is unmeasured. (Fixed 2026-10-30: `captured_ns` gives up after 2 ms on a word that stays odd, D-1700.)
- **Keeper:** never run against a real tray panel or notification server; a second launch builds its App before handing
  over; Web Push untried. (Fixed 2026-10-31: `file_stamp` reads statx, one layout on every Linux, compiled for aarch64, not run there, D-1705.)

## Next
- **Recall:** finish the race, review it, then add side B2: Personal Note's design (a page plus a llama.cpp embedding
  server over HTTP).
- **"The web can't at all" probes:** global-hotkey dictation into any app (needs a headless Wayland compositor such as
  sway, a system package the owner must approve); CoreML / Neural Engine on the Mac.
- **Later:** Reader (HTTPS/OAuth/keychain/background sync), Writer (rich text), Ship (signing and installers, on the Mac).
