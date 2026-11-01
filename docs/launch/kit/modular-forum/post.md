# Modular forum: the first post (Sunday Nov 1, evening)

**Where:** forum.modular.com → **Community Showcase**. Tags if offered: `gpu`, `ui`, `showcase`.

**Attach:** `[clip: robots-45s]` (upload the mp4 into the post, under the first paragraph), then `[shot: failure-cursor]`
and `[shot: mac-linux]` at the end.

## Title (pick one)

1. omxcode: a UI framework in Mojo, the app and its GPU kernels in one file
2. Why did the robot drop it? A data app written entirely in Mojo, on the GPU
3. Native apps in Mojo, from button to kernel: Linux and Mac today

*(Pick 1 if you want developers; 2 if you want clicks. 2 needs the drop clip, see shot-list.md.)*

## Body (copy from here)

Hi all. I've been building a UI framework in Mojo, called **omxcode**, and I'd like to show you what it can do now and hear what you think.

The demo is a question: **why did the robot drop it?** *(drop line)* The data is DROID, real robot episodes from 13 labs (CC-BY-4.0). The public 720p port has 67,029 episodes; my prototype uses 994 of them.

[clip: robots-45s]

What you're watching is **omxplorer**, a data app built on omxcode, in one Mojo codebase:

- a fleet sheet of episodes, pivoted by lab;
- click a failure: its video plays next to the joint-velocity and gripper telemetry, on one time cursor;
- ask in words; it writes the SQL, and `JOIN LINKED` follows the links I made between the sheet, the video and a document;
- export a pack of the episode.

**What Mojo made possible.** One language from the button to the kernel. The group-by behind a chart runs on the GPU, in the app's own process: 0.5–0.7 ms over 1M rows on an RTX 3090. There's no server and no JSON between the data and the window. On a Mac, the engine's queries run on Apple's GPU through Metal.

**It doesn't freeze.** `update()` and `view()` run on the UI thread and only decide. Queries, imports, video decoding and exports run as jobs on their own threads and come back as ordinary events. A watchdog (`MOJOUI_BUDGET_MS=16`) prints a `SLOW:` line for anything over budget. My checks run the video, 1M-row insert, query and export sessions with a 50 ms budget, and they print zero `SLOW:` lines.

**Agents use it without an API.** The same view tree that becomes GTK widgets becomes MCP tools. A button is a tool; a disabled button isn't.

**Where it runs today:** Linux (GTK 4, NVIDIA GPU) and Mac (AppKit, Metal). Next: the web on WebGPU, then Android and iPhone, then SaaS apps. A full component collection by the end of the year.

**Where Mojo pushed back, in case it helps anyone:** FFI is scalars and `(pointer, length)` strings only. A run-time-indexed `SIMD` used as scratch space crashed the compiler (`stack_allocation` works). Phone targets need two runtime functions I stand in for with a small, labelled C shim; I'd love an official answer there.

It's a public alpha, MIT:
https://github.com/abhisheksreesaila/omxcode

```bash
git clone https://github.com/abhisheksreesaila/omxcode && cd omxcode
pixi install && scripts/omxplorer.sh
```

Questions, and especially "you should have done X in Mojo", are very welcome.

[shot: failure-cursor] [shot: mac-linux]

---

*Sources (not for posting): DROID S1/S2, chart time S4, watchdog S5, Mac S8/S9, agent S11, Mojo limits S15, in ../sources.md.
"Mac (AppKit, Metal)" is true for the build on GitHub's virtual Macs (S9). If tonight's Mac recording is the CPU build,
change that line to "Mac (AppKit; the GPU build runs on Apple's GPU through Metal)".*
