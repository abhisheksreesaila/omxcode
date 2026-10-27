# CLAUDE.md — briefing for Claude Code

Mode: experiment
Ship: direct
Design language: omxplorer = Liquid light (docs/design/liquid.md; owner 2026-10-18: "liquid, smooth, a showcase"), Ledger/Graphite/Blueprint as switchable skins; Omarchy for MX Studio and the Workbook; Fluent 2 for the analytics showcase

Current experiment: `GOAL.md` (goal 33 done 2026-10-27: OMX Console rebuilt in omxcode, docs/goals/33-report.md; next: goal 34, first-class JS, docs/goals/34-draft.md). The owner tests Apple builds from the frozen worktree `../mojo-ui-apple-test`: don't touch it. Check with `scripts/check`; decisions in `docs/decisions.md`, attempts in `docs/journal.md`.

You are helping build **mojo-ui**: a long-term, experimental side project to write apps once in **Mojo** and run them natively on Linux, Mac, iPhone and the web. The owner is an app developer (Python/FastHTML background), not a systems programmer. They want to develop this **slowly and organically**: one small, verified step per session.

## Read first, in this order
1. `ROADMAP.md`: the vision, why Mojo, decisions 1–8, the two tracks.
2. `SPEC.md`: the technical spec and milestones (M0–M5) with acceptance checks.
3. `EXPERIMENTS.md`: what has actually been tried and what happened. **Trust this over the spec when they disagree.**

## Where things stand
- **Newest (Experiment 11, 2026-10-16, goal 10):** the Workbook made usable: a Fluent canvas theme with floating islands (`Overlay`, icon `Button` styles, Lucide icons on GTK too), a scrolling page that reveals inserted cards, a drawn grid scroll bar (`PRESS`/`RELEASE` gestures), column selection and sort, pivots that start from the selected column. Formatting planned in `docs/plans/formatting.md`.
- **Experiment 10 (2026-10-16):** the Workbook (`examples/workbook`): tables, pivots, charts and notes on a `Board`, one GPU engine (`mojoui/frame.mojo`, `frame_gpu.mojo`), workbook files, shared data per process (`App.init_shared()`), the wasm spike (`docs/wasm.md`). Run it with `scripts/workbook.sh`; walkthrough `docs/morning.md`. Morning fixes: radix sort, Board drags without jitter (gesture on the Board, moves as patches), Insert…/Remove cards (D-91–D-94).
- **Experiment 9 (2026-10-15):** the analytics showcase (`examples/analytics`): Flint charts drawn by mojoui, GPU group-by, MX frame engine, Fluent 2 controls; gallery at docs/gallery (GitHub Pages). See `docs/report.md`.
- **Experiment 8 (2026-10-15):** Android: Mojo drives Android views through JNI (`mojoui/hosts/android.mojo`, one framework Java file); runs on the emulator with real input, same results as GTK. Emulator: `ANDROID_AVD_HOME=~/.config/.android/avd`, AVD `mojoui`. See `docs/goals/07-report.md`, `docs/android.md`.
- **Experiment 7 (2026-10-15):** Canvas view + GPU PointCloud + Data Lens (`examples/lens`): 20M points, 1.5 ms/frame on the GPU, ~60 fps on GTK and streamed to the web; Mac/iPhone CPU path (builds, not run). See `docs/goals/06-report.md`.
- **Experiment 6 (2026-10-15):** layout settings (padding, sizes, grow, fill, align, justify) on every host; no layout engine (ROADMAP decision 10).
- **Experiment 5 (2026-10-15):** segmented, radio, text area, alert, tabs, navbar, date, icon, grid, lazy list; Pocket Expenses (`examples/expenses`).
- **Experiment 4 (2026-10-15):** web host (FastHTML), all common components, a real todo app, a GPU example, Android exploration. Linux + web run and are tested here; see `docs/report.md`.
- **Experiment 3 (2026-10-15):** declarative UI. Apps are `examples/<name>/app.mojo` (`view()`/`update()`), drawn natively by `mojoui/hosts/` (GTK, AppKit, UIKit). Build with `scripts/build.sh <name> all`. Linux runs and is tested here; Mac/iPhone build and sign but haven't run on hardware yet.
- **Done:** M0 (Mojo ↔ C both directions, Mojo keeps state across calls from C) and M5 steps 1–2 (Mojo compiles to iPhone objects; the app needs only two Mojo runtime functions, covered by `spike/kgen_shim.c`).
- **Next, main track (Linux):** M1, the real `core/` (`State`, `Msg`, `update`, `view`, `ViewTree`) with tests. See SPEC §5 and §9.
- **Next, side track (iPhone):** M5 step 3 via xtool, using `ios-xtool/`. Needs the owner's machine, an iPhone, and Xcode.xip downloaded from Apple. See `ios-xtool/README.md`.

## Components first (owner, 2026-10-16)
The Workbook is a showcase, but the product is the component library. Before building any feature:
1. List the components it needs and look them up in `docs/components.md` (✅ run by a check / 🔨 built, never run / ❌ missing, per platform). Show that list to the owner when they ask for something.
2. Build or extend the component in `mojoui/` first, with its own test, on every host it can reach; then build the app from it.
3. Never leave something another app would need inside an app: if it happens, it goes in the matrix's "debt" table until it's extracted.
4. Regenerate the matrix (`pixi run python scripts/components.py`); `scripts/check` fails when it's stale.

