# GOAL 39: omxplorer goes multimodal

**End goal (owner, 2026-10-30 night):** "I should be able to use the application multimodal: edit video, edit image, talk to the
product and edit Excel at the same time." Two scenarios from Draft F: the **warehouse** ("a 60-second reel of every damaged
pallet, faces blurred, shipment ID burned in"; "delivered shipments whose label never appears on camera") and the **drone**
("hours of inspection footage become a database of every asset and defect, located on the map; ask which got worse since
last time, and the answer becomes the next flight plan", with the telemetry playing beside the video). Framework first: every
piece another app would need goes into omxcode (`mojoui/`) with its own test; omxplorer only composes. Look: omxqua Liquid,
"as an Apple designer would: intuitive, minimal controls, very powerful".

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | Generated media + truth | `scripts/media_data.py OUT` writes warehouse.mp4, drone_a.mp4, drone_b.mp4 (1280×720, 30 fps, ≥ 20 s), shipments.csv, telemetry_a.csv, telemetry_b.csv and truth.json from its own scene model; two runs: CSVs and truth.json byte-equal |
| M1 | `VideoSource` (mojoui/video.mojo) | `tests/test_video.mojo` prints `video open: ok`, `video frame: ok` (frame N equals ffmpeg's own decode), `video seek: ok`, `video speed: ok` |
| M2 | `Player` + chart time cursor (mojoui) | `tests/test_player.mojo` prints `player: ok`, `cursor: ok`; `examples/media` (Player + a telemetry line chart) builds for linux and web; a headless GTK run (play, wait, pause) prints `PLAYER: t=` and `CURSOR: t=` lines that agree within one frame and t advanced ≥ 1 s; its screenshot is written |
| M3 | GPU image ops (mojoui) | `tests/test_imageops.mojo` prints `blur: ok`, `crop: ok`, `text: ok`, `gpu equals cpu: ok`, and `blur 720p ms: X` with X < 2 |
| M4 | Frames become rows (mojoui) | `tests/test_videotable.mojo` writes `build/g39/warehouse_regions.csv`; against truth.json: ≥ 95 % of pallets found with first/last frame within ±2, ≥ 95 % of visible codes decoded, no damaged flag on a sound pallet; prints `frames per s: X` with X ≥ 240 |
| M5 | Export a cut (mojoui) | `tests/test_export.mojo` writes `build/g39/reel.mp4`: its length equals truth's damaged intervals ±0.2 s; on truth's face boxes the reel's sharpness (Laplacian variance) is < 20 % of the source's; the burned-in ID band differs from the source |
| M6 | Video and image cards in omxplorer | a headless omxplorer run opens warehouse.mp4 as a card on the sheet, plays and pauses it (`PLAYER: t=` advances), shot written; the agent's tool list (scripts/agent_client.py) includes play, pause and seek for the card |
| M7 | The warehouse, end to end | `scripts/scenario.py warehouse` drives the real omxplorer only through its agent tools; outputs: reel.mp4 passes M5's tests; `missing.csv` (shipments whose label never appears) equals truth's set |
| M8 | The drone, end to end | `scripts/scenario.py drone` (agent tools only): at three seeks the cursor matches the video within one frame; `defects_a.csv`/`defects_b.csv` find ≥ 90 % of truth's defects within 5 m; `worse.csv` equals truth's worsened set; `waypoints.csv` lists exactly those, lat/lon within 1e-4 of truth |
| M9 | The covers | in ~/Projects/omxlabs: clip-warehouse.mp4 and clip-drone.mp4 recorded from the real app (≥ 8 s each) on the omxplorer cover and in its deck; the omxlabs page leads with omxplorer and "four breakthrough technologies"; every cover: no overflow at 1440 and 390, no console errors |
| M11 | An iMovie-grade editor (owner, 2026-10-30: "modelled on iMovie: timelines at the bottom, similar controls, really polished") | `tests/test_mediatimeline.mojo` prints `timeline: ok` (filmstrip thumbnails, zoom, playhead, trim, split, a marker lane from rows), `edit: ok` (trimmed/split clips export to the right length); `examples/media` shows the viewer above a filmstrip timeline with a detections lane and a telemetry lane; a headless GTK run that trims and splits prints `TIMELINE:` lines and writes its screenshot; omxplorer's video card opens the editor |
| M10 | The morning note | `docs/research/inprocess-ai.md`: how omxconsole could serve non-LLM models (e.g. Segment Anything) to omxplorer in process, no HTTP; ≥ 3 options with costs and one recommendation |

## Done means
`scripts/check` PASS for M0–M11, the reviewer passes it, and the two clips play on the cover.

## Out of bounds
Pushing, deploying, paid services, sign-ups, secrets; the frozen `../mojo-ui-apple-test`; patching Mojo; lowering a proof.

## Assumptions (instead of asking)
- Footage is generated (owned, exact truth); "detection" is GPU colour, motion and stripe-code analysis, a slot a model plugs into later (M10), and every page says so.
- Video decode/encode through the installed ffmpeg as a pipe (no new library); GTK and web first, Android/Apple later.
- Shipment IDs are a printed stripe code (an OCR stand-in), with the digits drawn beside it.
- T0 (stable state): main = release a818aa8, already checked and reviewed twice; not re-run.

## Budget
One night (≈ 6 h), cut order if short: M8's two-flight comparison, then M9's drone clip.
