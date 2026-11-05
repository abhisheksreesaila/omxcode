# GOAL 52: everything on Mojo 1.2, Flare 0.13, and the engine beside Flare

**End goal (owner, 2026-11-05):** "you can move to Mojo 1.2 .. not a big change anyway." Goal 35's draft
(docs/goals/35-draft.md, its number later went to AG-UI) on top of goal 50 (branch goal-50-native 4352a74), which already
did that draft's M2 (mojoui/libc.mojo + lint) and M4 (FlareTransport behind mojoui.http). The probe:
docs/research/mojo12-flare.md (branch probe-mojo12). Worktree `../mojo-ui-g52`, branch goal-52-mojo12.

## Milestones
| # | Milestone | Proof (`docs/goals/52-check.py`) |
|---|---|---|
| M0 | Its own env | `mojo --version` is 1.2 here and 1.1 in ../mojo-ui and ../mojo-ui-g50; this .pixi is a directory, not a symlink; pixi.toml pins `mojo >=1.2,<1.3` |
| M1 | The engine on 1.2 | vendor/omxcore.mojoc is the 1.2 build of omxcore 834ef9a's archive plus `vendor/patches/omxcore-834ef9a-mojo12.patch` (scripts/engine_lineage.py proves it: archive diffed, patch applied, size within 0.1 %); the patch touches only lines 1.2 or M5 need; a program built for Linux and one compiled for the Mac target see the engine's GPU switch as they did on 1.1 (Linux on, macOS on) |
| M2 | Flare 0.13 | vendor/flare is a Flare v0.13.x release (FLARE_VERSION, licences); the stream-body patch is kept only if 0.13 still drops the body (proved by a test either way); test_flare_link, test_https (a public site with the system CA bundle), test_serve, test_process, test_hash pass |
| M3 | Everything on 1.2 | the sweep (scripts/sweep.py) builds every example for each platform it lists (linux, web, mac, ios, android) and every Mojo test in tests/; nothing that built or passed in the same sweep on goal-50-native under Mojo 1.1 (docs/goals/52/baseline.json, made in ../mojo-ui-g50) fails here; iPhone objects need no new `KGEN_` symbols; scripts/libc_lint.py passes |
| M4 | omxconsole on 1.2 | goal 50's checker: M0–M5 PASS (a real Qwen chat through `max serve` and the Mojo gateway); M6 fails on nothing but what it failed on at goal 50 (goal 33's M5) |
| M5 | The engine beside Flare | tests/test_engine_flare.mojo runs an engine job (omxcore's thread pool, a group-by on a Frame) and answers an HTTP request through mojoui.serve (Flare) in one program; omxcore's pthread_create / pthread_detach / strtod / read declarations match Flare's (the omxcore issue drafted at goal 50) |
| M6 | The Mac on 1.2 | a fresh run on GitHub's Mac (scripts/mac-ci, side.mac_fresh) from these sources: maccheck's tests pass, omxplorer starts and draws, and the run's native GPU build used Mojo 1.2 |
| M7 | Flare never stalls the UI thread (owner, 2026-11-05: "ensure it does not interfere with our UI thread and blocks"; added during the run, D-5213) | tests/test_ui_thread.mojo, 5 runs: a main-thread frame loop ticking every 4 ms never gaps past 25 ms while the program serves (Flare), streams SSE, proxies, fetches over HTTPS through mojoui.http and answers engine jobs (27 requests at once, all 200); Server.start holds the caller ≤ 250 ms, stop() ≤ 5 ms, and the loops end within 3 s |

**Done means:** `scripts/check` prints PASS for M0–M7.

## Out of bounds
Pushing anything but the mac-test branch and the mac-ci release (scripts/mac-ci); committing to omxcore (~/Projects/mxframe,
another session's) or filing issues anywhere (the owner then allowed Flare issues: D-5215); changing engine code beyond what 1.2 and M5 need; touching
`../mojo-ui-apple-test`, the running Python daemon on :11435 or the real `~/.mxc`; `pip`; secrets; merging into main.

## Assumptions
- The engine goes in as 834ef9a + a patch kept here (as Flare's is), not a new omxcore stable commit: omxcore's main is
  busy with another session today; the patch is ready for its stable-engine process when the owner wants it.
- Flare moves to 0.13 now because it's why 1.2 was wanted; the newest 0.13.x tag, sources vendored as before (D-4759).
- "Nothing regressed" is measured against the same sweep on 1.1, not against a hand list: tests that need a server or
  data they don't find fail on both and are listed, not counted.
- 1.2's new "transfer has no effect" warnings are left alone (harmless; builds use --disable-warnings).

## Budget
80 turns.
