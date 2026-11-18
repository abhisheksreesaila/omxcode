# mojoui.voice: the mouth and the turn-taking (goal 72 M2); the ears are SpeechModel("parakeet") in mojoui.speech and the
# speaker is mojoui.speaker. Models run in the app's own process through Mojo's Python interop (backends:
# mojoui/voice_kokoro.py and mojoui/vad_silero.py), each on a thread of its own, so the UI thread never waits on a model.
#
#   var voice = Voice()                              # Kokoro-82M on the GPU, voice af_heart, warmed up
#   var job = voice.say("Hello. How can I help?")    # returns at once; the audio comes back clause by clause
#   for c in voice.poll(): speaker.play(c.samples, c.rate)       # VoiceChunk; or voice.pump(speaker) does just that
#   voice.cancel()                                   # barge-in: nothing more is made (speaker.stop() drops what plays)
#
#   var ep = Endpointer()                            # Silero VAD: mic frames in, turn events out
#   ep.feed(mic.read(since), mic.captured_ns(total - 1), speaker.playing())     # returns at once
#   for e in ep.poll(): ...                          # START, BARGE (speech over the speaker's voice), END (+ the audio)
#
# The interpreter's lock is handled as in mojoui.speech (this file shares its helpers). Other hosts: needs CPython with
# torch, kokoro and silero-vad beside the app (the `voice` pixi environment); Mac/iPhone/web: not run.

from std.python import Python, PythonObject
from std.atomic import Atomic
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.reflection import source_location
from std.sys import CompilationTarget
from mojoui.speech import _enter, _leave, _fail, _give_up_lock, _NOT_HERE
from mojoui.speaker import Speaker

comptime START = 0  # the person began to speak
comptime BARGE = 1  # they kept speaking while the speaker played: stop it
comptime END = 2  # they stopped (after the hangover): the utterance's audio rides along
comptime _A = Atomic[Scalar[DType.int64]]


def _module(file: String, name: String) raises -> PythonObject:
    """mojoui/<file>, loaded from its file once ($MOJOUI_PY, a folder, if set, else this source file's folder)."""
    comptime if CompilationTarget.is_linux():
        var sys = Python.import_module("sys")
        if Bool(py=sys.modules.__contains__(name)):
            return sys.modules[name]
        var os = Python.import_module("os")
        var folder = getenv("MOJOUI_PY", "")
        if folder.byte_length() == 0:
            folder = String(py=os.path.dirname(os.path.abspath(source_location().file_name())))
        var path = os.path.join(folder, file)
        if not Bool(py=os.path.isfile(path)):
            raise Error("voice: no backend at " + String(py=path) + " (set MOJOUI_PY to the folder of " + file + ")")
        var util = Python.import_module("importlib.util")
        var spec = util.spec_from_file_location(name, path)
        var mod = util.module_from_spec(spec)
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
        mod.OBJECTS = Python.list()
        return mod
    else:
        raise Error(_NOT_HERE)


def _keep(mod: PythonObject, obj: PythonObject) raises -> Int:
    var n = Int(py=Python.import_module("builtins").len(mod.OBJECTS))
    mod.OBJECTS.append(obj)
    return n


def _samples(arr: PythonObject) raises -> List[Float32]:
    """A float32 numpy array's samples, copied."""
    var n = Int(py=Python.import_module("builtins").len(arr))
    var out = List[Float32]()
    out.reserve(n)
    if n > 0:
        var p = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(py=arr.ctypes.data))
        for i in range(n):
            out.append(p.unsafe_offset(i)[])
    return out^


# The Python side of each call, run with the lock held (their Python objects die when they return or raise: D-1417).

def _py_voice(voice: String, device: String, flag: Int, wait: Bool) raises -> Int:
    var mod = _module("voice_kokoro.py", "mojoui_voice_kokoro")
    return _keep(mod, mod.Voice(voice, device, flag, not wait))


def _py_endpointer() raises -> Int:
    var mod = _module("vad_silero.py", "mojoui_vad_silero")
    return _keep(mod, mod.Endpointer())


def _py_say(id: Int, text: String, voice: String, speed: Float64) raises -> Int:
    return Int(py=_module("voice_kokoro.py", "mojoui_voice_kokoro").OBJECTS[id].say(text, voice, speed))


def _py_attr(file: String, name: String, id: Int, attr: String) raises -> String:
    return String(py=Python.import_module("builtins").getattr(_module(file, name).OBJECTS[id], attr))


def _py_call(file: String, name: String, id: Int, method: String) raises:
    _ = Python.import_module("builtins").getattr(_module(file, name).OBJECTS[id], method)()


def _py_poll_voice(id: Int) raises -> List[VoiceChunk]:
    var out = List[VoiceChunk]()
    for c in _module("voice_kokoro.py", "mojoui_voice_kokoro").OBJECTS[id].poll():
        out.append(VoiceChunk(Int(py=c[0]), Int(py=c[1]), Bool(py=c[2]), String(py=c[3]), Int(py=c[4]), Int(py=c[5]),
                              _samples(c[6]), 24000))
    return out^


def _py_feed(id: Int, addr: Int, n: Int, captured_ns: Int, playing: Bool) raises:
    _ = _module("vad_silero.py", "mojoui_vad_silero").OBJECTS[id].feed_address(addr, n, captured_ns, playing)


