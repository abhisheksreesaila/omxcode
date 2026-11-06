# GOAL 58: video and pictures on the Mac without ffmpeg

**End goal (owner, 2026-11-06: "yes continue, next steps"; goal 56 found it, D-5612):** omxplorer's video card said
"Couldn't open F00118.mp4: not a video" on the owner's Mac, because mojoui.video, mojoui.picture and mojoui.videoexport
run ffmpeg's command line, which a Mac doesn't have. On a Mac they now use the system's own frameworks (AVFoundation
decodes and encodes on the Apple media engine, ImageIO reads stills) behind the same APIs, opened at run time so nothing
new is linked; the owner's bar: components drop in and work the same on Linux, the web and the Mac.

Base: main 9f23c27 (Mojo 1.2). Worktree ../mojo-ui-g58, branch goal-58-mac-media. (57 is another session's.)

## Milestones
| # | Milestone | Proof (`docs/goals/58-check.py`) |
|---|---|---|
| M0 | Linux unchanged | tests/test_media_same.mojo and tests/test_framefeed_same.mojo on Linux (ffmpeg): every line printed, 30 frames written and read back |
| M1 | The Mac decodes | tests/test_media_same.mojo on the owner's Mac (`scripts/mac-ssh-test`): the video's size equal to Linux's, its rate within 0.01, its frame count within 1; every frame (0–9 in order, 30/100/12 by seeking) and every picture (an RGBA PNG, a colour and a grey JPEG) within 8 levels per channel of Linux's in each of 64 thumbnail cells |
| M2 | The Mac writes | the same run: 30 frames written (AVAssetWriter, H.264) read back as 30 frames, frame 10 within 10 levels of the source in every cell, on both platforms |
| M3 | A feed on the Mac | tests/test_framefeed_same.mojo on the Mac: ready at 1280×720, 244 frames, frame 50 taken (the feed's own thread, AVFoundation) |
| M4 | omxplorer on the Mac | `scripts/mac-ssh omxplorer docs/goals/58/mac.steps`: the video card knows its length (0:16) and plays (its clock moves past 0:00 after `tap:play`), its picture isn't blank; the picture card shows cat.jpg (451×300 JPG); nothing says "Couldn't open" |
| M5 | Nothing regressed | goal 54's M1 on Linux (the tiled board with the featured video, GTK) |

## Done means
58-check PASS for M0–M5, the reviewer passes it, the Mac's pictures were looked at.

## Out of bounds
Pushing before the reviewer's PASS and green checks; the frozen ../mojo-ui-apple-test; other sessions' worktrees
(g50, g52, g53, g55, g57); pip; writing the owner's global defaults or anything on their Mac outside ~/omxcode-g54;
lowering a proof; bundling ffmpeg into the Mac app (licences and size: the system frameworks are the point).

## Assumptions (taken instead of asking)
- Linux keeps ffmpeg (its decoder is the reference the Mac is compared against); Android and iPhone stay as they were.
- crf/preset (ffmpeg's quality knobs) don't apply on the Mac: AVAssetWriter's H.264 defaults.
- The frame a seek lands on follows ffmpeg's rule (the first frame at or after the time), proven by M1's seeks.

## Budget
80 turns.
