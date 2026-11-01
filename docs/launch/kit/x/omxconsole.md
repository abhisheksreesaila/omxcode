# X: omxconsole thread (Saturday Nov 7, after the forum post)

Post 1/ first, then reply to it with each next post. Every post is under 280 characters (checked by
`check_lengths.py`). Copy only the text between the lines.

---
**1/** · attach `[YouTube: omxconsole part 1]` (or `talks/omxconsole/part1/img/omxconsole-home-dark.png`)

Your GPU, as a private model server.

One command on Modular MAX gives you an OpenAI-compatible endpoint on your own NVIDIA card. Every model behind one local URL; each loads on its first call and sleeps when idle.

It's called omxconsole. 🧵

---
**2/** · attach a screenshot of the terminal after `mxc serve qwen2.5-0.5b`

mxc serve qwen2.5-0.5b

It pulls the weights, starts a daemon, loads the model and prints an endpoint, a key and a curl line. Any OpenAI client works: change the base URL, keep your code.

---
**3/** · no media

No server per model holding GPU memory all day. A model starts on its first request and unloads after 5 idle minutes, never mid-answer. Pin the one you use all day.

One key per app, stored as a hash. mxc expose puts it on your LAN over HTTPS.

---
**4/** · attach the porting slide (`talks/omxconsole/part2`, slide 4)

MAX can't run your model? mxc port has Claude Code write the port in a sandbox, then checks it against Hugging Face before serving.

8 architectures so far, text only: GPT-2, Pythia, Phi-2, StarCoder2, StableLM 2, SmolLM3, Granite MoE, OLMoE.

---
**5/** · attach `talks/omxconsole/part2/img/console-models-gtk.png`

Its console is rebuilt in Mojo with omxcode: native on Linux and Mac, and on the web within 99.2% of the original's pixels.

Linux + NVIDIA, public alpha, MIT.

github.com/abhisheksreesaila/mxstudio

---

*Sources: mxstudio README.md, docs/USER_GUIDE.md, docs/CLI.md, docs/PORTING.md; omxcode docs/goals/33-report.md; MIT: omxlabs/readmes/omxconsole.md (add a LICENSE file to mxstudio before posting).
5/ "Mac" means GitHub's virtual Macs; say so if anyone asks.*
