# omxcode roadmap

_Last updated: 2026-11-12 · public alpha · MIT_

## What omxcode is

omxcode is a UI framework written in Mojo. You write an app once, as `view()` (the screen, from state) and `update(event)` (what changes it), and it runs as a native app on Linux (GTK 4), on the web (a FastHTML server), on Android (real Android views), and builds for the Mac (AppKit) and the iPhone (UIKit). The same app is also an MCP server: an agent host turns every control on screen into a tool, so an agent uses the app through the code that draws it. Why one language: in a data app, the button, the table it shows and the GPU kernel that computes it can live in one codebase, with no JSON, HTTP or second process between the screen and the computing. Mojo reads like Python, calls C and Objective-C directly, and writes GPU kernels in the same program as the UI.

This roadmap replaces the first one (2026-10-14). That plan used SDL3 and Clay on Linux and a SwiftUI skin on Apple. What got built instead: each platform's own widgets, driven straight from Mojo ([docs/decisions.md](docs/decisions.md) has every decision with its reasons; [EXPERIMENTS.md](EXPERIMENTS.md) has what was tried).

## Where it is today

Two words matter here, and the repo uses them strictly:

- **Proven (✅):** a script in `scripts/check` or a goal's checker runs it on that platform and checks the result.
- **Built (🔨):** the code exists and compiles for that platform, but no check runs it there yet.

From [docs/components.md](docs/components.md), which is generated from the code and the checks:

**The 43 core components** (`Text`, `Button`, `TextField`, `Dropdown`, `Canvas`, `Board`, `Menu`, `Dialog`, `Table`, …):

| Platform | Proven | Built, not run | Missing |
|---|---|---|---|
| Linux (GTK 4) | 41 | 2 | 0 |
| Web (FastHTML + HTMX) | 43 | 0 | 0 |
| Android (views over JNI, on the emulator) | 16 | 11 | 16 |
| Mac (AppKit) | 0 | 43 | 0 |
| iPhone (UIKit) | 0 | 36 | 7 |
| Agent (MCP tools) | 26 | 10 | 7 |

**Everything in the matrix** (190 entries: core components, variants and gestures, native services, composites built from them, and JavaScript widgets):

| Platform | Proven | Built, not run | Missing |
|---|---|---|---|
| Linux | 181 | 9 | 0 |
| Web | 164 | 9 | 17 |
| Android | 19 | 56 | 115 |
| Mac | 5 | 155 | 30 |
| iPhone | 0 | 126 | 64 |
| Agent | 58 | 44 | 88 |

What those numbers mean in plain words:

- **Linux and the web** are where omxcode lives. Every component, gesture and theme runs there under a check, with real input on a headless display and in headless Chromium.
- **The Mac** is further along than its column shows. omxplorer, the globe sample and the SaaS client have run on an Apple M4 (Metal GPU) during goal runs over SSH (`scripts/mac-ssh`), and some apps run on GitHub's macOS runners (`scripts/mac-ci`). But only 5 entries (the SaaS server pieces) are counted as proven, because the matrix counts a component only when a check that runs it is wired in.
- **Android** runs the classic controls on the emulator. Overlays, menus, dialogs, the Board and the newer composites are not built there yet.
- **The iPhone** builds and signs, and has never run on a phone.
- **Windows** has no Mojo release yet; the web host is the way to reach it for now. WebAssembly is parked ([docs/wasm.md](docs/wasm.md)).
- **The GPU path** runs on NVIDIA under the checks, and on Apple's GPU on the owner's Mac. Phones use the CPU path, which runs the same functions.

Beyond widgets, the framework has grown building blocks apps need:

- **Data:** omxcore (formerly MX frame), a Mojo dataframe engine on the GPU, vendored in `vendor/`.
- **Agents:** the MCP agent host ([docs/agent.md](docs/agent.md)), and an AG-UI client that draws an agent's streamed screen from 38 components ([docs/ag-ui-compatibility.md](docs/ag-ui-compatibility.md)).
- **Server:** `mojoui.serve` (HTTP on Flare), and SaaS modules for sign-in, tenants, billing, email, background jobs, migrations and logging ([docs/saas.md](docs/saas.md)). These are checked against stand-ins for Google, Stripe and SMTP on Linux and the Mac. They have not yet run against the real services.
- **Themes:** looks as plugins in `themes/` (omxqua, Liquid, Fluent, Omarchy, Paper and others). The framework itself names no theme, and a check proves it.

Two apps are built entirely with it: **omxplorer**, a data app over a million-row table (`examples/omxplorer`), and **omxconsole**, a desktop app that runs models on your own GPU through MAX (`examples/console`, `examples/consoled`).

## Now (November 2026)

