# The claim data (goal 41)

The files behind omxplorer's claim story: **which damaged pallets does the carrier owe for?** One dock camera video, one
shipments spreadsheet, a forklift log and a folder of signed bills of lading (BOLs). Each answer is checked against an
exact truth file.

## What it is

- **Generated, not recorded.** `scripts/claims_data.py` draws everything from a scene model with fixed seeds: goal 39's
  warehouse scene (`scripts/media_data.py`), with pallets, stripe codes, tears and walking figures. Because nothing comes
  from a camera or a scanner, the truth of every frame and every field is known exactly.
- **No real people, companies or shipments.** The people on camera are drawn figures. The carriers, consignees and
  signatures are made up.
- The files:
  - `dock.mp4`: 1280×720, 30 fps, 38 s. Each pallet carries its shipment's stripe code.
  - `shipments.csv`: 18 shipments (`shipment_id`, carrier, consignee, pallets, status, claim_usd). `shipment_id` is the
    number in the stripe code.
  - `forklift_log.csv`: 10 Hz, on its own clock (log t = video t + 3.4 s).
  - `bol/BOL-<id>.pdf`: 17 one-page digital BOLs with a real text layer. The app reads them from their pictures (OCR).
  - `truth.json`: every BOL field's value and box, the disputed shipments (damaged on camera, BOL says
    "Exceptions: None"), and each damaged pallet's first frame wholly in view.

## Regenerate it

```sh
pixi run python scripts/claims_data.py OUT
```

This takes about 15 seconds. It gives a `truth.json` byte-equal to the one the checks use (`scripts/check M11`
regenerates it and compares). On this machine every other file came out byte-equal too: compare with
`(cd OUT && sha256sum -c path/to/examples/claims-data/SHA256SUMS)`. The video goes through ffmpeg, so another ffmpeg
version may encode `dock.mp4` with different bytes. The pictures and the truth stay the same.

## Replay the story

```sh
pixi run python scripts/scenario.py claims --media OUT --out build/g41/claims
```

This drives omxplorer only through its agent tools: open `dock.mp4`, Analyze, insert `shipments.csv`, insert the
`bol` folder, Read (docTR OCR), link `shipments.shipment_id` to the video's codes and to the BOLs' shipment numbers,
ask "damaged pallets whose BOL says no exceptions" with its SQL (`FROM shipments JOIN LINKED`), pick each answer row
(the video seeks to the damage, the BOL marks Exceptions), then Export pack. It writes `answer.csv`, `selections.csv`
and `pack/<shipment>.pdf` and `.mp4`.

The OCR model runs inside the app's process, so the scenario runs the app in pixi's **models** environment
(torch + docTR; it finds `.pixi/envs/models` by itself). `scripts/check M10` scores the run against `truth.json`.

The cover clip on omxlabs.tech is the same story, recorded on a headless display:
`pixi run -e models python scripts/covers.py claims --media OUT`.

## FUNSD (evaluation only)

`tests/test_documents.mojo` also scores the OCR on 20 forms from **FUNSD** (scanned, noisy business forms), as a check
on real scans. FUNSD is a research dataset under its own research-use licence. The test downloads it separately into
the build folder. It is **not** part of this bundle, never committed and never redistributed.
