# Goal 50 report: the framework serves, fetches and supervises; omxconsole's daemon in Mojo on it

**End goal (owner, 2026-11-04):** omxconsole Mojo end to end as "a convenient wrapper on Max Serve", built from
framework pieces ("the star of the show is OMX code … don't overfit OMX console"), HTTP from Flare ("I would rather trust
that than write something on my own"). Worktree `../mojo-ui-g50`, branch `goal-50-native` (off main bfacc58). Not merged,
not pushed. Plan: docs/plans/omxconsole-native.md; decisions D-4757..D-4777; journal "Goal 50".

## How far it got
`scripts/check` (docs/goals/50-check.py):

| # | Milestone | Result |
|---|---|---|
| M0 | Flare v0.12.0 + json vendored (MIT, NOTICE), shims built, mojoui and Flare link in one binary | PASS |
| M1 | HTTPS for every app: FlareTransport behind mojoui.http; test_http on both transports; Hugging Face over HTTPS; iOS and Android still build | PASS |
| M2 | mojoui.serve: routes, JSON, SSE pipes, proxy, a lock; curl and the OpenAI SDK | PASS |
| M3 | mojoui.process: spawn, log, health, crash tail, stop the group, idle | PASS |
| M4 | consoled answers the console's 18 reads in the original's shapes from the real store; labels and keys persist (SHA-256, interchangeable with the Python daemon's); the console on GTK against it | PASS |
| M5 | `max serve` per model, /v1 gateway with keys: the OpenAI SDK streams a real Qwen2.5-0.5B chat; logged, metered, idle unload | PASS |
| M6 | No Python under consoled but `max serve` and its workers; goal 48's M0; the component matrix; **goal 33's M5** | FAIL: goal 33's M5 only (below) |

**Why M6 is red:** goal 33's M5 (the console against its recorded fixture server) fails on unchanged main too, run on this
machine at bfacc58 in `../mojo-ui-g50-baseline`: the same "asked for what the daemon doesn't answer: ['GET /']" on every
screen and polls faster than the recorded 3 s / 5 s (1.1 to 2.5 s, varying run to run). The console's code hasn't changed
since goal 33's review fixes; the cause is older than this goal or in this machine (a program here probes local ports with
user agent "node": seen hitting mojoui.serve too). Not fixed here and not loosened: it stays a FAIL until someone finds it.

## What the framework gained (any app can use these)
- `mojoui.serve`: `Service.answer(req) -> Reply` with `req.matches("GET", "/models/{name}")`, `Server.run(service, port)`,
  `Pipe` streams filled by threads, `proxy(request, pipe)`, `Service.tick()` timers, `Service.stop()` on SIGTERM/SIGINT.
- HTTPS for every app on Linux (and macOS, not built here yet): `FlareTransport` behind `mojoui.http`; https:// picks it.
- `mojoui.process`: children in their own group, logged, health-probed, stopped TERM-then-KILL, `output()` for quick commands.
- `mojoui.hash` (SHA-256 in plain Mojo), `mojoui.libc` (one declaration per libc function, Flare's types) + `scripts/libc_lint.py`.
- `mojoui.sqlite`: `one_text(sql, args)` and `run(sql, args)`, so SQLite builds a reply's JSON itself.

## 30-second demo
```bash
cd ../mojo-ui-g50
scripts/mojo_flare.sh build examples/consoled/main.mojo -o build/consoled
pixi run python scripts/store_copy.py build/demo                 # a copy of ~/.mxc/mst.db (WAL included)
MXC_HOME=build/demo MXC_PORT=11436 MXC_MAX=~/Projects/mxstudio/.pixi/envs/default/bin/max build/consoled &
MXC_URL=http://127.0.0.1:11436 scripts/build.sh console linux && build/console/linux/console
curl -s -X POST -H 'X-Mst-Admin: 1' -d '{"app":"demo"}' localhost:11436/admin/keys      # a key
# then any OpenAI client: base_url=http://127.0.0.1:11436/v1, model="qwen2.5-0.5b"
```
Screens against consoled: docs/goals/50/console-models-consoled-gtk.png, -overview-, -keys-.

## Three decisions worth a second look
1. **D-4757: Flare v0.12, not 0.13, and no Mojo 1.2 move.** 0.12 has everything we used and runs on our Mojo 1.1; 0.13
   needs 1.2, which needs a new omxcore engine build in its own repo. Plan ticket F-1 moved out of this goal.
2. **D-4774: consoled runs mxstudio's `max serve` (MXC_MAX).** This repo's MAX has no serving extras; pulling MAX's Python
   serving stack into the framework repo would undo the all-Mojo story. A shipped omxconsole needs a MAX install with
   `max serve` beside it: that's the packaging question for the gallery card.
3. **D-4775: one patch to vendored Flare.** Its streaming client sent requests without their body; 20 lines fix it,
   kept in vendor/patches, upstream report drafted (docs/goals/50/flare-issue.md, not filed).

Also: the engine (omxcore) declares `pthread_create` differently from Flare, so one binary can't use engine jobs and
Flare threads yet (D-4761, D-4764; issue drafted in docs/goals/50/omxcore-issue.md, not filed). mojoui itself builds beside
both (it looks the three disputed functions up at run time).

## Not done (later goals)
Pulls and search over the network, bench, LAN expose, tray, the `omxc` CLI, the web build of the console (its host is
FastHTML), and packs/YOLOX/decision models (goal 49's M2 and M4). The gallery card returns only when the owner says.

## Next
Find goal 33's M5 cause on main (port probes vs. timer drift), then pulls/search over HTTPS and the `omxc` CLI.
