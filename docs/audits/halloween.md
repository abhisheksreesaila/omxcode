# Audit: Pumpkin Greeter (`halloween`) on omxcode

2026-10-31 · app: `/home/abhisheksreesaila/Projects/halloween` · question: could omxcode build it the same way, on the device it runs on?

## Verdict
**Partly. Not on the tablet.** Not on the tablet: omxcode can draw every screen and run the visit logic on Linux and the web today, but it has no camera, no audio output, no text-to-speech, no kiosk controls and no https, and its Android host lacks timers and HTTP.

Of 27 features: **12 have (44%), 9 partial (33%), 6 missing (22%).**

What we have is the easy half: the screen (cards, slider, segmented pickers, switches, badges, meter, omxqua theme), the
visit state machine and timers, and fallbacks when the model fails, all checked on Linux and the web. What's missing is
everything that makes it *this* app: the eyes (camera), the mouth (speaker and a voice), the kiosk (fullscreen,
keep awake) and a model call over https. On the real device, an Android tablet, the host doesn't yet have timers,
HTTP or overlays, so even the half we have can't run there.

The closest faithful rebuild today would be a Linux laptop running the GTK app with a webcam. It would still be
missing the camera, the speaker and the voice.

## Features
Hosts: Linux · Web · Android · Mac · iPhone (✅ run by a check, 🔨 built and never run, ❌ missing).

