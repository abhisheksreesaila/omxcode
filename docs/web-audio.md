# The web host's audio: a tablet as the screen, microphone and speaker of an app on this machine

Goal 72 M5. An app that uses `Microphone` and `Speaker` (mojoui.audio, mojoui.speaker) needs **no change** to run on the web
host: its microphone is the browser's, its speaker plays in the browser. The same Mojo calls, a different end.

```mojo
var mic = Microphone()
mic.start()                    # the page opens its microphone (the first time, the browser asks the person)
var heard = mic.read(since)    # 16 kHz mono floats, as on the desktop; total(), level(), captured_ns() too
var speaker = Speaker()
speaker.play(samples, 24000)   # plays in the page, gap-free; a rate that isn't 24 kHz is resampled
speaker.stop()                 # the page's queue is flushed within ~100 ms (measured 16 ms)
```

`examples/echo` is the smallest app that uses both (Listen, Play back, Tone, Stop sound).

## How it works

```
 browser (tablet)                                  this machine (web host, loopback only)
 ───────────────                                   ───────────────────────────────────────
 getUserMedia (echo cancellation on)
  → AudioWorklet: average to 16 kHz, 16-bit       ── WebSocket /audio ──►  audio_push → ring  → Microphone.read()
 AudioContext ◄ buffers scheduled back to back    ◄─────────────────────   audio_pull ◄ queue ◄ Speaker.play()
 flush: stop every scheduled buffer               ◄── {"t":"flush"} ─────  Speaker.stop() counts a flush
```

- **Transport: one WebSocket, `/audio`**, on the web host's own server (uvicorn). It is already there, it is full duplex, it
  keeps the order of frames and messages (a flush can never pass the samples before it), and it works through
  `tailscale serve` unchanged. Binary frames start with a tag byte: `1` microphone (16-bit mono, 16 kHz, up), `2` speaker
  (16-bit mono, 24 kHz, down), `3` a camera still (up; goal 77 M6, below). JSON text frames carry the rest:
  `claim`, `latency`, `mic_fail`, `cam_fail` up; `mic`, `flush`, `tap`, `bumped`, `cam`, `snap` down.
- **The hub** (`mojoui/webaudio.mojo`) is one block of memory per server process: the browser's microphone is a set of
  capture words in the layout `Microphone` already reads, the speaker's are the layout `Speaker` already writes. `Microphone`
  and `Speaker` find the hub (mojoui.shared slot 89) when they start and use it instead of the sound server; on the GTK host,
  in tests and everywhere else there is none, and they open the sound server as before.
- **One hub per machine**, because the machine has one microphone and one speaker: with two pages open, the one that was
  tapped last holds them, and the other is told (`bumped`) and stays quiet.
- **Speaker lead:** the host hands the page at most 600 ms of unplayed audio, so a `stop()` is a flush of at most that, and
  `queued_ms()` still means something. `playing()` counts what the page has been given until the time it would have ended.
- **Not in the public copy:** `MOJOUI_PUBLIC=1` has no `/audio`, no hub and no pairing (it has its own rules, docs/web-public.md).

## The camera (goal 77 M6)

An app that uses `Camera` (mojoui.camera) needs no change either: on the web host its camera is the page's rear camera, on a
desktop the machine's own (ffmpeg on Video4Linux). The same socket carries it, but never as a stream:

```
 app: cam.start()      -> {"t":"cam","on":true}   -> the page opens getUserMedia({video: facingMode environment, ideal 1280x720})
 app: cam.snapshot()   -> {"t":"snap","id":N}     -> the page draws the current video frame to a canvas, JPEG at 0.85
 page: tag 3 frame      = 0x03 | u32 N | u16 width | u16 height (little-endian) | the JPEG   -> mojoui.webcamera's hub -> cam.tick()
 app: cam.stop()       -> {"t":"cam","on":false}  -> the page closes the camera (its light goes out)
 page: {"t":"cam_fail","code":101|102|103}        -> refused / none found / not allowed here: cam.problem says so
```

