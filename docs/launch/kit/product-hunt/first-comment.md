# Product Hunt: the maker's first comment

Post it the minute the launch goes live.

```
Hi Product Hunt 👋 I'm the maker of omxplorer.

The question that started it: why did the robot drop it? To answer that today you open a spreadsheet of episodes, a video player, a plotting notebook and a PDF, and you copy between them. I wanted one place.

So omxplorer puts them on one page. The demo uses DROID, real robot episodes from 13 labs (CC-BY-4.0):

• open the fleet as a sheet and pivot success by lab
• click a failure: its video plays beside the joint and gripper telemetry, on one time cursor
• ask in words; it writes the SQL, and you can read exactly what it joined
• the robot's datasheet is linked by key, so it's one click away
• export the answer as a pack

Three things I care about:
1. It runs on your own GPU. The data work runs in the same process as the window: a chart over a million rows takes about 0.6 ms on an RTX 3090.
2. It never freezes. Queries, imports, video and exports run on their own threads.
3. Agents can use it. Every button is an MCP tool, so Claude or any MCP agent can drive it without screenshots, and it can't do anything you couldn't.

It's built on omxcode, my open-source framework in Mojo (MIT). Linux and Mac today; the web on WebGPU, Android and iPhone next.

What it isn't yet: production software. It's a public alpha, and the roadmap is on the site. I'd love to hear what data you'd open in it first.
```

*Sources: S1, S4, S5, S10, S11, S9/S16/S17, S18.*
