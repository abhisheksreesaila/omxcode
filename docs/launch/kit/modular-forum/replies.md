# Modular forum: reply bank

Paste and trim. Each answer is short on purpose; add a link if they ask for more.

### Is it production ready?
No. It's a public alpha. Every claim in the README is checked by a script in the repo (`scripts/check`), and the README lists what isn't done yet. I'd use it today for a data tool you control the machine for. I wouldn't ship it to customers yet.

### Why not just use JavaScript (or Electron, or Tauri)?
For forms, CRUD and dashboards over an API, JS wins on ecosystem, and I don't compete there. omxcode is for apps where the data and the screen are the same problem: a million rows, video frames, a GPU. In JS that becomes a browser, a server, a second language for the hot path and JSON in between. Here it's one Mojo process. When a JS library is the better tool, you can embed it as a widget.

### Does it run on a Mac?
Yes, with AppKit controls, and my Mac checks run on GitHub's virtual Macs (the README's table still says "builds" for the Mac because no check runs on real Mac hardware yet). The engine's GPU build runs its queries on Apple's GPU through Metal there, with the sum equal to the CPU's and NVIDIA's. Background jobs have their own threads there too: during a 1.5 s job, the longest gap between frames went from 1.5 s to 71–83 ms. Timings on real Mac hardware are next. The published Mac download is the CPU build for now, while I sort out shipping Modular's runtime libraries (there's a licensing question in the forum).

### What about the web?
Today the same app runs in the browser through a FastHTML server, checked in Chromium: the server computes, the page shows it. Next is the web on WebGPU, so the work runs on the visitor's GPU.

### Android? iPhone? Windows?
Android's classic controls already run as real Android views on the emulator, and the iPhone build compiles and signs. Both are next on the list after the web. No Windows yet, since Mojo has no Windows release.

### How do agents use it?
Every omxcode app is an MCP server with no per-app work. The view tree becomes tools: a button's tag names its tool, its tooltip describes it, and calling it is tapping it. A disabled button isn't a tool, so an agent can't do anything you couldn't. Each call answers in words with what changed. `scripts/agent.sh omxplorer` prints the `claude mcp add` line. There's also an AG-UI client, so an agent can stream words and build native UI (a chart, a form) in `examples/agentchat`.

### Do agents know how to write omxcode / Mojo?
Not out of the box. Mojo is new and models haven't seen much of it. The docs ship as `llms.txt` and `llms-full.txt` so an agent can read them, and the API is small (`view()`, `update()`, components). An agent writing an app should read those docs first and run `scripts/check` to prove what it wrote.

### Is the robot data real?
Yes. DROID, Khazatsky et al. 2024, CC-BY-4.0. The public 720p port has 67,029 episodes from 13 labs; 63,344 of them are in the demo, with 16.8M telemetry rows. DROID has joint velocities and the gripper position at 15 Hz, but no force sensing, so I don't show force.

### How fast is it really?
On one Linux machine with an RTX 3090: a chart over 1M rows in 0.5–0.7 ms, the 1M-row grid scrolls at 0.8 ms a frame (p95), a 100M-row file opens in 0.2 s. All from the checks or their benchmarks, listed in the README.

### What's the engine?
omxcore, a Mojo dataframe and SQL engine on the CPU and GPU, vendored into the repo as a package. It's the same code on NVIDIA and on Apple's GPU.

### How does it stay responsive?
`update()` and `view()` run on the UI thread and only decide. Anything slow is a request, a timer or a job (`start_ui_job`), and the result comes back as an event. App state is only touched on the UI thread, so there are no locks in app code. Run with `MOJOUI_BUDGET_MS=16` and anything over budget prints a `SLOW:` line. The rules are in `docs/ui-threads.md`.

### Can I use it with MAX / my own model?
Not MAX yet. Today the GPU work is the data engine and the drawing, and a speech model already runs in the app's process in `examples/dictate` (through PyTorch). Models in Mojo beside the interface and the data, on the same GPU, are the direction.

### How do I help?
Try `scripts/omxplorer.sh` and tell me where it broke. Issues on GitHub. Mojo people: the FFI and phone-runtime notes in the post are where I'd most like advice.