| Area | Feature | App code | omxcode piece | Hosts | Status | Gap (size, ETA) |
|---|---|---|---|---|---|---|
| Screens | Start screen: one big 'Wake Jack' button over everything (unlocks sound, camera, keep-awake) | `app/static/index.html:101` | Overlay + Card + Button(style=PROMINENT) | ✅ ✅ ❌ 🔨 🔨 | **have** |  |
| Eyes | Live camera view, rear or front, 'Switch camera' | `app/static/main.js:399` | none | ❌ ❌ ❌ ❌ ❌ | **missing** | mojoui.camera: live frames (V4L2/PipeWire on Linux, getUserMedia bridged by the web host, CameraX on Android, AVCaptureSession on Apple) into FrameFeed, so Canvas/Player show it and analyzers read it (L, Dec 2026, blocks) |
| Eyes | Tracking boxes drawn over the live picture | `app/static/main.js:332` | Canvas + mojoui.imageops (outline a rectangle) over mojoui.framefeed frames | ✅ ✅ 🔨 🔨 🔨 | **partial** | the drawing exists; it needs live frames from mojoui.camera (S, Dec 2026, blocks) |
| Eyes | Person detection on the device, ~10 times a second, box height as distance | `app/static/main.js:421` | mojoui.visionmodel (VisionModel DETECT, OWLv2 in process; SAM 2 tracking) | ✅ ❌ ❌ 🔨 ❌ | **partial** | a small real-time detector (EfficientDet/YOLO-nano class) compiled by MAX, running on the device's own GPU or NPU; today's model is a heavyweight desktop-CUDA one (M, Dec 2026, blocks) |
| Visit logic | Approach state machine: idle → far → closer → door (held 600 ms) → linger ×2 → leave → re-arm | `app/static/greeter.js:20` | plain Mojo struct in update() + App.every() timers | ✅ ✅ ❌ 🔨 ❌ | **have** |  |
| Visit logic | Rehearsal mode: a timer steps far → closer → door when there's no real door | `app/static/greeter.js:16` | App.every() + Toggle | ✅ ✅ ❌ 🔨 ❌ | **have** |  |
| Screens | Proximity meter with 'closer' and 'door' ticks, and the stage words | `app/static/index.html:43` | mojoui.meter (Meter) / ProgressBar | ✅ ✅ ❌ 🔨 🔨 | **have** |  |
| Look | Jack the pumpkin (vector art) whose mouth moves while he talks | `app/static/main.js:543` | Canvas + Painter.polygon + on_frame + mojoui.spring | ✅ 🔨 ❌ 🔨 🔨 | **partial** | no SVG paths or radial gradients in Painter: the art must be hand-ported to polygons; add Painter.path(svg d-string) + gradient fills (M, Nov 2026) |
| Look | Show mode: the whole screen is a big glowing Jack face, eyes blink, hold the face 1.5 s or tap Exit to leave | `app/static/main.js:526` | Overlay + Canvas (PRESS/RELEASE) + App.every() + Spring | ✅ ✅ ❌ 🔨 🔨 | **partial** | works as a window-filling overlay; true fullscreen needs App.fullscreen() (see kiosk); glow art needs gradients (S, Nov 2026) |
| Device | Kiosk: fullscreen, screen kept awake, wake lock re-taken when the page comes back, camera restarts if it freezes | `app/static/main.js:436` | none | ❌ ❌ ❌ ❌ ❌ | **missing** | App.fullscreen() and App.keep_awake(): gtk_window_fullscreen + idle inhibit (xdg portal), the web host's requestFullscreen + navigator.wakeLock, Android FLAG_KEEP_SCREEN_ON + immersive mode, NSWindow/UIApplication idleTimerDisabled (M, Nov 2026, blocks) |
| Screens | 'Jack said' card with the last line and a source badge (claude / fallback) | `app/static/index.html:47` | Card + Text + mojoui.chip (Badge) | ✅ ✅ 🔨 🔨 🔨 | **have** |  |
| Controls | Door-distance slider (20–85%), with 'right now' size and greeted-tonight count | `app/static/index.html:56` | Slider + Text | ✅ ✅ ✅ 🔨 🔨 | **have** |  |
| Controls | Voice (Ryan/Alan/Joe/Northern) and strength (Spooky/Monster) pickers | `app/static/index.html:58` | Segmented | ✅ ✅ ✅ 🔨 🔨 | **have** |  |
| Controls | 'Jack listens' and 'Rehearsal' switches | `app/static/index.html:61` | Toggle | ✅ ✅ ✅ 🔨 🔨 | **have** |  |
| Controls | 'Greet now' test button | `app/static/main.js:467` | Button | ✅ ✅ ✅ 🔨 🔨 | **have** |  |
| Storage | Settings remembered per device (door, voice, effect, listen, rehearsal) | `app/static/main.js:33` | mojoui.files (config_dir: ~/.config/<app>/settings.txt) | ✅ 🔨 ❌ 🔨 ❌ | **partial** | mojoui.prefs: typed get/set per device (a file on desktop, localStorage on the web, SharedPreferences on Android, NSUserDefaults on Apple) (S, this week) |
| AI | Snapshot as JPEG → Claude vision → tease, greeting, answer, goodbye in one call; up to two banter calls; key kept off the screen | `app/server.py:95` | mojoui.http (Request.post_json, header_from_env, SSE streams) / mojoui.agui (Anthropic SDK via Python) | 🔨 🔨 ❌ 🔨 ❌ | **partial** | https to api.anthropic.com (a TLS transport: flare at Mojo 1.2, or a mojoui.llm client over Python interop like speech_torch), plus a JPEG encoder and base64 (only encode_png today) (M, Nov 2026, blocks) |
| AI | Canned fallbacks when the model fails or is slow, so kids always hear something | `app/greeting.py:42` | mojoui.http Response.failed → Event + App.every() timeout | ✅ ✅ ❌ 🔨 ❌ | **have** |  |
| Voice | Jack's voice: Piper neural voice, pitched down with a haunted echo (ffmpeg), rendered and cached per line | `app/voice.py:31` | none | ❌ ❌ ❌ ❌ ❌ | **missing** | mojoui.voice: a TTS model in process (Piper ONNX via Python interop, like mojoui.speech; MAX later) + pitch/echo/low-pass as Mojo DSP kernels instead of an ffmpeg subprocess (M, Nov 2026, blocks) |
| Voice | Playing audio out of the speaker, and the mouth following its loudness | `app/static/main.js:89` | none | ❌ ❌ ❌ ❌ ❌ | **missing** | a Speaker beside Microphone in mojoui.audio: play(samples), level(), stop(); PulseAudio/PipeWire, Web Audio via the web host, AudioTrack, AVAudioEngine (M, Nov 2026, blocks) |
| Voice | Haunted tune before the greeting (oscillators with vibrato) | `app/static/main.js:46` | none | ❌ ❌ ❌ ❌ ❌ | **missing** | a tiny tone/envelope generator in Mojo feeding the Speaker (S, Nov 2026) |
| Voice | Fallback to the device's own voice when the laptop voice is down | `app/static/main.js:159` | none | ❌ ❌ ❌ ❌ ❌ | **missing** | platform TTS: speech-dispatcher, the browser's speechSynthesis, Android TextToSpeech, AVSpeechSynthesizer (M, Dec 2026) |
| Ears | Kids talk back: listen after the greeting, a tiny vocabulary (hi, trick or treat, boo, thanks, bye, joke, who are you), ignore Jack's own echo, canned instant replies | `app/static/ears.js:72` | mojoui.audio Microphone + mojoui.speech SpeechStream (whisper-large-v3-turbo on the GPU) + audio.best_match | ✅ ❌ ❌ 🔨 ❌ | **partial** | Linux only today: the web host doesn't stream the browser's mic, Android has no mic and no Python; needs a mic on every host plus a small on-device speech model (whisper tiny/base via MAX) (L, 2027, blocks) |
| Screens | Status badges: camera, detector, ears (ok / warn / bad) | `app/static/main.js:404` | mojoui.chip (Badge with tone and dot) | ✅ ✅ ❌ 🔨 🔨 | **have** |  |
| Look | omxqua night look: deep purple, pumpkin accent, kids' rounded type, roomy | `app/static/index.html:2` | themes/omxqua.mojo via App.theme() | ✅ ✅ ❌ 🔨 🔨 | **have** |  |
| Device | Runs on the Pixel Tablet itself (Android) | `CLAUDE.md:1` | mojoui/hosts/android.mojo (views over JNI) | ❌ ❌ 🔨 ❌ ❌ | **partial** | Android parity for what this app uses: Timers, HTTP, Overlay, Card, Canvas press/release, the chip and meter composites, then camera, mic and speaker (L, Dec 2026, blocks) |
| Reliability | Runs ~3 hours unattended without freezing (camera retry, model timeouts, no nagging) | `app/static/main.js:447` | mojoui.jobs + App.every() + MOJOUI_BUDGET_MS watchdog | ✅ ✅ ❌ 🔨 ❌ | **partial** | a 3-hour soak check once camera, detector and speaker exist (S, Dec 2026) |

