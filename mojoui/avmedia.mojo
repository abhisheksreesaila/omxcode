# mojoui.avmedia: video and pictures on a Mac through the system's own frameworks (goal 58): AVFoundation decodes a
# video (VideoToolbox underneath, the Apple GPU's media engine), ImageIO reads a still. A Mac has no ffmpeg, which
# mojoui.video, mojoui.picture and mojoui.videoexport use everywhere else ("Couldn't open F00118.mp4: not a video" on
# the owner's Mac, D-5612), so on a Mac those call this instead and keep their own API. Nothing new is linked: the
# frameworks are opened at run time (dlopen) and every call goes through the Objective-C runtime or dlsym.
#
#   var info = av_probe(path)                      # width, height, fps, frames, duration (raises: not a video)
#   var r = AvReader(path, info, frame)            # decodes from `frame` on
#   r.next_into_address(addr)                      # one RGBA frame (R in the low byte) into width × height UInt32s
#   var px = av_picture(path)                      # (pixels, width, height) of a still: PNG, JPEG, WebP, GIF, HEIC…
#
# Call these only on a Mac (comptime if CompilationTarget.is_macos()): on Linux their symbols don't exist.
# Structs: arm64 passes a struct over 16 bytes (CMTime 24, CMTimeRange 48) by a pointer to a copy, so they are written
# into memory here and their address passed; CGSize (two doubles) comes back in registers, as CGPoint.

from std.memory import Pointer
from mojoui.hosts.objc import cls, msg, ns_string, pool_push
from mojoui import libc
from mojoui.hosts.apple_canvas import cfunc, CGPoint

comptime _FRAMEWORKS = "/System/Library/Frameworks/"
comptime _BGRA = 0x42475241  # kCVPixelFormatType_32BGRA ('BGRA')


def _load():
    """The frameworks this module calls, opened once (RTLD_NOW | RTLD_GLOBAL; a second dlopen is a no-op)."""
    for name in ["AVFoundation", "CoreMedia", "CoreVideo", "ImageIO", "CoreGraphics"]:
        var path = String(_FRAMEWORKS) + name + ".framework/" + name
        var c = path.as_c_string_span()
        _ = cfunc("dlopen", Int(c.unsafe_ptr()), Int32(2 | 8))  # (through dlsym: other modules declare dlopen with their own signature)
        _ = path.byte_length()


def _pool_pop(pool: Int):
    """Drains an autorelease pool (pool_push's): a decoder's thread has none of its own, so each open and each frame
    gets one, and nothing autoreleased piles up over a long scrub."""
    _ = cfunc("objc_autoreleasePoolPop", pool)


def _url(path: String) -> Int:
    return msg(cls("NSURL"), "fileURLWithPath:", ns_string(path))


@fieldwise_init
struct AvInfo(Copyable, Movable, ImplicitlyCopyable):
    var width: Int
    var height: Int
    var fps: Float64
    var frames: Int
    var duration: Float64


def _seconds(value: Int) -> Float64:
    """A CMTime boxed in an NSValue, in seconds (its value / timescale; 0 when it isn't a number)."""
    var t = List[Int64](length=3, fill=0)  # value (int64), timescale + flags (int32 each), epoch (int64)
    _ = msg(value, "getValue:size:", Int(t.unsafe_ptr()), 24)
    var timescale = Int(t[1] & 0xFFFFFFFF)
    var flags = Int((t[1] >> 32) & 0xFFFFFFFF)
    if timescale <= 0 or (flags & 1) == 0:
        return 0.0
    return Float64(Int(t[0])) / Float64(timescale)


def _video_track(asset: Int) -> Int:
    var tracks = msg(asset, "tracksWithMediaType:", ns_string("vide"))  # AVMediaTypeVideo
    if tracks == 0 or msg(tracks, "count") == 0:
        return 0
    return msg(tracks, "objectAtIndex:", 0)


def av_probe(path: String) raises -> AvInfo:
    """The video's size, rate, frame count and length (AVFoundation's answers; frames = duration × fps, rounded)."""
    _load()
    var asset = msg(cls("AVURLAsset"), "URLAssetWithURL:options:", _url(path), 0)
    var track = _video_track(asset) if asset != 0 else 0
    if track == 0:
        raise Error("VideoSource: not a video (no picture stream found): " + path)
    var size = msg[CGPoint](track, "naturalSize")  # (CGSize: width, height)
    var fps = Float64(msg[Float32](track, "nominalFrameRate"))
    var duration = _seconds(msg(asset, "valueForKey:", ns_string("duration")))
    if size.x <= 0 or size.y <= 0:
        raise Error("VideoSource: not a video (no picture stream found): " + path)
    if fps <= 0:
        raise Error("VideoSource: cannot tell the frame rate of " + path)
    return AvInfo(Int(size.x + 0.5), Int(size.y + 0.5), fps, Int(duration * fps + 0.5), duration)


