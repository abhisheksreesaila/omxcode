# GOAL 50: the framework serves, fetches and supervises; omxconsole's daemon in Mojo on it

**End goal (owner, 2026-11-04):** "make OMX console completely … app native … a convenient wrapper on Max Serve. We
don't want to be writing our own thing … the star of the show is OMX code … anything else … contribute to the
framework … don't overfit OMX console … you don't have to write your HTTP server … There is Flare … I would rather trust
that." Plan: docs/plans/omxconsole-native.md (D-4755, D-4756). Base: main bfacc58.
**Framework first:** every generic piece is a `mojoui/` component with its own test; `examples/consoled` only composes.

## Milestones
| # | Milestone | Proof (`docs/goals/50-check.py`) |
|---|---|---|
| M0 | Flare in the repo | Flare v0.12.0 (MIT, Mojo 1.1) and its json dependency vendored under `vendor/` with their licences and a NOTICE line; `scripts/flare_ffi.sh` builds its C shims against OpenSSL; `tests/test_flare_link.mojo` imports mojoui (http, effects, sqlite, app) and flare in one binary and prints `link: ok` |
| M1 | HTTPS for every app | `mojoui.http` gains a Flare transport behind its `Transport` seam (D-320); `tests/test_http.mojo` passes on both transports against `scripts/http_server.py`; `tests/test_https.mojo` fetches a Hugging Face file over HTTPS on a worker and checks its size; hosts Flare can't reach (iOS, Android) keep the socket transport (builds checked: kit for iOS, todo for Android) |
| M2 | `mojoui.serve`: any app answers HTTP | routes with path parameters, JSON bodies, status codes, headers, SSE streaming and a streaming proxy to an upstream, on Flare's server, from a Mojo app's own state; `tests/test_serve.mojo` (prints `serve: ok`), and from outside: curl reads a route and the OpenAI Python SDK reads a streamed chat from a scripted SSE route |
| M3 | `mojoui.process`: children an app supervises | start with args, env and a log file; health by an HTTP probe; exit code and log tail on a crash; stop (TERM, then KILL after a grace time); idle stop; `tests/test_process.mojo` prints `process: ok` |
| M4 | omxconsole's daemon in Mojo | `examples/consoled` (no Python) on mojoui.serve answers every GET the console's screens make (the 18 recorded in docs/goals/33/fixtures) with the same JSON shape as the original (keys and value types, compared recursively), from a copy of a real `~/.mxc/mst.db` read by mojoui.sqlite; labels and keys (create, rotate, delete; stored as the original's SHA-256 hex, so a key works with either daemon) persist across a restart; the console (examples/console, GTK) runs against it and its Overview, Models and Keys pages show the store's models (shots) |
| M5 | LLMs through `max serve` | consoled starts `max serve` for Qwen2.5-0.5B-Instruct on `mojoui.process` when a model is loaded (admin load or the first `/v1` call), proxies `/v1/chat/completions` and `/v1/models` with a per-app key check (401 without), and the OpenAI Python SDK streams a chat reply through it; the request lands in the store's request log and `/admin/metrics`; idle unload stops the child |
| M6 | All-Mojo, nothing regressed | while M5's chat runs, the process tree of consoled and the console has no Python except `max serve` (the named exception, D-4755); goal 48's M0 and goal 33's M5 (the console against the fixture server, GTK and web) still pass; `scripts/components.py` matrix fresh with serve, process and the Flare transport |

## Out of bounds
Pushing or merging into main; the frozen `../mojo-ui-apple-test`; the running Python daemon on :11435 and the real
`~/.mxc` (tests use copies under build/); pip; Mojo 1.2 (Flare 0.12 runs on 1.1); paid services, sign-ups or keys;
lowering a proof or editing a milestone to pass.

## Assumptions (taken instead of asking)
- Flare v0.12.0, not 0.13: 0.13 needs Mojo 1.2, which needs a new omxcore engine build (another repo); 0.12 has the
  server, client, TLS and SSE (D-4757). The 1.2 move and Flare 0.13 come together later.
- Pulls, search, bench, LAN expose, tray, the CLI and packs are later goals (packs: goal 49's M2); this goal proves the
  daemon's spine: store, admin reads and writes, keys, `max serve`, the gateway.
- The gallery card returns only after the owner looks (D-4735 was theirs).

## Budget
150 turns. Split a milestone that is too big and log the split.