## How to work
- **One milestone (or less) per session.** Stop when its acceptance checks pass, show the result, and ask before starting the next.
- **Verify by running, not by reasoning.** Build it, run it, show the output (or a screenshot for UI). GTK checks run on a headless Xvfb display (`scripts/headless.py`, used by `scripts/check`): no windows on the owner's desktop; `MOJOUI_HEADLESS=0` to watch them.
- **Log every session** at the top of `EXPERIMENTS.md`: date, setup, what worked, what broke and how it was fixed, what it means, next small step.
- **Explain plainly.** Short sentences, no unexplained jargon. When there are trade-offs, list the cons.
- **Keep the repo honest:** mark anything unverified as unverified.

## Mojo rules that bite (verified on Mojo 1.1.0)
- Install: `pixi install` (this repo's `pixi.toml` pins Mojo 1.1); run with `pixi run mojo …`.
- `def` only (`fn` is deprecated); no `@value` (use `@fieldwise_init` + explicit traits).
- Imports use `std.`: `from std.ffi import external_call`, `from std.memory import Pointer`, `from std.memory.alloc import alloc, Layout`.
- `UnsafePointer` is deprecated: use `Pointer`. Heap state handed to C: `alloc(Layout[T].single())` → `allocation^.unsafe_leak()` → `p.unsafe_write(...)`; back from an address with `Pointer[T, MutUntrackedOrigin](unsafe_from_address=addr)`; free with `unsafe_deinit_pointee()` + `unsafe_free()`.
- FFI: scalars and `(ptr, len)` strings only (`s.unsafe_ptr()`, `s.byte_length()`); never structs by value. Exports use `@export` + `abi("C")` and cannot `raise`.
- Linking a Mojo shared library: add `-Xlinker -rpath -Xlinker '$ORIGIN'` (Mojo sets its own RUNPATH).
- Inspect Mach-O (iOS) objects on Linux with `llvm-nm` / `llvm-objdump`, not GNU `nm`.
- A `SIMD` vector indexed with a run-time index as scratch space (`stack[sp] = v`) segfaults the compiler (no message, exit 139): use `stack_allocation[n, T]()`. Bisect compiler crashes with tiny probe files built in parallel.
- The compiler tries to reach `telemetry.modular.com`; in a sandbox that warning is harmless.
- When unsure of an API, fetch the docs as Markdown: append `.md` to any `mojolang.org/docs/...` URL, or start from `https://mojolang.org/llms.txt`. Don't guess.

## Guardrails
- `spike/kgen_shim.c` is an **unofficial** stand-in for two Mojo runtime functions; signatures were inferred from compiled code. Keep it in `spike/`, labelled. After any change to Mojo code destined for iOS, re-run `llvm-nm -u` and record new `KGEN_*` symbols in `EXPERIMENTS.md`.
- Don't patch the Mojo compiler or rewrite Mach-O platform tags. If blocked, record the blocker and stop; the owner decides.
- Experiment mode: commit after each passing milestone; never push.

## Repo map
```
CLAUDE.md          this briefing
ROADMAP.md         vision, decisions, tracks, risks
SPEC.md            technical spec + milestones
EXPERIMENTS.md     dated log of real results
app_entry.mojo     M0: Mojo app exported to C (init/event/quit), keeps state
m0_call_c.mojo     M0: Mojo calling C
bridge/            C side: mojoui_bridge.c (bridge), host_main.c (C shell driving Mojo)
spike/             iOS spike: tiny.mojo, kgen_shim.c (runtime stand-in)
scripts/m0_linux.sh  reproduces Experiment 1 end to end on Linux
themes/            looks on top of the framework (D-260): liquid, skins, fluent, omarchy, paper (the one to copy); apps pick one with App.theme()
mojoui/            the framework: view.mojo (components), diff.mojo, app.mojo (App, Event, Runtime), gpu.mojo, png.mojo, hosts/ (gtk, web.mojo+web.py, appkit, uikit, objc, mojo_rt)
hosts/             entry points per platform (import your app.mojo)
examples/          hello/, gallery/, todo/, gpu/, kitchen/, expenses/, layout/, lens/: one app.mojo each (optional `platforms` file)
scripts/build.sh   build an example for linux|web|mac|ios|android|all
scripts/drive.py   drives the web app in headless Chromium with the GTK test-mode steps
apple/             Info.plists, sdk/ (.tbd stubs), install_iphone.sh, README
GOAL.md            current experiment contract; scripts/check proves it; docs/decisions.md, docs/journal.md
ios-xtool/         superseded: earlier SwiftUI skin + prebuilt Mojo iPhone library
docs/              visual guide (open visual-guide.html in a browser)
```
M1 onwards follows the layout in SPEC §3 (`core/`, `hosts/native/`, `hosts/web/`, `tests/`); move the M0 files into it when convenient.
