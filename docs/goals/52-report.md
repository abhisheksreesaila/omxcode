# Goal 52 report: everything on Mojo 1.2, Flare 0.13, the engine beside Flare

**End goal (owner, 2026-11-05):** "you can move to Mojo 1.2 .. not a big change anyway"; mid-run: "ensure it does not
interfere with our UI thread and blocks" (M7) and "we can log tickets for flare". Worktree `../mojo-ui-g52`, branch
`goal-52-mojo12` (from goal-50-native 4352a74), its own env. Not merged, not pushed (except scripts/mac-ci's mac-test).
Decisions D-5201..D-5217; journal "Goal 52".

## How far it got
`scripts/check` (docs/goals/52-check.py), final run on these sources:

| # | Milestone | Result |
|---|---|---|
| M0 | Own env: Mojo 1.2.0 (MAX 26.7.0) here, 1.1 in ../mojo-ui and ../mojo-ui-g50 | PASS |
| M1 | Engine = omxcore 834ef9a + vendor/patches/omxcore-834ef9a-mojo12.patch built by 1.2; lineage proved; 40/40 engine tests; GPU switch as on 1.1 | PASS |
| M2 | Flare v0.13.1 + json v0.4.2; the stream-body patch proved still needed; link, HTTPS, serve, process, hash | PASS |
| M3 | Same sweep as on 1.1: 96/101 example builds (1.1: 96), 104/140 tests (1.1: 100/137), nothing lost; iPhone KGEN_ set unchanged; libc lint | PASS |
| M4 | omxconsole: a real Qwen chat through `max serve` and the Mojo gateway; goal 50's M6 red only on goal 33's M5, as before | PASS |
| M5 | Engine jobs answering requests through Flare in one program (was impossible: D-4783) | PASS |
| M6 | GitHub's Macs (run 42104613263, these sources): maccheck exit 0, console + widgets 110 pictures, no crashes, macOS 15 and 26 | FAIL: omxplorer only (below) |
| M7 | A 4 ms frame loop through serving, SSE, proxy, HTTPS and engine jobs: longest gap 4-5 ms; Server.start ≤ 21 ms; stop() 0 ms; lifecycle test | PASS |

**Why M6 is red:** omxplorer's Mac cross-build fails on 1.1 too (docs/goals/52/baseline.json): its video, document
and vision parts need Python and libc functions apple/sdk's stubs don't list, so there's no zip for the Mac run, and
the run's native GPU build and GPU probe only run with omxplorer. Not loosened. The owner's M4 Mac Pro is the next way
to check the Metal path on 1.2.

## What changed for the framework
- Mojo 1.2 everywhere: one Mac line (objc's UTF-8 pointer); the engine's GPU query; nothing else in mojoui.
- The engine declares no disputed libc function (looked up at run time): engine + Flare in one program.
- `Server.start` returns a `Served` (keep it; `stop()` returns at once; `stopped()`); it returns once a worker answers.
- mojoui.serve keeps Flare's serving loops off Mojo's runtime pool, so `parallelize` work (the engine, MAX) never waits
  behind them and programs can exit.
- scripts/flare_ffi.sh: Flare's own link lines and a load check of every shim; libc_lint rejects a thread id read back
  through a local's address.

## Upstream (filed, owner's go)
flare#46 streamed requests drop their body · flare#47 serving loops on the AsyncRT pool (parallelize hangs, no exit) ·
flare#48 no listener for a moment after bind. omxcore: docs/goals/52/omxcore-mojo12.md (not filed: another session's repo).

## 30-second demo
```bash
cd ../mojo-ui-g52
pixi run mojo --version                                 # Mojo 1.2.0
scripts/mojo_flare.sh build tests/test_engine_flare.mojo -o build/t && build/t   # engine jobs served by Flare
scripts/mojo_flare.sh build tests/test_ui_thread.mojo -o build/u && build/u      # frame loop gaps under load
scripts/check M5 M7
```

## Three decisions worth a second look
1. **D-5202: the engine is 834ef9a + our patch**, not a new omxcore stable commit (omxcore's main is another session's).
   The patch is ready for omxcore's stable process.
2. **D-5207: mojoui holds Flare's pool leases** so its loops run on OS threads. It reaches into an underscore module of
   Flare until #47 gives a supported switch.
3. **D-5214: `stop()` doesn't wait.** The record is shared by the handle and the serve thread; the last one frees it.

## Next
The M4 Mac Pro: the engine's Metal tests, the GPU probe and a native omxplorer build on 1.2; then merge goal 50 + 52.
