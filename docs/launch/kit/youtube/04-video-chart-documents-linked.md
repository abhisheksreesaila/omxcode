# YouTube 4 · Video + chart + documents, linked by key, time and place

**Length:** about 5 min · **Record:** omxplorer, Liquid dark; robot data and goal 41's claims data · **Post:** Thu Nov 5

## Titles (≤ 60 characters)
1. Video, data and documents on one sheet, joined on purpose
2. Explicit links: how omxplorer joins video, sheets and PDFs
3. JOIN LINKED: asking questions across video and documents

**Thumbnail:** `[shot: linked-doc]` with the peek's lines; big text **VIDEO + DATA + DOCS**; small: `joined on purpose`.

## Script

| Time | On screen | Say |
|---|---|---|
| 0:00 | The robot failure: video, charts, the datasheet card | "A video, a table, a PDF. Putting them on one screen is easy. Knowing why they belong together is the hard part." |
| 0:20 | Hold a card: the rest dims, linked cards lift | "In omxplorer, cards connect only through links you make. Hold a card and you see its links. Nothing is joined by guessing." |
| 0:50 | Make a key link: drag a column onto a card → "Link these?" with a match count | "A key link: drag the robot column onto the datasheet. It asks first, and tells you how many rows match before you say yes." |
| 1:30 | Time link: the cursor across video and telemetry `[clip: scrub-cursor]` | "A time link: the video and the telemetry share a clock. One cursor, and every linked card follows it." |
| 2:00 | Place link (if the robot build has it; otherwise goal 41's warehouse shot) | "And place: a box in the frame linked to a row." |
| 2:20 | `[clip: ask-join-linked]` | "Now ask in words. The SQL it writes says JOIN LINKED. That's the links you made, turned into a join you can read. If the answer looks wrong, you can see exactly why." |
| 3:05 | Goal 41's claim story (`~/Projects/omxlabs/assets/img/clip-claims.mp4`) | "Same idea on a different problem: a damaged shipment. The video, the shipping sheet and the bills of lading, read in the app. Same links, same questions." |
| 3:45 | Export pack | "And when you've found the answer, export it: the clip, the rows, the documents, as one pack." |
| 4:10 | Slide: "the models are plugins" | "Reading the documents is a model running in the app's process, behind a slot you can swap. The links stay yours." |
| 4:30 | Repo | "That's the multimodal part of omxplorer. Links below." |

## Description

```
omxplorer puts video, sheets and documents on one page and joins them only through links you make: by key, by time, or by place. Each link shows its match count before you confirm it, and questions in words turn into SQL with JOIN LINKED, so you can read exactly what was joined. Shown on real robot data (DROID) and on a shipping-claim example.

Code: https://github.com/abhisheksreesaila/omxcode
Site: https://abhisheksreesaila.github.io/omxcode/
DROID dataset (CC-BY-4.0): https://droid-dataset.github.io/

Chapters
0:00 Why joining is the hard part
0:20 Links you make
0:50 Key links, with a match count
1:30 Time links: one cursor
2:00 Place links
2:20 JOIN LINKED
3:05 Another example: a shipping claim
3:45 Export a pack
4:10 Models are plugins
```

**Tags:** multimodal data, data linking, SQL join, video analysis, document AI, OCR, robotics data, data exploration, Mojo, GPU, omxplorer, omxcode

*Sources: S10, S14, S3; the in-process document reader (docTR) from docs/goals/41-report.md. The claims example uses
generated footage and digital PDFs (41-report "Not done"): say "an example", not "a real claim".*
