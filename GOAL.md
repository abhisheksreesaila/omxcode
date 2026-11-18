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
| M7 | Experience first: a translucent, liquid look | owner 2026-11-18: "the success of this app will depend on the user interface and the experience… very liquid flowing interface, minimal movements… a macOS translucent interface like the one I'm showing you (docs/goals/77/ref-translucent-home.png)… the prototype was like that… more about experience than features." A framework theme (not app CSS): a translucent window/sidebar over the wallpaper, soft rounded white cards with gentle depth, quiet type, springs with small movements; every card (word, map, iso, sight, table, to-do, comic) wears it on GTK and the web host. Proof: side-by-side shots with the reference and with omx-local's prototype; computed translucency/blur and card radius/shadow read from the running app; motion durations within the theme's spring set; goal 72's M3–M6 still pass, component matrix current, lints |

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
- Budget: 200 turns.
