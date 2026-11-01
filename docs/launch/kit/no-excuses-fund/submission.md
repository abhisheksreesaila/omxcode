# No Excuses Fund: submission answers

**The fund (as briefed; the site refused an automated read on 2026-10-31, so check the form itself):** noexcuses.get.tech,
equity-free grants from .tech. The product must be live and working on a .tech domain (ours: **omxlabs.tech**).
Submissions close **2026-12-15**. Judges include Product Hunt's Ryan Hoover and Rajiv Ayyangar.

The form's exact questions weren't readable. These answers cover the usual ones; paste each into the closest field
and trim to its limit. Short version first, longer version under it.

---

**What we're entering:** omxlabs is the entrant (the umbrella); the product submitted is **omxplorer**, told through the
robot story, "why did the robot drop it?". omxcode, omxcore, omxconsole and omxqua appear only as what it's built with.

### Product name and URL
omxplorer, by omxlabs · https://omxlabs.tech

### One line
A workspace where a spreadsheet, its video and its documents sit side by side, joined on purpose, running on your own GPU, and usable by AI agents.

### The problem
**Short:** To answer one question about physical work (why did the robot drop it? *(drop line)* why was this shipment damaged?) people juggle four apps: a spreadsheet, a video player, a plotting notebook and a PDF reader, with exports in between.

**Longer:** Robots, warehouses and fleets now record video, telemetry and paperwork for every event. The tools to look at them were built separately. The sheet lives in Excel, the footage in a video editor, the sensor data in a Python notebook and the manual in a PDF. Every question means an export, an upload or a copy, and waiting for each one. Data apps that try to combine them run in a browser, compute on a server and send JSON back, so they're slow on big data and freeze while they work. And AI agents, which could do a lot of this legwork, can only use these apps by reading screenshots.

### The product
**Short:** omxplorer opens a sheet, its video and its documents on one page. You link them by key, time or place; it shows how many rows match before you confirm. Click a row and its video plays beside its telemetry on one time cursor. Ask in words and read the SQL it wrote. Export the answer as a pack.

**Longer:** The demo uses DROID, 67,029 real robot episodes from 13 labs (public, CC-BY-4.0; 63,344 of them in the app, 16.8M telemetry rows). Open the fleet as a sheet, pivot success by lab, click a failure: the episode's video plays beside its joint-velocity and gripper telemetry, one cursor across all of them. Ask "how many failures per lab?" and it writes the SQL, following the links you made (`JOIN LINKED`), so nothing is joined by guessing. Link the robot's datasheet to the episodes by model and it's one click away. Export a pack with the clip, the charts and the document.

Under it are three technologies we built:
- **omxcode**, a UI framework in Mojo (open source, MIT): one language from the button to the GPU kernel, native on Linux and Mac;
- **omxcore**, the engine: SQL on the CPU and GPU, in the app's own process (a chart over 1M rows in 0.5–0.7 ms on an RTX 3090);
- **omxqua**, the design language (Liquid, here in dark mode).

Beside it, **omxconsole** turns the same GPU into a private, OpenAI-compatible model server on Modular MAX, so a model can live next to the data.

Tools like Foxglove and Rerun already sync video and plots for one recording. omxplorer starts one level up: they replay a recording; omxplorer starts from a question across the whole fleet (asked in words over 16.8M telemetry rows in about 40 ms, no Python, no server), then shows you the moment, with the documents linked.

Every button is also an MCP tool, so Claude or any MCP agent can drive omxplorer with no screenshots and no extra API, and it can do nothing a person couldn't.

### What's built and working today
- omxplorer on Linux (GTK 4, NVIDIA GPU) and Mac (AppKit; the published download is the CPU build; the GPU build runs on Apple's GPU through Metal, checked on GitHub's virtual Macs).
- In the repo and checked by scripts: sheets, pivots, charts edited by their sentence, SQL asked in words, video on its own decoder thread, documents read in process, explicit links by key, time and place with `JOIN LINKED`, and exported packs (proven on a shipping-claim example).
- The robot demo on DROID: *(list what the recorded build shows: the fleet sheet, the failure's video beside its telemetry on one cursor, the linked datasheet, the pack)*.
- Slow work runs as background jobs, and a watchdog checks for slow frames: 0 at a 50 ms budget across the checked video, query and export sessions.
- An agent host: every app is an MCP server. AG-UI support: agents can stream words and build native UI.
- Public alpha on GitHub, MIT, with every claim re-proved by a script in the repo.
- Live on omxlabs.tech: *(fill in what's live on the day: download, hosted demo, video)*.

### Who it's for
First: robotics and physical-AI teams who debug failures across video, telemetry and documents. Next: anyone whose data is part numbers, part footage, part paperwork: warehouses, insurance claims, inspections, fleets. Developers get the framework underneath for their own data apps.

### Traction and plan (Nov 1 → Dec 15)
- **Week 1 (Nov 1–8):** launch to Mojo developers (Modular forum), then X and YouTube: a 7-post thread, a daily post and 5 videos on the robot story.
- **Week 2:** Product Hunt launch of omxplorer, linking to omxlabs.tech.
- **Weeks 3–6:** the web on WebGPU so anyone can try it in a browser; fetch video for every episode (today 3,546) and add the second and wrist cameras; talk to 10 robotics teams about their failure-review workflow.
- **Measure:** GitHub stars and clones, downloads, demo sessions, forum and PH comments, and teams who try it on their own data. *(Fill in real numbers before submitting.)*

### Why it can become a startup
**Short:** Every robot, warehouse and fleet is becoming a stream of video, sensor data and paperwork. The teams who review it need one fast tool that their agents can also use. We have that tool and the engine and framework under it, written in one language, which makes it cheap to build the next app on top.

**Longer:**
1. **A growing need.** Physical AI produces more video and telemetry every month, and failure review is still done by hand across four tools.
2. **A technical edge that compounds.** One language from interface to GPU kernel: no server, no JSON, nothing copied. Each new app (inspections, claims, fleets) reuses the same components, engine and agent tools.
3. **Agent-native from the start.** As teams hand legwork to agents, apps that agents can use directly, safely, win over apps that agents have to screenshot.
4. **Business model:** the framework stays open source; omxplorer is free to start; paid for teams (shared workspaces, hosted GPU, large-fleet connectors) and as SaaS apps built on the same components.
5. **Roadmap:** the web on WebGPU, then Android and iPhone, then SaaS apps; a full component collection by year end. One framework for everything, starting with data apps.

### The founder
Solo founder, app developer (Python, FastHTML), building omxlabs in the open: every decision and measurement is in the repo.

---

*Sources: S1/S2 (DROID), S4 (0.5–0.7 ms), S5 (watchdog), S9 (Mac GPU), S10 (links), S11/S12 (MCP, AG-UI), S16/S17, S19.
The business model and the "10 teams" plan are proposals for the owner to confirm or edit, not facts.*