The camera belongs to the page that was tapped last, as the microphone does (a page that is not the claimed one is told
`bumped` and lets go of it). A still answers the request it carries; an older still never answers a newer request. Nothing is
kept: the hub holds the newest JPEG (two buffers of 4 MiB, the number published last), and the app's card shows it. The hub
is mojoui.shared slot 186. Proof: scripts/g77_camera_check.py (headless Chromium's fake camera playing a file), tests/test_camera.

## The tap

A browser plays no sound, and on a phone or tablet may not open a microphone, until the person has touched the page. The first
tap, key press or click anywhere on the page (the app's own microphone button is one) turns audio on and makes that page the
one the app hears and speaks through. Until then, if an app wants audio (it started its Microphone, or queued sound), the page
shows a small **Tap to turn on sound** button. Sound an app queued before the first tap is dropped, not played late.

## Another device: pairing, and `scripts/tablet.sh`

The web host binds this machine's loopback, so nothing else can reach it. `tailscale serve` is a reverse proxy on this machine:
`https://<machine>.<tailnet>.ts.net:<port>` → `http://127.0.0.1:<port>`, with a real certificate (a browser only lets a page use
the microphone over https or on localhost). Behind it every caller looks local, so the host has its own rules
(`mojoui/hosts/pairing.py`, tests/test_pairing.py), for every page, event and socket:

| Rule | Why |
|---|---|
| The `Host` header names this machine (localhost, 127.0.0.1, [::1], its host name, its addresses) or a name in `$MOJOUI_EXTRA_HOSTS` (comma separated: the tailnet name; tablet.sh sets it) | DNS rebinding, a stray proxy |
| An `Origin`, when the browser sends one, equals `Host` | another site's page can't use the host from a visitor's browser |
| From anything but a loopback peer with **no** proxy headers (`X-Forwarded-*`, `Forwarded`, `X-Real-IP`, `Tailscale-User-*`, or `$MOJOUI_BEHIND_PROXY=1`): the pairing key | behind a proxy, nobody counts as local |
| The key: a first visit to `https://<name>/?k=<key>` sets a cookie (HttpOnly, SameSite=Strict, Secure over https) and redirects to the address without it | the key isn't left in the address bar or history |

The key is made once and kept at mode 0600 in `$XDG_STATE_HOME/mojoui/pair-key` (`$MOJOUI_PAIR_KEY_FILE` to move it;
`pixi run python mojoui/hosts/web.py --pair-key` prints it). Delete the file to pair again.

```
scripts/tablet.sh echo          # builds it if needed, starts it, puts it on the tailnet, prints the address with ?k=
```

It picks the first free https port from 8444 up (443, 8443 and 10000 are other services' on this machine; `$MOJOUI_TABLET_PORT`
picks one), never touches another `tailscale serve` entry, and takes its own away on Ctrl-C. An app that needs a pixi
environment (`examples/<app>/needs`: speech, voice) runs in it (`$TABLET_ENV` overrides). `MOJOUI_PUBLIC` keeps its meaning:
public mode is for a server on the internet and has none of this.

## What the check proves (tests/test_web_audio.py, `--tailnet` adds the tailnet part; numbers in build/g72/web-audio.json)

Headless Chromium with a fake microphone playing a known .wav (`--use-file-for-fake-audio-capture`), against `examples/echo`:

- the app's `Microphone` receives the browser's samples (16 000 a second) and they match the .wav to 100 % (with the
  browser's own processing off; with echo cancellation, noise suppression and gain control on, which is what a person's page
  gets, the samples still arrive but Chromium filters a synthetic voice, 34 % match);
- the app's `Speaker` output reaches the page's audio graph: 4.5 s recorded, 4.5 s scheduled, no gap (0 underruns), a 440 Hz
  tone read back at 440 Hz and RMS 0.354 from the page's AnalyserNode;
- `Speaker.stop()` flushes the page's queue 16 ms after the click (click → event → `update()` → `stop()` → host → socket →
  page), and the graph is silent 150 ms later;
- over `https://<machine>.<tailnet>.ts.net:8444` through `tailscale serve`: the page and the socket answer **403 without the key**
  and work with it, the key is moved into a Secure cookie, the same numbers hold.

## Limits

- Camera is not carried yet (tag byte 3 is kept).
- Safari on iOS may need the tap to also open the microphone: the first tap does both.
- `connect-src 'self'` covers the same-origin `wss:` socket in current Chrome, Firefox and Safari.
- Playback is scheduled on the page's own clock; the page reports its output delay (`latency_ms()`), but the network's isn't counted.
