"""Goal 71's reference: omxcore's own Python `omxcore.robot` (and lerobot), run in the omxcore checkout's `robotics` env with
that checkout as the working directory. Prints one JSON object (the last line of stdout).

    oracle.py episodes <index.parquet>                       every episode in the pool: [{dataset, episode}]
    oracle.py like <index.parquet> <picks.json> <k>          top k for picks["one"] (one clip each) and picks["three"]
    oracle.py load <folder> [dataset:episode ...]            LeRobotDataset(root=folder): episodes, frames, tasks; with
                                                             the source episodes, their frames and tasks too
    oracle.py frames <frames.json>                           the app's decoded frames vs ds.decode at the same times
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / "scripts/robotics"))
import omx  # noqa: E402,F401  (omxcore from the checkout)
import numpy as np  # noqa: E402
from omxcore import robot  # noqa: E402


def key(s):
    d, e = s.rsplit(":", 1)
    return d, int(e)


def hits(t):
    return [[f"{r['dataset']}:{r['episode']}", float(r["score"])] for r in t.to_pylist()]


def main(cmd, *a):
    if cmd == "episodes":
        idx = robot.load_index(a[0])
        tab = idx.table.select(["dataset", "episode"]).to_pylist()
        seen = sorted({(r["dataset"], r["episode"]) for r in tab})
        return {"episodes": [{"dataset": d, "episode": e} for d, e in seen]}
    if cmd == "like":
        idx = robot.load_index(a[0])
        picks = json.loads(Path(a[1]).read_text())
        k = int(a[2])
        return {"one": [hits(idx.search(like=key(p), k=k, device="cuda")) for p in picks["one"]],
                "three": [hits(idx.search(like=[key(p) for p in t], k=k, device="cuda")) for t in picks["three"]]}
    if cmd == "load":
        from lerobot.datasets.lerobot_dataset import LeRobotDataset

        out = Path(a[0])
        ds = LeRobotDataset(repo_id="local/" + out.name, root=out)
        eps = ds.meta.episodes
        tasks = []
        for i in range(ds.num_episodes):
            t = eps[i]["tasks"]
            tasks.append(t[0] if isinstance(t, list) else t)
        res = {"episodes": ds.num_episodes, "frames": ds.num_frames, "tasks": tasks}
        if len(a) > 1:
            src = [key(s) for s in a[1:]]
            sets = {}
            sf, st = 0, []
            for d, e in src:
                s = sets.setdefault(d, robot.open(d))
                row = s.sql(f"SELECT length, tasks FROM episodes WHERE episode_index = {e}").to_pylist()[0]
                sf += int(row["length"])
                t = row["tasks"]
                st.append(t[0] if isinstance(t, list) else t)
            res.update(source_frames=sf, source_tasks=st)
        return res
    if cmd == "frames":
        spec = json.loads(Path(a[0]).read_text())
        base = Path(a[0]).parent
        sets, worst, n = {}, 0, 0
        for f in spec["frames"]:
            d, e = key(f["key"])
            s = sets.setdefault(d, robot.open(d))
            want = s.decode(e, [float(f["t"])], device="cpu").numpy()[0].transpose(1, 2, 0)   # H, W, 3
            got = np.fromfile(base / f["raw"], dtype=np.uint8).reshape(f["h"], f["w"], 3)
            if got.shape != want.shape:
                return {"compared": n, "max_diff": 255, "why": f"{f['key']}: shape {got.shape} vs {want.shape}"}
            worst = max(worst, int(np.abs(got.astype(np.int16) - want.astype(np.int16)).max()))
            n += 1
        return {"compared": n, "max_diff": worst}
    raise SystemExit(f"unknown command {cmd}")


if __name__ == "__main__":
    print(json.dumps(main(*sys.argv[1:])))
