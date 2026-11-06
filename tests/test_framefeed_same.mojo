# mojoui.framefeed on every platform (goal 58): a feed opens the video on its own thread, reports its size, then decodes
# frames asked for. The same lines on Linux (ffmpeg) and a Mac (AVFoundation on the feed's thread).
#   MEDIA_VIDEO=<an .mp4> pixi run mojo run -I . tests/test_framefeed_same.mojo
# Prints "FEED: ready w h frames" (or "FEED: problem …"), "FEED: frame 50 taken", "FEED: done".
from std.os import getenv
from mojoui.framefeed import FrameFeed


def main() raises:
    var feed = FrameFeed(getenv("MEDIA_VIDEO", ""))
    _ = feed.wait(20.0)
    if not feed.ready():
        print("FEED: problem " + feed.problem())
        return
    var info = feed.info()
    print("FEED: ready", info.width, info.height, info.frames)
    feed.want(50)
    var buf = List[UInt32]()
    var got = False
    for _ in range(400):
        if feed.take(buf):
            got = True
            break
        _ = feed.wait(0.05)
    print("FEED: frame 50 " + ("taken" if got and len(buf) == info.width * info.height else "not taken"))
    print("FEED: done")
