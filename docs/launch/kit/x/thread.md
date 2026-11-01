# X: the launch thread (Sunday Nov 1, after the forum post)

Post 1/ first, then reply to it with each next post. Attach the media named under each post. Every post is under 280
characters (checked by script). Copy only the text between the lines.

---
**1/** · attach `[clip: robots-45s]`

Why did the robot drop it?

Real data: DROID, robot episodes from 13 labs. A fleet sheet, a pivot, a failure's video next to its joint and gripper telemetry, on one time cursor.

One app, written in Mojo, on the GPU. It's called omxplorer. 🧵

---
**2/** · attach `[shot: fleet-pivot]`

Open the fleet sheet: 63,344 episodes. Pivot by lab. Click a failure.

The video plays beside joint velocity and the gripper's position. Drag the cursor and all three move together.

No notebook, no export, no second app.

---
**3/** · attach `[clip: scrub-cursor]`

The data never leaves the app. The group-by runs on the GPU in the same process that draws the window.

A chart over 1M rows: 0.6 ms on an RTX 3090. No server, no JSON in between.

---
**4/** · attach `[clip: ask-join-linked]`

Ask in words. It writes the SQL.

The sheet, the video and the paper are joined by links I made on purpose, by key, time or place. Nothing joins by guessing. The SQL says JOIN LINKED, so you can read exactly what it did.

---
**5/** · attach `[clip: never-freeze]`

The window doesn't freeze. Queries, imports, video decoding and exports run on their own threads; the answer comes back as an event.

A watchdog prints a line for anything over budget. My checks run video, query and export sessions at 50 ms: zero lines.

---
**6/** · attach `[shot: mac-linux]`

Built on omxcode, my framework: one Mojo codebase from button to GPU kernel. Linux and Mac today.

Next: the web on WebGPU, then Android and iPhone. Every app is also a set of MCP tools for agents.

---
**7/** · no media

Public alpha, MIT. Every number has a script in the repo behind it.

Code: github.com/abhisheksreesaila/omxcode
Site: abhisheksreesaila.github.io/omxcode

---

*Sources: DROID S1, cursor S10 (tonight's build), 0.6 ms S4, links S10, never freezes S5, platforms S9/S16/S17, MCP S11.
After omxlabs.tech is live, swap the site line for `omxlabs.tech`. If the recorded failure isn't a drop, change 1/'s
first line to "Why did the robot fail?"*
