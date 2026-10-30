# mojoui.video's VideoSource against ffmpeg/ffprobe's own answers (goal 39 M1), on the generated warehouse.mp4:
#   G39_MEDIA=build/g39/media pixi run mojo run -I . tests/test_video.mojo
# Prints one "<label>: ok" line per check (scripts/check.py m1 reads them), plus the speed it measured.
from std.testing import assert_equal, assert_true
from std.os import getenv
from std.ffi import external_call
from std.python import Python
from mojoui.video import VideoSource
from mojoui.clock import now_ns


def sh(cmd: String):
    var c = cmd
    _ = external_call["system", Int32](c.as_c_string_span())


def ref_frame(path: String, n: Int, dest: String):
    """ffmpeg's own decode of frame n (select filter, counted from the start), written to a file as RGBA."""
    sh("ffmpeg -v error -y -i '" + path + "' -vf 'select=eq(n\\," + String(n) + ")' -vframes 1 -f rawvideo -pix_fmt rgba '" + dest + "'")


def same(pixels: List[UInt32], path: String) raises -> Bool:
    """The pixels' bytes equal the file's."""
    var want = open(path, "r").read_bytes()
    if len(want) != len(pixels) * 4:
        return False
    var p = pixels.unsafe_ptr().unsafe_bitcast[UInt8]()
    for i in range(len(want)):
        if p.unsafe_offset(i)[] != want[i]:
            return False
    return True


def main() raises:
    var media = getenv("G39_MEDIA", "build/g39/media")
    var path = media + "/warehouse.mp4"
    var tmp = getenv("TMPDIR", "/tmp") + "/test_video_ref.rgba"

    # open: size, rate, length against ffprobe's JSON (read by Python's json module, used only here)
    var json = Python.import_module("json")
    var sp = Python.import_module("subprocess")
    var raw = sp.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries",
         "stream=width,height,r_frame_rate,nb_read_frames,duration", "-of", "json", path],
        capture_output=True, text=True,
    )
    var s = json.loads(raw.stdout)["streams"][0]
    var v = VideoSource(path)
    assert_equal(v.width, Int(py=s["width"]))
    assert_equal(v.height, Int(py=s["height"]))
    assert_equal(v.frames, Int(String(s["nb_read_frames"])))  # decoded and counted, not the container's claim
    var rate = String(s["r_frame_rate"]).split("/")
    assert_equal(v.fps, Float64(rate[0]) / Float64(rate[1]))
    assert_true(abs(v.duration - Float64(String(s["duration"]))) < 0.01, "duration " + String(v.duration))
    assert_equal(v.width * v.height * 4, 1280 * 720 * 4)
    print("video open: ok", v.width, "x", v.height, "@", v.fps, "fps,", v.frames, "frames,", v.duration, "s")

    # errors are messages, not crashes
    var failed = String("")
    try:
        _ = VideoSource(media + "/no-such-file.mp4")
    except e:
        failed = String(e)
    assert_true(failed.startswith("VideoSource: no such file"), failed)
    try:
        _ = VideoSource(media + "/truth.json")
        failed = String("opened a json file")
    except e:
        failed = String(e)
    assert_true(failed.startswith("VideoSource: not a video"), failed)

    # a path with a space and a quote still opens (the pipe goes through one /bin/sh)
    var odd = getenv("TMPDIR", "/tmp") + "/it's a video.mp4"
    sh("cp '" + path + "' \"" + odd + "\"")
    var vo = VideoSource(odd)
    assert_equal(vo.frames, v.frames)
    assert_equal(len(vo.next()), 1280 * 720)

    # frame: sequential reads from the start, frame 150 equals ffmpeg's own decode
    var last = List[UInt32]()
    for _ in range(151):
        last = v.next()
    assert_equal(v.position(), 151)
    ref_frame(path, 150, tmp)
    assert_true(same(last, tmp), "frame 150 differs from ffmpeg's")
    assert_true(same(v.read(150), tmp), "read(150) (a seek back) differs from ffmpeg's")
    print("video frame: ok frame 150 byte-equal to ffmpeg")

    # seek: 12.5 s is frame 375; then back to 1.0 s (frame 30) and the first frame
    v.seek(12.5)
    var at = v.next()
    ref_frame(path, 375, tmp)
    assert_true(same(at, tmp), "frame at 12.5 s differs from ffmpeg's")
    var after = v.next()  # the pipe goes on from there
    ref_frame(path, 376, tmp)
    assert_true(same(after, tmp), "frame after 12.5 s differs")
    v.seek(1.0)
    ref_frame(path, 30, tmp)
    assert_true(same(v.next(), tmp), "frame at 1.0 s differs")
    v.seek_frame(0)
    ref_frame(path, 0, tmp)
    assert_true(same(v.next(), tmp), "frame 0 differs")
    v.seek_frame(v.frames - 1)  # the last frame, then the end
    ref_frame(path, v.frames - 1, tmp)
    assert_true(same(v.next(), tmp), "last frame differs")
    var ended = False
    try:
        _ = v.next()
    except:
        ended = True
    assert_true(ended, "next() past the end should raise")
    print("video seek: ok 12.5 s, back to 1.0 s, frame 0, the last frame")

    # speed: sequential 720p decode, frames per second, one pass of 300 frames into one reused buffer
    v.seek_frame(0)
    var buf = List[UInt32]()
    var t0 = now_ns()
    var n = 0
    while n < 300 and v.next_into(buf):
        n += 1
    var secs = Float64(now_ns() - t0) / 1e9
    var fps = Float64(n) / secs
    assert_equal(n, 300)
    assert_true(fps >= 240.0, "sequential decode " + String(fps) + " frames/s")
    print("video speed: ok frames/s=" + String(Int(fps)))