struct AvReader(Copyable, Movable):
    """Frames from `frame` on, decoded by AVAssetReader as BGRA and handed out as RGBA. Plain handles, closed by close()
    (no destructor: a Linux build holding an empty one never touches the Objective-C runtime)."""
    var reader: Int
    var output: Int
    var width: Int
    var height: Int

    @staticmethod
    def none() -> AvReader:
        return AvReader(0, 0, 0, 0)

    def __init__(out self, reader: Int, output: Int, width: Int, height: Int):
        self.reader = reader
        self.output = output
        self.width = width
        self.height = height

    def open(self) -> Bool:
        return self.reader != 0

    def __init__(out self, path: String, info: AvInfo, frame: Int) raises:
        _load()
        var pool = pool_push()
        self.width = info.width
        self.height = info.height
        self.reader = 0
        self.output = 0
        var asset = msg(cls("AVURLAsset"), "URLAssetWithURL:options:", _url(path), 0)
        var track = _video_track(asset) if asset != 0 else 0
        if track == 0:
            _pool_pop(pool)
            raise Error("VideoSource: not a video (no picture stream found): " + path)
        var err = List[Int](length=1, fill=0)
        self.reader = msg(msg(cls("AVAssetReader"), "alloc"), "initWithAsset:error:", asset, Int(err.unsafe_ptr()))
        if self.reader == 0:
            _pool_pop(pool)
            raise Error("VideoSource: AVFoundation can't read " + path)
        var settings = msg(cls("NSDictionary"), "dictionaryWithObject:forKey:", msg(cls("NSNumber"), "numberWithInt:", Int32(_BGRA)),
                           ns_string("PixelFormatType"))  # kCVPixelBufferPixelFormatTypeKey
        self.output = msg(msg(cls("AVAssetReaderTrackOutput"), "alloc"), "initWithTrack:outputSettings:", track, settings)
        _ = msg(self.output, "setAlwaysCopiesSampleData:", 0)
        _ = msg(self.reader, "addOutput:", self.output)
        if frame > 0:  # from a quarter frame into frame n, to the end: AVAssetReader starts at the frame whose span holds the
            # start (ffmpeg's -ss drops the frames before it, so VideoSource asks half a frame early there; here that gave n - 1)
            var t = (Float64(frame) + 0.25) / info.fps
            var range = List[Int64](length=6, fill=0)  # CMTimeRange: start {value, timescale|flags, epoch}, duration {…}
            range[0] = Int64(Int(t * 600000.0))
            range[1] = Int64(600000) | (Int64(1) << 32)  # timescale 600000, kCMTimeFlags_Valid
            range[3] = 0
            range[4] = Int64(0) | (Int64(1 | 4) << 32)  # kCMTimePositiveInfinity: Valid | PositiveInfinity
            _ = msg(self.reader, "setTimeRange:", Int(range.unsafe_ptr()))
            _ = len(range)
        var started = (msg(self.reader, "startReading") & 0xFF) != 0
        _pool_pop(pool)
        if not started:  # (past the end, or a file AVFoundation can't decode: nothing left open)
            self.close()
            raise Error("VideoSource: AVFoundation couldn't start reading " + path)

    def close(mut self):
        if self.reader != 0:
            _ = msg(self.reader, "cancelReading")
            _ = msg(self.output, "release")
            _ = msg(self.reader, "release")
            self.reader = 0
            self.output = 0

    def next_into_address(mut self, addr: Int) -> Bool:
        """The next frame as RGBA into width × height UInt32s at `addr`; False at the end."""
        var pool = pool_push()
        var sample = msg(self.output, "copyNextSampleBuffer")
        _pool_pop(pool)
        if sample == 0:
            return False
        var image = cfunc("CMSampleBufferGetImageBuffer", sample)
        if image == 0:
            cfunc[NoneType]("CFRelease", sample)
            return False
        _ = cfunc[Int32]("CVPixelBufferLockBaseAddress", image, UInt64(1))  # kCVPixelBufferLock_ReadOnly
        var base = cfunc("CVPixelBufferGetBaseAddress", image)
        var stride = cfunc("CVPixelBufferGetBytesPerRow", image)
        var w = min(cfunc("CVPixelBufferGetWidth", image), self.width)
        var h = min(cfunc("CVPixelBufferGetHeight", image), self.height)
        var dst = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=addr)
        for y in range(h):
            var row = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=base + y * stride)
            var out = y * self.width
            for x in range(w):
                var p = row.unsafe_offset(x)[]  # bytes B, G, R, A: as a little-endian UInt32, 0xAARRGGBB
                dst.unsafe_offset(out + x)[] = (p & 0xFF00FF00) | ((p >> 16) & 0xFF) | ((p & 0xFF) << 16)
        _ = cfunc[Int32]("CVPixelBufferUnlockBaseAddress", image, UInt64(1))
        cfunc[NoneType]("CFRelease", sample)
        return True


