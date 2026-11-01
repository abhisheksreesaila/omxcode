# Claims ledger

Every number and claim in this kit, and where it comes from. If a line isn't here, it doesn't get posted. Codes like
`[S4]` appear in the kit files so you can look them up. They're for checking, not for posting.

| Code | Claim as we say it | Source |
|---|---|---|
| S1 | DROID's public 720p port: **67,029 real robot episodes** (53,282 success + 13,747 failure), **326 hours**, from **13 labs**, **CC-BY-4.0** | `~/data/robot-scout/REPORT.md` (counted from the repos' file lists, 2026-10-31); HF `jnogga/droid_success`, `jnogga/droid_failure` |
| S1b | The full DROID dataset: "76k demonstration trajectories or 350h", "564 scenes and 86 tasks", "13 institutions". Paper: Khazatsky, Pertsch et al., 2024 | droid-dataset.github.io (read 2026-10-31); arxiv.org/abs/2403.12945 |
| S2 | The prototype: **994 episodes**, 3.0 h, 3.6 GB, one camera. **Only 2 labs** (AUTOLab 626 + RAIL 165 successes; all 203 failures are AUTOLab) | REPORT.md, "The 1k sample on disk" |
| S3 | Per episode: 720p H.264 video at 15 fps (3 cameras), **52 telemetry channels at 15 Hz** incl. 7 joint velocities and the gripper position. **No force, torque or effort** | REPORT.md, comparison table and caveats |
| S4 | A chart over 1M rows: **0.5–0.7 ms** (we say 0.6 ms); status-bar sum: 0.3 ms; 1M-row grid scroll: 0.8 ms p95 a frame; 20M points: 1.5 ms (130 ms on the CPU); a 100M-row file opens in 0.2 s. One Linux machine, RTX 3090 | README.md, "Measured" |
| S5 | The window keeps up: a watchdog (`MOJOUI_BUDGET_MS`) prints a `SLOW:` line for any update, view or draw over budget; goal 41's sessions (video, 1M-row insert, query, export) ran with **0 `SLOW:` lines at 50 ms**, headless with CPU drawing. Open edge: a median over 100M rows in memory still makes the window wait ~0.7 s (README "The honest edge") | docs/goals/41-report.md M1–M3; docs/ui-threads.md "How it's checked" |
| S6 | Video decodes on its own thread: open ≈ 40 µs, seek ≈ 6 µs, newest seek wins; scrubbing gaps 17 ms | docs/goals/41-report.md (framefeed, M2) |
| S7 | Linux: a 1.5 s job ran while the window drew 90 frames, longest gap 17 ms | docs/ui-threads.md, platform table (`examples/jobwake`) |
| S8 | Mac: background jobs got their own threads; the longest frame gap during a 1.5 s job went from **1516–1527 ms to 71–83 ms** (GitHub's virtual Macs, macOS 15 and 26) | docs/ui-threads.md; docs/decisions.md D-792 |
| S9 | Mac GPU: the engine's queries ran on Apple's GPU through Metal on GitHub's macos-26 runner, the sum equal to the CPU's and NVIDIA's. Real MacBook numbers: **not measured yet**. The published Mac download is the CPU build | docs/decisions.md D-308; docs/forum/modular-license-runtime.md |
| S10 | Explicit links between cards by **key, time or place**, with match counts; a link implies a quoted `JOIN`; asks in words can use `JOIN LINKED`; hold a card to peek at what's linked | docs/goals/41-report.md ("Links"; M6, M8 PASS) |
| S11 | Every omxcode app is an MCP server with no per-app work; `scripts/agent.sh omxplorer` prints the `claude mcp add` line; a disabled button isn't a tool | README.md "Agent native"; docs/agent.md |
| S12 | AG-UI: omxcode reads every listed AG-UI event (official SDK `ag-ui-protocol` 1.0.0 used as the check); `examples/agentchat` on GTK and the web: streamed words, a chart and a form built by the agent | EXPERIMENTS.md, Experiment 35 |
| S13 | omxplorer opens in Liquid dark | docs/goals/41-report.md M5, "Look" |
| S14 | Packs: goal 41 exports a claim pack (PDF + video reel) as a background job | docs/goals/41-report.md M10 |
| S15 | Mojo 1.1; no official iPhone, Android or WebAssembly target (two hand-written runtime functions stand in); no Windows release | README.md "Why Mojo, honestly" |
| S16 | Android: the classic controls run as real Android views on the emulator; iPhone builds and signs, not run on hardware | README.md "Where it stands"; docs/components.md |
| S17 | Web today: the same app served by FastHTML, checked in Chromium (the server computes, the page shows it). WebGPU in the browser is roadmap | README.md table; owner's platform note (2026-11-01 kit brief) |
| S18 | MIT licence; repo github.com/abhisheksreesaila/omxcode | README.md |
| S19 | omxplorer is the product; omxcore the engine, omxcode the framework, omxqua the design language, omxconsole local AI | ~/Projects/omxlabs/README.md |
| S21 | A speech model already runs in the app's process (`examples/dictate`, PyTorch fp16 on the GPU) | EXPERIMENTS.md, goal 43 |
| S20 | The docs ship as `llms.txt` / `llms-full.txt` so an agent can read them | README.md "Read more" |

## Claims that depend on tonight's build

These are in the story but **not proven by anything in the repo yet**. Only post them if the recorded clip shows them:

- the fleet sheet of DROID episodes, the pivot by lab, the failure's video beside joint-velocity and gripper charts on one cursor;
- the robot ask that uses `JOIN LINKED` (the feature is proven in goal 41 on the claims data, S10, not yet on robot data);
- the linked document (DROID paper or the Franka datasheet) and the exported pack for a robot episode;
- **the Mac running the robot story on its GPU.** S9 is the only Mac GPU proof (a virtual Mac). If you record on your MacBook, that clip becomes the proof; if you don't, say "the same queries run on Apple's GPU through Metal" and nothing about speed.

## Things we must not say

- Any per-lab success rate from the 994 sample. Its failures all come from one lab's files (S2), so "AUTOLab fails more" would be a sampling artefact, not a finding. Show the pivot as the action; don't read its numbers as a result. (Fix: grow to 10k across 13 labs first, see shot-list.md.)
- "Force spike" or "grip force" for DROID. There's no force data (S3).
- That agents already know Mojo. They use the **app** through MCP; to **write** apps they read our docs (S20).
- "Production ready". It's a public alpha (README badge).
