# omxplorer talks: three parts

Open a part's `index.html` in a browser, press `S` for the speaker notes, arrow keys to move. Each part is a complete
talk with its own intro and outro; record any subset. Lengths are the speaker notes at 150 words a minute. Sources live
in `../_src/omxplorer-part*.html` (build: `pixi run python docs/launch/kit/talks/build.py`).

| Part | Folder | Slides | Length | What it is |
|---|---|---|---|---|
| 1 | [part1/](part1/index.html) | 14 | ~4:50 | The robot story: why did the robot drop it? (F00118 beat by beat, on real DROID data) |
| 2 | [part2/](part2/index.html) | 14 | ~5:05 | "Not a replay. An investigation.": the five ideas (fleet as a sheet, question → moment, documents in the join, links by hand, no server) |
| 3 | [part3/](part3/index.html) | 12 | ~4:30 | Beyond robots (sentence charts, 100M rows, video as rows, linked evidence) and where we're behind |

**Before recording part 1:** slide 9 plays `img/clip-robots.mp4` (42 s, no sound); talk over it. If you'd rather
record your own screen there, skip the slide.

---

## Part 1 · Why did the robot drop it?

**Titles (≤ 60 characters)**
1. Why did the robot drop it? Real robot data, one GPU app (55)
2. 63,344 robot episodes, one question, one cursor (47)
3. Debugging a real robot failure in one Mojo app (46)

**Thumbnail:** the drop frame (`img/robots-06-drop-falling.jpg`, cropped to the video), darkened left; big text
**WHY DID IT DROP?**; small mono line `63,344 episodes · 13 labs · ~40 ms`.

**Description**
```
Why did the robot drop it? Real public robot data (DROID: 13 labs, CC-BY-4.0) opened in omxplorer: the whole fleet as a spreadsheet, success by lab, a pivot, and one failure's video beside its joint and gripper telemetry on one cursor. A question in words over 16.8M telemetry rows answers in about 40 ms, with no Python and no server.

They replay a recording. omxplorer starts from a question across the whole fleet, then shows you the moment.

Part 1 of 3. Built in Mojo with omxcode; public alpha, MIT.

Try it: https://omxlabs.tech
Code: https://github.com/abhisheksreesaila/omxcode
DROID dataset: https://droid-dataset.github.io/
DROID paper (Khazatsky, Pertsch et al., 2024): https://arxiv.org/abs/2403.12945

Chapters
0:00 Why did the robot drop it?
0:27 One question, four apps
0:49 The data: DROID
1:12 The fleet as a sheet
1:31 Success by lab, typed as a sentence
1:50 Lab × outcome pivot
2:05 Four links, typed by a person
2:26 F00118: the gripper lets go over the edge
2:50 The whole story in 42 seconds
3:06 2,997 re-grasps in ~40 ms
3:26 The paper and the pack
3:50 What the data can't tell you
4:13 A question, not a replay
4:28 Try it
```

## Part 2 · Not a replay. An investigation.

**Titles (≤ 60 characters)**
1. Not a replay. An investigation. (31)
2. From a fleet-wide question to the moment, in one motion (55)
3. Links you confirm by hand: joining video, data and docs (55)

**Thumbnail:** the link-peek shot (`img/links-peek.jpg`); big text **NOT A REPLAY.**; small line `links you confirm · no server`.

**Description**
```
Five ideas behind omxplorer: the robot fleet is a spreadsheet you touch; a question in words goes to the moment in one motion (16.8M telemetry rows in ~40 ms, tap, video and telemetry on one cursor); documents sit in the same join; links are confirmed by hand by key, time or place, with no schema in code; and the analytics run in the app's own process, on your GPU or CPU (whichever the engine picks), with no server.

Part 2 of 3. Public alpha, MIT.

Try it: https://omxlabs.tech
Code: https://github.com/abhisheksreesaila/omxcode
DROID dataset: https://droid-dataset.github.io/ · paper: https://arxiv.org/abs/2403.12945

Chapters
0:00 Not a replay. An investigation.
0:20 1 · The fleet is a spreadsheet you touch
0:41 2 · Question → moment in one motion
1:02 The SQL says JOIN LINKED
1:20 3 · Documents in the same join
1:47 4 · Links you confirm by hand
2:13 Hold a card to see its links
2:30 No schema in code
2:52 A link in the framework
3:18 5 · No server: the query runs in-process
3:44 The window keeps up
4:08 Agents can investigate too
4:27 Recap
4:45 Try it
```

## Part 3 · Beyond robots, and what's next

**Titles (≤ 60 characters)**
1. Beyond robots: sheets, video and paperwork on one GPU (53)
2. A 100M-row dashboard at 30 ms a click, and what's next (54)
3. omxplorer: where it's ahead, where it's behind (46)

**Thumbnail:** the report shot (`img/readme-report.jpg`); big text **EVERY KIND OF DATA**; small line `100M rows · 30 ms a click`.

**Description**
```
omxplorer beyond robots: a chart you edit by tapping the words of its title, a 100M-row dashboard at about 30 ms a click (measured before the release build), video that becomes rows, and a video, a sheet and paperwork answering one question. Then, honestly, where we're behind: 3D scenes, MCAP and ROS bags, teams and more cameras. Robotics replay tools are great for replaying a recording; omxplorer starts one level up, and wants to sit alongside them.

Part 3 of 3. Public alpha, MIT.

Try it: https://omxlabs.tech
Code: https://github.com/abhisheksreesaila/omxcode

Chapters
0:00 Beyond robots, and what's next
0:17 The title is the chart
0:40 Words are buttons, buttons are tools
0:57 100M rows, 30 ms a click
1:17 A video becomes rows
1:37 The drone: what got worse
2:03 Linked evidence: video, sheet, paperwork
2:26 Find more like this
2:46 Where it runs
3:09 Where we're behind
3:38 What's next
3:57 Try it
```

*Every number on the slides has its source in the slide's bottom line. Re-time the chapters to the final cut.*
