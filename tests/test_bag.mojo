# mojoui.bag (goal 68 M3): cameras become videos mojoui.video plays, a topic becomes a sheet table, bad files say why.
#   pixi run mojo build -I . tests/test_bag.mojo -o build/g68/bin/test_bag && build/g68/bin/test_bag   (needs build/bags)
from std.os import makedirs
from mojoui.bag import Bag, camera_video, sheet_table, MsgTypes
from mojoui.video import VideoSource


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def fails(path: String, words: String) -> Bool:
    try:
        _ = Bag.open(path)
        return False
    except e:
        print("  ", path, "→", String(e))
        return words in String(e)


def main() raises:
    makedirs("build/g68/videos", exist_ok=True)
    var r2b = Bag.open("build/bags/r2b_galileo")
    var k = r2b.find("/front_stereo_camera/left/image_compressed")
    var v = camera_video(r2b, k, "build/g68/videos/r2b_front_left.mp4")
    var s = VideoSource(v.path)
    check(s.frames == r2b.topics[k].count and s.width == 1920, "h264 video " + String(s.frames) + " frames " + String(s.width))
    print("bag-video-h264: ok", s.frames, "frames", s.width, "x", s.height, s.fps, "fps")

    var nav = Bag.open("build/bags/navwareset_15")
    var j = nav.find("/robot/camera/color/image_raw")
    var w = camera_video(nav, j, "build/g68/videos/nav15_front.avi")
    var s2 = VideoSource(w.path)
    check(s2.frames == nav.topics[j].count and w.width == 640 and s2.width == 640, "jpeg video")
    var px = s2.read(s2.frames // 2)
    check(len(px) == 640 * 480, "a frame's pixels")
    print("bag-video-jpeg: ok", s2.frames, "frames", w.width, "x", w.height)

    var odom = r2b.table(r2b.find("/chassis/odom"))
    var t = sheet_table(odom, r2b.start_ns)
    check(t.rows() == odom.rows and t.name(0) == "t" and t.index("pose.pose.position.x") > 0 and t.index("t_ns") == t.columns() - 1, "sheet table")
    var x = t.index("twist.twist.linear.x")
    check(t.get(0, t.rows() - 1) > t.get(0, 0) and t.get(0, t.rows() - 1) <= Int64(Int(r2b.duration_s() * 1000.0) + 1), "t in ms from the start")
    print("bag-table: ok", t.rows(), "rows", t.columns(), "columns; last t", t.get(0, t.rows() - 1), "ms; speed col", x)

    with open("build/g68/not_a_bag.mcap", "w") as f:
        f.write("hello, this isn't a bag at all, just some text long enough to have a tail")
    check(fails("build/g68/not_a_bag.mcap", "isn't an MCAP file"), "a text file")
    makedirs("build/g68/empty_dir", exist_ok=True)
    check(fails("build/g68/empty_dir", "not a ROS 2 bag"), "an empty folder")
    check(fails("build/g68/no_such_bag", "no such file"), "a missing path")
    # (a cut download: the first 3 MB of a real MCAP)
    with open("build/bags/navwareset_25/navwareset_25_0.mcap", "r") as f:
        var head = f.read_bytes(3_000_000)
        with open("build/g68/cut.mcap", "w") as g:
            g.write_bytes(Span(head))
    var cut_ok = False
    try:
        var cut = Bag.open("build/g68/cut.mcap")
        var all = List[Int]()
        for i in range(len(cut.topics)):
            all.append(i)
        _ = cut.tables(all)
    except e:
        print("   cut.mcap →", String(e))
        cut_ok = "ends" in String(e) or "cut" in String(e)
    check(cut_ok, "a cut file")
    # (a damaged file: a record whose length runs past the file, read without a summary: an error, never a hang or a crash)
    var bad = List[UInt8]()
    for b in [0x89, 0x4D, 0x43, 0x41, 0x50, 0x30, 0x0D, 0x0A]:
        bad.append(UInt8(b))
    bad.append(0x03)
    for _ in range(8):
        bad.append(0xFF)  # (a length of 2^64 - 1)
    for _ in range(64):
        bad.append(0)
    with open("build/g68/damaged.mcap", "w") as g:
        g.write_bytes(Span(bad))
    check(fails("build/g68/damaged.mcap", "damaged"), "a damaged record length")
    # (a schema whose type holds itself, and a huge fixed array: refused, never a stack overflow or a hang)
    var cyc = False
    try:
        _ = MsgTypes("a/Foo", "int32 x\na/Foo next")
    except e:
        cyc = "holds itself" in String(e)
    check(cyc, "a type that holds itself")
    var huge = False
    try:
        _ = MsgTypes("a/Big", "float64[1000000000] x")
    except e:
        huge = "4,096" in String(e)
    check(huge, "a huge fixed array")
    var many = False  # (lists of messages count by their element: 4,096 × 4,096 × 4,096 columns, said up front)
    try:
        _ = MsgTypes("a/Big", "a/C[] items\n================================================================================\nMSG: a/C\na/D[4096] d\n"
                     + "================================================================================\nMSG: a/D\na/E[4096] e\n"
                     + "================================================================================\nMSG: a/E\nfloat64[4096] v")
    except e:
        many = "20,000 columns" in String(e)
    check(many, "a schema of billions of columns")
    print("bag-errors: ok")
