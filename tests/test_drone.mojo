# The drone, end to end on the framework (goal 39 M8 core): two generated flights along a power line → defects on the
# map, the assets that got worse, and the next flight plan. Never reads truth.json.
#   CUDA_VISIBLE_DEVICES=1 G39_MEDIA=build/g39/media G39_OUT=build/g39/drone_core pixi run mojo run -I . tests/test_drone.mojo
# Writes into $G39_OUT: regions_a.csv / regions_b.csv (every georeferenced row), defects_a.csv, defects_b.csv (asset, lat,
# lon, severity), worse.csv (asset, severity_a, severity_b, change), waypoints.csv (asset, lat, lon, alt_m, action);
# prints "drone: ok" and frames per second (decode included). scripts/check.py m8 scores the files.
from std.testing import assert_equal, assert_true
from std.os import getenv
from std.os.path import exists
from mojoui.video import VideoSource
from mojoui.videotable import scan
from mojoui.timeseries import TimeSeries
from mojoui.geo import NadirCamera, Pose, pose_at, georeference, places, name_along_route, metres, Place
from mojoui.inspection import findings, compare, write_findings, write_changes, write_waypoints, Finding, Change
from mojoui.vision_presets import (drone_ranges, drone_analyzer, drone_severity, drone_camera_gsd_per_m_alt, DRONE_CELL,
                                   DRONE_ASSET_RADIUS_M, DRONE_ASSET_MIN_ROWS, DRONE_DEFECT_RADIUS_M, DRONE_DEFECT_MIN_ROWS,
                                   DRONE_DEFECT_TO_ASSET_M, DRONE_MATCH_M)


def read_series(path: String) raises -> TimeSeries:
    """A numeric CSV whose first column is time, as a TimeSeries (tests run without omxcore's reader, D-838)."""
    var lines = open(path, "r").read().split("\n")
    var head = lines[0].split(",")
    var cols = List[List[Float64]]()
    for _ in range(len(head)):
        cols.append(List[Float64]())
    for i in range(1, len(lines)):
        if lines[i].byte_length() == 0:
            continue
        var cells = lines[i].split(",")
        for c in range(len(head)):
            cols[c].append(Float64(String(cells[c])))
    var ts = TimeSeries(cols[0].copy())
    for c in range(1, len(head)):
        ts.add(String(head[c]), cols[c].copy())
    return ts^


struct Flight(Movable):
    var assets: List[Place]
    var found: List[Finding]
    var frames: Int
    var seconds: Float64

    def __init__(out self, var assets: List[Place], var found: List[Finding], frames: Int, seconds: Float64):
        self.assets = assets^
        self.found = found^
        self.frames = frames
        self.seconds = seconds


def fly(media: String, dir: String, key: String) raises -> Flight:
    var ts = read_series(media + "/telemetry_" + key + ".csv")
    var video = VideoSource(media + "/drone_" + key + ".mp4")
    var cam = NadirCamera(video.width, video.height, drone_camera_gsd_per_m_alt(), ts.value("lat", 0))
    var a = drone_analyzer()
    var table = scan(video, a, drone_ranges(), DRONE_CELL)
    georeference(table, ts, cam)
    table.write_csv(dir + "/regions_" + key + ".csv")
    var assets = places(table, "insulator", DRONE_ASSET_RADIUS_M, DRONE_ASSET_MIN_ROWS)
    name_along_route(assets, ts, "P", 2)
    var marks = places(table, "defect", DRONE_DEFECT_RADIUS_M, DRONE_DEFECT_MIN_ROWS)
    var found = findings(assets, marks, drone_severity(), DRONE_DEFECT_TO_ASSET_M)
    write_findings(dir + "/defects_" + key + ".csv", found)
    print("flight", key, ":", table.frames, "frames,", table.rows(), "rows,", len(assets), "assets,", len(found), "defects;",
          table.frames_per_second(), "frames/s")
    for p in assets:
        print("  asset", p.name, p.lat, p.lon, "rows", p.rows)
    for f in found:
        print("  defect on", f.asset, f.lat, f.lon, "severity", f.severity, "radius", f.radius_m, "m")
    for f in found:
        assert_true(f.asset.byte_length() > 0, "every defect is on an asset")
    return Flight(assets^, found^, table.frames, table.seconds)


def main() raises:
    var media = getenv("G39_MEDIA", "build/g39/media")
    var out = getenv("G39_OUT", "build/g39/drone_core")

    # the camera model round-trips a pixel through the ground
    var cam = NadirCamera(1280, 720, 0.001, 52.01)
    var pose = Pose(52.01, 5.12, 60.0, 38.0)
    var g = cam.to_ground(pose, 100.5, 600.5)
    var px = cam.to_pixel(pose, g[0], g[1])
    assert_true(abs(px[0] - 100.5) < 1e-6 and abs(px[1] - 600.5) < 1e-6, "pixel → ground → pixel")
    var c = cam.to_ground(pose, 640, 360)
    assert_true(abs(c[0] - 52.01) < 1e-12 and abs(c[1] - 5.12) < 1e-12, "the picture's centre is under the camera")
    var d = metres(52.01, 5.12, 52.01 + 100.0 / 111320.0, 5.12)
    assert_true(abs(d - 100.0) < 0.2, "haversine: 100 m north")

    var fa = fly(media, out, "a")
    var fb = fly(media, out, "b")
    var changes = compare(fa.assets, fa.found, fb.assets, fb.found, DRONE_MATCH_M)
    write_changes(out + "/worse.csv", changes, worse_only=True)
    write_waypoints(out + "/waypoints.csv", changes, fb.assets, 25.0, "inspect", worse_only=True)
    var worse = 0
    for ch in changes:
        print("  ", ch.asset, ch.severity_a, "→", ch.severity_b, ch.change)
        if ch.is_worse():
            worse += 1
    assert_true(len(fa.assets) >= 2 and len(fa.assets) == len(fb.assets), "the same assets on both flights")
    assert_true(len(fa.found) >= 1 and len(fb.found) >= 1, "defects found")
    assert_true(exists(out + "/waypoints.csv"), "waypoints written")
    print("drone: ok", len(fb.assets), "assets,", worse, "worse")
    print("frames per s:", Float64(fa.frames + fb.frames) / (fa.seconds + fb.seconds))
