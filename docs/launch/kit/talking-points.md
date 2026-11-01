# Talking points: a 5-minute talk a day, Sun Nov 1 – Sat Nov 7

One theme a day. Bullets to riff on while recording (a short, a live, a voice note, or the intro to that day's video).
Roughly 1 minute per block. Every number is in sources.md.

---

## Sun Nov 1 · The launch: why did the robot drop it?
**Open:** "A robot drops a block. Here's how long it takes to find out why." *(drop line)*
- The usual way: a spreadsheet of episodes, a video player, a Python notebook for the joints, a PDF for the manual. Four apps, exports between them.
- The data: DROID. Real robot episodes from 13 labs, open (CC-BY-4.0). 67,029 episodes in the public 720p port; tonight's prototype uses 994.
- The demo, out loud (sample of 994 from two labs, so the pivot shows the sample): fleet sheet → pivot by lab → click a failure → video beside joint velocity and gripper → one cursor → ask in words → the linked datasheet → export a pack.
- Why one app matters: the question stays in your head instead of in a copy-paste.
- **Close:** "It's called omxplorer. It's open source. Link's in the post. Tell me what you'd ask this data."

## Mon Nov 2 · The data is real
**Open:** "No mockups. Every row you saw is a real robot."
- What one DROID episode is: three 720p cameras at 15 frames a second, and 52 telemetry channels at 15 Hz: joint positions, joint velocities, the gripper.
- What it doesn't have: force sensing. So I don't show force. Saying what the data can't tell you is part of the job.
- The fleet is real: 13 labs, each with its own robots and scenes.
- Why public data: anyone can check my work. Same files, same answers.
- The sample's limit: 994 episodes from 2 labs. Growing it to 10k across all 13 labs takes under an hour of downloading.
- **Close:** "If you have robot data of your own, I want to see it in here."

## Tue Nov 3 · The UI thread never freezes
**Open:** "Every app has frozen on you. Mine can't, and here's the one rule why."
- One thread draws the screen. At 60 fps it has 16 ms a frame.
- The rule: `update()` and `view()` only decide. Anything slow is a job on its own thread; the answer comes back as an event.
- No locks in app code: state is only touched on the UI thread.
- Video gets its own decoder thread: open in about 40 µs, seek in about 6 µs, the newest seek wins.
- Proof, not promises: the watchdog prints `SLOW:` for anything over budget. Zero lines at 50 ms across the checked sessions (headless, CPU drawing).
- The edge still open: a median over 100M rows in memory still makes the window wait (~0.7 s). Moving it off the UI thread is next.
- The Mac: from a 1.5 s freeze to a 71–83 ms worst gap during the same job (GitHub's virtual Macs).
- **Close:** "No framework can save an app that does slow work on the UI thread. The watchdog tells you when you did."

## Wed Nov 4 · One codebase, from button to GPU kernel
**Open:** "Most apps are four programs pretending to be one."
- The four: the interface (again per platform), the data work in Python on a server, the graphics in a shader language, an API for other software.
- omxcode: one Mojo codebase. The button and the kernel that sums a million rows are the same language, in the same process.
- What that buys: no JSON, no server hop. A chart over 1M rows in about 0.6 ms on an RTX 3090.
- Native controls: GTK on Linux, AppKit on the Mac. No web view.
- Apple's GPU: the Mac's GPU build runs the same engine code through Metal; answers checked equal to the CPU's and NVIDIA's on GitHub's virtual Macs. Real Mac hardware is next.
- Mojo honestly: young (1.1), small ecosystem, no official phone target, no Windows yet. What nobody else has is one readable language from button to kernel.
- **Close:** "If you know Python, you can read every line of it."

## Thu Nov 5 · Linked data: video, sheets and documents, joined on purpose
**Open:** "Putting a video, a table and a PDF on one screen is easy. Knowing why they belong together is the hard part."
- Auto-joining guesses, and guesses are wrong in ways you can't see.
- In omxplorer you link on purpose: by key (the robot model), by time (the episode's clock), by place (a box in the frame).
- Each link shows its match count before you say yes.
- Ask in words: the SQL says `JOIN LINKED`. You can read exactly what was joined.
- Hold a card: everything else dims and the linked cards lift.
- Same idea, other problems: a damaged shipment, an inspection, a fleet.
- **Close:** "Your links are your knowledge. The app should keep them, not guess them."

## Fri Nov 6 · Agents drive the app
**Open:** "My app has no API for agents, and agents use it anyway."
- Today's agents use apps through screenshots and guessed clicks. Slow, fragile.
- omxcode turns the screen into MCP tools: the button's tag is the tool's name, the tooltip its description, calling it is tapping it.
- Safe by construction: a disabled button isn't a tool. A dialog's buttons exist only while it's open.
- Answers in words: each call says what changed.
- AG-UI the other way: the agent streams words and builds a native chart or form.
- Honest: agents don't know Mojo yet. They read the docs (llms.txt) and run the checks.
- **Close:** "Every app built on omxcode is an agent's toolbox from its first line."

## Sat Nov 7 · Where it's going
**Open:** "One framework for everything, starting with data apps."
- Today: Linux (NVIDIA GPU) and Mac (the GPU build checked on GitHub's virtual Macs).
- Next: the web on WebGPU, so anyone can try it in a browser on their own GPU.
- Then Android and iPhone: Android's classic controls already run on the emulator; iPhone builds.
- Then SaaS apps on the same components; a full component collection by year end.
- The bigger idea: the model in the same program as the interface and the data, on the same GPU. A speech model already runs in the app's process (through PyTorch); models in Mojo beside the data are the direction.
- How I build: one small step at a time, every claim proved by a script in the repo, every decision written down.
- **Close:** "It's live at omxlabs.tech. Try it, break it, tell me."
