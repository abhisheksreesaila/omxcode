#!/usr/bin/env python3
"""The robot demo data, fetched from its public home and built (goal 59): what `scripts/setup` runs.

    pixi run python -I scripts/fetch_demo.py OUT           (OUT: build/demo; the downloads: $OMX_CACHE/droid, else ~/.cache/omxcode/droid)

A slice of DROID 720p (Khazatsky et al. 2024, CC-BY-4.0; the LeRobot port jnogga/droid_success and jnogga/droid_failure
on the Hugging Face Hub): whole packed video files (each holds 30–80 episodes; v3 can't fetch one episode), the
telemetry files those episodes live in, the metadata, and the DROID paper (arXiv 2403.12945v2, CC-BY-4.0). Then
scripts/robot_data.py makes OUT/fleet.csv, telemetry.parquet, clips/, limits.csv, truth.json and ATTRIBUTION.txt from
it, as it made goal 47's full set (13 GB: ~/data/robot-scout, docs/goals/47-report.md).

Plain HTTPS (the Hub's resolve/ URLs), resumable .part files, each checked against the size the server sent;
a file already there is skipped, so a second run fetches nothing. HF_TOKEN, when set, is sent (higher rate limits).
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parent.parent
CAMERA = "observation.images.left_external"
# (repo, local folder (robot_data.py reads "failure" in a folder's name as the outcome), the camera's (chunk, file) to take)
SLICE = [
    ("jnogga/droid_success", "droid720", [(0, 0), (0, 1), (0, 4)]),
    ("jnogga/droid_failure", "droid720_failure", [(0, 0), (0, 1)]),  # (0, 1) holds F00118, the story's featured failure
]
META = ["meta/info.json", "meta/stats.json", "meta/tasks.parquet", "meta/episodes/chunk-000/file_000.parquet", "README.md"]
PAPER = "https://arxiv.org/pdf/2403.12945v2"


def cache() -> Path:
    return Path(os.environ.get("OMX_CACHE", Path.home() / ".cache/omxcode")) / "droid"


def _open(url, start=0):
    req = urllib.request.Request(url, headers={"User-Agent": "omxcode-setup"})
    if os.environ.get("HF_TOKEN") and url.startswith("https://huggingface.co/"):
        # (unredirected: the Hub answers with a redirect to its file CDN, which must not get the token)
        req.add_unredirected_header("Authorization", "Bearer " + os.environ["HF_TOKEN"])
    if start:
        req.add_header("Range", f"bytes={start}-")
    return urllib.request.urlopen(req, timeout=60)


def fetch(url, dst: Path) -> int:
    """url into dst (resuming dst.part); the bytes fetched (0: it was there)."""
    if dst.exists():
        return 0
    dst.parent.mkdir(parents=True, exist_ok=True)
    part = dst.with_name(dst.name + ".part")
    got = 0
    for attempt in range(5):
        have = part.stat().st_size if part.exists() else 0
        try:
            with _open(url, have) as r, open(part, "ab" if have and r.status == 206 else "wb") as f:
                if have and r.status != 206:
                    have = 0
                total = have + int(r.headers.get("Content-Length", 0))
                while chunk := r.read(1 << 20):
                    f.write(chunk)
                    got += len(chunk)
            if total and part.stat().st_size != total:
                raise IOError(f"{dst.name}: {part.stat().st_size} of {total} bytes")
            part.rename(dst)
            return got
        except urllib.error.HTTPError as e:
            if e.code == 416 and have:  # (the .part was already whole: nothing left to fetch)
                part.rename(dst)
                return got
            if attempt == 4:
                raise
            print(f"   {dst.name}: {e}; again", flush=True)
            time.sleep(2 * (attempt + 1))
        except Exception as e:  # a dropped connection resumes from the .part file
            if attempt == 4:
                raise
            print(f"   {dst.name}: {e}; again", flush=True)
            time.sleep(2 * (attempt + 1))
    return got


def plan(repo, folder, files):
    """The files of one repo's slice: its metadata (fetched now), then the videos and telemetry its episodes need."""
    base = f"https://huggingface.co/datasets/{repo}/resolve/main/"
    d = cache() / folder
    for m in META:
        fetch(base + m, d / m)
    eps = pq.read_table(d / "meta/episodes/chunk-000/file_000.parquet").to_pylist()
    key = f"videos/{CAMERA}"
    picked = [e for e in eps if (e[key + "/chunk_index"], e[key + "/file_index"]) in set(files)]
    want = set()
    for e in picked:
        want.add(f"data/chunk-{e['data/chunk_index']:03d}/file_{e['data/file_index']:03d}.parquet")
        want.add(f"{key}/chunk-{e[key + '/chunk_index']:03d}/file_{e[key + '/file_index']:03d}.mp4")
    return [(base + p, d / p) for p in sorted(want)], len(picked)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1]).resolve()
    t0 = time.time()
    jobs, n = [], 0
    for repo, folder, files in SLICE:
        j, k = plan(repo, folder, files)
        jobs += j
        n += k
    paper = cache() / "docs" / "droid-2403.12945v2.pdf"
    jobs.append((PAPER, paper))
    todo = [j for j in jobs if not j[1].exists()]
    print(f"   {n} episodes with video: {len(jobs)} files, {len(todo)} to fetch into {cache()}", flush=True)
    with ThreadPoolExecutor(6) as pool:
        got = sum(pool.map(lambda j: fetch(*j), todo))
    print(f"   fetched {got / 1e6:.0f} MB in {time.time() - t0:.0f} s", flush=True)
    if (out / "truth.json").exists() and not todo:
        print(f"   {out} is there: kept", flush=True)
        return
    env = dict(os.environ, DROID_PAPER=str(paper))
    r = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/robot_data.py"), str(out)] + [str(cache() / f) for _, f, _ in SLICE], env=env)
    if r.returncode:
        sys.exit(r.returncode)
    truth = json.loads((out / "truth.json").read_text())
    print(f"   {out}: {truth['episodes']} episodes, {sum(1 for _ in (out / 'clips').glob('*.mp4'))} clips, hero {truth.get('hero')}", flush=True)


if __name__ == "__main__":
    main()
