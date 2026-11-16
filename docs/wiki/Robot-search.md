# Robot search

![Robot search: one clip tapped, the episodes like it ranked beside it](images/robot-search.jpg)

*Robot search on Linux: a tapped clip on the left, the episodes most like it on the right.*

- It opens a pool of robot episodes from an omxcore moments index (a `.parquet` file), where the datasets already sit.
- Tap one clip to rank every episode like it. Pick a few and press More like these, or filter by one robot.
- Export writes your picks as a LeRobot dataset (see [Export to LeRobot](Export-to-LeRobot.md)).

In the checks, the top 24 results equal omxcore's own Python, and a warm search took 0.10 ms on the GPU. The pool in
the demo film holds 1,851 episodes, 8.3 hours, from 4 LeRobot datasets.

## How to try it

Download omxplorer for Linux from the [linux-app release](https://github.com/abhisheksreesaila/omxcode/releases/tag/linux-app),
unpack it, run `./omxplorer`, pick **Robot search…** on Start and choose a moments index (a `.parquet`). Or open
straight into it:

```sh
OMX_ROBOT_POOL=path/to/index.parquet ./omxplorer
```

The index comes from [omxcore](https://github.com/abhisheksreesaila/omxcore) (`scripts/robotics/build_index.sh`, about 5 minutes for the demo's 1,851 episodes); a
ready-made pool to download isn't there yet. From the source, `scripts/build.sh omxplorer linux` builds the same app.

Tap a poster to get the episodes like it. Pick a few, then press **More like these**. **Export** writes the picks to
`~/omxplorer-exports/picks-N`.

## Not there yet

- Linux only. On the Mac, decoding needs pieces the Mac build doesn't carry yet; the Mac page says so.
- The phone layout was checked on the web host, not on GTK.
- Opening a Hugging Face repo id from the Mojo package, and a table with a vector column, wait on omxcore.
- Typing a phrase to search is left out; it is a rough first cut upstream.

<sub>Source: docs/goals/71-report.md; docs/goals/71/cold-open.md (pool size, quoted from omxcore's robotics report).</sub>
