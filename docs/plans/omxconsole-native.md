# omxconsole, Mojo end to end (plan, 2026-11-04)

Why: D-4735 took omxconsole out of the gallery because only its screens are Mojo; its engine is mxstudio's Python
daemon (`~/Projects/mxstudio/mxconsole/`, ~9.7k lines, 40 modules). It comes back when our code is all Mojo.

The line (owner, 2026-11-04, D-4755):
- omxconsole is a convenient wrapper on `max serve`, like Ollama on llama.cpp. We never write our own LLM serving.
  `max serve` is Modular's (Python inside); our code is all Mojo, and the gallery card says so.
- Non-LLM models (vision, robotics) ship as **packs**: compiled MAX graphs (`.mef`) loaded in-process through
  MAX's C API (`libmax.so`, in our env). Two or three popular models ship with the app; YOLO-style detection first.
- Building a pack needs Python once, on our machine (MAX graphs are built from Python only since 25.3). Users
  never run it. A porting tool (a section of omxconsole) comes later.
- Classic ML (sklearn-style trees, linear models) needs no MAX: plain Mojo, later.
- Out of scope now: the Learn page's Jupyter, the porting sandbox, the web build (its host is FastHTML; the
  gallery shows Linux and Mac until the web host runs on C-01's server).

## Part A: the daemon in Mojo, same features, back in the gallery

| # | Ticket | Replaces | Done when |
|---|---|---|---|
| C-01 | HTTP/1.1 server in mojoui: TCP listen, routes, JSON, SSE streaming, worker threads | (new) | curl gets a streamed reply; Linux and Mac |
| C-02 | HTTPS client (OpenSSL or libcurl over FFI) | network in pulls.py, search.py | fetches a Hugging Face file, size checked |
| C-03 | `omxc daemon` skeleton: /admin/info, system, status, shutdown; a contract test running the console fixture's replies against both daemons | app.py, admin_system.py | the console runs against the Mojo daemon |
| C-04 | Store: the existing `~/.mxc/mst.db` via mojoui.sqlite | store.py, settings.py | today's file opens unchanged |
| C-05 | Supervisor: one `max serve` child per model, health, idle unload, logs | supervisor.py, serve.py | load → answer → unload after idle |
| C-06 | Gateway /v1/*: key check, route by model, SSE pass-through, request log | gateway.py | the OpenAI SDK streams a chat through it |
| C-07 | Keys: create, rotate, delete, hashed (SHA-256 in Mojo); admin key | keys.py | the Keys page works end to end |
| C-08 | Pulls and search: progress, cancel, kinds | pulls.py, search.py, resolve.py, kinds.py | Add flow pulls a model; it shows in the list |
| C-09 | Labels, metrics, series, insights, bench | metrics.py, bench.py, insights.py | Overview and Bench show live numbers |
| C-10 | LAN expose: Caddy (Go) as a child | expose.py | a phone gets a chat reply over HTTPS |
| C-11 | `omxc` CLI: run, pull, list, serve, daemon | cli.py, pull_cli.py | `omxc run qwen2.5-0.5b` chats in a terminal |
| C-12 | Tray and autostart on mojoui/tray.mojo | tray.py, autostart.py | starts at login; tray shows status |
| C-13 | All-Mojo check (no Python of ours running; `max serve` named as the one exception), then the gallery card returns | (new) | check passes; D-4735 reversed |

## Part B: packs, in-process, for robotics

| # | Ticket | Done when |
|---|---|---|
| C-20 | Pack format: folder with manifest, safetensors weights, compiled `.mef` | documented; a test reads one |
| C-21 | `mojoui.maxrt`: load a `.mef` through libmax's C API, run on a frame (CPU, GPU when present) | a tiny graph runs in-process from Mojo |
| C-22 | First shipped pack: a YOLO-style detector with a permissive licence (YOLOX-Nano/S, Apache-2.0; not Ultralytics, AGPL) | boxes match the PyTorch original on test images; latency measured |
| C-23 | Console screens for packs: list, try (drop an image), bench; `/v1/detect` for other apps | try page shows boxes |
| C-24 | Robotics demo: camera → in-process detect → action; latency vs HTTP | numbers published |
| later | Second/third shipped pack (segmentation, depth or pose); classic-ML packs in plain Mojo; the porting tool | |
