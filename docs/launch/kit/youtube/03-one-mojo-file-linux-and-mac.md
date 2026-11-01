# YouTube 3 · One Mojo codebase → Linux + Mac, on the GPU

**Length:** about 4 min · **Record:** the editor, the Linux machine, the MacBook · **Post:** Wed Nov 4

## Titles (≤ 60 characters)
1. One Mojo codebase, two GPUs: Linux and Mac, native
2. From button to GPU kernel in one language
3. Native Linux and Mac apps in Mojo, no web view

**Thumbnail:** `[shot: mac-linux]`; big text **ONE FILE. TWO GPUS.**; small: `NVIDIA · Apple`.

## Script

| Time | On screen | Say |
|---|---|---|
| 0:00 | `[shot: mac-linux]` | "Same app, two machines. Linux on an NVIDIA GPU, and a Mac. One Mojo codebase. Let me show you how." |
| 0:15 | `examples/hello/app.mojo` in the editor | "The smallest app is one file. A struct with state, update to change it, view to describe the screen. If you've used Elm or SwiftUI, you know this shape." |
| 0:50 | `scripts/build.sh hello all`, then the GTK window | "One build command. On Linux the view becomes GTK 4 widgets: the platform's own buttons, text and keyboard." |
| 1:15 | The same app on the Mac | "On the Mac it becomes AppKit. Not a web view, not an imitation. Mojo calls C and Objective-C directly." |
| 1:45 | omxplorer's group-by kernel next to the sheet code | "Now the part I care about. The code that sums a million rows is Mojo too, in the same codebase, running on the GPU in the same process as the window." |
| 2:15 | `[clip: linux-run]`, GPU line reading RTX 3090 | "On Linux: a chart over a million rows in about 0.6 milliseconds on an RTX 3090." |
| 2:40 | `[clip: mac-run]` | "On the Mac the same engine code runs on Apple's GPU through Metal. I've checked the answers match the CPU and NVIDIA. Speed on real Mac hardware is what I'm measuring next." *(If you recorded on your MacBook with the Metal build, say what the GPU line shows.)* |
| 3:10 | README "Where it stands" table | "Where it runs today: Linux and Mac. The browser through a server today, on WebGPU next. Android's classic controls run on the emulator; iPhone builds. Those are next." |
| 3:40 | Repo | "It's a public alpha, MIT. Clone it, run scripts/omxplorer.sh, and tell me where it breaks." |

## Description

```
One Mojo codebase, native on Linux (GTK 4) and Mac (AppKit), with the data engine on the GPU: NVIDIA on Linux, Apple's GPU through Metal on the Mac. omxcode is a UI framework where the button and the GPU kernel are written in the same language and run in the same process.

Code: https://github.com/abhisheksreesaila/omxcode
Where it stands (generated from the code): https://github.com/abhisheksreesaila/omxcode/blob/main/docs/components.md
Site: https://abhisheksreesaila.github.io/omxcode/

Chapters
0:00 Same app, two machines
0:15 The smallest app
0:50 Linux: GTK 4
1:15 Mac: AppKit
1:45 The GPU code, same codebase
2:15 1M rows on NVIDIA
2:40 Apple's GPU through Metal
3:10 Where it runs
3:40 Try it
```

**Tags:** Mojo, Mojo language, cross platform, native apps, GTK 4, AppKit, macOS, Linux, GPU programming, Metal, CUDA, app framework, omxcode, Modular

*Sources: S4, S9, S15, S16, S17; hello app and build command from README "Try it".*
