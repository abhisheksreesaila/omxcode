# Goal 72 report: omx, the voice app, rebuilt on omxcode

Branch `goal-72-omx-voice` (base main cc33c9d7). Check: `pixi run python docs/goals/72-check.py` (M0 to M7; numbers in `build/g72/*.json`,
the last full run in `build/g72/check-full.txt`). Decisions D-7200 to D-7315 in `docs/decisions.md`. The prototype this reproduces is
`~/Projects/omx-local` (Python and JavaScript, goals 1 to 4, 23 of 23 checks); it was only read.

## What was built

The framework first; the app only composes.

| Piece | What it is | Proved by |
|---|---|---|
| `mojoui.llm` + `bridge/llm_shim.cpp` | Qwen3.8-27B (UD-Q4_K_M) through libllama in the app's own process: one engine thread, tokens to the UI as events, the prompt cache kept between turns (checkpoints for the hybrid model), the model's own chat template, parsed tool calls, cancel, a second sequence for background work. Survives what one request throws (D-7302). | tests/test_llm, test_llm_room |
| `mojoui.voice`, `mojoui.speaker`, `mojoui.voiceloop` | Kokoro TTS, Parakeet speech to text (in-process, through Python interop as `mojoui.speech` runs Whisper), Silero endpointing, barge-in, PulseAudio out; the browser's microphone and speaker on the web host (one WebSocket, `docs/web-audio.md`) | tests/test_voice, tests/test_web_audio.py |
| `mojoui.llmagent` | an AG-UI agent whose brain is the in-process model (`LocalAgent`): RUN_*, TEXT_MESSAGE_*, TOOL_CALL_*, STATE_*, `render_ui` cards from the catalog; the app's buttons are its tools (the agent host's rule, D-162); a conversation that never fills (D-7314); text from outside is data (D-7301) | tests/test_llmagent, test_compact, test_trust |
| `mojoui.agentserve` | the same agent as an AG-UI HTTP/SSE endpoint | the official `ag-ui-protocol` client, `scripts/agui_llm_check.py` |
| `mojoui.assistant`, `todo`, `news`, `llmjob`, `cloudlane` | to-do (a file, the voice and the tick boxes edit it), news cards, think-it-through jobs on the second sequence, the cloud lane (`claude -p`, only when named, capped, the record written first, a turn state machine `CloudTurn`) | tests/test_todo, test_news, test_llmjob, test_cloudlane, test_assistant |
| `mojoui.creator`, `comic`, `imagegen`, `notes`, `album` | comics and pictures (stable-diffusion.cpp as a supervised child on its own GPU, panel by panel on a card), find in my notes (e5-small by MAX in the process, an incremental cached index, one folder only, cited) | tests/test_creator, test_imagegen, test_notes |
| `mojoui.trust`, `mojoui.utf8` | untrusted text is fenced and taints the turn; byte cuts that never split a character | tests/test_trust, test_utf8 |
| `examples/omx` | the app: the orb that listens and speaks, captions, the shelf of cards, the lane chip, the cloud frame, Liquid light and dark; no host imports, colours or pixel sizes (the app-lint passes) | 72-check M4 |

The web host serves it to a tablet behind a pairing key over `tailscale serve` (`scripts/tablet.sh omx`).

## Numbers, beside the prototype's

Last full run, this machine (two RTX 3090s: the brain on GPU 0, the voice, embeddings and pictures on GPU 1).

| What | This build | omx-local (prototype) | Limit |
|---|---|---|---|
| Decode, Qwen3.8-27B Q4, one 3090 | 43.0 tok/s (no MTP) | 42.8 without MTP, 74.3 with MTP | 40 |
| First token, warm cache, in-process vs llama-server HTTP | 50 ms vs 76 ms | n/a | in-process no slower |
| Second turn first token vs first (cache kept) | 103 ms vs 2345 ms (0.044x) | n/a | 0.5x |
| Cancel mid-reply | 18 ms | n/a | 100 ms |
| Agent first words, in-process vs the AG-UI SSE endpoint | 104.7 ms vs 111.7 ms (+7.0 ms) | n/a | n/a |
| TTS first audio (Kokoro) | 43 to 64 ms | n/a | 400 ms |
| Parakeet hears the TTS back, WER | 0.00 | n/a | 0.10 |
| Speech end to final text (unit) | 115 ms (median 120) | n/a | 300 ms |
| First audio after the question, in the app | 814 ms | 726 ms (M3) | 1500 ms |
| Interruption stops the speaker | 208 ms | 251 ms (M4) | 500 ms |
| Tablet: question to first spoken audio | 1.08 s | n/a | 2.0 s |
| Comic: first panel, four panels | 12.4 s, 22.7 s | 10.9 s, 21.1 s (M21) | n/a |
| Notes: answered and cited | 5 of 5, search 17 to 19 ms | 5 of 5 (M22) | 4 of 5 |
| Spoken question during a think-it-through job, first audio | 964 ms | 915 ms (M23) | 1500 ms |
| Cloud lane, one real request | 217 bytes out, 292 in, 3 s, a sent row then its outcome (0600) | n/a | n/a |
| Never full: 84 turns on an 8192-token context | condensed 4 times, no failed run, the first turn's facts recalled, first words late/early 1.03 | n/a | 1.3 |
| Notes index of 351 notes (1650 passages), longest UI tick | 6.4 ms; the app on that folder with the 16 ms watchdog printed no `SLOW:` line | n/a | 16 ms |

