# mojoui.video: VideoSource, a video file read as RGBA frames (goal 39 M1). A generic component: any app can play, scan or
# export frames; omxplorer's video card, the frame table and the exporter are built on it.
#
#   var v = VideoSource("warehouse.mp4")            # raises (a clear message) when the file is missing or isn't a video
#   v.width, v.height, v.fps, v.frames, v.duration
#   var px = v.next()                               # the next frame, List[UInt32]: row by row, R in the low byte
#   v.seek(12.5)                                    # accurate: the next next() is the frame shown at 12.5 s
#   var f = v.read(150)                             # frame 150 (sequential when it is the next one, a seek otherwise)
#   scene.image(px, v.width, v.height, x, y, w, h)  # or Image(px, v.width, v.height), or a canvas Surface
#
# How: ffprobe tells the size, rate and length once; frames come from ONE long-lived `ffmpeg ... -f rawvideo -pix_fmt rgba -`
# process read through a pipe (libc popen/fread, so it works the same on Linux and Mac); a seek closes the pipe and starts
# a new process at the new time (`-ss` before `-i`: decodes from the keyframe before it and drops frames up to the time).
# Nothing outside this file knows about the pipe: a decoder in the process (libav) can replace _Pipe and the code
# below it without changing a caller. Each popen runs one /bin/sh, so paths are single-quoted (a quote in a path is escaped).

from std.ffi import external_call


comptime _CHUNK = 4096


def _quote(s: String) -> String:
    """A shell word for s: single quotes, with any quote inside written as '\\''."""
    var out = String("'")
    for c in s.codepoint_slices():
        if c == "'":
            out += "'\\''"
        else:
            out += c
    return out + "'"


def _popen(cmd: String) -> Int:
    var c = cmd
    var mode = String("r")
    return external_call["popen", Int](c.as_c_string_span(), mode.as_c_string_span())


def _pclose(fp: Int):
    _ = external_call["pclose", Int32](fp)


def _fread(fp: Int, addr: Int, n: Int) -> Int:
    """Reads up to n bytes (fread loops until n or the end of the stream); returns how many arrived."""
    return external_call["fread", Int](addr, 1, n, fp)


def _read_all(fp: Int) -> String:
    var out = List[UInt8]()
    var buf = List[UInt8](length=_CHUNK, fill=0)
    while True:
        var n = _fread(fp, Int(buf.unsafe_ptr()), _CHUNK)
        if n <= 0:
            break
        for i in range(n):
            out.append(buf[i])
    return String(unsafe_from_utf8=out)


def _run_text(cmd: String) -> String:
    var fp = _popen(cmd)
    if fp == 0:
        return String("")
    var s = _read_all(fp)
    _pclose(fp)
    return s


def _file_exists(path: String) -> Bool:
    var c = path
    var mode = String("rb")
    var fp = external_call["fopen", Int](c.as_c_string_span(), mode.as_c_string_span())
    if fp == 0:
        return False
    _ = external_call["fclose", Int32](fp)
    return True


def _num(s: String) -> Float64:
    """A number from ffprobe's text; -1 when it isn't one ("N/A")."""
    try:
        return Float64(s)
    except:
        return -1.0


@fieldwise_init
struct VideoInfo(Copyable, Movable, ImplicitlyCopyable):
    """What ffprobe tells about a video: its file, size, rate, frame count and length. All zeros until known (an
    opening mojoui.framefeed.FrameFeed); a known one lets a second decoder of the same file start without probing."""
    var path: String
    var width: Int
    var height: Int
    var fps: Float64
    var frames: Int
    var duration: Float64

    @staticmethod
    def unknown(path: String) -> VideoInfo:
        return VideoInfo(path, 0, 0, 0.0, 0, 0.0)

    def known(self) -> Bool:
        return self.width > 0 and self.height > 0 and self.fps > 0


def file_exists(path: String) -> Bool:
    """The file is there and readable (one fopen: cheap enough for the UI thread)."""
    return _file_exists(path)


