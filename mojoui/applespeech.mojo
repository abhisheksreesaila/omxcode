# mojoui.applespeech: Apple's on-device speech recogniser for mojoui.dictation on a Mac (goal 82 M5). SFSpeechRecognizer
# with requiresOnDeviceRecognition (nothing leaves the Mac, nothing to download), fed 16 kHz mono samples (the
# microphone's, through AVAudioEngine, or a recording's) as AVAudioPCMBuffers; its results arrive on an operation queue of
# their own and wait in a small mutex-guarded slot until the UI thread polls. Frameworks are opened at run time (dlopen),
# every call goes through the Objective-C runtime (mojoui.hosts.objc), as mojoui.avmedia does.
#
#   var a = apple_begin("en-US")     # (session address, "") or (0, why: not allowed yet, no on-device model for the language)
#   apple_feed(a[0], samples)        # any time; copied into a buffer the recogniser keeps
#   var got = apple_poll(a[0])       # (List[SpeechEvent], why): PARTIAL = the words so far (they may change), FINAL at the end
#   apple_end(a[0])                  # no more audio: the FINAL follows
#   apple_free(a[0])
#
# Permission: the recogniser needs the person's yes (System Settings → Privacy & Security → Speech Recognition), which
# macOS asks for once, and only for an app whose Info.plist says why (NSSpeechRecognitionUsageDescription). apple_begin
# asks when the answer is "not determined" and $MOJOUI_SPEECH_ASK isn't 0 (a bare test program has no Info.plist and
# would be killed for asking, so tests set it to 0 and report "not allowed yet").
# Call only on a Mac (comptime if CompilationTarget.is_macos()): elsewhere these symbols don't exist.

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.atomic import Atomic
from std.os import getenv
from mojoui.hosts.objc import cls, msg, ns_string, from_ns, data_block, block_data, global_block, pool_push
from mojoui.hosts.apple_canvas import cfunc
from mojoui.speech import SpeechEvent, PARTIAL, FINAL
from mojoui.audio import RATE
from mojoui import libc

comptime _FRAMEWORKS = "/System/Library/Frameworks/"
comptime _TEXT = 16384  # the slot's text bytes (a minute of dictation is well under)
# the slot: [0] mutex (64 bytes) | [8] seq | [9] final | [10] failed | [11] length | [12] recognizer | [13] request | [14] task | [15] format | text…
comptime _SEQ = 8
comptime _FINAL = 9
comptime _FAILED = 10
comptime _LEN = 11
comptime _RECOGNIZER = 12
comptime _REQUEST = 13
comptime _TASK = 14
comptime _FORMAT = 15
comptime _SEEN = 16  # the seq the UI thread last turned into an event
comptime _HEAD = 17  # words before the text
comptime _A = Atomic[Scalar[DType.int64]]


def _load():
    for name in ["Speech", "AVFAudio", "AVFoundation"]:
        var path = String(_FRAMEWORKS) + name + ".framework/" + name
        var c = path.as_c_string_span()
        _ = cfunc("dlopen", Int(c.unsafe_ptr()), Int32(2 | 8))
        _ = path.byte_length()


def _w(slot: Int, k: Int) -> Pointer[Int64, MutUntrackedOrigin]:
    return Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=slot + 8 * k)


def _on_result(block: Int, result: Int, error: Int) abi("C"):
    """The recogniser's result handler (its own queue): the newest words into the slot."""
    var slot = block_data(block)
    _ = libc.pthread_mutex_lock(slot)
    if result != 0:
        var best = msg(result, "bestTranscription")
        var text = from_ns(msg(best, "formattedString")) if best != 0 else String("")
        var n = min(text.byte_length(), _TEXT - 1)
        var bytes = text.as_bytes()
        for i in range(n):
            Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=slot + 8 * _HEAD + i)[] = bytes[i]
        _w(slot, _LEN)[] = Int64(n)
        if msg[Int8](result, "isFinal") != 0:
            _w(slot, _FINAL)[] = 1
        _w(slot, _SEQ)[] = _w(slot, _SEQ)[] + 1
    elif error != 0:
        _w(slot, _FAILED)[] = Int64(msg(error, "code"))
        _w(slot, _FINAL)[] = 1  # (an error ends the session too: nothing more will come)
        _w(slot, _SEQ)[] = _w(slot, _SEQ)[] + 1
    _ = libc.pthread_mutex_unlock(slot)


def _noop(block: Int, status: Int) abi("C"):
    pass


def apple_status() -> Int:
    """SFSpeechRecognizer's authorization: 0 not determined, 1 denied, 2 restricted, 3 authorized."""
    _load()
    return msg(cls("SFSpeechRecognizer"), "authorizationStatus")