- **Mac: from "built" to "proven".** Wire the Mac runs that already happen (owner's M4, GitHub runners) into the matrix, so a component counts as proven on the Mac when a check runs it there. Start with the core 43.
- **Server hardening.** Fix the known stop-and-restart race in `mojoui.serve` (a stopped server can close a socket a new one reused; see docs/saas.md). Run the SaaS modules once against real Google, Stripe and an SMTP provider.
- **omxconsole stability.** Its daemon crashed a few times in worker threads during long runs; the traces point at memory corruption, not one call. Find and fix it. Model porting stays labelled beta, with its real hit rate (8 of 14 models on the owner's machine).
- **Pay down the debt.** The matrix lists 10 pieces still living inside one app (mostly omxplorer). Move them into `mojoui/` as components with their own tests.

## Next (December 2026)

- **Downloads people can run.** Linux and Mac downloads of omxplorer and omxconsole, with a page on omxlabs.tech, by mid-December.
- **A contributor guide.** `CONTRIBUTING.md`: how to build, how checks work, how to add a component to every host, how to add a row to the matrix.
- **An agent that writes omxcode apps.** `AGENTS.md` plus a "build an omxcode app" skill, so a coding agent can write a working app from one sentence (it builds on [llms.txt](docs/llms.txt)).
- **Android: the missing core components.** Board, Overlay, MenuBar, Menu, Item, ContextMenu, Dialog, Toast, Popover and the rest of the 16, on the emulator under a check.
- **Agent host: the rest of the core.** The 17 core components the agent can't fully drive yet (sliders, date pickers, tabs, lazy lists and others).

## Later (no dates yet)

- **iPhone on a real phone.** It builds and signs today; the next step is running it on hardware, then wiring a check.
- **Windows,** once Mojo ships for Windows.
- **WebAssembly,** if and when Mojo targets it well (parked; docs/wasm.md).
- **Phone GPUs.** Today phones use the CPU path.
- **Accessibility on every host,** checked, not only accessible names.
- **Packaging and updates:** signing, notarization, installers and auto-update for desktop apps.
- **A stable API and a package** you can depend on, instead of cloning the repo.

## Where help is wanted

Each of these is a self-contained piece of work. The component matrix shows exactly what is missing, and `scripts/components.py` regenerates it, so progress is visible.

1. **Android host: the missing components.** 16 core components and most composites are ❌ on Android. Start from `mojoui/hosts/android.mojo`, `mojoui/hosts/jni.mojo` and the one Java file, `mojoui/hosts/android/MojoActivity.java`. Build with `scripts/build.sh <example> android`; drive the emulator with `scripts/android_drive.py`. Setup notes: [docs/android.md](docs/android.md).
2. **Mac checks.** 155 entries are built but not proven on the Mac. If you have an Apple Silicon Mac, run the AppKit test steps and help turn them into checks. Start from `mojoui/hosts/appkit.mojo`, `scripts/mac-ci` and `scripts/mac-ssh`. Known Mac gaps (no save or open panel yet, no tray item, a quit-on-last-window host) are listed in the matrix's notes.
3. **iPhone on hardware.** Nobody has run an omxcode app on an iPhone yet. Start from `mojoui/hosts/uikit.mojo`, `apple/install_iphone.sh` and `apple/README.md`. The app needs two Mojo runtime functions that an unofficial stand-in provides (`spike/kgen_shim.c`); re-check its symbols when the code changes.
4. **The agent host.** 88 entries are ❌ for agents. Start from `mojoui/hosts/agent.py`, `mojoui/hosts/agent_link.mojo` and [docs/agent.md](docs/agent.md), which lists what the agent can't do yet (read a chart's figures as text, drag objects on a page).
5. **Web gaps.** 17 web entries are ❌, mostly machine services a browser doesn't offer the same way (a folder watcher, a tray item, holding a card on the Board). Start from `mojoui/hosts/web.mojo` and `mojoui/hosts/web.py`.
6. **Components out of apps.** The "debt" table at the bottom of docs/components.md lists pieces that live in `examples/omxplorer` or `examples/workbook` and should be `mojoui/` components. Each one says what it is and where it belongs.
7. **`mojoui.serve` and Flare.** The stop-and-reuse descriptor race described in docs/saas.md. Start from `mojoui/serve.mojo` and the server tests in `tests/`.
8. **Docs and examples.** Small, plain examples beyond `examples/hello`, `examples/todo` and `examples/tasks`; corrections to [docs/reference.md](docs/reference.md); a theme of your own (copy `themes/paper.mojo`).

If you want to pick one up, open an issue first saying which, so two people don't build the same host twice.

## How to start

You need x86-64 Linux with GTK 4 and libadwaita 1.7 or newer, and [pixi](https://pixi.sh). An NVIDIA GPU is used when present; without one the CPU path runs the same code. Mojo 1.2 is installed by pixi.

```bash
git clone https://github.com/abhisheksreesaila/omxcode && cd omxcode
pixi install                                   # Mojo, MAX and the tools, pinned in pixi.toml

scripts/build.sh hello linux                   # one app file → a native GTK app
build/hello/linux/hello

scripts/build.sh hello web                     # the same file → the web host
pixi run python mojoui/hosts/web.py build/hello/web   # → http://127.0.0.1:5001

scripts/build.sh hello android                 # an APK for the emulator
```

The whole showcase, with demo data and models (large downloads):

```bash
scripts/setup
scripts/omxplorer.sh build/demo/fleet.csv
```

**Checks.** `scripts/check` runs the current goal's milestones and prints PASS, FAIL or BLOCKED for each (`scripts/check M2` runs one). Earlier goals keep their checkers in `docs/goals/NN-check.py`. GTK checks run on a private headless display, so no windows open on your desktop (`MOJOUI_HEADLESS=0` to watch them). After adding or changing a component, run `pixi run python scripts/components.py`; the checks fail when the matrix is stale.

**Read next:** [your first app](https://abhisheksreesaila.github.io/omxcode/start.html), [docs/architecture.md](docs/architecture.md) (how the view tree reaches each platform), [docs/reference.md](docs/reference.md) (every component), [docs/components.md](docs/components.md) (what exists where).

---

*Mojo and MAX are trademarks of Modular Inc.; omxcode is independent, not affiliated with or endorsed by Modular.*
