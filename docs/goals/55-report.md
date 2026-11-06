# Goal 55 report: omxconsole, LM Studio for MAX, all omxcode

**End goal (owner, 2026-11-05):** "a simple app, a desktop app, which wraps around MAX and does all the MAX [things]
with benchmarking and an easy to use interface just like LM Studio… as long as everything is built using omxcode it
can go into the gallery." Worktree `../mojo-ui-g55`, branch `goal-55-console`, off main (Mojo 1.2). Reviewer: PASS
(round 3). Decisions D-5501–D-5532.

| # | Milestone | Result |
|---|---|---|
| M0 | consoled starts on a first run (creates its store) | PASS |
| M1 | find models: `mojoui.hf` (Hub search with sizes, files, downloads), consoled's search asks the Hub | PASS |
| M2 | download: pulls with progress, resume, cancel; delete; sha256 = the Hub's; test_safety, test_consoled_paths | PASS |
| M3 | chat: try/chat, the OpenAI SDK with a key, the console's search → pull → load → reply on GTK | PASS |
| M4 | benchmark: p50 333.1 tok/s vs the SDK's 335.2 (same workload, quiet GPU); the console's Benchmark tab | PASS |
| M5 | one download: the console starts and stops its own consoled (a killed console's too); runs bare | PASS |
| M6 | Mac: omxconsole.app built on GitHub's macOS 15 and 26 runners, starts consoled, says MAX isn't installed | PASS |
| M7 | in the gallery with its Linux and Mac downloads (gallery-apps), each run | PASS |

## What the framework gained (any app)
`mojoui.hf` (the Hugging Face Hub), `http_flare.fetch_to_file` + `Transfer` (resumable downloads; redirects followed
with the token kept only on same-host HTTPS), `http_flare.stream_timed` (a stream's chunks with their times),
`mojoui.companion` (a helper started beside an app, stopped with it, ending itself if the app dies),
`files.remove_tree` (never follows a symlink), `examples/<app>/companions` built by build.sh on Linux and on a Mac,
package.sh for any product (Flare's shims bundled), AppKit's `say:` test step, Flare's shims loadable on a Mac.

## 30-second demo
```bash
cd ../mojo-ui-g55
scripts/build.sh console linux && build/console/linux/console   # starts its own consoled on :11435 unless one answers
```
(Needs MAX: MXC_MAX=/path/to/max. The download: gallery-apps, omxconsole-linux-x86_64.tar.gz / omxconsole-mac-arm64.zip.)

## Worth a second look
- D-5516 → D-5528 → D-5532: M4 once passed on best runs (withdrawn); it now waits for a quiet GPU and brackets the
  benchmark with SDK runs. Other projects share this GPU.
- D-5531: a killed console left a consoled holding 7.5 GB of GPU; helpers now end with their app.
- D-5526: the Mac download is the macOS 15 runner's build; not yet run with MAX on a real Mac.

## Not done
Switching the owner's machine from the Python daemon (needs their yes); MAX on a real Mac (the M4 Mac Pro); model
porting and robotics models (later goals); LAN expose, tray, CLI.
