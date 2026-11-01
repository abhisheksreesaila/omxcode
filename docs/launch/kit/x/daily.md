# X: one post a day, Nov 2–8

One idea each. Post in the morning, reply to comments in the evening. Media named under each post.

---
**Mon Nov 2 · the data is real** · attach `[shot: fleet-sheet]`

The robot demo isn't a mockup. DROID is real: 67,029 robot episodes from 13 labs, 326 hours, CC-BY-4.0.

I'm prototyping on 994 of them. The sheet, the video and the telemetry all come from the same files.

---
**Tue Nov 3 · never freezes** · attach `[shot: slow-terminal]`

Rule one of my framework: update() and view() only decide.

Anything slow is a job on its own thread, and its answer comes back as an event. Run with MOJOUI_BUDGET_MS=16 and anything over budget prints a SLOW: line. No locks in app code.

---
**Wed Nov 4 · one cursor** · attach `[clip: robots-15s]`

A robot failure is three things at once: what the camera saw, what the joints did, what the gripper did.

In omxplorer they share one time cursor. Drag it and the video, the joint velocities and the gripper move together.

---
**Thu Nov 5 · explicit links** · attach `[shot: linked-doc]`

Video, a sheet and a PDF in one place is easy. Knowing why they belong together is the hard part.

In omxplorer you link them on purpose, by key, time or place, and it shows how many rows match. Hold a card to see what it's linked to.

---
**Fri Nov 6 · agents** · attach `[clip: agent-drives]`

My app has no API for agents. It doesn't need one.

Every button is an MCP tool: its tag names it, its tooltip describes it, calling it is tapping it. A disabled button isn't a tool. The agent can do nothing you couldn't.

---
**Sat Nov 7 · one file, two GPUs** · attach `[shot: mac-linux]`

The same Mojo engine code runs on an NVIDIA GPU on Linux and on Apple's GPU through Metal (checked on GitHub's virtual Macs; real Macs next).

The app uses each platform's own controls: GTK and AppKit. No web view.

---
**Sun Nov 8 · where it's going** · attach `[shot: code-file]`

Where omxcode goes next:

· the web on WebGPU
· Android and iPhone
· SaaS apps on the same components
· a full component collection by year end

One framework for everything, starting with data apps.

github.com/abhisheksreesaila/omxcode

---

*Sources: S1/S2, S5, S10, S11, S9, S16/S17. Sat Nov 7: if you recorded the Metal build on your MacBook, replace the
bracket with what its GPU line shows.*