def _py_poll_ep(id: Int) raises -> List[TurnEvent]:
    var out = List[TurnEvent]()
    for e in _module("vad_silero.py", "mojoui_vad_silero").OBJECTS[id].poll():
        var kind = START if String(py=e[0]) == "start" else (BARGE if String(py=e[0]) == "barge" else END)
        var audio = _samples(e[2])
        out.append(TurnEvent(kind, Int(py=e[1]), audio^))
    return out^


@fieldwise_init
struct VoiceChunk(Copyable, Movable):
    """One clause's audio. `done`: the job is over (no samples). Times are now_ns()'s clock: say_ns when say() was called,
    ready_ns when the clause's audio was finished."""

    var job: Int
    var seq: Int
    var done: Bool
    var text: String
    var say_ns: Int
    var ready_ns: Int
    var samples: List[Float32]
    var rate: Int


@fieldwise_init
struct TurnEvent(Copyable, Movable):
    """START / BARGE / END at `ns` (now_ns()'s clock; when the speech was captured if feed() was given capture times).
    END carries the utterance's samples (16 kHz, with 0.3 s before the first word); START's first sample is 1.0 when the
    speaker was playing."""

    var kind: Int
    var ns: Int
    var samples: List[Float32]


struct Voice(Movable):
    """Kokoro-82M text to speech. wait=False: loads on a thread of the backend's own and the caller asks ready()."""

    var _id: Int
    var _flag: Int  # an int64 the backend sets: 0 loading, 1 ready, -1 failed

    def __init__(out self, voice: String = "af_heart", device: String = "cuda", wait: Bool = True) raises:
        comptime if CompilationTarget.is_linux():
            var flag = unsafe_alloc[Int64](1)
            flag[] = 0
            self._flag = Int(flag)
            self._id = -1
            var g = _enter()
            try:
                self._id = _py_voice(voice, device, self._flag, wait)
            except e:
                flag.unsafe_free()
                _fail(g, e)
            _leave(g)
            _give_up_lock()
        else:
            raise Error(_NOT_HERE)

    def ready(self) -> Bool:
        return Int(_A.load(Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=self._flag))) == 1

    def failed(self) -> Bool:
        return Int(_A.load(Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=self._flag))) == -1

    def _attr(self, attr: String) raises -> String:
        var g = _enter()
        var v = String()
        try:
            v = _py_attr("voice_kokoro.py", "mojoui_voice_kokoro", self._id, attr)
        except e:
            _fail(g, e)
        _leave(g)
        return v

    def why(self) raises -> String:
        return self._attr("error")

    def gpu(self) raises -> String:
        return self._attr("gpu")

    def load_ms(self) raises -> Float64:
        return atof(self._attr("load_ms"))

    def say(self, text: String, voice: String = "", speed: Float64 = 0.0) raises -> Int:
        """Queues `text` (clause by clause); returns its job id at once. Audio comes back through poll()."""
        var g = _enter()
        var job = 0
        try:
            job = _py_say(self._id, text, voice, speed)
        except e:
            _fail(g, e)
        _leave(g)
        return job

    def poll(self) raises -> List[VoiceChunk]:
        var out = List[VoiceChunk]()
        var g = _enter()
        try:
            out = _py_poll_voice(self._id)
        except e:
            _fail(g, e)
        _leave(g)
        return out^

    def pump(self, mut speaker: Speaker) raises -> Int:
        """poll() and hand every clause to `speaker`; returns the samples sent."""
        var sent = 0
        for c in self.poll():
            speaker.play(c.samples, c.rate)
            sent += len(c.samples)
        return sent

    def cancel(self) raises:
        """Barge-in: jobs so far make no more audio (a clause being made is dropped when it is done)."""
        var g = _enter()
        try:
            _py_call("voice_kokoro.py", "mojoui_voice_kokoro", self._id, "cancel")
        except e:
            _fail(g, e)
        _leave(g)


struct Endpointer(Movable):
    """Silero VAD turn-taking: feed microphone samples, poll for START / BARGE / END."""

    var _id: Int

    def __init__(out self) raises:
        comptime if CompilationTarget.is_linux():
            self._id = -1
            var g = _enter()
            try:
                self._id = _py_endpointer()
            except e:
                _fail(g, e)
            _leave(g)
            _give_up_lock()
        else:
            raise Error(_NOT_HERE)

    def feed_address(self, addr: Int, n: Int, captured_ns: Int = 0, playing: Bool = False) raises:
        """n float32 samples at 16 kHz at addr (copied before it returns). captured_ns: when the last was captured
        (Microphone.captured_ns), 0: now. playing: the speaker is playing (so speech over it is a barge-in)."""
        if n <= 0:
            return
        var g = _enter()
        try:
            _py_feed(self._id, addr, n, captured_ns, playing)
        except e:
            _fail(g, e)
        _leave(g)

    def feed(self, samples: List[Float32], captured_ns: Int = 0, playing: Bool = False) raises:
        self.feed_address(Int(samples.unsafe_ptr()), len(samples), captured_ns, playing)

    def poll(self) raises -> List[TurnEvent]:
        var out = List[TurnEvent]()
        var g = _enter()
        try:
            out = _py_poll_ep(self._id)
        except e:
            _fail(g, e)
        _leave(g)
        return out^

    def close(self) raises:
        var g = _enter()
        try:
            _py_call("vad_silero.py", "mojoui_vad_silero", self._id, "close")
        except e:
            _fail(g, e)
        _leave(g)
