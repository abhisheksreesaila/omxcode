# Goal 43 report: Dictate, what the web can't do

**Verdict: omxcode wins the race.** Same model (whisper-large-v3-turbo), same RTX 3090 (index 0), same 20 LibriSpeech
clips: omxcode in process **135 ms** median per clip (WER 0.034) against transformers.js on WebGPU **933 ms** (WER 0.030),
6.9× faster at the median, inside the goal's bar (≤ half of B's median, WER ≤ B's + 0.01). Cold start 4.6 s vs 7.8 s.
The asterisk, stated plainly: B couldn't run fp16 here (Chromium's Dawn exposes no `shader-f16` on this NVIDIA/Vulkan
stack) and its fp32 encoder (2.5 GB) failed to fetch in the page, so B ran the same model's 4-bit encoder + decoder, its
fastest variant that loads (q4/fp32 decoder: 1164 ms). A is fp16 torch.

## The race (docs/goals/43/race.json, commit cca81b5)
| | A: omxcode, in process | B: transformers.js 4.3.2, WebGPU, Chromium |
|---|---|---|
| model | openai/whisper-large-v3-turbo, fp16 | onnx-community/whisper-large-v3-turbo, q4 encoder + q4 decoder |
| per clip p50 / p95 (audio in → final text) | 134.6 / 174.0 ms | 933.3 / 1476.0 ms |
| real-time factor | 0.014 | 0.104 |
| WER (20 clips, the checker's) | 0.034 | 0.030 |
| cold start (process → model ready, warmed) | 4.6 s | 7.85 s |
| peak GPU memory (nvidia-smi rise) | 2,076 MB | 2,270 MB |
| downloaded | — (HF cache) | 762 MB (served locally, counted) |

B's variants (all in race.json): fp16/fp16 "The device (webgpu) does not support fp16"; fp32/fp32 and fp32/q4 "Failed to
fetch" (the 2.5 GB external data); q4/fp32 1164 ms, WER 0.030; q4/q4 933 ms, WER 0.030 (kept). Quiet: GPU 0 at 0 %
before; 13 % mean (67 % max) in the 3 s after A finished (recorded, not explained; another session may have used it).

In the app itself (M2), the final text is on screen 290–330 ms after the speaker stops (120 ms of quiet + one
transcription + a 30 ms tick).

## 30-second demo
```bash
cd ../mojo-ui-g43
pixi install -e speech
scripts/build.sh dictate linux && build/dictate/linux/dictate      # Record, speak, Stop (your default microphone)
pixi run python docs/goals/43-check.py                              # M0-M4 headless, through a null sink it makes and removes
pixi run python scripts/dictate_race.py --gpu 0                     # the race -> docs/goals/43/race.json
```

## Screenshots
- `docs/goals/43/dictate-gtk.png` (= `docs/gallery/img/dictate-gtk.png`): five clips transcribed, each "N ms after you stopped · on NVIDIA GeForce RTX 3090 · on this machine".

## Decisions worth a second look
1. **D-1410, what "ms after you stopped" means.** The utterance closes after 1.3 s of quiet (the clips pause up to 1.02 s
   mid-sentence), but its text was on screen from the transcript made after 120 ms of quiet; the readout times that,
   from the capture time of the last voiced 20 ms. Timing to the close would add ~1.2 s that a person doesn't wait for.
2. **D-1411, B's precision.** Every variant was tried and the fastest kept; B never got fp16. On a stack with
   shader-f16 (Chrome on Windows/Mac, or a future Dawn) B would likely be faster than 933 ms; how much is unmeasured.
3. **D-1409, the GIL.** Mojo's main thread gives the interpreter's lock up after the first model and every call takes
   it briefly. It works (feed+poll ≤ 5.2 ms), but any other Python use on the main thread must follow the same rule.

Also: D-1413 changed how the GTK host and present.mojo dlopen (OwnedDLHandle), which every GTK app goes through.

## Unverified
- A real microphone: everything went through the checker's null sink (owner's devices untouched by rule).
- The Mac: `scripts/build.sh dictate mac` builds; the microphone and the model report "not on this host" there.
- B with fp16, and B on a machine where Chromium's WebGPU reaches f16.
- M0's proof is timing-sensitive: the first run after editing audio.mojo compiles longer than the checker's 1.5 s lead
  and misses the tone (D-1407); warm runs match 0.990.
- The reviewer hasn't run yet.

## Final checker run
```
M0 PASS: captured the played tone through the sound server, match 0.9902822245095156, the caller never blocked
M1 PASS: whisper-large-v3-turbo in process, 20 clips, WER 0.030, partials before each clip ends
M2 PASS: 5 clips through the null sink: WER 0.016, final text 291 ms median / 329 ms p95 after speech ends
M3 PASS: A 135 ms p50, WER 0.034; B (onnx-community/whisper-large-v3-turbo) 933 ms p50, WER 0.030; cold start 4.6 s vs 7.8 s
M4 PASS: gallery Dictation section with the race's numbers, matrix, llms.txt, EXPERIMENTS; mac built
```
