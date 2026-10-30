# mojoui.speech: a speech model in the app's own process (goal 43 M1). Whisper on the GPU through Mojo's Python interop
# (backend: mojoui/speech_torch.py, PyTorch + transformers, fp16). Samples go over as an address of float32s, read in
# place: no file, no network, no second process.
#
#   var model = SpeechModel()                              # openai/whisper-large-v3-turbo on the GPU, warmed up
#   var text = model.transcribe(samples)                   # List[Float32] at 16 kHz -> text
#   var live = SpeechStream(model)                         # dictation: a thread of the backend's own does the work
#   live.feed(mic.read(since))                             # returns at once
#   for e in live.poll(): ...                              # SpeechEvent: PARTIAL (words so far) or FINAL (at a pause)
#
# The GIL: the first SpeechModel is made on the main thread, which then gives the interpreter's lock up
# (PyEval_SaveThread), so the backend's thread runs while the UI thread is in its own loop; every call here takes the lock
# for its few lines (PyGILState_Ensure/Release) and lets it go, so the caller waits at most for the backend to reach a
# switch point (Python's switch interval, 5 ms), never for a transcription (feed and poll don't touch the model).
# Other hosts: needs CPython with torch beside the app (the `speech` pixi environment); Mac/iPhone/web: not run.

from std.python import Python, PythonObject
from std.atomic import Atomic
from std.memory.alloc import unsafe_alloc
from std.os import getenv, setenv
from std.reflection import source_location
from std.sys import CompilationTarget
from mojoui.audio import dl_call

comptime MODEL_ID = "openai/whisper-large-v3-turbo"
comptime PARTIAL = 0  # the words so far (they may still change)
comptime FINAL = 1  # the utterance is over: its text, and how long after its last word the text was ready
comptime _NOT_HERE = "no speech model on this host yet (it needs CPython with torch in the app's process: Linux)"
comptime _A = Atomic[Scalar[DType.int64]]
comptime _SAVED = "MOJOUI_SPEECH_GIL_SAVED"  # set once the main thread has given the lock up (this process)


def _enter() raises -> Int:
    """Takes the interpreter's lock if the main thread gave it up; -1: we already hold it (before the first model)."""
    comptime if CompilationTarget.is_linux():
        if getenv(_SAVED, "") == "":
            return -1
        return Int(dl_call[Int32](0, "PyGILState_Ensure"))
    else:
        raise Error(_NOT_HERE)


def _leave(state: Int) raises:
    comptime if CompilationTarget.is_linux():
        if state >= 0:
            dl_call[NoneType](0, "PyGILState_Release", Int32(state))
    else:
        raise Error(_NOT_HERE)


def _give_up_lock() raises:
    """Once, on the thread that started the interpreter: let other threads run Python while it does other things."""
    comptime if CompilationTarget.is_linux():
        if getenv(_SAVED, "") != "":
            return
        _ = dl_call[Int](0, "PyEval_SaveThread")
        _ = setenv(_SAVED, "1")
    else:
        raise Error(_NOT_HERE)


def _backend() raises -> PythonObject:
    """mojoui/speech_torch.py, loaded from its file (never through sys.path): $MOJOUI_PY (a folder) if set, else the folder
    of this source file as the compiler saw it."""
    comptime if CompilationTarget.is_linux():
        var sys = Python.import_module("sys")
        if Bool(py=sys.modules.__contains__("mojoui_speech_torch")):
            return sys.modules["mojoui_speech_torch"]
        var os = Python.import_module("os")
        var folder = getenv("MOJOUI_PY", "")
        if folder.byte_length() == 0:
            folder = String(py=os.path.dirname(os.path.abspath(source_location().file_name())))
        var path = os.path.join(folder, "speech_torch.py")
        if not Bool(py=os.path.isfile(path)):
            raise Error("SpeechModel: no backend at " + String(py=path) + " (set MOJOUI_PY to the folder of speech_torch.py)")
        var util = Python.import_module("importlib.util")
        var spec = util.spec_from_file_location("mojoui_speech_torch", path)
        var mod = util.module_from_spec(spec)
        sys.modules["mojoui_speech_torch"] = mod
        spec.loader.exec_module(mod)
        mod.OBJECTS = Python.list()  # what Mojo holds, by index (Mojo keeps ints, never Python objects, across calls)
        return mod
    else:
        raise Error(_NOT_HERE)


def _keep(mod: PythonObject, obj: PythonObject) raises -> Int:
    comptime if CompilationTarget.is_linux():
        var n = Int(py=Python.import_module("builtins").len(mod.OBJECTS))
        mod.OBJECTS.append(obj)
        return n
    else:
        raise Error(_NOT_HERE)


@fieldwise_init
struct SpeechEvent(Copyable, Movable, ImplicitlyCopyable):
    """PARTIAL: the words so far. FINAL: the utterance's text; ms = end_ns → shown_ns (its last voiced 20 ms arrived →
    this text was ready), 0 for partials while someone still speaks. Times are now_ns()'s clock (CLOCK_MONOTONIC)."""

    var kind: Int
    var text: String
    var ms: Float64
    var end_ns: Int
    var shown_ns: Int


