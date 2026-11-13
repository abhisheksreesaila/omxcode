#!/usr/bin/env python3
"""A small fleet of ROS 2 bags for goal 68 (M3, M4): fetched from their public homes, kept under 2 GB in total.

    pixi run -e bagcheck python -I scripts/fetch_bags.py [OUT]     (OUT: build/bags; downloads: $OMX_CACHE/bags, else ~/.cache/omxcode/bags)

What it takes (both CC BY 4.0, written to OUT/ATTRIBUTION.txt):
  - NVIDIA Isaac ROS r2b dataset 2024 (NGC, nvidia/isaac/r2bdataset2024 v1): r2b_galileo and r2b_whitetunnel, whole and
    untouched (rosbag2 MCAP folders, 493 MB and 527 MB): stereo CompressedImage, Imu, Odometry, TF.
  - NavWareSet (Voxel51/navwareset on the Hugging Face Hub; Clearpath Jackal, IJRR 2026, doi 10.1177/02783649261447305):
    each scene is a 4 GB MCAP, so only a slice is fetched: its summary (schemas, channels, chunk index) by HTTP range,
    then the chunks of SLICE_S seconds from START_S in, up to BUDGET bytes. The slice is rewritten with the official
    `mcap` writer (messages byte for byte; the fixed room sensors /grs/* dropped, they aren't the robot's), one in zstd
    chunks, one in lz4, one unchunked-compression ("" — chunks stored plain), so the reader meets every kind.
  - One rosbag2 sqlite3 bag (the older storage), written by `rosbags` from the first NavWareSet slice's robot topics.

Resumable .part files checked against the server's size; anything already there is skipped (a second run fetches nothing).
"""
import os
import struct
import sys
import urllib.request
from pathlib import Path

NGC = "https://api.ngc.nvidia.com/v2/resources/nvidia/isaac/r2bdataset2024/versions/1/files/"
R2B = ["r2b_galileo", "r2b_whitetunnel"]
HF = "https://huggingface.co/datasets/Voxel51/navwareset/resolve/main/data/%s.mcap"
# (scene, seconds in, compression of the rewrite)
NAV = [("15", 40.0, "zstd"), ("25", 40.0, "lz4"), ("46", 40.0, "")]
SLICE_S = 30.0
BUDGET = 190_000_000  # bytes of chunks fetched per scene at most (3 × 190 MB + 1.02 GB < 2 GB)
MAGIC = b"\x89MCAP0\r\n"


def cache() -> Path:
    return Path(os.environ.get("OMX_CACHE", Path.home() / ".cache/omxcode")) / "bags"


def _open(url, a=None, b=None):
    req = urllib.request.Request(url, headers={"User-Agent": "omxcode-setup"})
    if os.environ.get("HF_TOKEN") and url.startswith("https://huggingface.co/"):
        req.add_unredirected_header("Authorization", "Bearer " + os.environ["HF_TOKEN"])
    if a is not None:
        req.add_header("Range", f"bytes={a}-" + ("" if b is None else str(b)))
    return urllib.request.urlopen(req, timeout=60)


def size_of(url) -> int:
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "omxcode-setup"})
    return int(urllib.request.urlopen(req, timeout=60).headers["Content-Length"])


def fetch(url, dst: Path, a=None, b=None) -> int:
    """url (or bytes a..b of it) into dst, resuming dst.part; the bytes fetched (0: it was there)."""
    if dst.exists():
        return 0
    dst.parent.mkdir(parents=True, exist_ok=True)
    want = (b - a + 1) if a is not None else size_of(url)
    part = dst.with_name(dst.name + ".part")
    for _ in range(6):
        have = part.stat().st_size if part.exists() else 0
        if have >= want:
            break
        try:
            with _open(url, (a or 0) + have, b) as r, open(part, "ab") as f:
                while True:
                    buf = r.read(1 << 20)
                    if not buf:
                        break
                    f.write(buf)
                    have += len(buf)
                    print(f"\r  {dst.name}: {have / 1e6:.0f} of {want / 1e6:.0f} MB", end="", file=sys.stderr, flush=True)
        except OSError as e:
            print(f"\n  {dst.name}: {e}; resuming", file=sys.stderr)
    print(file=sys.stderr)
    if part.stat().st_size != want:
        raise SystemExit(f"{dst.name}: got {part.stat().st_size} bytes, the server said {want}")
    part.rename(dst)
    return want


def records(buf: bytes):
    p = 0
    while p + 9 <= len(buf):
        op = buf[p]
        n = struct.unpack_from("<Q", buf, p + 1)[0]
        yield op, buf[p + 9 : p + 9 + n]
        p += 9 + n


