"""mojoui.lerobot: a LeRobot (v3) dataset folder as episodes and telemetry (goal 47). A generic source plugin, as
mojoui/ocr_torch.py is a model plugin: any robot dataset in the LeRobot layout (meta/info.json, meta/episodes/*.parquet,
data/chunk-*/file-*.parquet, videos/<camera>/chunk-*/file-*.mp4) reads the same way.

    ds = Dataset("/data/droid720")                     # reads meta/info.json and the episode index
    eps = ds.episodes(present_only=True)               # [Episode]: index, uuid, length, tasks, data file, each camera's clip
    frames = ds.frames(ep)                             # {feature: numpy array (length × width)} for one episode
    tele = telemetry(frames, fps=ds.fps)               # display-ready channels: joint velocities, gripper, position,
                                                       #   rotation (quaternion made continuous, then roll/pitch/yaw unwrapped)
    ev = gripper_events(tele["gripper"])               # [(frame, "close" | "open")] with hysteresis

Nothing here knows DROID: feature names are read from info.json; `telemetry()` takes the common LeRobot names
(observation.joint_velocity, observation.gripper_position, observation.cartesian_position as xyz + quaternion wxyz) and
skips what a dataset lacks. Files are data: read with pyarrow, never executed. No pandas.
"""

import json
import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

# Gripper hysteresis (position 0 = open, 1 = closed): a close starts above CLOSE_AT rising, an open below OPEN_AT falling.
CLOSE_AT = 0.25
OPEN_AT = 0.12


@dataclass
class Clip:
    """One camera's part of an episode: the packed mp4 and where the episode sits in it (seconds)."""
    camera: str
    path: Path
    start: float
    end: float


@dataclass
class Episode:
    index: int
    uuid: str
    length: int
    tasks: list
    data_path: Path
    first_row: int  # the episode's first row in the dataset (dataset_from_index)
    clips: dict = field(default_factory=dict)  # camera → Clip


class Dataset:
    def __init__(self, root):
        self.root = Path(root)
        info = json.loads((self.root / "meta" / "info.json").read_text())
        self.info = info
        self.fps = float(info.get("fps", 30))
        self.robot_type = info.get("robot_type", "")
        self.features = info.get("features", {})
        self.cameras = [k for k, v in self.features.items() if v.get("dtype") == "video"]
        if not self.cameras:  # (some ports list videos only under videos/)
            vids = self.root / "videos"
            self.cameras = sorted(p.name for p in vids.iterdir()) if vids.exists() else []
        self._cache = {}  # data file → its table (one at a time: files hold hundreds of episodes)

    def _path(self, template, **kw):
        return self.root / template.format(**kw)

    def episodes(self, present_only=True, with_video=False):
        """Every episode in meta/episodes, oldest file first; present_only: those whose data file is on disk (a partial
        download); with_video: and at least one camera's video file too."""
        out = []
        for f in sorted((self.root / "meta" / "episodes").rglob("*.parquet")):
            t = pq.read_table(f)
            names = [c for c in t.column_names if not c.startswith("stats/")]
            rows = t.select(names).to_pylist()
            for r in rows:
                data = self._path(self.info["data_path"], chunk_index=r["data/chunk_index"], file_index=r["data/file_index"])
                clips = {}
                for cam in self.cameras:
                    key = f"videos/{cam}/"
                    if key + "file_index" not in r or r[key + "file_index"] is None:
                        continue
                    vp = self._path(self.info["video_path"], video_key=cam, chunk_index=r[key + "chunk_index"], file_index=r[key + "file_index"])
                    clips[cam] = Clip(cam, vp, float(r[key + "from_timestamp"]), float(r[key + "to_timestamp"]))
                ep = Episode(int(r["episode_index"]), str(r.get("uuid") or ""), int(r["length"]), list(r.get("tasks") or []),
                             data, int(r["dataset_from_index"]), clips)
                if present_only and not data.exists():
                    continue
                if with_video and not any(c.path.exists() for c in clips.values()):
                    continue
                out.append(ep)
        return out

    def _arrays(self, path):
        """A data file's numeric columns as numpy arrays (length × width), its episode index and frame index; one file
        kept at a time."""
        if path not in self._cache:
            self._cache.clear()
            t = pq.read_table(path)
            cols = {}
            for name in t.column_names:
                col = t.column(name).combine_chunks()
                try:
                    if hasattr(col.type, "list_size"):
                        cols[name] = col.flatten().to_numpy(zero_copy_only=False).astype(np.float64).reshape(len(col), col.type.list_size)
                    elif col.type in (pa.float64(), pa.float32(), pa.int64(), pa.int32()):
                        cols[name] = col.to_numpy(zero_copy_only=False).astype(np.float64)
                except (pa.ArrowInvalid, pa.ArrowNotImplementedError, ValueError):
                    continue
            self._cache[path] = cols
        return self._cache[path]

    def frames(self, ep, columns=None):
        """One episode's rows: {feature: array (length × width) or (length,)}, in frame order."""
        cols = self._arrays(ep.data_path)
        rows = np.nonzero(cols["episode_index"] == ep.index)[0]
        if len(rows) == 0:
            raise ValueError(f"episode {ep.index} has no rows in {ep.data_path.name}")
        rows = rows[np.argsort(cols["frame_index"][rows], kind="stable")]
        return {name: a[rows] for name, a in cols.items() if columns is None or name in columns}