## Where omxcode would be better
- **Ears run whisper-large-v3-turbo in the app's own process on the GPU, offline: no audio sent to Google as Android's Web Speech API does, and Jack's echo can be rejected by matching his own samples (audio.best_match).** Evidence: docs/probes.md Dictate (goal 43): 140 ms vs 912 ms per clip against transformers.js; tests/test_speech.mojo, tests/test_audio.mojo. Linux only.
- **Open-vocabulary detection and tracking in process (OWLv2 + SAM 2): 'a child in a costume', boxes that follow each kid, not just the generic 'person' class.** Evidence: tests/test_visionmodel.mojo (goal 39); unproven live, and too heavy for a tablet today.
- **One program, no laptop server: UI, state machine, detector, voice and the Claude call in one process; the key read from the environment by the HTTP worker, never in the app's state.** Evidence: mojoui/http.mojo header_from_env; the one-process claim is unproven for this app (no camera, speaker or TTS yet).
- **Agent-drivable for free: an agent could press Greet now, switch the voice, flip Rehearsal and read what Jack said, through MCP, with no extra code.** Evidence: docs/agent.md (Slider, Segmented, Toggle, Button become tools; read returns texts).
- **Voice effects as Mojo DSP instead of an ffmpeg subprocess per line.** Evidence: unproven.
- **A freeze watchdog for the 3-hour run: any update, view or draw over budget is named.** Evidence: docs/ui-threads.md, MOJOUI_BUDGET_MS, examples/slowcheck.

None of these is proven *in this app*. The ears and the detector are real and checked, but only on a Linux desktop
GPU. On the tablet they'd need the MAX-compiled small models in the gap list.

## Gaps, in order
1. **No camera**: mojoui.camera into FrameFeed (V4L2/PipeWire, web getUserMedia bridge, CameraX, AVCaptureSession). L, Dec 2026. Unblocks: Live camera view, Tracking boxes, Person detection, Snapshot to Claude, Show mode watching underneath.
2. **No audio out**: mojoui.audio Speaker: play(samples), level() (PulseAudio, Web Audio, AudioTrack, AVAudioEngine). M, Nov 2026. Unblocks: Jack's voice, Mouth following loudness, Haunted tune.
3. **No text-to-speech**: mojoui.voice: Piper in process + Mojo DSP effects; platform TTS as fallback. M, Nov 2026. Unblocks: Jack's voice, Device-voice fallback.
4. **No https and no image payloads for model calls**: TLS transport (flare, Mojo 1.2) or mojoui.llm over Python interop; JPEG + base64 encoders. M, Nov 2026. Unblocks: Snapshot to Claude, Banter.
5. **Android host can't run this app**: Android Timers, HTTP, Overlay, composites, then camera/mic/speaker. L, Dec 2026. Unblocks: Runs on the Pixel Tablet, Visit logic on the tablet, Show mode on the tablet.
6. **No kiosk controls**: App.fullscreen() + App.keep_awake() on every host. M, Nov 2026. Unblocks: Kiosk, Show mode fullscreen.
7. **No real-time on-device detector**: a small detector compiled by MAX on the device GPU/NPU behind VisionModel. M, Dec 2026. Unblocks: Person detection on the tablet.
8. **Mic and speech only on Linux**: mic on web/Android/Apple + a small on-device speech model via MAX. L, 2027. Unblocks: Kids talk back on the tablet.
9. **No SVG paths or gradients**: Painter.path(svg d) + radial gradient fills. M, Nov 2026. Unblocks: Jack face, Show mode glow.
10. **No per-device preferences**: mojoui.prefs (file, localStorage, SharedPreferences, NSUserDefaults). S, this week. Unblocks: Settings remembered.

Gaps 1 to 4 are generic. Every camera, voice or AI app needs them: a doorbell, a dictation app, a vision kiosk. A
**"Jack on Linux" demo video** becomes possible once 1 to 4 land (Dec 2026): a webcam, in-process detection, whisper
ears and Piper voice in one Mojo process, with no server. "Jack on the Pixel Tablet" also needs 5 to 8 (Dec 2026 for
the visit, 2027 for the ears).

Method: read the app's code, brief and plan, `docs/components.md` (generated from the checks), `docs/ui-threads.md`,
`docs/probes.md`, `docs/agent.md` and the mojoui sources named above. No checks were run: every ✅ is the matrix's
check-backed mark, and each gap was confirmed by grepping `mojoui/` (camera, playback, tts, fullscreen, wakelock, https).