def nav_slice(scene: str, start_s: float, raw: Path) -> int:
    """A valid (summary-less) MCAP holding scene's header, schemas, channels and the chunks of SLICE_S s from start_s."""
    if raw.exists():
        return 0
    url = HF % scene
    size = size_of(url)
    with _open(url, size - 37, size - 1) as r:
        tail = r.read()
    if tail[-8:] != MAGIC or tail[0] != 0x02:
        raise SystemExit(f"NavWareSet {scene}: no MCAP footer")
    summary_start = struct.unpack_from("<Q", tail, 9)[0]
    with _open(url, summary_start, size - 38) as r:
        summary = r.read()
    with _open(url, 0, 4095) as r:
        head = r.read()
    if head[:8] != MAGIC or head[8] != 0x01:
        raise SystemExit(f"NavWareSet {scene}: no MCAP header")
    header_rec = head[8 : 8 + 9 + struct.unpack_from("<Q", head, 9)[0]]
    meta, chunks = [], []
    for op, body in records(summary):
        if op in (0x03, 0x04):  # Schema, Channel
            meta.append(bytes([op]) + struct.pack("<Q", len(body)) + body)
        elif op == 0x08:  # ChunkIndex: start, end, chunk_start_offset, chunk_length
            chunks.append(struct.unpack_from("<QQQQ", body, 0))
    chunks.sort(key=lambda c: c[2])
    t00 = chunks[0][0]
    pick = [c for c in chunks if c[0] >= t00 + start_s * 1e9 and c[1] <= t00 + (start_s + SLICE_S) * 1e9]
    a = pick[0][2]
    b = pick[0][2]
    for c in pick:
        if c[2] + c[3] - a > BUDGET:
            break
        b = c[2] + c[3]
    # (the bytes after a chunk up to the next chunk are its message indexes: valid records too)
    body = raw.with_name(raw.name + ".chunks")
    got = fetch(url, body, a, b - 1)
    data_end = bytes([0x0F]) + struct.pack("<QI", 4, 0)
    footer = bytes([0x02]) + struct.pack("<QQQI", 20, 0, 0, 0)
    tmp = raw.with_name(raw.name + ".tmp")
    with open(tmp, "wb") as f:
        f.write(MAGIC + header_rec + b"".join(meta))
        f.write(body.read_bytes())
        f.write(data_end + footer + MAGIC)
    tmp.rename(raw)
    body.unlink()
    return got


def rewrite(raw: Path, dst: Path, compression: str):
    """raw's messages (all but /grs/*) into dst with the official writer: chunked, indexed, with a summary."""
    from mcap.reader import NonSeekingReader
    from mcap.writer import CompressionType, Writer

    if dst.exists():
        return
    comp = {"zstd": CompressionType.ZSTD, "lz4": CompressionType.LZ4, "": CompressionType.NONE}[compression]
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".tmp")
    with open(raw, "rb") as fi, open(tmp, "wb") as fo:
        w = Writer(fo, compression=comp, chunk_size=4 * 1024 * 1024)
        r = NonSeekingReader(fi, validate_crcs=True)
        w.start(profile="ros2", library="omxcode fetch_bags (mcap writer)")
        schemas, channels = {}, {}
        for schema, channel, msg in r.iter_messages():
            if channel.topic.startswith("/grs/"):
                continue
            if schema is not None and schema.id not in schemas:
                schemas[schema.id] = w.register_schema(schema.name, schema.encoding, schema.data)
            if channel.id not in channels:
                channels[channel.id] = w.register_channel(
                    channel.topic, channel.message_encoding, schemas.get(channel.schema_id, 0), dict(channel.metadata)
                )
            w.add_message(channels[channel.id], msg.log_time, msg.data, msg.publish_time, msg.sequence)
        w.finish()
    tmp.rename(dst)


def sqlite_bag(src: Path, dst: Path, limit_s: float = 10.0):
    """The robot's small topics (pose, cmd_vel, tf) of src's first limit_s seconds as a rosbag2 sqlite3 bag."""
    from mcap.reader import make_reader
    from rosbags.rosbag2 import StoragePlugin, Writer
    from rosbags.typesys import Stores, get_typestore, get_types_from_msg

    if dst.exists():
        return
    keep = ("/robot/cmd_vel", "/robot/amcl_pose", "/robot/tf", "/robot/camera/color/camera_info")  # (CDR ones: sqlite bags hold CDR)
    store = get_typestore(Stores.ROS2_HUMBLE)
    with open(src, "rb") as f:
        r = make_reader(f)
        s = r.get_summary()
        for sch in s.schemas.values():  # (the file's own message definitions: custom ones register too)
            if sch.encoding == "ros2msg":
                store.register(get_types_from_msg(sch.data.decode(), sch.name))
        w = Writer(dst, version=8, storage_plugin=StoragePlugin.SQLITE3)
        w.open()
        conns = {}
        t0 = None
        for schema, channel, msg in r.iter_messages():
            t0 = msg.log_time if t0 is None else t0
            if msg.log_time - t0 > limit_s * 1e9:
                break
            if channel.topic not in keep:
                continue
            if channel.id not in conns:
                conns[channel.id] = w.add_connection(channel.topic, schema.name, typestore=store)
            w.write(conns[channel.id], msg.log_time, msg.data)
        w.close()


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/bags")
    got = 0
    for name in R2B:
        for f in ("metadata.yaml", f"{name}_0.mcap"):
            got += fetch(NGC + f"{name}/{f}", out / name / f)
    for scene, start, comp in NAV:
        raw = cache() / f"navwareset_{scene}.slice.mcap"
        got += nav_slice(scene, start, raw)
        rewrite(raw, out / f"navwareset_{scene}" / f"navwareset_{scene}_0.mcap", comp)
    sqlite_bag(out / "navwareset_15" / "navwareset_15_0.mcap", out / "navwareset_15_sqlite")
    (out / "ATTRIBUTION.txt").write_text(
        "r2b_galileo, r2b_whitetunnel: NVIDIA Isaac ROS r2b dataset 2024 (NGC nvidia/isaac/r2bdataset2024 v1), CC BY 4.0.\n"
        "navwareset_*: NavWareSet (Voxel51/navwareset, Hugging Face), CC BY 4.0; slices of scenes 15, 25, 46 "
        f"({SLICE_S:.0f} s from 40 s in, /grs/* room sensors dropped), rewritten with the mcap writer. doi 10.1177/02783649261447305.\n"
    )
    total = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
    print(f"fetched {got / 1e6:.0f} MB; {out}: {total / 1e6:.0f} MB on disk")


if __name__ == "__main__":
    main()
