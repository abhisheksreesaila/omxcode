# GOAL 43: Dictate, what the web can't do

**End goal (owner, 2026-10-30):** the third probe. "It's for performance… you're using low native stuff and you should
be able to tap into native APIs which the web can never do… the reason for existing is it should do something that can
never be done before; if it is not then don't even bother." So this goal is a race with a verdict, not a demo: the same
speech model, on the same GPU, in omxcode (native microphone, the model in the app's own process, audio handed over by
address) against the best the browser has (transformers.js on WebGPU). Yardstick: Personal Note's voice plugin
(`personalnotev2/src/modules/voice`: browser mic → WebSocket → a separate engine process).

Framework first: the microphone and the speech model are `mojoui` components with their own tests; `examples/dictate`
composes them. Slow work off the UI thread (docs/ui-threads.md). Look: Liquid.

## Milestones
| # | Milestone | Proof (`pixi run python docs/goals/43-check.py`) |
|---|---|---|
| M0 | The microphone (`mojoui/audio.mojo`) | `tests/test_audio.mojo` captures 16 kHz mono from the system's sound server (PulseAudio API, PipeWire underneath) on its own thread, from the source named by `$MOJOUI_AUDIO_SOURCE`; the checker makes a virtual null sink, plays `docs/goals/43/tone.wav` into it and records its monitor: the test prints `audio capture: ok` and `audio match: X` with X ≥ 0.9 (normalised correlation with the played file at the best lag) and `audio ui free: ok` (capture never blocks the caller) |
| M1 | The speech model in process (`mojoui/speech.mojo`) | `tests/test_speech.mojo` runs `openai/whisper-large-v3-turbo` in the app's own process on the GPU (Python interop as goal 39's VisionModel; samples handed over by address: no file, socket or HTTP), streaming (feed chunks → partial words, a final at a pause); on the 20 clips of `docs/goals/43/clips/` (LibriSpeech test-clean, with reference text) prints one `speech hyp: <clip id> <text>` per clip (the checker computes WER ≤ 0.05 against the references), the model id, and `speech partials: ok` (partial words arrive before the clip ends) |
| M2 | examples/dictate | one Mojo file: a record button, the live words, the transcripts, and a readout "N ms after you stopped · on <GPU> · on this machine"; headless GTK with the checker's null sink playing 5 clips with 1.5 s pauses: the app prints one `DICTATE FINAL: ms=… text=…` per clip; WER over them ≤ 0.08; p95 of ms (end of speech → final text) ≤ 500; screenshot `docs/goals/43/dictate-gtk.png` |
| M3 | The race | `scripts/dictate_race.py` writes `docs/goals/43/race.json` (fresh: its commit's mojoui/audio.mojo, speech.mojo and the script equal HEAD's): the same 20 clips, the same model id, the same GPU (index recorded), A = omxcode in process, B = transformers.js (`@huggingface/transformers`, WebGPU, fp16 where it loads) in headless Chromium with the GPU (goal 36's flags); per side: cold start (process start → model ready), per-clip latency p50/p95, real-time factor, WER, peak GPU memory, what B had to download. **Pass:** A's p50 latency ≤ half of B's and A's WER ≤ B's + 0.01. If B can't load the same model, race.json says why and B runs its largest model that loads; A must then beat it on latency and WER both. A loss is recorded as a FAIL, not explained away |
| M4 | In the gallery, back in the library | a Dictation section in `docs/gallery/index.html` with `img/dictate-gtk.png` and the race's numbers drawn from race.json (both sides, losses included); `scripts/components.py --check` passes and components.md lists the microphone and the speech model (honest per host: GTK ✅ if run; Mac and web 🔨/❌ with notes); `docs/llms.txt` names `mojoui.audio` and `mojoui.speech`; EXPERIMENTS.md's newest entry is goal 43; `scripts/build.sh dictate mac` succeeds (built, not run) |

## Done means
The checker prints PASS for M0–M4 and the reviewer passes it. If M3 fails honestly, the goal stops there with the race
written up: that is a result too (the owner: "if it is not then don't even bother").

## Out of bounds
Pushing; the frozen `../mojo-ui-apple-test`; `GOAL.md` and `scripts/check.py`; windows on the owner's desktop
(headless only); the owner's real microphone and speakers (only a virtual null sink the run creates and removes);
paid services. Downloads allowed: the model weights, the LibriSpeech clips, the npm package.

## Assumptions (instead of asking)
- Branch `goal-43-dictate` from local `main` 49cbd8d; worktree `../mojo-ui-g43`; decisions D-1400 onward. Goal 42 (Jot) runs in parallel in `../mojo-ui-g42`; goal 41 belongs to another thread.
- Goal 39's `models` environment (torch + transformers) isn't on main yet: this goal adds its own `speech` pixi feature/environment, Linux only, so the default environment is unchanged; a later merge reconciles the two.
- The model is whisper-large-v3-turbo on both sides (onnx-community's export for transformers.js) so the race is like for like.
- One of the two RTX 3090s, fixed by index for both sides; the race runs when the GPU is otherwise quiet (recorded).
- The web side gets an audio file, not a microphone (a headless browser has none): this favours the web, and is stated.

## Budget
80 turns.
