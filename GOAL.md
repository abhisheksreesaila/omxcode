# GOAL 77: omx shows and points (visual answers for a kitchen counter)

**End goal (owner, 2026-11-17/18):** "No one's going to read text… this is an app on a kitchen countertop, not an app on a big
monitor… it has to be visual and it has to be pointy: open up a card, 'hey, look at this'… a trip is a map… any explanation,
isometric… if someone asks the meaning she can print the word… open up the camera… segment and tell you what to do." Then:
"yes go, isometrics can be simple." Goal 72 built the app on omxcode (examples/omx: in-process Qwen3.8-27B, AG-UI agent, voice,
tablet). This goal makes its answers visual and pointed, framework first: every card and the pointer are generic components an
agent can use in any omxcode app.

Base: main eba2bbdc (goal 72 + 73). Worktree ../mojo-ui-g77, branch goal-77-show-and-point. Decisions D-77xx. Goal 72's
contract: docs/goals/72.md. Reference prototype pieces (read-only): ~/Projects/omx-local/src/omxlocal/visual.py (word/map/
explainer data + the clause-to-part pointer matcher), omx-local GOAL.md goal 5 (M24–M30).

## Milestones (framework first; the app only composes)
| # | Milestone | Proof (`docs/goals/77-check.py`; PASS, FAIL or BLOCKED each) |
|---|---|---|
| M0 | Ground | disk ≥ 40 GB free, both GPUs free of other work, playwright Chromium, goal 72's M4 still passes on this base |
| M1 | She points | a framework pointer: cards declare named parts (tags); while a reply is spoken, each clause that names a part sends an AG-UI CUSTOM `point` event timed to where in that clause's audio the name is said; the pointer (a soft ring, a spring) moves to the part and the orb's eyes look at it; GTK and the web host. Proof: a card with 3 named parts walked through aloud → ≥ 3 points, each on a part that exists, each shown within 250 ms of the audio that names it (measured against the speaker's play clock); a screenshot mid-point with the ring on its target |
| M2 | Word card | "What does X mean?" → a Word card (the word typed out big, how it sounds, part of speech, meaning, one example), the voice says the gist and points at word → meaning → example. Proof: 3 of 3 words, the meaning judged right by the model against a reference; points land; phone screenshot |
| M3 | Map card | trips and places → a map with real tiles (fetched from the web, cached on disk, marked "web"), numbered stops in the order spoken, a route line; stops placed by the model and checked against a geocoder; the map flies to each stop as it is named. Proof: 2 of 2 trips (a city day, a three-city trip) give ≥ 3 stops each within 25 km of the truth; points fly to stops; tablet screenshot |
| M4 | Simple isometric explainer | "How does X work?" → a small isometric diagram (3–6 blocks, arrows, numbered steps) drawn by a generic Iso component; steps point block by block. Proof: 3 of 3 concepts give ≥ 3 blocks, ≥ 2 links, ≥ 3 steps naming blocks that exist; points follow the steps; screenshot |
| M5 | Visual first | the agent prefers a card for anything it can show and keeps speech to one or two sentences that refer to it (system prompt + tool descriptions, no app logic). Proof: ≥ 9 of 10 routing utterances land on the right card kind (map / word / iso / table / to-do / none); spoken replies on card turns ≤ 2 sentences |
| M6 | The camera | the tablet's camera (web host, the reserved tag-3 frames) and a desktop camera if present are a framework Camera; "what am I looking at / what should I do" sends the frame to Qwen's own eyes in-process (mojoui.llm gains image input through llama.cpp's mtmd); the card shows the frame with boxes round the things that matter and the pointer lands on the one she names. Proof: a fake-camera scene with objects at known places: the asked-for object's box overlaps the truth (IoU ≥ 0.4), the answer names it, the point lands on it; screenshot |
| M7 | Experience first: the Stage (owner-approved prototype v14, 2026-11-18; supersedes the translucent M7, D-7780) | Split into M7a–M7f below. Design reference: docs/goals/77/stage-prototype.html (the approved prototype, copied in) and docs/goals/77/stage-*.png. Every piece is a framework component in mojoui/ with its own test; examples/stage shows them without a model; omx only composes. |
| M7a | The Stage shell | `mojoui.stage`: one view of four regions (top bar; left = passive; centre = what matters now; right = live), the side columns receding under a soft shade, the centre a raised panel; gitaway's Stage look as theme tokens (white cards on #F5F5F7, #1C1C1E on black at night; sh2/sh3 shadows); a phone width stacks it (top, left, centre, right, the chat bar fixed at the bottom). Proof: examples/stage on GTK (headless) and the web host (headless Chromium) at 1280x820 and 390x844: the four regions' rects read from the running app in the right order and proportions, the centre panel's colour/radius/shadow read back, screenshots |
| M7b | Live tiles | `mojoui.livetiles`: tiles of five sizes (s 1x1, w 2x1, l 2x2, xl 4x2, band 4x1) on an exact 4x3 grid (presets so the grid is always full: 6 = l w w w s s, 5 = l w w w w, 4 = l l w w, 3 = xl w w, 2 = xl band), sized by importance (the most urgent first and largest; `big` makes it xl); a tile changes size like water (a spring k=150 c=19.5: it glides to its new place while its surface grows or shrinks, the words drawn at the final size and faded in, never stretched); press-in (omxqua: 0.9 / 0.955 / 0.975 by size, back on the fast spring); drag to reorder; a corner grip resizes, snapping s→w→l→xl; a charm (a small drawing) can sit on a tile. Proof: unit tests (every preset fills 12 cells exactly; the spring settles within 1 s and overshoots ≤ 3 %; a tile's text is drawn at its final rect from the first frame); examples/stage frame-sampled during a promotion on both hosts (the surface's size moves monotonically to the new rect, no frame stretches text); a synthetic drag reorders and a grip drag resizes |
| M7c | Agent-driven tiles (AG-UI) | the tiles are a genui catalog component (`LiveTiles`: tiles with id, kind, head, faces, importance, actions, charm, kind of column: passive / live / centre) that render_ui creates and JSON-patches; an agent tool promotes, adds or removes a tile; every tile is a pointer part (the ring lands on it while she names it). Proof: genui validates the sample and refuses a bad one; an AG-UI run (scripted events through the real agent loop, no model needed) creates tiles, promotes one (it becomes the large tile, the grid stays full) and the pointer's ring lands on it |
| M7d | The TV | the chat bar (orb, text box, mic) grows over the whole centre when she explains: the box reshapes on gitaway's soft spring (900 ms, ≤ 2 % overshoot) while the tiles fade out (260 ms) and the TV's content fades in after 160 ms (420 ms, 0.985→1); a card (Word, Iso, TripMap, Sight) on the left of the TV, the conversation on the right; closing (×, or quiet) shrinks it back and the tiles return. Proof: frames sampled during open and close on both hosts: the box's height follows the spring (monotonic to within the overshoot, settles ≤ 1.1 s), the tiles are hidden while it is open, a card is shown inside it, screenshots |
| M7e | Sides, pins and charms | left: the clock, a quiet Today list (passive tiles that are not urgent: weather, calendar, home, birthday), Pinned; right: Live, one-line rows (timers, scores, traffic) that keep ticking; dragging a tile onto Pinned pins it, dragging a pinned card onto the stage unpins it; occasions (a day's context: school, game, Thanksgiving, rain, birthday, flight) put one charm on the card it is about (six charms: bag, pennant, party hat, umbrella, luggage tag, turkey). Proof: examples/stage: weather sits on the left until rain makes it urgent (then it is the large tile); a synthetic drag pins a tile (it leaves the grid, the grid stays full, the pinned card appears); each occasion shows its charm on the right tile; screenshots |
| M7f | omx on the Stage | examples/omx composes the Stage: tiles fed by the assistant (to-do, timer, calendar, news) and the agent, the chat bar and TV around the voice loop, the pointer over it all; goal 72's M3–M6 and goal 77's M1–M6 still pass; components.md current; lints; reviewer PASS. Proof: those checks, plus omx screenshots at 1280x820 and 390x844 in light and dark |

## Ideas parked for later goals (owner 2026-11-18)
Home controls through Matter (lights, plugs), a baby monitor (camera + sound alerts on the tablet), the printer over the Wi-Fi (IPP),
all as voice-first cards. Not this goal: experience before features.

## Done means
77-check PASS for M0–M7 (a BLOCKED says exactly what is missing), a fresh reviewer subagent passes it, docs/goals/77-report.md
with numbers and screenshots, EXPERIMENTS.md. Committed after each passing milestone; merged to main locally after the reviewer
passes; pushed only under the owner's standing rule (reviewer PASS + green checks).

## Out of bounds
Editing omx-local (read only); other worktrees (goals 73–76 belong to other threads); pip (pixi only); lowering a proof or
deleting a test; sending the camera's frames anywhere off this machine; map tiles and geocoding are the only web calls added,
marked "web" on the card.

## Assumptions (instead of asking)
- Map tiles: OpenStreetMap-compatible raster tiles with a polite User-Agent and a disk cache (personal, low volume); geocoding:
  Nominatim, one request a second, cached; both go through the framework's HTTPS client.
- "Segment" starts as boxes from Qwen's own grounding; the owner's phone segmentation model plugs in later as a model plugin.
- Points ride AG-UI as CUSTOM events, so any AG-UI client can follow them.
- Budget: 200 turns (M7a–M7f: an overnight unattended run, 2026-11-18/19; as far as it gets, reported honestly).
- M7 (2026-11-18): the owner approved the Stage prototype (v14) and asked for it to be built unattended, framework first, agent-driven (AG-UI) wherever possible; the earlier translucent-glass M7 is superseded (owner: no glass, no shimmer; flat with gitaway's soft shadows; water-like motion).