def continuous_quaternions(q):
    """Quaternions (n × 4, any order) with signs chosen so neighbours agree (q and −q are one rotation: a sign flip shows
    as a square step in a plot)."""
    q = np.array(q, dtype=np.float64, copy=True)
    for i in range(1, len(q)):
        if np.dot(q[i], q[i - 1]) < 0:
            q[i] = -q[i]
    return q


def rpy_from_wxyz(q):
    """Roll, pitch, yaw (radians) from quaternions w, x, y, z (n × 4)."""
    w, x, y, z = q[:, 0], q[:, 1], q[:, 2], q[:, 3]
    roll = np.arctan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
    pitch = np.arcsin(np.clip(2 * (w * y - z * x), -1.0, 1.0))
    yaw = np.arctan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
    return np.stack([roll, pitch, yaw], axis=1)


def unwrap(a):
    """Angles (radians) without 2π jumps: each step taken the short way round (numpy's unwrap, per column)."""
    return np.unwrap(np.asarray(a, dtype=np.float64), axis=0)


def gripper_events(g, close_at=CLOSE_AT, open_at=OPEN_AT):
    """[(frame, "close" | "open")]: the gripper passing close_at rising (closed) and open_at falling (open again)."""
    out, closed = [], False
    for i, v in enumerate(g):
        if not closed and v > close_at:
            closed = True
            out.append((i, "close"))
        elif closed and v < open_at:
            closed = False
            out.append((i, "open"))
    return out


def telemetry(frames, fps):
    """Display-ready channels for one episode (each a 1-D array, one value per frame), named as mojoui's telemetry chart
    groups them (stem_suffix: joint_vel_1…7, pos_x/y/z, rot_roll/pitch/yaw):
      t                  seconds from the episode's first frame
      joint_vel_1…n      observation.joint_velocity (rad/s)
      gripper            observation.gripper_position (0 open … 1 closed)
      pos_x, pos_y, pos_z    observation.cartesian_position xyz (m)
      rot_roll, rot_pitch, rot_yaw   its quaternion made continuous, as roll/pitch/yaw, unwrapped (rad)
      speed              the fastest joint's |velocity| at each frame (rad/s)
      track_err          the largest |commanded − measured| joint velocity (action.joint_velocity − observation's), rad/s
    Missing features are skipped."""
    out = {}
    n = len(next(iter(frames.values())))
    out["t"] = np.arange(n, dtype=np.float64) / fps
    jv = frames.get("observation.joint_velocity")
    if jv is not None:
        for j in range(jv.shape[1]):
            out[f"joint_vel_{j + 1}"] = jv[:, j]
    g = frames.get("observation.gripper_position")
    if g is not None:
        out["gripper"] = g.reshape(-1)
    cp = frames.get("observation.cartesian_position")
    if cp is not None and cp.shape[1] >= 3:
        for k, a in enumerate("xyz"):
            out[f"pos_{a}"] = cp[:, k]
        if cp.shape[1] >= 7:
            rpy = unwrap(rpy_from_wxyz(continuous_quaternions(cp[:, 3:7])))
            for k, a in enumerate(("roll", "pitch", "yaw")):
                out[f"rot_{a}"] = rpy[:, k]
    if jv is not None:
        out["speed"] = np.abs(jv).max(axis=1)
        ajv = frames.get("action.joint_velocity")
        if ajv is not None and ajv.shape == jv.shape:
            out["track_err"] = np.abs(ajv - jv).max(axis=1)
    return out


def parse_uuid(uuid):
    """DROID-style uuid "LAB+robot+YYYY-MM-DD-HHh-MMm-SSs" → (lab, robot, date, time); blanks when it isn't one."""
    parts = uuid.split("+")
    if len(parts) != 3:
        return "", "", "", ""
    lab, robot, stamp = parts
    bits = stamp.split("-")
    date = "-".join(bits[:3]) if len(bits) >= 3 else ""
    time = ":".join(b[:-1] for b in bits[3:6]) if len(bits) >= 6 else ""
    return lab, robot, date, time


def verb_of(task):
    """A task's first word, lower case ("Put the blue block…" → "put"); "" for none."""
    for w in task.replace(",", " ").split():
        w = w.strip().lower()
        if w.isalpha():
            return w
    return ""


def finite(x, nd=4):
    return round(float(x), nd) if math.isfinite(float(x)) else 0.0
