# Framework pieces, proved by omxconsole going all-Mojo (plan, 2026-11-04)

**omxcode is the product.** omxconsole is the proof: every ticket below lands in `mojoui/` (or a vendored library)
as a component any app can drop in, with its own test, and omxconsole only composes them (D-4756). If a piece
only omxconsole would use, it stays small and inside `examples/console`.

Why now: D-4735 took omxconsole out of the gallery because its engine is mxstudio's Python daemon
(`~/Projects/mxstudio/mxconsole/`, ~9.7k lines, 40 modules). It returns when our code is all Mojo.

The line (owner, 2026-11-04, D-4755, D-4756):
- LLMs: `max serve`, always. omxconsole is a convenient wrapper on it (as Ollama is on llama.cpp); we never write
  our own LLM serving. `max serve` is Modular's (Python inside) and the gallery card says so.
- HTTP: **Flare** (ehsanmok/flare, MIT): server and client, HTTP/1–3, TLS, SSE, streaming proxies, static files.
  Trusted over writing our own. Not a hand-rolled server in mojoui.
- Robotics: machine-learning and decision models in-process. Two or three popular ones ship as **packs**
  (compiled MAX graphs, `.mef`, loaded through libmax's C API), a YOLO-style detector first (YOLOX, Apache-2.0;
  Ultralytics YOLO is AGPL-3.0). Classic decision models (trees, forests, boosting, linear) run in plain Mojo.
  Packs are built once with Python on our side; a porting tool comes later.
- Out of scope now: Jupyter in Learn, the porting sandbox.

What adopting Flare costs (measured 2026-10-26, `../mojo-ui-mojo12/docs/research/mojo12-flare.md`):
Flare needs Mojo 1.2 (we pin 1.1); the engine `.mojoc` must be rebuilt for 1.2 (6 lines, then all engine tests
pass); mojoui and Flare declare 17 of the same libc functions with different types, which breaks the link
(one signature per symbol per binary); Flare's default CA bundle is broken on 1.2.0 (pass the system bundle;
report upstream); OpenSSL and `libflare_tls` are dlopened, so a shipped app bundles them (Mac: build them on
`scripts/mac-ci`). Flare is Linux and macOS only: iPhone and Android keep today's socket transport.
Worktrees share one `.pixi` through a symlink: the 1.2 move must not touch `../mojo-ui-apple-test`'s env.

## Framework tickets (the real work)

| # | Ticket (component) | Done when |
|---|---|---|
| F-1 | Mojo 1.2 for the repo: new engine stable commit + re-vendor, the objc.mojo pointer fix, every example builds | `scripts/check` green on 1.2; the frozen Apple worktree untouched |
| F-2 | Flare behind `mojoui.http`'s `Transport` seam (D-320): HTTPS for every app; mojoui's libc declarations aligned with Flare's; CA bundle bug reported | an app fetches a Hugging Face file over HTTPS on Linux and Mac; old socket transport stays for iOS/Android |
| F-3 | `mojoui.serve`: any app can expose an API (routes, JSON, SSE, streaming proxy) on Flare's server, with the app's state | a test app serves and streams; curl and the OpenAI SDK read it |
| F-4 | `mojoui.process`: start, health-check, log, stop and idle-stop child processes (a robot's driver, a tool, `max serve`) | a test supervises a child through crash and restart |
| F-5 | `mojoui.maxrt` + packs: load a `.mef` through libmax's C API, run on a frame (CPU, GPU when present); `VisionModel` gains packs beside today's torch path | a tiny graph runs in-process from Mojo on Linux and Mac |
| F-6 | First shipped pack: YOLOX detector | boxes match the original on test images; latency measured in-process vs HTTP |
| F-7 | `mojoui.ml`: decision models in plain Mojo (trees, forests, gradient boosting, linear/logistic), loaded from a pack exported from scikit-learn | same predictions as sklearn on a test set; faster |
| F-8 | Web host on `mojoui.serve` instead of FastHTML (later): every app's web build all-Mojo | the console's web build runs with no Python |

## omxconsole tickets (thin: compose the above)

| # | Ticket | Replaces | Done when |
|---|---|---|---|
| C-1 | Daemon on `mojoui.serve`: admin API; a contract test runs the console fixture's replies against both daemons | app.py, admin_*.py | the console runs against the Mojo daemon |
| C-2 | Store: the existing `~/.mxc/mst.db` via mojoui.sqlite | store.py | today's file opens unchanged |
| C-3 | `max serve` per model on `mojoui.process`; `/v1/*` gateway as a streaming proxy with keys | supervisor.py, gateway.py, keys.py | the OpenAI SDK streams a chat through it |
| C-4 | Pulls and search over HTTPS | pulls.py, search.py, resolve.py | Add flow pulls a model |
| C-5 | Metrics, bench, labels, LAN expose (Caddy as a child), CLI, tray | the rest | each page works as today |
| C-6 | Packs in the console: list, try (drop an image / a row), bench; `/v1/detect` for other apps | (new) | try page shows boxes |
| C-7 | All-Mojo check (`max serve` the named exception), then the card returns; robotics demo: camera → detect → decide | (new) | check passes; D-4735 reversed; latency published |

Order: F-1 → F-2 → F-3 → C-1..C-3 (the console is all-Mojo for LLMs) → F-5, F-6, F-7, C-6, C-7 (robotics) → F-8.
