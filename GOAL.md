# GOAL 33: OMX Console, rebuilt in omxcode

**End goal (owner, 2026-10-25):** "the whole point of the framework is to build apps and it should have all the
components necessary… let's fix this… it proves it can build a console app like this… the web should be identical,
99%… showcase it in our gallery." The app is MXConsole (repo `mxstudio`, `mxconsole/console/`: ten screens, 4,400 lines
of plain JS and 870 of CSS over omxqua, polling the daemon's `/admin/*` JSON API). Its Python daemon stays as it is.
Goal 32 is parked at M0, M1, M2 PASS, with M3 in progress (archived: docs/goals/32-GOAL.md, 32-check.py); goal 31's
draft waits.

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | The measure | `scripts/console_fixture.py` replays `/admin/*` replies recorded from a real daemon (mxconsole's fake `max`) and serves the original console's files from `MXCONSOLE_DIR`; `scripts/console_side.py` shoots its ten screens at 1440×900 and 390×844 with motion off, twice; no request misses the fixtures; the noise floor (the two runs' largest differing-pixel share) is ≤ 1 % and saved in docs/goals/33/floor.txt |
| M1 | HTTP, a component | `mojoui/http.mojo`: a request is an effect and its reply an `Event`; `tests/test_http.mojo` against a Python test server: GET and POST JSON, a header read from an env var by name, chunked replies, a 1 MB body, a timeout, connection refused, a 500; `examples/httpcheck` draws ≥ 60 frames on GTK and the web while one reply takes 2 s, then shows it |
| M2 | Timers and real JSON | `App.every(ms, id)` on GTK and the web: 10 ticks of 100 ms each land within ±20 ms; `mojoui/json.mojo` reads every recorded reply in docs/goals/33/fixtures and equals Python's `json.loads`, value for value (decimals, negatives, exponents, `\u` escapes, nulls) |
| M3 | The omxqua theme | `themes/omxqua.mojo` declares a `Look` from omxqua's tokens.css (Geist and Geist Mono, its accent, surfaces, one soft shadow, the press spring), both light and dark; only framework tags styled (goal 32's lint) |
| M4 | The console's components | in `mojoui/`, each with its own test, on GTK and the web, built for the Mac: Table (rows, tick boxes), CodeBlock with Copy, LogView (pinned to the end), Timeline (stages, elapsed), Breadcrumbs, Chip/Badge, Confirm (tap twice), Skeleton, Markdown, Sparkline, Route (`#/models/<name>/<tab>` deep links on the web); docs/components.md regenerated; the debt table holds nothing from the console |
| M5 | My models and the model page | `examples/console` against the fixtures: the model list (table and cards, tick to change many, drag onto a label) and the model page's overview, benchmark, logs and notebook tabs; numbers follow the poll; Jupyter in an iframe on the web, the browser on GTK and the Mac |
| M6 | The other screens | Add a model (search with fit badges, the stage timeline, the live log, the Ready card with curl to copy), Keys (create, rotate, revoke by tapping twice), Gateway, Security, Settings |
| M7 | Identical | the web: every M0 screen at both sizes has ≥ 99 % of its pixels equal to the original's (the same tolerance M0 measured); GTK and the Mac: every tagged view's box within goal 32's parity tolerance of the web's; scripts/live.py on a live daemon (fake `max`): load a model, its numbers update, create a key and call `/v1` with it, revoke it, stop the model |
| M8 | In the gallery, nothing regressed | the console in docs/gallery beside omxplorer (GTK, web and Mac shots); goal 32's M0–M2 and goal 30's M0–M5 pass |

## Out of bounds
Changing mxconsole's daemon or API, or anything in `~/Projects/mxstudio` (read it, never write it); the `/docs` and
installer pages; the tray and the pywebview window; TLS; iPhone and Android; paid services; pushing; touching
`../mojo-ui-apple-test`.

## Assumptions (instead of asking)
- HTTP is our own small HTTP/1.1 client on libc sockets (the console only talks to 127.0.0.1); flare (ehsanmok/flare)
  needs Mojo ≥ 1.2 and OpenSSL and has no iPhone or Android, so it waits behind the same `mojoui.http` API (D-310).
- A request never blocks `update` or a frame: the host runs it on a worker and posts the reply back, as goal 30's jobs do.
- The console is `examples/console`, given the daemon's URL; replacing mxconsole's shipped JS console is the owner's call later.
- "Identical" is the web, in pixels; GTK and the Mac use native widgets, so they're held to boxes, not pixels.
- Each milestone's proof is written in scripts/check.py before its work starts (todo() until then), from this table's
  words, never weaker.

## Done means
`scripts/check` prints PASS for M0–M8; the reviewer passes it; a short `docs/report.md` with side-by-side shots of the
original console and ours. Committed locally on `goal-33-console`, nothing pushed. Budget: 80 turns a run; if M5 runs
long, M6 becomes goal 34 (logged).