struct VideoSource(Movable):
    """A video file as RGBA frames. Sequential next() is the fast path; seek() restarts the decoder at a time."""
    var path: String
    var width: Int
    var height: Int
    var fps: Float64
    var frames: Int  # frame count (the container's, or duration x fps when it doesn't say)
    var duration: Float64  # seconds
    var _fp: Int  # the open pipe (0: none)
    var _at: Int  # index of the frame next() returns

    def __init__(out self, path: String) raises:
        self.path = path
        self.width = 0
        self.height = 0
        self.fps = 0.0
        self.frames = 0
        self.duration = 0.0
        self._fp = 0
        self._at = 0
        if not _file_exists(path):
            raise Error("VideoSource: no such file: " + path)
        var probe = _run_text(
            "ffprobe -v error -protocol_whitelist file -select_streams v:0 -of flat -show_entries "
            + "stream=width,height,avg_frame_rate,r_frame_rate,nb_frames,duration:format=duration -i "
            + _quote(path) + " < /dev/null 2>/dev/null"
        )
        var rate = String("")
        var rate_r = String("")
        var nb = -1.0
        var sdur = -1.0
        var fdur = -1.0
        for line in probe.split("\n"):
            var eq = line.find("=")
            if eq < 0:
                continue
            var key = String(line[byte = :eq])
            var val = String(line[byte = eq + 1 :]).replace('"', "")
            if key.endswith(".width"):
                self.width = Int(_num(val))
            elif key.endswith(".height"):
                self.height = Int(_num(val))
            elif key.endswith(".avg_frame_rate"):
                rate = val
            elif key.endswith(".r_frame_rate"):
                rate_r = val
            elif key.endswith(".nb_frames"):
                nb = _num(val)
            elif key.startswith("streams") and key.endswith(".duration"):
                sdur = _num(val)
            elif key.startswith("format") and key.endswith(".duration"):
                fdur = _num(val)
        if self.width <= 0 or self.height <= 0:
            raise Error("VideoSource: not a video (no picture stream found): " + path)
        self.fps = _rate(rate)
        if self.fps <= 0:
            self.fps = _rate(rate_r)
        if self.fps <= 0:
            raise Error("VideoSource: cannot tell the frame rate of " + path)
        self.duration = sdur if sdur > 0 else max(fdur, 0.0)
        self.frames = Int(nb) if nb > 0 else Int(self.duration * self.fps + 0.5)
        if self.duration <= 0:
            self.duration = Float64(self.frames) / self.fps

    def __init__(out self, info: VideoInfo) raises:
        """A decoder for a video already probed (`info` from another VideoSource or a FrameFeed): no ffprobe."""
        if not info.known():
            raise Error("VideoSource: the video's size and rate aren't known yet: " + info.path)
        self.path = info.path
        self.width = info.width
        self.height = info.height
        self.fps = info.fps
        self.frames = info.frames
        self.duration = info.duration
        self._fp = 0
        self._at = 0

    def info(self) -> VideoInfo:
        return VideoInfo(self.path, self.width, self.height, self.fps, self.frames, self.duration)

    def __deinit__(deinit self):
        if self._fp != 0:
            _pclose(self._fp)

    def frame_len(self) -> Int:
        """Pixels (UInt32) in one frame."""
        return self.width * self.height

    def _start(mut self, frame: Int) raises:
        """Starts the decoder so the next frame it delivers is `frame`."""
        self._stop()
        # Half a frame early: whatever the container's timestamps round to, frame n is the first one at or after this time.
        var t = max((Float64(frame) - 0.5) / self.fps, 0.0)
        var seek = String("")
        if frame > 0:
            seek = "-ss " + String(t) + " "
        var cmd = (
            "ffmpeg -v error -nostdin -protocol_whitelist file " + seek + "-i " + _quote(self.path)
            + " -an -sn -fps_mode passthrough -f rawvideo -pix_fmt rgba - 2>/dev/null"
        )
        self._fp = _popen(cmd)
        if self._fp == 0:
            raise Error("VideoSource: cannot start ffmpeg for " + self.path)
        self._at = frame

    def _stop(mut self):
        if self._fp != 0:
            _pclose(self._fp)
            self._fp = 0

    def next_into(mut self, mut pixels: List[UInt32]) raises -> Bool:
        """Reads the next frame into `pixels` (resized to one frame); False at the end of the video."""
        if self._fp == 0:
            self._start(self._at)
        if len(pixels) != self.frame_len():
            pixels = List[UInt32](length=self.frame_len(), fill=0)
        var want = self.frame_len() * 4
        var got = _fread(self._fp, Int(pixels.unsafe_ptr()), want)
        if got < want:
            self._stop()
            return False
        self._at += 1
        return True

    def next_into_address(mut self, addr: Int) raises -> Bool:
        """Reads the next frame into memory the caller owns (frame_len() UInt32s at `addr`: e.g. pinned memory a GPU
        copies from); False at the end of the video."""
        if self._fp == 0:
            self._start(self._at)
        var want = self.frame_len() * 4
        var got = _fread(self._fp, addr, want)
        if got < want:
            self._stop()
            return False
        self._at += 1
        return True

    def next(mut self) raises -> List[UInt32]:
        """The next frame: width x height RGBA pixels, row by row, R in the low byte. Raises at the end of the video."""
        var pixels = List[UInt32](length=self.frame_len(), fill=0)
        if not self.next_into(pixels):
            raise Error("VideoSource: end of video: " + self.path)
        return pixels^

    def position(self) -> Int:
        """Index of the frame next() returns."""
        return self._at

    def seek_frame(mut self, frame: Int) raises:
        """The next next() returns this frame (0-based; clamped to the video)."""
        var n = max(0, min(frame, max(self.frames - 1, 0)))
        if n == self._at and self._fp != 0:
            return
        self._start(n)

    def seek(mut self, seconds: Float64) raises:
        """The next next() returns the frame shown at this time."""
        self.seek_frame(Int(seconds * self.fps + 0.0001))

    def read(mut self, frame: Int) raises -> List[UInt32]:
        """Frame `frame` (0-based): the next one when it follows the last read, a seek otherwise."""
        self.seek_frame(frame)
        return self.next()

    def close(mut self):
        self._stop()


def _rate(s: String) -> Float64:
    """ffprobe's "30000/1001" or "30/1" as frames per second (0 when unknown)."""
    var slash = s.find("/")
    if slash < 0:
        return max(_num(s), 0.0)
    var a = _num(String(s[byte = :slash]))
    var b = _num(String(s[byte = slash + 1 :]))
    if a <= 0 or b <= 0:
        return 0.0
    return a / b