## The review round (this branch's last commits)

A reviewer's findings, each fixed at its root with a behaviour test (D-7300 to D-7315):

- `Origin: null` is a foreign page (page and `/audio` socket refused); the key redirect stays on a relative path; `tablet.sh` sets
  `MOJOUI_BEHIND_PROXY`; one live audio page per process, a second tab says why; the audio pump logs once when it stops.
- Notes and headlines are data: fenced, they taint the turn; `news`, `todo_remove`, `todo_done` and every app button but `stop` and `type`
  are refused until the person says yes in their next message; topics are plain words, 80 bytes. The cloud lane starts only from the
  person's own words, so it needs no gate.
- The engine thread catches what one request throws; a forced fault in the token feed, the admission or the end ends only that request.
  Two sequences share one context: a background prompt that doesn't fit is refused and a full context never wipes the conversation.
- Cloud lane: the record first (0600, nothing leaves without it), `--` before the prompt, cancel never waits, names in other words
  ("Claude Monet", "do you have a haiku") stay local.
- The conversation never fills: condensed between turns on the second sequence, the cache warmed while idle, `start_over()` clears it.
- UI thread: the notes index builds a few passages a tick and a question takes an incremental look; byte cuts are UTF-8 safe;
  `Album.hold` is capped; the to-do file reports a failed save and sets an unreadable file aside; the watcher never follows a link out.

## Honest gaps

- **Speech end to final text is 521 to 533 ms in the app against 115 ms in the unit test, and the unit's limit is 300 ms.** The unit
  counts from the endpointer's decision; the app counts from the person's last voiced sample (`LoopEvent.ms`), so it includes the
  endpointer's 384 ms hangover: 533 minus 384 is about 150 ms of recognition, the unit's 115 ms plus a tick. The 300 ms limit was
  written for the unit; the app has no limit of its own on this number, and its end-to-end first audio (814 ms) is inside 1.5 s. The
  check's own line says "after the endpointer's quiet"; it is after the last voiced sample.
- **No MTP in the process yet.** 43 tok/s is the no-MTP speed; the prototype's 74 tok/s needs the MTP head, which `mojoui.llm` does not drive.
- **MAX is not the brain** (D-7201): MAX 26.7 knows Qwen3.8-27B only as bf16 (54 GB, more than both 3090s), fp8 (no Ampere path shown, a small FP8 Qwen failed here) or NVFP4 (Blackwell). MAX runs where it fits: the notes' embeddings.
- **One tab at a time.** A second tab ends the first, with a message (D-7310): one model, one microphone and one speaker per process. Sharing the model between sessions was not built.
- **Echo without headphones.** The speaker and the microphone share a room; barge-in works with the browser's echo cancellation on the tablet and is checked on the desktop with a file as the microphone, not with a person in the room.
- **Not provoked by a test:** the decode-time branch of a full shared context (D-7309); a long natural conversation (the compaction test is a scripted one). One run in three of that script at temperature 0.3 drifted into one-word replies from turn 57, unrelated to a condensing; the test runs greedy. Not investigated further.
- `start_over()` is in the agent; no button in the app calls it yet.

## Screenshots

`docs/goals/72/`: `desktop_light_home.png`, `desktop_light_work.png`, `desktop_dark_home.png`, `desktop_dark_work.png`,
`phone_light_home.png`, `phone_light_work.png`, `phone_dark_home.png`, `phone_dark_work.png` (390x844), `tablet.png` (820x1180, over the
tailnet), `a_card.png`, `todo_five.png`, `todo_ticked.png`, `news_one.png`, `news_two.png`, `job_running.png`, `job_done.png`,
`frame_local.png`, `frame_cloud.png`, `frame_after.png` (the cloud lane's orange frame), `comic_card.png`, `picture_card.png`, `notes_card.png`.

## The AG-UI story

Every reply of the in-process agent is AG-UI events (`LlmAgent`, a `LocalAgent`): RUN_STARTED, STATE, TEXT_MESSAGE_*, TOOL_CALL_*
with results, RUN_FINISHED, and `render_ui` cards validated against the catalog and drawn natively. The app's own buttons, fields and
switches are the agent's tools (`view_tools`), named as the agent host names them, so what a person can tap the agent can press, and
what another AG-UI client or an MCP client can drive is the same set. The same agent is served over HTTP and SSE (`agentserve`), and the
official `ag-ui-protocol` client runs against that endpoint with every event validating (`scripts/agui_llm_check.py`); the in-process path
is 7 ms faster to the first word than the endpoint. Nothing in the app is specific to the model: a different `LlmAgent` brain, or a
remote AG-UI agent, drives the same screen.

## Reproduce

```
scripts/build_llm_shim.sh                      # build/llm/libmojoui_llm.so against omx-local's llama.cpp build
G72_GPU=0 pixi run python docs/goals/72-check.py M1 M3      # the brain's card; the HTTP baseline runs on the other
G72_GPU=1 pixi run python docs/goals/72-check.py M2         # the voice's card
G72_LAYOUT=split pixi run python docs/goals/72-check.py M4 M5 M6 M7
scripts/omx.sh                                 # the app; scripts/tablet.sh omx for the tablet
```
