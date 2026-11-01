# Modular forum: omxconsole (Saturday Nov 7)

**Where:** forum.modular.com → the **MAX** category if it's offered, otherwise **Community Showcase**. Tags if offered:
`max`, `serving`, `showcase`.

**Attach:** the part 1 talk (`[YouTube: omxconsole part 1]`) as the first link, so it embeds; then a screenshot of the
console's My models screen (`talks/omxconsole/part1/img/omxconsole-home-dark.png`) and the GTK console
(`talks/omxconsole/part2/img/console-models-gtk.png`) at the end.

## Title (pick one)

1. omxconsole: every model behind one local URL on MAX, asleep until called
2. Porting architectures MAX doesn't support yet, with Claude Code in a sandbox
3. A private OpenAI-compatible server on MAX, with a console written in Mojo

*(1 for MAX users; 2 for people who care about porting; 3 if this week's audience came for the Mojo UI.)*

## Body (copy from here)

Hi all. Last of my posts this week: **omxconsole**, a small model server on top of MAX. Short talk first:

[YouTube: omxconsole part 1]

**One endpoint for every model.** `mxc serve qwen2.5-0.5b` pulls the weights, starts a daemon, loads the model and prints an endpoint (`http://127.0.0.1:11435/v1`), a key (shown once) and a curl line. Any OpenAI client works by changing the base URL. The API is four routes: `/v1/models`, `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`.

**Models sleep when idle.** The daemon runs one `max serve` per loaded model, on loopback ports. A model starts on its first request (callers arriving together share one start) and unloads after 5 idle minutes, never mid-request. `--pin` keeps one loaded; `--keep-alive 10m` sets its own timeout. Request fields `max serve` would refuse are dropped and named in an `X-Mxc-Dropped-Params` reply header (read from MAX's own request schema); fields that change the answer (`tools`, `response_format`, `seed`, `stop`…) are never dropped, so MAX's own error reaches you.

**Safe to share.** One key per app, stored only as a SHA-256 hash. `mxc expose` runs Caddy with its own CA on :8443; only the four `/v1` routes reach the daemon from the LAN. (A LiteLLM proxy used to sit in between; I removed it after its supply-chain incidents.)

**When MAX can't run it: port it.** `mxc port <repo> --auto` picks the closest architecture MAX has, has Claude Code write the port in a bubblewrap sandbox (following Modular's porting skill), compiles, serves and compares it with Hugging Face (first-token score and top token at several prefix lengths), then re-runs that comparison itself before registering the model at a pinned revision. Ported and serving so far, on 2× RTX 3090 with MAX 26.7, text models only: GPT-2, Pythia, Phi-2, StarCoder2, StableLM 2, SmolLM3, Granite MoE, OLMoE. A port takes 7–40 minutes and about $2–5 of Claude usage.

**What didn't port, in case it saves you time:** BLOOM (ALiBi positional bias hits a MAX limitation; it stops after "the same failure twice in a row"), and EXAONE (its config loads remote code from the Hub; one run spent 18 minutes and $3.75 before I understood that, so remote-code models are now parked before anything is spent). Also: a port is tied to a MAX version, so I pin the porting skill's environment to the MAX that omxconsole serves with; an early OLMoE port built against 26.7 wouldn't load in the 26.5 I was serving. And Modular's porting skills have two bugs I patch locally ([modular/skills#15](https://github.com/modular/skills/issues/15)).

**The console is written in Mojo.** I rebuilt omxconsole's console with omxcode, my Mojo UI framework (Tuesday's post): native GTK on Linux, AppKit on the Mac (checked on GitHub's virtual Macs), and a web page that matches the original JavaScript console on at least 99 % of pixels across 20 screens (lowest 99.2 %). Its HTTP calls are effects: `update()` sends a tagged request and the reply comes back as an event, so the window never waits on the daemon. The server still ships the JS console for now.

**Honest edges:** Linux + NVIDIA only (whether MAX serves these models on Apple silicon is still to be checked on a real Mac); a public alpha on a MAX 26.7 nightly; porting is text-only and can fail after spending.

MIT:
https://github.com/abhisheksreesaila/mxstudio

```bash
git clone https://github.com/abhisheksreesaila/mxstudio.git && cd mxstudio
pixi install && pixi run mxc serve qwen2.5-0.5b
```

MAX folks: which architecture should I try porting next? And if you know a better way to handle the ALiBi case, I'm all ears.

---

*Sources (not for posting): mxstudio README.md, docs/USER_GUIDE.md (routes, idle unload, keys, expose), docs/ARCHITECTURE.md
(daemon, dropped params, keys, Caddy, LiteLLM/F-063), docs/CLI.md (--pin, --keep-alive default 5m), docs/PORTING.md (steps,
proven, limits, cost, time, skills#15), docs/port-study.md (EXAONE run 19), docs/plan.md (OLMoE 26.5 vs 26.7, F-049 Mac
check); omxcode docs/goals/33-report.md (99.2 %, 20 shots, live check), examples/console/api.mojo.
MIT: omxlabs/readmes/omxconsole.md, mxstudio docs/site/index.html. Before posting: add a LICENSE (MIT) file to mxstudio; the repo has none yet.
Swap `[YouTube: omxconsole part 1]` for the real link before posting.*
