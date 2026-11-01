# Shot list

Record everything in **omxplorer, Liquid dark**, on the Linux machine (RTX 3090) unless the shot says Mac. 1920×1080,
60 fps, cursor visible, system notifications off. Name each file exactly as below so the kit's placeholders match.

## Before you record (10 minutes)

1. **The failure is picked: F00118** (AUTOLab, 2023-11-21, 16 s). The gripper opens at 12.7 s and the peach shirt falls
   outside the box. It's a real drop, so keep the *(drop line)* wording.
2. **Labs are done.** The fleet has all 63,344 episodes from 13 labs. The click path and what to say at each beat are in
   `docs/goals/47-report.md`, "Record it yourself". To re-record the clip and shots: `pixi run python scripts/clips.py robots`.
3. Turn on the watchdog for the freeze shots: `MOJOUI_BUDGET_MS=50` (what the checks prove), terminal visible at the side. Try 16 off camera first; only show 16 if it prints nothing.
4. Have the linked document ready (DROID paper PDF, arxiv.org/abs/2403.12945, or the Franka Panda datasheet).

## Already recorded (use these until you record your own)

- `[clip: robots-45s]` → `docs/img/clip-robots.mp4` (42 s, no narration) · poster `docs/img/clip-robots.jpg` (the drop)
- `[shot: fleet-sheet]` → `build/g47/shots/01-fleet.png` · `[shot: fleet-pivot]` → `03-pivot-lab-outcome.png` (and `02-success-by-lab.png`)
- `[shot: failure-cursor]` → `06-drop-falling.png` (and `07-drop-fallen.png`) · `[shot: linked-doc]` → `08-paper-15hz.png`
- `[shot: ask-sql]` → `09-ask-regrasped.png` · `[shot: pack-folder]` → `11-pack.png` · telemetry at scale → `04-telemetry-17m.png`

## Clips (moving)

| Name | Length | What's on screen | Used in |
|---|---|---|---|
| `[clip: robots-45s]` | 45 s | The whole story in one take: open the fleet sheet → pivot success by lab → click a failure → video plays beside joint-velocity and gripper charts on one cursor → scrub → ask in words (the SQL with `JOIN LINKED` appears) → the linked paper/datasheet opens → Export pack | X thread 1/, forum, PH video, YouTube 1, deck |
| `[clip: robots-15s]` | 15 s | Click a failure → video + telemetry on one cursor → scrub | X daily, PH gallery |
| `[clip: scrub-cursor]` | 10 s | Close-up: drag the cursor; video frame, joint-velocity and gripper lines move together | X thread 3/, YouTube 4 |
| `[clip: ask-join-linked]` | 12 s | Type the question in words; the sentence and its SQL (`JOIN LINKED`) appear; the table answers | X thread 4/, YouTube 4, 5 |
| `[clip: never-freeze]` | 20 s | Start a big import or query, keep scrolling the grid and scrubbing the video while it runs; the terminal shows no `SLOW:` line | X thread 5/, YouTube 2 |
| `[clip: slow-line]` | 8 s | A deliberately slow `update()` in a toy app (`examples/slowcheck`): the terminal prints `SLOW: update msg=… ms` | YouTube 2 |
| `[clip: mac-run]` | 15 s | **Mac.** The same story on your MacBook. Show "Apple" in the GPU line only if it's the Metal build | X thread 6/, YouTube 3 |
| `[clip: linux-run]` | 10 s | The same moment on Linux, GPU line reading the RTX 3090 | YouTube 3 |
| `[clip: agent-drives]` | 25 s | Claude Code with the omxplorer MCP tools: it opens the sheet, asks the question, exports the pack; the window updates by itself | YouTube 5, X daily |
| `[clip: agui-chat]` | 15 s | `examples/agentchat`: an agent streams words and builds a chart and a form natively | YouTube 5 |
| `[clip: export-pack]` | 8 s | Export pack → the folder opens with the episode's clip, charts and the linked document | YouTube 1, PH gallery |

## Shots (stills, 1920×1080 PNG)

| Name | What's on screen | Used in |
|---|---|---|
| `[shot: fleet-sheet]` | The fleet sheet, many rows, status bar showing the row count | X, PH gallery 2 |
| `[shot: fleet-pivot]` | Success by lab, as a pivot and a bar chart | X, PH gallery 3, deck |
| `[shot: failure-cursor]` | Failure open: video left, joint-velocity and gripper charts right, one cursor across all | X, PH gallery 1 (hero), deck |
| `[shot: ask-sql]` | The question in words and its SQL with `JOIN LINKED` | X, PH gallery 4 |
| `[shot: linked-doc]` | The document card linked to the episode (hold-to-peek: the rest dims, the link lifts) | X, PH gallery 5 |
| `[shot: pack-folder]` | The exported pack | PH gallery 6 |
| `[shot: slow-terminal]` | Terminal with the watchdog on and no `SLOW:` lines | X, PH gallery 7 |
| `[shot: mac-linux]` | Mac window and Linux window side by side, same screen | X, PH gallery 8, deck |
| `[shot: mcp-tools]` | The tool list an agent sees for omxplorer | X, YouTube 5 thumbnail |
| `[shot: code-file]` | One `app.mojo` in the editor: `view()` and `update()` | X, YouTube 3 |

## Thumbnails (YouTube, 1280×720)

| Video | Background | Big text |
|---|---|---|
| 1 | `[shot: failure-cursor]` | WHY DID IT DROP? |
| 2 | `[shot: slow-terminal]` + grid | 0 SLOW FRAMES |
| 3 | `[shot: mac-linux]` | ONE CODEBASE. LINUX + MAC. |
| 4 | `[shot: linked-doc]` | VIDEO + DATA + DOCS |
| 5 | `[shot: mcp-tools]` | THE AGENT CLICKS NOTHING |
