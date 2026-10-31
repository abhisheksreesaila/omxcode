# Goal 43 report: Dictate, what the web can't do

**Verdict (after review round 1): omxcode wins the race, honestly stated.** Same model weights (whisper-large-v3-turbo),
same RTX 3090 (index 0), same 20 LibriSpeech clips, **A fp16 vs B fp32 encoder + q4 decoder**: omxcode in process
**140 ms** median per clip (WER 0.034) against transformers.js on WebGPU **912 ms** (WER 0.034),
**6.5× at the median**, inside the bar (≤ half of B's median, WER ≤ B's + 0.01). B's full-fp32 run: 924 ms. B can't run fp16 on
this machine (no Chromium flag set offers shader-f16: docs/goals/43/webgpu-f16-probe.json); B with fp16 is unmeasured.
Log-mel features: A on the GPU, B on the CPU in JavaScript. No other process used GPU 0 during any timed run.

## Review round 1 (reviewer: NEEDS WORK → what changed)
1. **Race honesty.**
   - fp32 B: the old "Failed to fetch" wasn't the harness. Root cause, measured: Chromium can't allocate one ArrayBuffer of
     2,547,875,840 bytes (`RangeError: Array buffer allocation failed`; a 1.27 GB file reads whole), and transformers.js
     reads each external-data file into one. The server now streams from disk with HTTP Range anyway. The same tensors,
     byte for byte, split into two files under 1.9 GB (`scripts/dictate_rechunk.py`, D-1416) load as transformers.js's
     use_external_data_format = 2, so fp32 B runs. The one-file variant stays in race.json with its root cause.
   - fp16 B: `scripts/webgpu_f16_probe.py` launches Chromium 152 under 18 flag sets (Vulkan via ANGLE, without ANGLE under
     --headless=new, allow_unsafe_apis, WebGPUExperimentalFeatures, the Dawn GL backend, SwiftShader, compat, …) and asks
     for four adapter kinds each; output in docs/goals/43/webgpu-f16-probe.json. None offers shader-f16 (D-1415).
   - B is now the fastest variant whose WER is within 0.01 of A's; every variant is kept with its latency/WER or its error.
     Per side, race.json records precision, where log-mel runs, and decoding (greedy, en, transcribe, one 30 s window),
     plus `precision_note`. Checker addition (D-1420): M3 also requires both precisions, a note when they differ, and
     names them and the ratio in its verdict.
   - GPU quiet: a side thread samples utilisation, memory and `--query-compute-apps` about every 0.18 s during every run.
     A run where another process held or grew ≥ 100 MiB on GPU 0 is repeated (up to 6 times, each after 20 s of quiet).
     This mattered: other sessions' omxplorer tests and a vision benchmark (100 % on GPU 0) landed during earlier passes.
     Those runs were thrown away; fp32/q4 took 3 attempts. In the kept runs, the only other processes were the desktop's
     (1Password, voxtype, the desktop Chromium: 6–8 MiB). Utilisation during A 22.1 % mean / 67 % max and
     during B 29.1 % / 100 %: that is the race itself.
   - Run-to-run spread on B is about ±10 % (q4/fp32 908 ms in the previous pass, 1018 ms in this one), so the
     B variants within ~100 ms of each other are a tie; the verdict holds for every one of them.
   - Also fixed: the download count lost concurrent files (the counter was read before a long send).
2. **GIL leak (D-1417).** Every mojoui.speech call releases the interpreter's lock on a Python error (`_fail`: leave,
   re-raise). The Python work runs in `_py_*` functions so its objects die before the lock goes back.
   tests/test_speech_errors.mojo (a bad model id and a bad attribute after the model loaded, then a stream must still give
   a FINAL) fails on the old speech.mojo (no FINAL in 30 s) and passes now.
3. **Lost stream (D-1418).** A pa_simple_read error marks the microphone failed with a reason; captured_ns reads time and
   total as one pair (sequence word). tests/test_audio_fail.mojo drops its own client with `pw-cli destroy` rather than
   unloading the sink: unloading lets the server move the stream to the default source, the owner's microphone.
4. **M0 flake (D-1419).** Checker addition: an untimed warm-up run first. M0 passed on the first run after editing audio.mojo.
5. **M2 readout.** "ms after you stopped" is a floor: it starts when the last voiced 20 ms chunk reached Mojo and ends
   when the event is polled; "stopped" = quieter than RMS 0.006. The app shows that under the transcripts and says it in
   its header.
