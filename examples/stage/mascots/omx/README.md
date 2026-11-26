# The omx mascot pack ("Omx Spirit")

Six transparent PNG sprite strips and a `manifest.json` that `mojoui.mascot` plays (rest, listen, think, speak, hype, nap).
The Stage demo and omx use it when a person picks the mascot instead of the orb (`mojoui.personalize`, D-8408).

## Where the art comes from

- **The character is original and AI-generated.** Google's Gemini image model made it, through the Antigravity agent, on
  2026-11-25, from a text prompt (a dark-blue round creature). It is not based on any existing character or artwork.
- **What it made:** one 1024 x 1024 pose sheet, four poses of the creature on a near-black background, in a 2 x 2 grid:
  rest (top left), listen (top right), think (bottom left), hype (bottom right). The sheet stays where Antigravity saved it
  (`omxome_mascot_poses_1795658704996.jpg` in that session's folder, outside this repository); the build doesn't need it.
- **The cut-out poses:** in the same session the four quadrants were cut out with the background made transparent, as
  `mascot_rest.png`, `mascot_listen.png`, `mascot_think.png` and `mascot_hype.png` (RGBA, 256 px tall). That cutting step
  isn't in this repository.
- **No third-party artwork.** A video by Masko on X (a monkey called "Momo") was a reference for the *pattern* only: a hub
  state with spoke clips that leave from it and come back to it. None of its frames or art are in this pack.
- **Terms:** used under the generator's terms. NOTICE has the same line.

## How the six strips were made

`scripts/build_mascot_pack.py --poses-dir <folder with the four mascot_*.png> --out examples/stage/mascots/omx` cleans each
pose (alpha dust removed, holes in the fur sealed: `trim_and_clean`), anchors its feet at the same baseline in a 192 x 192
frame, and animates it with scale, tilt and small drawn glows. It draws nothing of the character itself:

| strip | frames, fps | made from |
|---|---|---|
| rest | 16 at 12, loops | the rest pose: a slow breath and sway, a warm firefly glow |
| listen | 12 at 12, loops | the listen pose: a forward tilt and bounce, a blue glow by the ear |
| think | 16 at 12, loops | the think pose: a sway, three small orbs circling above |
| speak | 12 at 16, loops | **no pose of its own:** the rest and listen poses blended (up to 65 % listen) with a bob on the beat, two glows |
| hype | 14 at 18, once, then rest | the rest pose for the crouch and landing, the hype pose for the jump, drawn sparkles |
| nap | 12 at 8, loops | **no pose of its own:** the rest pose dimmed (brightness 0.84, colour 0.82), squashed into a slow sleep breath, a rising mote |

## Regenerating

Cut the four poses from a pose sheet (any tool: transparent background, one pose per PNG with the names above), then run the
command above. The builder writes `manifest.json` again, with its `source` field (`--source "…"` for a pack made from other
art: say what it was made from and under which terms).

Keep this pack stable: the strips are about 2.4 MB of binary files, and every regeneration adds that much to the
repository's history for good. Regenerate only when the character itself changes.
