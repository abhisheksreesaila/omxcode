"""Goal 47: grow a LeRobot sample's TELEMETRY toward N episodes without its video (video stays only for the episodes the
story opens). Picks whole data files (~730 DROID episodes, ~100 MB each) at an even stride, so every lab is covered.

  pixi exec --spec python=3.12 --spec huggingface_hub --spec pyarrow -- python -I scripts/robot_grow_telemetry.py \
      jnogga/droid_success ~/data/robot-scout/droid720_tele 8000

Files are data: downloaded, never executed. Skips files already present; writes <dst>/sample_episodes.csv.
"""
import csv
import sys

import pyarrow.parquet as pq
from huggingface_hub import snapshot_download

repo, dst, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
snapshot_download(repo, repo_type="dataset", local_dir=dst, allow_patterns=["meta/*", "README.md"])
m = pq.read_table(f"{dst}/meta/episodes/chunk-000/file_000.parquet",
                  columns=["episode_index", "uuid", "length", "data/chunk_index", "data/file_index"]).to_pylist()
files = sorted({(r["data/chunk_index"], r["data/file_index"]) for r in m})
per_file = len(m) / len(files)
want = min(len(files), max(1, round(n / per_file)))
picked = {files[round(i * (len(files) - 1) / max(1, want - 1))] for i in range(want)}
eps = [r for r in m if (r["data/chunk_index"], r["data/file_index"]) in picked]
labs = {}
for r in eps:
    lab = r["uuid"].split("+")[0]
    labs[lab] = labs.get(lab, 0) + 1
print(f"{len(eps)} episodes in {len(picked)} data files, labs: {dict(sorted(labs.items(), key=lambda x: -x[1]))}", flush=True)
pats = sorted(f"data/chunk-{c:03d}/file_{f:03d}.parquet" for c, f in picked)
snapshot_download(repo, repo_type="dataset", local_dir=dst, allow_patterns=pats, max_workers=8)
with open(f"{dst}/sample_episodes.csv", "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["episode_index", "uuid", "length"])
    for r in eps:
        w.writerow([r["episode_index"], r["uuid"], r["length"]])
print("done:", dst)
