# omxcode talks · two parts

Open `part1/index.html` or `part2/index.html` in a browser, press **S** for the speaker notes, arrow keys to move.
Built from `../_src/omxcode-part*.html` by `../build.py` (don't edit the index.html files by hand).

| Part | Slides | Length (notes at 150 wpm) | What it covers |
|---|---|---|---|
| [part1](part1/index.html) · One Mojo app, every screen | 13 | ≈ 4:15 | the struct, six hosts, a tap and its patch, Mojo ↔ C, build.sh all, the GPU kernel in the same file, numbers |
| [part2](part2/index.html) · Never freezes, and agents drive it | 14 | ≈ 4:35 | the UI-thread rule, jobs, jobwake before/after, the watchdog, MCP, AG-UI, five stacks, where Mojo pushed back, honest edges |

Record part 1 first; part 2 stands alone but its outro assumes people saw part 1.

---

## Part 1 · One Mojo app, every screen

**Titles (≤ 60 characters)**
1. One Mojo app, every screen: GTK, web, Mac, Android (50)
2. A UI framework in Mojo, from button to GPU kernel (49)
3. Native apps in Mojo: two functions, six hosts (45)

**Thumbnail:** the four-tile picture of slide 1 (GTK, Mac, web, Data Lens), darkened left; big text **ONE MOJO FILE**; small mono line `GTK · AppKit · web · GPU`.

**Description**
```
omxcode is a UI framework written in Mojo. An app is one struct with two functions, view() and update(); the same file opens with native controls on Linux (GTK 4), the web (FastHTML) and the Mac (AppKit, checked on GitHub's macOS runners), on the Android emulator, and builds for the iPhone. The GPU kernel sits in the same file: a plain Mojo function, launched with no CUDA and no shader language. 20M points draw in 1.5 ms a frame on an RTX 3090.

Part 2: why the window never freezes, and how every app becomes an MCP server for agents.

Code (MIT): https://github.com/abhisheksreesaila/omxcode
Site: https://omxlabs.tech

Chapters
0:00 omxcode in one minute
0:26 Why: three languages and a guessing agent
0:48 An app is a struct: state, update, view
1:07 How it's built
1:26 One view tree, six hosts
1:51 Native, not imitated
2:02 A tap, as it runs
2:21 Patch, don't rebuild
2:41 Mojo ↔ C under the hosts
3:02 One command, every platform
3:18 The GPU, in the same file
3:37 The numbers
3:56 Try it
```

## Part 2 · Never freezes, and agents drive it

**Titles (≤ 60 characters)**
1. The UI thread never freezes: how omxcode does it in Mojo (56)
2. Every app is an MCP server: agents drive omxcode apps (53)
3. Mojo apps that never freeze, and agents that drive them (55)

**Thumbnail:** slide 5's bars (Mac 1,527 ms → 71–83 ms); big text **NEVER FREEZES**; small mono line `+ every button is an MCP tool`.

**Description**
```
Part 2 of omxcode, a UI framework in Mojo. update() and view() only decide; queries, imports, video and documents run as jobs on their own threads and come back as events, with no locks in app code. A watchdog (MOJOUI_BUDGET_MS) prints a SLOW: line for anything over budget. On GitHub's virtual Macs, a 1.5 s job's worst frame gap went from 1,516–1,527 ms to 71–83 ms.

Then agents: the same view tree that becomes GTK widgets becomes MCP tools, with no per-app work. A disabled button is no tool. AG-UI the other way: an agent sends UI as JSON, checked, then drawn natively. Plus a five-stack benchmark with every loss stated, where Mojo pushed back, and what isn't done yet.

Code (MIT): https://github.com/abhisheksreesaila/omxcode
Agent docs: https://github.com/abhisheksreesaila/omxcode/blob/main/docs/agent.md
Benchmarks: https://github.com/abhisheksreesaila/omxcode/blob/main/docs/benchmarks.md
Site: https://omxlabs.tech

Chapters
0:00 Never freezes, agents drive it
0:22 The UI thread rule
0:44 What runs off the thread
1:03 How a job wakes the UI
1:27 A 1.5 s job, before and after
1:45 The watchdog
2:05 Every app is an MCP server
2:25 A real session
2:42 The screen is the permission model
3:00 AG-UI: agents build UI as data
3:17 One app, five stacks
3:36 Where Mojo pushed back
3:55 The honest edges
4:14 Try it
```

**Tags (both):** Mojo, Mojo language, Modular, MAX, GPU, UI framework, GTK, AppKit, FastHTML, MCP, AG-UI, AI agents, native apps, omxcode, open source

*Re-time the chapters to the final cut. Sources are on each slide's bottom line; the hello transcript in part 2 is a real
run of `scripts/agent_client.py build/hello/web` (2026-11-01).*