6. **scripts/build.sh** says the speech launcher hard-codes this checkout's .pixi paths and runs `pixi install -e speech`.
7. **WebKitGTK after D-1413.** examples/widgets built and run headless on GTK: `WEBVIEW: mx-counter#1 ready mounts=1 csp=0
   crashes=0`, ECharts drawn (docs/goals/43/widgets-gtk-review.png). The injected `click:` on the counter's button didn't
   register on GTK (count stayed 0); taps on native buttons did.

## The race (docs/goals/43/race.json, commit 5937c38)
| | A: omxcode, in process | B: transformers.js 4.3.2, WebGPU, Chromium |
|---|---|---|
| weights | openai/whisper-large-v3-turbo | the same, onnx-community's ONNX export |
| precision | fp16 | encoder fp32, decoder q4 |
| log-mel | GPU (torch) | CPU (JavaScript) |
| decoding | greedy, en, transcribe | greedy, en, transcribe |
| per clip p50 / p95 | 140.2 / 189.3 ms | 912.2 / 1244.2 ms |
| real-time factor | 0.0151 | 0.0986 |
| WER (20 clips) | 0.034 | 0.034 |
| cold start | 6.59 s | 9.94 s |
| peak GPU memory (nvidia-smi rise) | 2,075 MB | 3,941 MB |
| fetched | — (HF cache) | 2,886 MB (served locally) |

| B variant (encoder / decoder) | p50 / p95 | WER | fetched |
|---|---|---|---|
| fp16 / fp16 | didn't load: the adapter has no shader-f16 under any of 18 Chromium flag sets (docs/goals/43/webgpu-f16-probe.json) | | |
| fp32-1file / fp32 | didn't load: Chromium can't allocate one 2,547,875,840-byte ArrayBuffer for the single external-data file (page fetchtest: 'RangeError: Array buffer allocation failed'; files up to 1.27 GB read whole); transformers.js reports it as 'Failed to fetch'. Same tensors split under 2 GB = variant fp32 (D-1416) | | |
| fp32 / fp32 | 924 / 1214 ms | 0.034 | 3239 MB |
| fp32 / q4 | 912 / 1244 ms | 0.034 | 2886 MB |
| q4 / fp32 | 1018 / 1361 ms | 0.030 | 1116 MB |
| q4 / q4 | 944 / 1226 ms | 0.030 | 762 MB |

## Round 0 (first pass, superseded)
B ran q4/q4 at 933 ms against A's 135 ms (6.9×), with fp32 "failed to fetch" and the GPU's quietness not sampled during runs.

In the app itself (M2), the final text is on screen 290–330 ms after the speaker stops (a floor, see review item 5) (120 ms of quiet + one
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
2. **D-1411/D-1416, B's precision.** B has no fp16 here, and its fp32 encoder loads only with its weights split under
   2 GB (same bytes). Every precision that loads was raced; B is the fastest within 0.01 WER of A. fp16 B is unmeasured.
3. **D-1409, the GIL.** Mojo's main thread gives the interpreter's lock up after the first model and every call takes
   it briefly. It works (feed+poll ≤ 5.2 ms), but any other Python use on the main thread must follow the same rule.

Also: D-1413 changed how the GTK host and present.mojo dlopen (OwnedDLHandle), which every GTK app goes through.

## Unverified
- A real microphone: everything went through the checker's null sink (owner's devices untouched by rule).
- The Mac: `scripts/build.sh dictate mac` builds; the microphone and the model report "not on this host" there.
- B with fp16: no Chromium flag set here offers shader-f16; unmeasured on any machine.
- Why the shader-f16 is missing (driver lacks a Vulkan 16-bit feature Dawn needs, or Dawn blocks it on this driver): not checked (no vulkaninfo here).
- The reviewer hasn't re-run on round 1.

## Final checker run
```
M0 PASS: captured the played tone through the sound server, match 0.9902822245095156, the caller never blocked
M1 PASS: whisper-large-v3-turbo in process, 20 clips, WER 0.030, partials before each clip ends
M2 PASS: 5 clips through the null sink: WER 0.016, final text 291 ms median / 329 ms p95 after speech ends
M3 PASS: A 135 ms p50, WER 0.034; B (onnx-community/whisper-large-v3-turbo) 933 ms p50, WER 0.030; cold start 4.6 s vs 7.8 s
M4 PASS: gallery Dictation section with the race's numbers, matrix, llms.txt, EXPERIMENTS; mac built
```
