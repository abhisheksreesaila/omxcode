# GOAL 55: omxconsole, a desktop app for MAX, all omxcode

**End goal (owner, 2026-11-05):** "All we need is a simple app, a desktop app, which wraps around MAX and does all the
MAX [things] with benchmarking and an easy to use interface… as long as everything is built using
omxcode it can go into the gallery." No Python service of ours: the Mojo consoled (goals 50/52, on main) replaces
mxstudio's daemon; only `max serve` itself is Python. Worktree `../mojo-ui-g55`, branch `goal-55-console`, off main
(Mojo 1.2). (Goal 54 is another session's: omxplorer's shell, `../mojo-ui-g54`.)

## Milestones
| # | Milestone | Proof (`scripts/check`, docs/goals/55-check.py) |
|---|---|---|
| M0 | Baseline | console and consoled build on main; consoled on a throwaway MXC_HOME and port, with this env's MAX, answers /health |
| M1 | Find models | `mojoui.hf` (any app: Hub search, a repo's files, sizes and revision) with tests/test_hf.mojo on the live Hub; consoled's /admin/search?q= answers any query from the Hub with sizes and a fits-this-machine flag |
| M2 | Download | `mojoui.hf` downloads a repo's files with progress, resume and cancel; POST /admin/pulls + GET /admin/pulls/{id} pull Qwen/Qwen2.5-0.5B-Instruct into MXC_HOME (each file's sha256 = the Hub's LFS id), register it; a cancelled pull leaves no model; DELETE /admin/models/{name} removes files and row |
| M3 | Chat | POST /admin/try/chat answers from the pulled model through `max serve`; the OpenAI SDK streams a chat with a key; the console on GTK, driven by steps, searches, pulls, shows Ready and a real reply in its chat |
| M4 | Benchmark | POST /admin/bench runs a fixed workload; GET /admin/bench reports time to first token and decode tokens/s per model, within 25 % of the OpenAI SDK's own streaming measurement; the console's Benchmark tab draws the bars |
| M5 | One app, one download | the console starts its own consoled when none answers and stops it on quit (a framework piece any app can use); `scripts/package.sh omxconsole linux` (console + consoled) unpacked and run with no Mojo or pixi and a fresh HOME draws its window, its consoled answers, and a chat works with MXC_MAX naming a MAX install |
| M6 | Mac | console + consoled build for the Mac; on GitHub's macOS 15 and 26 runners the app opens, starts consoled, and says MAX isn't installed (no MAX there) without a crash |
| M7 | In the gallery | an omxconsole card with its downloads (each one run), the gallery-apps release holding them; docs/goals/53-check.py passes |

## Done means
`scripts/check` prints PASS for M0–M7, the reviewer passes it, and main carries it (the owner allows pushing main after
a reviewer PASS and green checks).

## Out of bounds
The owner's running Python daemon on :11435 and the real `~/.mxc` (never read, written or stopped: switching over needs
the owner's yes at that moment); `~/Projects/mxstudio`; `../mojo-ui-apple-test`; goal 54's worktree. No secrets (public
models only, no Hugging Face token). No paid services. Pushing: the mac-test branch and mac-ci release (scripts/mac-ci),
the gallery-apps release, and main at the end. Model porting and robotics models (later goals). LAN expose, the tray,
the `omxc` CLI.

## Assumptions
- Pulled weights go to a plain folder, MXC_HOME/models/<owner>--<name>/, served with `max serve --model-path <folder>`
  (the Python daemon's local-weights path), not Hugging Face's cache layout.
- Tests use Qwen/Qwen2.5-0.5B-Instruct (~1 GB, Apache-2.0) on this machine's RTX 3090; the network is up.
- The download needs MAX installed by the user (as any local-model app needs its runtime); MXC_MAX or `max` on PATH.
- Benchmark workload: 5 chat prompts, 128 tokens each, one at a time.

## Budget
80 turns.