def apple_begin(locale: String) -> Tuple[Int, String]:
    _load()
    var pool = pool_push()
    var status = apple_status()
    if status == 0 and getenv("MOJOUI_SPEECH_ASK", "1") != "0":
        _ = msg(cls("SFSpeechRecognizer"), "requestAuthorization:", global_block(_noop, "v12@?0q8"))
        return (0, "macOS is asking for permission to recognise speech: allow it, then hold the mic again")
    if status != 3:
        var what = "not allowed yet" if status == 0 else ("turned off" if status == 1 else "restricted on this Mac")
        return (0, "speech recognition is " + what + " (System Settings → Privacy & Security → Speech Recognition)")
    var rec: Int
    if locale != "":
        var loc = msg(msg(cls("NSLocale"), "alloc"), "initWithLocaleIdentifier:", ns_string(locale))
        rec = msg(msg(cls("SFSpeechRecognizer"), "alloc"), "initWithLocale:", loc)
    else:
        rec = msg(msg(cls("SFSpeechRecognizer"), "alloc"), "init")
    if rec == 0:
        return (0, "no speech recogniser for " + (locale if locale != "" else "this Mac's language"))
    if msg[Int8](rec, "supportsOnDeviceRecognition") == 0:
        return (0, "this Mac has no on-device speech model for " + (locale if locale != "" else "its language") + " (System Settings → Keyboard → Dictation can download it)")
    var queue = msg(msg(cls("NSOperationQueue"), "alloc"), "init")
    _ = msg(rec, "setQueue:", queue)
    var req = msg(msg(cls("SFSpeechAudioBufferRecognitionRequest"), "alloc"), "init")
    _ = msg(req, "setRequiresOnDeviceRecognition:", 1)
    _ = msg(req, "setShouldReportPartialResults:", 1)
    var slot = Int(unsafe_alloc[UInt8](8 * _HEAD + _TEXT))
    for k in range(_HEAD):
        _w(slot, k)[] = 0
    _ = libc.pthread_mutex_init(slot)
    _w(slot, _RECOGNIZER)[] = Int64(rec)
    _w(slot, _REQUEST)[] = Int64(req)
    # AVAudioPCMFormatFloat32 = 1, 16 kHz, mono, not interleaved
    var fmt = msg(msg(cls("AVAudioFormat"), "alloc"), "initWithCommonFormat:sampleRate:channels:interleaved:", 1, Float64(RATE), UInt32(1), 0)
    _w(slot, _FORMAT)[] = Int64(fmt)
    var task = msg(rec, "recognitionTaskWithRequest:resultHandler:", req, data_block(_on_result, "v24@?0@8@16", slot))
    _w(slot, _TASK)[] = Int64(task)
    _ = cfunc("objc_autoreleasePoolPop", pool)
    if task == 0:
        return (0, "the speech recogniser didn't start")
    return (slot, String(""))


def apple_feed(slot: Int, samples: List[Float32]):
    if len(samples) == 0:
        return
    var pool = pool_push()
    var fmt = Int(_w(slot, _FORMAT)[])
    var buf = msg(msg(cls("AVAudioPCMBuffer"), "alloc"), "initWithPCMFormat:frameCapacity:", fmt, UInt32(len(samples)))
    var channels = msg(buf, "floatChannelData")  # float * const * : channel 0's samples
    var ch0 = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=channels)[]
    for i in range(len(samples)):
        Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=ch0 + 4 * i)[] = samples[i]
    _ = msg(buf, "setFrameLength:", UInt32(len(samples)))
    _ = msg(Int(_w(slot, _REQUEST)[]), "appendAudioPCMBuffer:", buf)
    _ = msg(buf, "release")
    _ = cfunc("objc_autoreleasePoolPop", pool)


def apple_end(slot: Int):
    _ = msg(Int(_w(slot, _REQUEST)[]), "endAudio")


def apple_poll(slot: Int) -> Tuple[List[SpeechEvent], String]:
    var out = List[SpeechEvent]()
    var why = String("")
    _ = libc.pthread_mutex_lock(slot)
    var seq = _w(slot, _SEQ)[]
    if seq != _w(slot, _SEEN)[]:
        _w(slot, _SEEN)[] = seq
        var n = Int(_w(slot, _LEN)[])
        var bytes = List[UInt8](capacity=n)
        for i in range(n):
            bytes.append(Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=slot + 8 * _HEAD + i)[])
        var text = String(unsafe_from_utf8=Span(bytes))
        var final = _w(slot, _FINAL)[] != 0
        var failed = Int(_w(slot, _FAILED)[])
        if failed != 0 and n == 0:
            why = "the speech recogniser stopped (error " + String(failed) + ")"
        out.append(SpeechEvent(FINAL if final else PARTIAL, text^, 0.0, 0, 0))
    _ = libc.pthread_mutex_unlock(slot)
    return (out^, why^)


def apple_free(slot: Int):
    var task = Int(_w(slot, _TASK)[])
    if task != 0:
        _ = msg(task, "cancel")
    # (the recogniser, request and task belong to their queue until it lets go; the slot stays for a late result: a few
    # hundred bytes and 16 KB a session, kept for the process's life rather than freed under a handler that may still run)
