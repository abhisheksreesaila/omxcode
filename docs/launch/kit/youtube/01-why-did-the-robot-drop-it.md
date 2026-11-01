# YouTube 1 · Why did the robot drop it?

**Length:** about 5 min · **Record:** omxplorer, Liquid dark, Linux · **Post:** Mon Nov 2

## Titles (≤ 60 characters)
1. Why did the robot drop it? Real robot data, one GPU app
2. Debugging a robot failure: video, telemetry, one cursor
3. Real robot failures, debugged in one app on the GPU

**Thumbnail:** `[shot: failure-cursor]`, darkened on the left; big text **WHY DID IT DROP?**; small mono line under it: `DROID · 13 labs · on the GPU`.

## Script

| Time | On screen | Say (riff on it, don't read it) |
|---|---|---|
| 0:00 | `[clip: robots-15s]`, no voice for 3 s | "A robot reaches for a block and drops it. *(drop line)* Why? Let's find out with real data, in one app." |
| 0:20 | Your face or the desktop; DROID's site | "The data is DROID. Real robot episodes from 13 labs, released under CC-BY. The public 720p version has 67,029 episodes. 63,344 of them are in this sheet." |
| 0:45 | omxplorer opens, Liquid dark, the fleet sheet `[shot: fleet-sheet]` | "This is omxplorer. Each row is one episode: the lab, the robot, the task, success or failure, the length." |
| 1:10 | Pivot: success by lab `[shot: fleet-pivot]` | "Pivot success by lab. One click." *Add:* "Labs ran different tasks, so this is the spread, not a ranking." |
| 1:35 | Filter to failures, click one | "Let's open a failure." |
| 1:45 | Video left, joint-velocity and gripper charts right, one cursor | "Here's what the camera saw. Here's what the seven joints did. Here's the gripper. They share one time cursor." |
| 2:10 | Drag the cursor slowly through the grasp `[clip: scrub-cursor]` | "Watch the gripper line and the video together." *(Then say what your episode actually shows: when the gripper closes, when it opens, what the camera sees at that moment. Don't claim a cause the footage doesn't show.)* |
| 2:50 | Type the question in words; the SQL with `JOIN LINKED` shows `[clip: ask-join-linked]` | "Now ask in words. It writes the SQL. JOIN LINKED means: follow the links I made between the sheet, the video and the documents. Nothing gets joined by guessing." |
| 3:30 | The linked document opens; hold to peek | "The robot's datasheet is linked to these episodes by robot model. Hold a card and it shows what it's linked to." |
| 3:55 | Export pack `[clip: export-pack]` | "Export a pack: the clip, the charts, the document. Send it to whoever has to fix the robot." |
| 4:15 | Scroll the grid hard while a query runs | "And the whole time, the window kept up. The heavy work runs on its own threads. That's the next video." |
| 4:35 | `[shot: code-file]` | "It's one Mojo codebase, built on my framework omxcode. The data work runs on the GPU in the same process as the window. Linux and Mac today; web, Android and iPhone next." |
| 4:55 | The repo page | "It's open source, MIT, public alpha. Link below. Tell me what you'd ask this data." |

## Description

```
Why did the robot drop it? Real robot data from DROID (13 labs, CC-BY-4.0), opened in omxplorer: a fleet spreadsheet, a pivot by lab, and a failure's video next to its joint-velocity and gripper telemetry on one time cursor. Ask in words, follow explicit links to the robot's documents, export a pack. Heavy work runs off the UI thread.

omxplorer is built with omxcode, a UI framework in Mojo: one codebase from the button to the GPU kernel. Linux and Mac today; the web on WebGPU, Android and iPhone next. Public alpha, MIT.

Code: https://github.com/abhisheksreesaila/omxcode
Site: https://abhisheksreesaila.github.io/omxcode/
DROID dataset: https://droid-dataset.github.io/
DROID paper (Khazatsky, Pertsch et al., 2024): https://arxiv.org/abs/2403.12945

Chapters
0:00 A robot drops a block
0:20 The data: DROID
0:45 The fleet sheet
1:10 Success by lab
1:45 One failure, one cursor
2:50 Ask in words (JOIN LINKED)
3:30 The linked datasheet
3:55 Export a pack
4:15 The window kept up
4:35 How it's built
```

**Tags:** robotics, robot learning, DROID dataset, Franka Panda, data visualization, Mojo, Mojo language, GPU, spreadsheet, telemetry, robot failure analysis, omxplorer, omxcode, open source

*Sources: S1, S2, S3, S10, S5, S9/S16/S17, S18. Re-time chapters to the final cut.*
