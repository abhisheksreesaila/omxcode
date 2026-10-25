# GOAL 33 (draft, 2026-10-25): OMX Console, rebuilt in omxcode

**Why (owner, 2026-10-25):** "the whole point of the framework is to build apps and it should have all the components
necessary. If we can't build apps and struggle, then there's no point in advertising this… let's fix this… it proves
it can build a console app like this… the web should be identical, 99%… showcase it in our gallery." Ahead of the rest
of the queue (goal 31's draft waits). The app is MXConsole (repo `mxstudio`, code in `mxconsole/`): about 10 screens,
4,400 lines of plain JS and 870 of CSS over omxqua; the Python daemon behind it stays as it is.

## What's missing today (the gap that made this goal)
| Need | Today | Becomes |
|---|---|---|
| Call the daemon's `/admin/*` JSON API | no HTTP in mojoui | `mojoui.http`: a request is an effect, its reply an `Event` (never blocks a frame) |
| Poll every 0.7–5 s | only Canvas `on_frame` | `App.every(ms, id)`: timer events on every host |
| Tokens per second, memory, decimals | `mojoui/json.mojo` reads whole numbers only | decimals, negatives, exponents, `\u` escapes |
| The omxqua look | no theme | `themes/omxqua.mojo`, a `Look` (goal 32's theme-as-data) from omxqua's tokens.css |
| Console widgets | missing | Table (rows, tick boxes), CodeBlock with Copy, LogView (pinned to the end), Timeline (stages, elapsed), Breadcrumbs, Badge/Chip, Confirm (tap twice), Skeleton, Markdown (the notebook tab), Sparkline, Route (deep links: `#/models/<name>/<tab>`) |

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | The measure | `scripts/console_fixture.py` replays the `/admin/*` replies recorded from a real daemon (fake `max`, as mxconsole's tests do) so both consoles show the same data; `scripts/console_side.py` shoots every screen of the original console and of ours at 1440×900 and 390×844 with motion off; the original against itself sets the noise floor |
| M1 | HTTP, a component | `mojoui/http.mojo` + its test against a Python test server: GET and POST JSON, headers (the admin key by env var name), chunked replies, a 1 MB body, a timeout, connection refused, a 500; the reply arrives as an `Event` while frames keep drawing (a check counts frames during a 2 s slow reply); GTK, the web host and the Mac (CI) |
| M2 | Timers and real JSON | `App.every` on GTK, the web and the Mac: 10 ticks of 100 ms land within ±20 ms each; `json.mojo` reads every recorded console reply and equals Python's `json.loads` value for value |
| M3 | The omxqua theme | `themes/omxqua.mojo` declares a `Look` from omxqua's tokens (Geist, accent, surfaces, one soft shadow, the press spring); the kitchen screen in omxqua on the web matches omxqua's own component page within M0's tolerance |
| M4 | The console's components | each widget in the table above in `mojoui/`, its own test, on GTK and the web, built for the Mac; `docs/components.md` regenerated; nothing console-specific left in the app (the debt table stays empty for it) |
| M5 | My models and the model page | `examples/console`: the model list (table and cards, tick to change many, drag onto a label), the model page's overview, benchmark, logs and notebook tabs; live numbers from the poll; Jupyter opens in an iframe on the web, in the browser on GTK and the Mac |
| M6 | The other screens | Add a model (search with fit badges, the stage timeline, the live log, the Ready card with curl to copy), Keys (create, rotate, revoke by tapping twice), Gateway, Security (share on the LAN), Settings |
| M7 | Identical | the web: every M0 screen ≥ 99 % of pixels equal to the original's (above the noise floor), desktop and phone widths; GTK and the Mac: every view's box within goal 32's parity tolerance of the web's; on a live daemon (scripts/live.py): load a model, its tokens per second update, create a key and use it on `/v1`, revoke it, stop the model |
| M8 | In the gallery, nothing regressed | the console in docs/gallery beside omxplorer (shots on GTK, the web and the Mac); goal 32's checks pass |

## Decisions in this draft (instead of asking)
- **HTTP: our own small client now, flare later.** Ehsan Kermani's [flare](https://github.com/ehsanmok/flare) (MIT,
  v0.13, HTTP/1–3, TLS, WebSocket) is the right long-term stack, but it needs Mojo ≥ 1.2 (we pin 1.1), builds C shims
  and OpenSSL, and targets Linux and macOS only (no iPhone or Android). The console talks plain HTTP to its own daemon
  on 127.0.0.1, so M1 is a small HTTP/1.1 client on libc sockets that works on every host. `mojoui.http` keeps one API so
  flare can sit behind it when we move to Mojo 1.2 and need TLS.
- **The console is an example in this repo** (`examples/console`), pointed at the daemon by URL. Swapping mxconsole's
  shipped JS console for it is a later call for the owner.
- **Calls run off the frame:** the host does the request on a worker and posts the reply back, as goal 30's background
  queries do; a blocking call in `update` is never allowed (a check).

## Out of bounds
Changing mxconsole's daemon or its API; the `/docs` API page and the installer page (server-rendered, not the
console); the tray icon and the pywebview window; TLS; iPhone and Android; pushing.

## Risks
- **Size.** Ten screens is bigger than any goal so far. If M5 runs long, M6 becomes its own goal.
- **99 % of pixels** is strict: fonts, anti-aliasing and timing differ even between two runs of the original. M0
  measures that floor first; the threshold is 99 % above it, never lowered.
- **Native isn't pixel-identical.** GTK and the Mac use native widgets, so they're held to box positions, not pixels.

## Done means
`scripts/check` prints PASS for M0–M8; the reviewer passes it; `docs/report.md` is short, with side-by-side shots of
the original console and ours.
