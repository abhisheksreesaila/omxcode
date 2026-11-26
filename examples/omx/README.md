# omxome

A voice assistant for the kitchen counter, built on omxcode. Ask out loud, and it shows you. The product page is
[omxome.html](https://abhisheksreesaila.github.io/omxcode/omxome.html). This folder is the app: `app.mojo` only composes
framework components from `mojoui/`. (Inside, the assistant still answers to "omx".)

## How it got here

It started as a voice loop on a counter: talk, and a local model talks back in under a second. It worked, but a voice in a
box can't show you anything. A counter screen gets used four ways in one morning (glance, talk, "show me", check), and
most assistants pick one. So the design was prototyped fourteen times before any of it was built. Each version taught one
thing:

| Version | What it was | What it taught |
|---|---|---|
| before | glass on the wallpaper: a translucent sidebar over a photo | no glass, no shimmer: the look is solid, only the motion is liquid |
| A–C | a stage, a sidebar, a board | each solved one mode and broke the others |
| D | One surface: Glance, Jam, Show me, Check | what you say picks the mode; silence folds it back. Then voice first: the chat pill hid the cards, so voice became a corner orb |
| E–H | Frame, River, Orbit, Companion | four structures, not four colours |
| I · J | live tiles; a mind map | tiles won the home screen; the mind map became Plans, opened from the to-do tile |
| v8 | solid tiles, a spring sampled into the motion curve | words never stretch when a tile resizes; the pointing ring stays |
| v9 | drag, corner resize through four sizes, urgency grows a tile | your own size beats urgency |
| v10 | themes and profiles, a kid-safe model | (themes were later dropped) |
| v11 | flat, every press sinks in and springs back | "tvOS is for a remote; this is touch" |
| v12 | no theme picker: occasions and charms | one small charm on the card it's about, never a makeover |
| v13 | the Stage: three columns, an exact grid | the free grid looked uneven |
| v14 | the TV: the chat bar grows over the stage when it explains | the one that was built |

Then every piece went into omxcode first, each with its own test (goal 77, M7a–M7f):

- the Stage shell (`mojoui.stage`);
- live tiles (`mojoui.livetiles`);
- tiles the agent can move (genui `LiveTiles`, the `tiles` tool, JSON Patch);
- the TV (`mojoui.stagetv`);
- the sides with pins and charms (`mojoui.stagefeed`, `mojoui.charms`);
- omx on top.

The full record is in [docs/goals/77-report.md](../../docs/goals/77-report.md) and
[docs/goals/72-report.md](../../docs/goals/72-report.md).

## Inside

| Part | Where | What |
|---|---|---|
| ears and mouth | `mojoui.voiceloop` | microphone → Silero VAD → Parakeet; Kokoro → speaker; barge-in |
| brain | `mojoui.llmagent`, `mojoui.llm` | Qwen3.8-27B (4-bit) in this process through llama.cpp, AG-UI events, `render_ui` |
| cards | `mojoui.agentui`, `mojoui.genui` | the model's `render_ui` calls, checked against one catalog and drawn natively |
| the Stage | `mojoui.stage`, `stagetv`, `livetiles`, `stagefeed`, `charms` | three columns, the TV, live tiles, pins, charms |
| pointing | `mojoui.visual`, `mojoui.tripmap`, `mojoui.explain` | the ring on the part it's saying; maps; isometric diagrams |
| the camera | `mojoui.looker` | the model's own eyes; frames are kept nowhere and sent nowhere |
| cloud lane | `mojoui.cloudlane` | only when asked by name: one capped request through the logged-in `claude -p`, an orange frame, a record of what left |

## Run it

```
git clone https://github.com/abhisheksreesaila/omxcode
cd omxcode && pixi install
# the Stage, with sample data and canned answers (no model)
scripts/build.sh stage linux && build/stage/linux/stage
# omxome, with its models
scripts/build.sh omx linux && build/omx/linux/omx
```

omx looks for `Qwen3.8-27B-UD-Q4_K_M.gguf` and `parakeet-tdt-0.6b-v3` in `OMX_MODELS`. Every setting is listed at the top
of `app.mojo`.

## Numbers

All measured on one Linux machine with two RTX 3090s, by the goal checks:

| What | Value | Source |
|---|---|---|
| end of question → first spoken word | 814 ms | goal 72 |
| talking over it → it stops | 208 ms | goal 72 |
| follow-up first token (context kept on the GPU) | 103 ms (2,345 ms cold) | goal 72 |
| decode, Qwen3.8-27B Q4, one 3090 | 43 tokens/s | goal 72 |
| a 40-component screen streamed over AG-UI, native GTK | first part 12 ms, whole 70 ms | goal 48, docs/agui.md |

## Honest edges

- It's an alpha. There's no download yet; one will come once the app can carry its models.
- omx with its model and voice runs on Linux, measured on two RTX 3090s: the model on one card, the voice on the other. A
  single-card setup hasn't been measured.
- On the Mac, the Stage runs natively on an M4. The model hasn't run there yet.
- iPhone and iPad: the host is built but hasn't run on a device. Android: not started for omx.
- The tiles' calendar, weather, photos and door are sample data. Real connectors come later.
- The cloud lane speaks to Claude only, through its own command line.
- The input hint says "just say omx", but there's no wake word: it listens to any speech (VAD).
- A rare crash showed up in long test runs: 3 in 16 before a fix (D-7889), none in 32 since. Its root cause isn't found yet.
