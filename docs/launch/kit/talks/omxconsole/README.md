# omxconsole talk · two parts

Open `part1/index.html` or `part2/index.html` in a browser; arrow keys to move, `S` for speaker notes. Each part
stands alone (its own intro and outro). Lengths are estimated from the notes at 150 words a minute; you'll run a little
longer with pauses.

| Part | Slides | Length | What it covers |
|---|---|---|---|
| [part1](part1/index.html) · Your GPU as a private model server | 13 | ~4:15 | why, `mxc serve`, curl and any OpenAI client, the four layers, a request as it runs, idle unload and pin, keys, `mxc expose` |
| [part2](part2/index.html) · Porting with Claude Code, and a console in Mojo | 14 | ~4:20 | `mxc port --auto` (five steps, eight architectures, what failed), the sandbox, the console rebuilt in omxcode, real code, honest edges, roadmap |

Record part 1 first; part 2 says "part one was the server" and works after it. Sources: the `.src` line on each slide.

---

## Part 1 · Your GPU as a private model server

**Titles (≤ 60 characters)**
1. Your GPU as a private OpenAI-compatible server, on MAX
2. One command, one local AI endpoint: omxconsole on MAX
3. Local models that sleep when idle: omxconsole

**Thumbnail:** the console's My models screen (`img/omxconsole-home-dark.png`), darkened left; big text **YOUR GPU. ONE URL.**; small mono line `mxc serve qwen2.5-0.5b`.

**Description**
```
omxconsole turns the NVIDIA GPU you already own into a private, OpenAI-compatible model server on Modular MAX. One command (mxc serve qwen2.5-0.5b) prints an endpoint, a key and a curl line. Every model sits behind one local URL; a model loads on its first call and unloads after 5 idle minutes, unless you pin it. One key per app, stored as a hash; mxc expose puts the four /v1 routes on your LAN over HTTPS.

Public alpha on MAX 26.7 nightly, Linux + NVIDIA, MIT.

Code: https://github.com/abhisheksreesaila/mxstudio
Site: https://omxlabs.tech/omxconsole/
Part 2 (porting with Claude Code, and the console in Mojo): [link]

Chapters
0:00 Your GPU, as a private model server
0:25 Why: bills, one server per model, "not supported"
0:44 Who it's for
1:02 A small server, and a console
1:21 mxc serve: what it prints
1:43 Call it with curl
2:03 Any OpenAI client
2:17 Four layers, one URL
2:37 A request for a sleeping model
3:00 Idle unload and pin
3:19 Keys, stored as hashes
3:35 mxc expose: your LAN over HTTPS
3:55 Try it
```

## Part 2 · Porting with Claude Code, and a console in Mojo

**Titles (≤ 60 characters)**
1. MAX can't run your model? Claude Code ports it
2. Porting 8 model architectures to MAX with an agent
3. A model server's console, rebuilt in Mojo

**Thumbnail:** the five-step porting slide, or the GTK console (`img/console-models-gtk.png`); big text **MAX CAN'T RUN IT? PORT IT.**; small mono line `mxc port <repo> --auto`.

**Description**
```
When Modular MAX doesn't support a model's architecture, omxconsole's mxc port --auto has Claude Code write a MAX version in a bubblewrap sandbox, then checks it against Hugging Face itself before serving it. Eight architectures so far (GPT-2, Pythia, Phi-2, StarCoder2, StableLM 2, SmolLM3, Granite MoE, OLMoE), 7–40 minutes and about $2–5 of Claude usage each; BLOOM and EXAONE don't port, and the talk says why.

Then the console, rebuilt in Mojo with omxcode: native on Linux (GTK) and the Mac (AppKit), and on the web matching at least 97 % of the original's pixels on all 20 screens checked.

Code: https://github.com/abhisheksreesaila/mxstudio
The Mojo console: https://github.com/abhisheksreesaila/omxcode (examples/console)
Site: https://omxlabs.tech/omxconsole/
Part 1 (the server): [link]

Chapters
0:00 MAX can't run it? Port it.
0:17 Three kinds of model
0:34 Why porting is its own step
0:56 Five steps, one checked answer
1:14 Eight ported, two parked
1:36 The sandbox, and the caveats
1:57 The console, rebuilt in Mojo
2:17 Measured against the original
2:35 Checked live
2:52 Code: just HTTP, replies as events
3:11 Code: timers are data
3:29 The honest edges
3:49 Where it's going
4:05 Try it
```

**Tags:** Modular MAX, Mojo, local LLM, OpenAI compatible API, self-hosted AI, GPU, NVIDIA, model serving, Claude Code, model porting, omxconsole, omxlabs, open source

*Re-time the chapters to the final cut.*
