"""Goal 47: mojoui/lerobot.py (the LeRobot source) on a tiny LeRobot v3 dataset written here, and on the real one when present.
  pixi run python -I tests/test_lerobot.py        → "lerobot: ok" (and "droid: ok" when ~/data/robot-scout/droid720_failure exists)"""
import json
import math
import sys
import tempfile
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "mojoui"))
import lerobot as lr  # noqa: E402


def tiny(root):
    (root / "meta" / "episodes" / "chunk-000").mkdir(parents=True)
    (root / "data" / "chunk-000").mkdir(parents=True)
    (root / "videos" / "cam" / "chunk-000").mkdir(parents=True)
    (root / "meta" / "info.json").write_text(json.dumps({"fps": 10, "robot_type": "toy", "data_path": "data/chunk-{chunk_index:03d}/file_{file_index:03d}.parquet",
                                                        "video_path": "videos/{video_key}/chunk-{chunk_index:03d}/file_{file_index:03d}.mp4",
                                                        "features": {"cam": {"dtype": "video"}}}))
    (root / "videos" / "cam" / "chunk-000" / "file_000.mp4").write_bytes(b"")
    eps = {"episode_index": [0, 1, 2], "uuid": ["LAB+r1+2024-01-02-03h-04m-05s", "LAB+r1+2024-01-02-03h-09m-05s", "X"], "length": [4, 3, 2],
           "tasks": [["Put the cup down"], [], []], "data/chunk_index": [0, 0, 0], "data/file_index": [0, 0, 1], "dataset_from_index": [0, 4, 7],
           "videos/cam/chunk_index": [0, 0, 0], "videos/cam/file_index": [0, 0, 0], "videos/cam/from_timestamp": [0.0, 0.4, 0.7], "videos/cam/to_timestamp": [0.4, 0.7, 0.9]}
    pq.write_table(pa.table(eps), root / "meta" / "episodes" / "chunk-000" / "file_000.parquet")
    # frames out of order on purpose; a quaternion that flips sign mid-episode; yaw across ±π
    yaw = [3.0, 3.1, -3.1, -3.0]
    quat = [[math.cos(y / 2), 0, 0, math.sin(y / 2)] for y in yaw]
    quat[2] = [-v for v in quat[2]]
    rows = {"episode_index": [0, 0, 0, 0, 1, 1, 1], "frame_index": [1, 0, 3, 2, 0, 1, 2],
            "observation.joint_velocity": [[0.1, 0.2], [0.0, 0.0], [0.5, -0.9], [0.3, 0.0], [0, 0], [0, 0], [0, 0]],
            "action.joint_velocity": [[0.1, 0.2], [0.0, 0.0], [0.5, -0.4], [0.3, 0.0], [0, 0], [0, 0], [0, 0]],
            "observation.gripper_position": [0.5, 0.0, 0.05, 0.6, 0, 0, 0],
            "observation.cartesian_position": [[0.1, 0, 0] + quat[1], [0, 0, 0] + quat[0], [0.3, 0, 0] + quat[3], [0.2, 0, 0] + quat[2]] + [[0] * 3 + [1, 0, 0, 0]] * 3}
    t = pa.table({k: (pa.array(v, type=pa.list_(pa.float64(), len(v[0]))) if isinstance(v[0], list) else pa.array(v)) for k, v in rows.items()})
    pq.write_table(t, root / "data" / "chunk-000" / "file_000.parquet")


with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    tiny(root)
    ds = lr.Dataset(root)
    assert ds.fps == 10 and ds.cameras == ["cam"]
    eps = ds.episodes()
    assert [e.index for e in eps] == [0, 1], "episode 2's data file isn't on disk"
    assert eps[0].clips["cam"].end == 0.4 and eps[1].clips["cam"].start == 0.4
    fr = ds.frames(eps[0])
    assert fr["frame_index"].tolist() == [0, 1, 2, 3], "frames in order"
    te = lr.telemetry(fr, ds.fps)
    assert te["t"].tolist() == [0.0, 0.1, 0.2, 0.3]
    assert np.allclose(te["joint_vel_2"], [0.0, 0.2, 0.0, -0.9])
    assert np.allclose(te["speed"], [0.0, 0.2, 0.3, 0.9]) and np.allclose(te["track_err"], [0, 0, 0, 0.5])
    yaw = te["rot_yaw"]
    assert np.all(np.abs(np.diff(yaw)) < 0.2), f"yaw continuous across the sign flip and ±π: {yaw}"
    assert lr.gripper_events(te["gripper"]) == [(1, "close"), (3, "open")]
    assert lr.parse_uuid(eps[0].uuid) == ("LAB", "r1", "2024-01-02", "03:04:05") and lr.parse_uuid("X") == ("", "", "", "")
    assert lr.verb_of("Put the cup down") == "put" and lr.verb_of("") == ""
    print("lerobot: ok")

real = Path.home() / "data" / "robot-scout" / "droid720_failure"
if (real / "meta" / "info.json").exists():
    ds = lr.Dataset(real)
    eps = ds.episodes(with_video=True)
    assert len(eps) >= 200, len(eps)
    te = lr.telemetry(ds.frames(eps[0]), ds.fps)
    assert len(te["t"]) == eps[0].length and set(["joint_vel_7", "gripper", "pos_z", "rot_yaw", "speed"]) <= set(te)
    print("droid: ok")