def is_still(path: String) -> Bool:
    """A file ImageIO reads as a picture (PNG, JPEG, WebP, GIF, HEIC, TIFF…), not a video."""
    var lower = path.lower()
    for ext in [".png", ".jpg", ".jpeg", ".webp", ".gif", ".heic", ".tif", ".tiff", ".bmp"]:
        if lower.endswith(ext):
            return True
    return False


def av_picture(path: String) raises -> Tuple[List[UInt32], Int, Int]:
    """A still's first picture as straight RGBA (R in the low byte), drawn through ImageIO and CoreGraphics."""
    _load()
    var src = cfunc("CGImageSourceCreateWithURL", _url(path), 0)
    if src == 0:
        raise Error("Picture: can't read " + path)
    var image = cfunc("CGImageSourceCreateImageAtIndex", src, 0, 0)
    cfunc[NoneType]("CFRelease", src)
    if image == 0:
        raise Error("Picture: no picture in " + path)
    var w = cfunc("CGImageGetWidth", image)
    var h = cfunc("CGImageGetHeight", image)
    var pixels = List[UInt32](length=w * h, fill=0)
    var space = cfunc("CGColorSpaceCreateDeviceRGB")
    # premultiplied RGBA (the only 8-bit RGBA CoreGraphics draws into), un-premultiplied below
    var ctx = cfunc("CGBitmapContextCreate", Int(pixels.unsafe_ptr()), w, h, 8, w * 4, space, UInt32(1))  # kCGImageAlphaPremultipliedLast
    cfunc[NoneType]("CGContextDrawImage", ctx, Float64(0), Float64(0), Float64(w), Float64(h), image)
    cfunc[NoneType]("CGContextRelease", ctx)
    cfunc[NoneType]("CGColorSpaceRelease", space)
    cfunc[NoneType]("CGImageRelease", image)
    for i in range(len(pixels)):
        var p = pixels[i]
        var a = Int((p >> 24) & 0xFF)
        if 0 < a < 255:
            var r = min(255, (Int(p & 0xFF) * 255 + a // 2) // a)
            var g = min(255, (Int((p >> 8) & 0xFF) * 255 + a // 2) // a)
            var b = min(255, (Int((p >> 16) & 0xFF) * 255 + a // 2) // a)
            pixels[i] = UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(a) << 24)
    return (pixels^, w, h)


struct AvWriter(Copyable, Movable):
    """Frames in, an H.264 .mp4 out, through AVAssetWriter (the Apple media engine encodes). Plain handles, finished
    by close() (no destructor, as AvReader). RGBA frames (R in the low byte) are copied into BGRA pixel buffers."""
    var writer: Int
    var input: Int
    var adaptor: Int
    var width: Int
    var height: Int
    var timescale: Int  # frame n's time is n × 1000 / timescale seconds (timescale = fps × 1000)
    var frames: Int

    @staticmethod
    def none() -> AvWriter:
        return AvWriter(0, 0, 0, 0, 0, 0, 0)

    def __init__(out self, writer: Int, input: Int, adaptor: Int, width: Int, height: Int, timescale: Int, frames: Int):
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.width = width
        self.height = height
        self.timescale = timescale
        self.frames = frames

    def __init__(out self, path: String, width: Int, height: Int, fps: Float64) raises:
        _load()
        self.width = width
        self.height = height
        self.timescale = max(Int(fps * 1000.0 + 0.5), 1)
        self.frames = 0
        var url = _url(path)
        _ = msg(msg(cls("NSFileManager"), "defaultManager"), "removeItemAtURL:error:", url, 0)  # (AVAssetWriter won't overwrite)
        var err = List[Int](length=1, fill=0)
        self.writer = msg(msg(cls("AVAssetWriter"), "alloc"), "initWithURL:fileType:error:", url, ns_string("public.mpeg-4"), Int(err.unsafe_ptr()))
        if self.writer == 0:
            raise Error("VideoWriter: AVFoundation can't write " + path)
        var keys = msg(cls("NSMutableDictionary"), "dictionary")
        _ = msg(keys, "setObject:forKey:", ns_string("avc1"), ns_string("AVVideoCodecKey"))  # H.264
        _ = msg(keys, "setObject:forKey:", msg(cls("NSNumber"), "numberWithLong:", width), ns_string("AVVideoWidthKey"))
        _ = msg(keys, "setObject:forKey:", msg(cls("NSNumber"), "numberWithLong:", height), ns_string("AVVideoHeightKey"))
        self.input = msg(msg(cls("AVAssetWriterInput"), "alloc"), "initWithMediaType:outputSettings:", ns_string("vide"), keys)
        _ = msg(self.input, "setExpectsMediaDataInRealTime:", 0)
        var attrs = msg(cls("NSMutableDictionary"), "dictionary")
        _ = msg(attrs, "setObject:forKey:", msg(cls("NSNumber"), "numberWithInt:", Int32(_BGRA)), ns_string("PixelFormatType"))
        _ = msg(attrs, "setObject:forKey:", msg(cls("NSNumber"), "numberWithLong:", width), ns_string("Width"))
        _ = msg(attrs, "setObject:forKey:", msg(cls("NSNumber"), "numberWithLong:", height), ns_string("Height"))
        self.adaptor = msg(msg(cls("AVAssetWriterInputPixelBufferAdaptor"), "alloc"), "initWithAssetWriterInput:sourcePixelBufferAttributes:", self.input, attrs)
        _ = msg(self.writer, "addInput:", self.input)
        if (msg(self.writer, "startWriting") & 0xFF) == 0:
            _ = msg(self.adaptor, "release")
            _ = msg(self.input, "release")
            _ = msg(self.writer, "release")
            self.writer = 0
            raise Error("VideoWriter: AVFoundation couldn't start writing " + path)
        var zero = List[Int64](length=3, fill=0)  # CMTime 0: value 0, timescale 1 | valid
        zero[1] = Int64(1) | (Int64(1) << 32)
        _ = msg(self.writer, "startSessionAtSourceTime:", Int(zero.unsafe_ptr()))
        _ = len(zero)

    def write_address(mut self, addr: Int) raises:
        """One frame: width × height RGBA UInt32s at `addr`."""
        var waited = 0
        while (msg(self.input, "isReadyForMoreMediaData") & 0xFF) == 0:  # (the encoder catches up)
            if msg(self.writer, "status") == 3:  # AVAssetWriterStatusFailed: it won't ever be ready
                raise Error("VideoWriter: AVFoundation failed writing frame " + String(self.frames))
            _ = libc.usleep(1000)
            waited += 1
            if waited > 10000:
                raise Error("VideoWriter: the encoder stopped taking frames")
        var pool = msg(self.adaptor, "pixelBufferPool")
        var out = List[Int](length=1, fill=0)
        if pool == 0 or cfunc[Int32]("CVPixelBufferPoolCreatePixelBuffer", 0, pool, Int(out.unsafe_ptr())) != 0 or out[0] == 0:
            raise Error("VideoWriter: no pixel buffer for frame " + String(self.frames))
        var pb = out[0]
        _ = cfunc[Int32]("CVPixelBufferLockBaseAddress", pb, UInt64(0))
        var base = cfunc("CVPixelBufferGetBaseAddress", pb)
        var stride = cfunc("CVPixelBufferGetBytesPerRow", pb)
        var src = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=addr)
        for y in range(self.height):
            var row = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=base + y * stride)
            for x in range(self.width):
                var p = src.unsafe_offset(y * self.width + x)[]  # RGBA → BGRA (R and B swap)
                row.unsafe_offset(x)[] = (p & 0xFF00FF00) | ((p >> 16) & 0xFF) | ((p & 0xFF) << 16)
        _ = cfunc[Int32]("CVPixelBufferUnlockBaseAddress", pb, UInt64(0))
        var t = List[Int64](length=3, fill=0)  # CMTime: frames × 1000 / timescale
        t[0] = Int64(self.frames * 1000)
        t[1] = Int64(self.timescale) | (Int64(1) << 32)
        var ok = msg(self.adaptor, "appendPixelBuffer:withPresentationTime:", pb, Int(t.unsafe_ptr())) & 0xFF
        _ = len(t)
        cfunc[NoneType]("CVPixelBufferRelease", pb)
        if ok == 0:
            raise Error("VideoWriter: AVFoundation refused frame " + String(self.frames))
        self.frames += 1

    def close(mut self) raises:
        """Finishes the file (moov written); raises if AVFoundation failed."""
        if self.writer == 0:
            return
        _ = msg(self.input, "markAsFinished")
        var ok = msg(self.writer, "finishWriting") & 0xFF  # (synchronous; the completion-handler form needs a block)
        var status = msg(self.writer, "status")  # 2: completed
        _ = msg(self.adaptor, "release")
        _ = msg(self.input, "release")
        _ = msg(self.writer, "release")
        self.writer = 0
        if ok == 0 or status != 2:
            raise Error("VideoWriter: AVFoundation couldn't finish the video (status " + String(status) + ")")
