# GOAL 72: omx, the voice app, rebuilt on omxcode (in-process, AG-UI, every button a tool)

**End goal (owner, 2026-11-17):** "Now that I've proved how well it works… make the story about our stack… if you use omxcode,
you have in-process stuff, you have AG-UI for free, you can generate complex interfaces because it runs on GPU already… every
button is a tool, so MCP becomes a no-brainer… I would prefer all of them in Mojo… pick Qwen 27B… use that for your in-process
calling… Parakeet and stuff, if not supported by Mojo or MAX, use llama.cpp for voice… convert the existing shell into a nice
app that is native to our framework… adhering to that protocol [AG-UI] will help us scale… bring all the features about comic
and stuff." The prototype is ~/Projects/omx-local (Python + JS, goals 1–4 PASS, 23/23 checks): it is the reference for
behaviour and numbers, read-only. This goal proves the real stack. Next (not this goal): visual, pointy answers for a kitchen
counter (maps, isometric explainers, "look at this").

Base: main cc33c9d7. Worktree ../mojo-ui-g72, branch goal-72-omx-voice. Decisions D-72xx. Goal 71's contract: docs/goals/71.md.

## Milestones (framework first; the app only composes)
| # | Milestone | Proof (`docs/goals/72-check.py`; PASS, FAIL or BLOCKED each) |
|---|---|---|
| M0 | Ground | GPUs, models and engines found (Qwen3.8-27B UD-Q4_K_M + MTP GGUF, Kokoro, Parakeet, Z-Image, from omx-local/models, read-only); libllama built with CUDA sm_86 reachable from the worktree; D-7201 (why the brain isn't MAX on the 3090s) recorded with the evidence |
| M1 | `mojoui.llm`: a local LLM in-process | a framework component (no app code) that loads a GGUF on a chosen GPU through libllama (a small C shim: scalars and pointers only), streams tokens to the UI as events from a worker thread, keeps the conversation's prompt cache between turns, applies the model's own chat template, parses tool calls, cancels mid-reply, and runs a second sequence for background work. tests/test_llm: Paris; a tool call with JSON args parsed; cancel stops within 100 ms; decode ≥ 40 tok/s on one 3090; second-turn time to first token ≤ 0.5× the first (cache kept); in-process first token ≤ the same prompt through llama-server HTTP |
| M2 | `mojoui.voice`: ears and mouth | `Speaker` (audio out: PulseAudio on Linux, the browser on the web host), `Voice` TTS (Kokoro, in-process), Parakeet as a `SpeechModel` backend (in-process), an endpointer with barge-in. tests/test_voice: TTS first audio ≤ 400 ms; Parakeet hears the TTS back with WER ≤ 0.10; speech end → final text ≤ 300 ms; barge-in stops the speaker within 300 ms |
| M3 | The agent speaks AG-UI | a voice agent as an in-process `LocalAgent` over `mojoui.llm`: every reply is AG-UI events (RUN_*, TEXT_MESSAGE_*, TOOL_CALL_*, STATE_*, render_ui cards from the catalog), its tools are the app's own buttons (the agent host, D-162) plus render_ui; the same agent is served as an AG-UI HTTP/SSE endpoint so any AG-UI client can use it. Proof: the official `ag-ui-protocol` client runs against the endpoint and every event validates; an in-app run renders a card; the app's buttons appear as its tools |
| M4 | The app, `examples/omx` | composed only of framework parts, Liquid: the orb that listens and speaks, captions, a shelf of cards (render_ui), the lane chip, the cloud frame. Voice loop on the desktop (GTK): a recorded question → spoken answer, first audio ≤ 1.5 s after the speaker stops, the answer right; an interruption stops it ≤ 500 ms; screenshots; the app-lint passes (no host imports, colours or pixel sizes in the app) |
| M5 | The tablet | the web host carries the browser's mic in and the speaker out, behind a pairing key, served on the tailnet (`tailscale serve` → loopback). Proof: Chromium with a fake mic over https://<machine>.ts.net: question → spoken answer ≤ 2 s; no key → refused; tablet-width screenshot |
| M6 | The features come home | to-do (store, voice ticks), news cards, comics (Picture from agent-made images; Z-Image on card 2), find in my notes (in-process embeddings via MAX, cited), think-it-through jobs (the second sequence), the cloud lane (`claude -p`, orange frame). Proof: omx-local's M15–M17 and M21–M23 scenarios, ported, pass on the new app |
| M7 | Nothing regressed | the component matrix regenerated; goal 71's check (M5 inside it); decisions lint; omx-local untouched |

## Done means
72-check PASS for M0–M7 (a BLOCKED says exactly what is missing), a fresh reviewer subagent passes it, docs/goals/72-report.md
with numbers (in-process vs HTTP, voice latency, the prototype's numbers beside them) and screenshots, EXPERIMENTS.md.
Committed after each passing milestone; merged to main locally after the reviewer passes; not pushed.

## Out of bounds
Editing omx-local (read its code, models and engines only); other worktrees; pushing; pip (pixi only); lowering a proof or
deleting a test; the visual/pointing skills (next goal); GPU 1 beyond what the creator tier already used (and given back).

## Assumptions (instead of asking)
- The brain is Qwen3.8-27B 4-bit through libllama in-process (D-7201): MAX 26.7 knows Qwen3.8-27B but only as bf16 (54 GB,
  more than both 3090s), fp8 (no Ampere path shown; a small FP8 Qwen failed in MAX here) or NVFP4 (Blackwell only), and GPTQ
  for Qwen3.5 "is not implemented yet". MAX is used where it fits: embeddings (maxrt packs).
- Voice models run in-process through Python interop the way `mojoui.speech` already runs Whisper (the owner allowed
  llama.cpp-class engines for voice when MAX has no path).
- The tablet uses the web host in its browser (the Android host lacks timers, HTTP and mic; never run on a device).
- Budget: 200 turns, stop with a report if blocked.
