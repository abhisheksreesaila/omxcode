# Goal 58 report: video and pictures on the Mac without ffmpeg

`scripts/check` (docs/goals/58-check.py): M0–M5 PASS (2026-11-06), on the owner's Mac (Apple M4, macOS 27.2).

| # | Result |
|---|---|
| M0 | Linux unchanged (ffmpeg): every frame, picture and a 30-frame write; a FrameFeed ready, frame 50 taken |
| M1 | the Mac decodes through AVFoundation and ImageIO: size, rate and length as Linux's; 13 frames (seeks included) and 3 pictures (RGBA PNG, colour and grey JPEG) within 6 levels of Linux's in every cell |
| M2 | the Mac writes through AVAssetWriter: 30 H.264 frames read back, frame 10 within 10 levels of the source (Linux too) |
| M3 | a FrameFeed on the Mac: ready, 1280×720, 244 frames, frame 50 taken on its own thread |
| M4 | omxplorer on the Mac: the DROID clip plays (0:04 / 0:16 after play), its picture drawn, cat.jpg 451×300; nothing says "Couldn't open" |
| M5 | goal 54 M1 on Linux |

## What changed
- `mojoui/avmedia.mojo`: AvReader, AvWriter, av_probe, av_picture (D-5801–D-5803); VideoSource and VideoWriter call them on a Mac.
- `mojoui/wake.mojo` UIWaker: a worker thread wakes the host on Linux and the Mac alike (D-5804); jobs and FrameFeed use it.
- `scripts/mac-ssh-test` (D-5805).

## Found, not fixed
- The status bar keeps "Opened cat.jpg · opening…" after the picture shows (Mac; the picture's ready isn't announced).
- mojoui.watch still says a Mac app polls take() on a timer; UIWaker could wake it now.
- The Mac encoder ignores crf/preset (AVAssetWriter's H.264 defaults).
- An animated GIF or WebP is its first frame on a Mac (ImageIO), where ffmpeg plays it on Linux.