struct SpeechModel(Movable):
    """One model, loaded once. `name`: a Hugging Face id (cached under HF_HOME) or a local folder. wait=False: it loads
    on a thread of the backend's own and the caller asks ready() (which reads a word, never the interpreter's lock)."""

    var name: String
    var _id: Int
    var _flag: Int  # an int64 the backend sets: 0 loading, 1 ready, -1 failed

    def __init__(out self, name: String = MODEL_ID, device: String = "cuda", wait: Bool = True) raises:
        comptime if CompilationTarget.is_linux():
            self.name = name
            var flag = unsafe_alloc[Int64](1)
            flag[] = 0
            self._flag = Int(flag)
            var g = _enter()
            var mod = _backend()
            self._id = _keep(mod, mod.Model(name, device, True, self._flag, not wait))
            _leave(g)
            _give_up_lock()
        else:
            raise Error(_NOT_HERE)


    def _state(self) -> Int:
        return Int(_A.load(Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=self._flag)))

    def ready(self) -> Bool:
        return self._state() == 1

    def failed(self) -> Bool:
        return self._state() == -1

    def _attr(self, name: String) raises -> String:
        comptime if CompilationTarget.is_linux():
            var g = _enter()
            var v = String(py=Python.import_module("builtins").getattr(_backend().OBJECTS[self._id], name))
            _leave(g)
            return v
        else:
            raise Error(_NOT_HERE)


    def why(self) raises -> String:
        """Why loading failed, in words."""
        return self._attr("error")

    def gpu(self) raises -> String:
        """The device's name ("NVIDIA GeForce RTX 3090", or "CPU"), once ready."""
        return self._attr("gpu")

    def load_ms(self) raises -> Float64:
        """Load + warm-up, once ready."""
        return atof(self._attr("load_ms"))

    def transcribe_address(self, addr: Int, n: Int) raises -> String:
        """The text of n float32 samples (16 kHz mono) at addr; the memory is read in place, not copied by the caller."""
        comptime if CompilationTarget.is_linux():
            var g = _enter()
            var text = String(py=_backend().OBJECTS[self._id].transcribe_address(addr, n))
            _leave(g)
            return text
        else:
            raise Error(_NOT_HERE)


    def transcribe(self, samples: List[Float32]) raises -> String:
        return self.transcribe_address(Int(samples.unsafe_ptr()), len(samples))

    def last_ms(self) raises -> Float64:
        """The last transcription's time (features, encoder and decoder on the GPU)."""
        return atof(self._attr("last_ms"))

    def peak_gpu_mb(self) raises -> Float64:
        comptime if CompilationTarget.is_linux():
            var g = _enter()
            var v = Float64(py=_backend().OBJECTS[self._id].peak_gpu_mb())
            _leave(g)
            return v
        else:
            raise Error(_NOT_HERE)


struct SpeechStream(Movable):
    """Live dictation over a SpeechModel: feed samples as they arrive, poll for words. The work runs on a thread of the
    backend's own; feed() copies and returns, poll() takes what's ready."""

    var _id: Int

    def __init__(out self, model: SpeechModel) raises:
        comptime if CompilationTarget.is_linux():
            var g = _enter()
            var mod = _backend()
            self._id = _keep(mod, mod.Stream(mod.OBJECTS[model._id]))
            _leave(g)
        else:
            raise Error(_NOT_HERE)


    def feed_address(self, addr: Int, n: Int, captured_ns: Int = 0) raises:
        """n float32 samples at addr (copied before it returns). captured_ns: when the last of them was captured
        (Microphone.captured_ns), so a FINAL's end_ns is when the words were spoken, not when they were handed over."""
        comptime if CompilationTarget.is_linux():
            if n <= 0:
                return
            var g = _enter()
            _ = _backend().OBJECTS[self._id].feed_address(addr, n, captured_ns)
            _leave(g)
        else:
            raise Error(_NOT_HERE)


    def feed(self, samples: List[Float32], captured_ns: Int = 0) raises:
        self.feed_address(Int(samples.unsafe_ptr()), len(samples), captured_ns)

    def flush(self) raises:
        """Ends the utterance in progress now (Stop pressed): its FINAL follows without waiting for a pause."""
        comptime if CompilationTarget.is_linux():
            var g = _enter()
            _ = _backend().OBJECTS[self._id].flush()
            _leave(g)
        else:
            raise Error(_NOT_HERE)


    def poll(self) raises -> List[SpeechEvent]:
        comptime if CompilationTarget.is_linux():
            var out = List[SpeechEvent]()
            var g = _enter()
            var got = _backend().OBJECTS[self._id].poll()
            for e in got:
                var kind = FINAL if String(py=e[0]) == "final" else PARTIAL
                out.append(SpeechEvent(kind, String(py=e[1]), Float64(py=e[2]), Int(py=e[3]), Int(py=e[4])))
            _leave(g)
            return out^
        else:
            raise Error(_NOT_HERE)


    def close(self) raises:
        comptime if CompilationTarget.is_linux():
            var g = _enter()
            _ = _backend().OBJECTS[self._id].close()
            _leave(g)
        else:
            raise Error(_NOT_HERE)

