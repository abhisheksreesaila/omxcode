# mojoui.dictation: hold to talk, and the words appear at the caret (goal 82 M5). Three generic pieces an app composes:
#
#   PressToTalk   the mic button's rule (Personal Note's press-to-talk.js): hold it to talk and let go to finish, or tap it
#                 once to keep listening and tap again to stop. press()/release() say START, STOP or nothing.
#   DictationText the words at a caret: what is still being heard is shown as an input method's preedit (underlined, it may
#                 change); a finished utterance is committed as text, with a space before it when the caret follows a word
#                 (transcript-session.js's rule). Nothing but text is ever kept.
#   Dictation     the engine: a Microphone and a speech recogniser. Linux: mojoui.speech in this process on the GPU
#                 (Parakeet TDT 0.6B v3 by default, whisper-large-v3-turbo by name); macOS: Apple's on-device recogniser
#                 (mojoui.applespeech: SFSpeechRecognizer, requiresOnDeviceRecognition, no download), fed by the
#                 microphone through AVAudioEngine. start() returns at once; tick() (from the app's timer) hands the new
#                 samples over and returns the words that are ready; stop() ends the utterance and its final words follow.
#
#   var talk = PressToTalk(); var words = DictationText(); var ears = Dictation()      # Dictation("file:a.wav"): a recording
#   on the mic's PRESS:   if talk.press(now_ms(), ears.listening()) == TALK_START: ears.start(); words.start(text_before_caret)
#   on its RELEASE:       if talk.release(now_ms()) == TALK_STOP: ears.stop()
#   on a timer (30 ms):   for e in ears.tick(): var put = words.hear(e)   → put.commit (insert at the caret) / put.preedit (show)
#
# The speech model is loaded on the first start(), on a thread of its own: the samples wait in the microphone's ring
# meanwhile (two minutes), so words said while it loads are not lost. A model that isn't on this machine is never
# downloaded by itself: may_download() is false until the app has asked the person (Dictation.download_ok = True), and
# then it goes to models_dir (huggingface_hub's cache folder there; default: where it already is).

from std.os import getenv, setenv, listdir
from std.os.path import exists, isdir
from std.sys import CompilationTarget
from std.memory import Pointer
from std.memory.alloc import alloc, Layout
from mojoui.audio import Microphone, RATE
from mojoui.speech import SpeechEvent, PARTIAL, FINAL, SpeechModel, SpeechStream
from mojoui.applespeech import apple_begin, apple_feed, apple_end, apple_poll, apple_free
from mojoui.clock import now_ns
from mojoui.hfcache import hf_hub_cache
from mojoui import libc

comptime TALK_NONE = 0
comptime TALK_START = 1
comptime TALK_STOP = 2
comptime HOLD_MS = 450  # a press shorter than this is a tap (keep listening); a longer one is a hold (talk while down)
comptime PARTIAL_EVERY_MS = 400  # Linux: words still being said, at most this often (the first ones this long after speech starts)
comptime FINISH_NS = 4_000_000_000  # after stop(), the last words have this long to arrive (the web's finishTimer)

comptime PARAKEET = "parakeet"
comptime PARAKEET_REPO = "istupakov/parakeet-tdt-0.6b-v3-onnx"  # (where onnx_asr fetches it from)
comptime WHISPER_REPO = "openai/whisper-large-v3-turbo"


struct PressToTalk(Copyable, Movable):
    var hold_ms: Int
    var pressed_at: Int  # -1: not pressed
    var stop_on_release: Bool

    def __init__(out self, hold_ms: Int = HOLD_MS):
        self.hold_ms = hold_ms
        self.pressed_at = -1
        self.stop_on_release = False

    def press(mut self, now_ms: Int, listening: Bool) -> Int:
        if listening:  # (tapped to keep listening before: this press ends it, when it is let go)
            self.stop_on_release = True
            return TALK_NONE
        self.pressed_at = now_ms
        return TALK_START

    def release(mut self, now_ms: Int) -> Int:
        if self.stop_on_release:
            self.stop_on_release = False
            return TALK_STOP
        if self.pressed_at < 0:
            return TALK_NONE
        var held = now_ms - self.pressed_at >= self.hold_ms
        self.pressed_at = -1
        return TALK_STOP if held else TALK_NONE  # (a tap: keep listening)

    def cancel(mut self):
        self.pressed_at = -1
        self.stop_on_release = False


def normalized(text: String) -> String:
    """Runs of white space as one space, trimmed (transcript-session.js's normalizeTranscript)."""
    var out = String("")
    var gap = False
    for w in text.split():
        var word = String(w)
        if word == "":
            continue
        if gap:
            out += " "
        out += word
        gap = True
    return out^


def _is_space(s: String) -> Bool:
    return s == "" or s == " " or s == "\n" or s == "\t"


@fieldwise_init
struct Put(Copyable, Movable):
    var commit: String  # text to insert at the caret now ("" for none)
    var preedit: String  # what to show at the caret as an input method's preedit ("" clears it)


struct DictationText(Copyable, Movable):
    var active: Bool
    var partial: String
    var said: String  # what this session committed (for the person's word count, and a check)
    var last: String  # the character before the caret (one grapheme's worth is enough: is it a space?)

    def __init__(out self):
        self.active = False
        self.partial = ""
        self.said = ""
        self.last = ""

    def start(mut self, before_caret: String):
        """A new session at a caret with `before_caret` to its left (only its last character matters)."""
        self.active = True
        self.partial = ""
        self.said = ""
        self.last = String(before_caret[byte = before_caret.byte_length() - 1 :]) if before_caret.byte_length() > 0 else ""

    def _spaced(self, words: String) -> String:
        return words if _is_space(self.last) else " " + words

    def hear(mut self, e: SpeechEvent) -> Put:
        if not self.active:
            return Put("", "")
        var text = normalized(e.text)
        if e.kind == PARTIAL:
            self.partial = text
            return Put("", self._spaced(text) if text != "" else "")
        self.partial = ""
        if text == "":
            return Put("", "")
        var put = self._spaced(text)
        self.said += (" " if self.said != "" else "") + text
        self.last = String(text[byte = text.byte_length() - 1 :])
        return Put(put^, "")

    def finish(mut self) -> Put:
        """The session ends: a preedit still shown goes (its words were never final)."""
        self.active = False
        self.partial = ""
        return Put("", "")


def use_python_env(env_dir: String) -> String:
    """Points Mojo's Python interop at a pixi/conda environment's CPython before the interpreter starts (the speech model
    runs in it): "" when done or already chosen ($MOJO_PYTHON_LIBRARY set), else why not. Linux."""
    if getenv("MOJO_PYTHON_LIBRARY", "") != "":
        return ""
    if not isdir(env_dir + "/lib"):
        return "no Python environment at " + env_dir
    try:
        for f in listdir(env_dir + "/lib"):
            var name = String(f)
            if name.startswith("libpython3") and name.endswith(".so.1.0"):
                _ = setenv("MOJO_PYTHON_LIBRARY", env_dir + "/lib/" + name)
                _ = setenv("CONDA_PREFIX", env_dir)
                if getenv("FLARE_LIB_DIR", "") == "":  # (Flare finds its shims in $CONDA_PREFIX/lib otherwise: keep them where they were)
                    _ = setenv("FLARE_LIB_DIR", libc.exe_dir())
                return ""
    except:
        pass
    return "no libpython in " + env_dir + "/lib"


def model_on_disk(repo: String, models_dir: String = "") -> Bool:
    """Is huggingface_hub's copy of `repo` in the cache (models_dir's, else the usual one)?"""
    var cache = (models_dir + "/hub") if models_dir != "" else hf_hub_cache()
    return isdir(cache + "/models--" + repo.replace("/", "--") + "/snapshots")


comptime _IDLE = 0
comptime _LOADING = 1
comptime _LISTENING = 2
comptime _FINISHING = 3


struct Dictation(Movable):
    var source: String  # the microphone's source ("": the default input; "file:a.wav": a recording, for checks)
    var engine: String  # Linux: PARAKEET or a whisper id; macOS: the locale ("" = the system's)
    var models_dir: String  # where a downloaded model goes ("": huggingface_hub's own cache folder)
    var download_ok: Bool  # the person said yes to a download (the app asks; never this module)
    var why: String  # why it can't listen, in words ("" while fine)
    var mic: Microphone
    var since: Int
    var state: Int
    var finish_by: Int
    var _model: Int  # (an address: Linux SpeechModel / SpeechStream on the heap; 0 until first used)
    var _stream: Int
    var _apple: Int  # macOS: the AppleSpeech session (0 when none)

    def __init__(out self, source: String = "", engine: String = PARAKEET, models_dir: String = ""):
        self.source = source
        self.engine = engine
        self.models_dir = models_dir
        self.download_ok = False
        self.why = ""
        self.mic = Microphone(source)
        self.since = 0
        self.state = _IDLE
        self.finish_by = 0
        self._model = 0
        self._stream = 0
        self._apple = 0

    def repo(self) -> String:
        return PARAKEET_REPO if self.engine == PARAKEET else self.engine

    def needs_download(self) -> Bool:
        """The model isn't on this machine (and the engine is one that downloads: not Apple's)."""
        comptime if CompilationTarget.is_macos():
            return False
        else:
            return not model_on_disk(self.repo(), self.models_dir) and not isdir(self.engine)

    def listening(self) -> Bool:
        return self.state == _LOADING or self.state == _LISTENING

    def busy(self) -> Bool:
        """Listening, or still finishing the last words."""
        return self.state != _IDLE

    def level(self) -> Float64:
        return self.mic.level() if self.listening() else 0.0

    def start(mut self) -> Bool:
        """Starts listening (returns at once). False, with `why`, when it can't: no model and no yes to download one, no
        microphone, no speech engine on this host."""
        if self.busy():
            return self.listening()
        self.why = ""
        if self.needs_download() and not self.download_ok:
            self.why = "the voice model isn't on this computer yet"
            return False
        self.mic = Microphone(self.source)
        self.mic.start()
        if self.mic.failed():
            self.why = self.mic.why()
            return False
        self.since = 0
        comptime if CompilationTarget.is_linux():
            if self.models_dir != "" and getenv("HF_HOME", "") == "":
                _ = setenv("HF_HOME", self.models_dir)
            if not self.download_ok:
                _ = setenv("HF_HUB_OFFLINE", "1")  # (nothing leaves this machine unless the person said yes)
            elif getenv("HF_HUB_OFFLINE", "") == "1":
                _ = setenv("HF_HUB_OFFLINE", "0")
            if getenv("MOJOUI_SPEECH_PARTIAL_MS", "") == "":
                _ = setenv("MOJOUI_SPEECH_PARTIAL_MS", String(PARTIAL_EVERY_MS))
            try:
                if self._model == 0:
                    var p = alloc_model(self.engine)
                    self._model = p
                self.state = _LOADING
            except e:
                self.why = "the speech model couldn't start: " + String(e)
                self.mic.stop()
                return False
        elif CompilationTarget.is_macos():
            var a = apple_begin(self.engine)
            if a[0] == 0:
                self.why = a[1]
                self.mic.stop()
                return False
            self._apple = a[0]
            self.state = _LISTENING
        else:
            self.why = "no speech engine on this host yet"
            self.mic.stop()
            return False
        return True

    def stop(mut self):
        """Ends the utterance now: its final words come from tick() within a moment (FINISH_NS at most)."""
        if not self.listening():
            return
        self.state = _FINISHING
        self.finish_by = now_ns() + FINISH_NS
        _ = self._hand_over()
        self.mic.stop()
        comptime if CompilationTarget.is_linux():
            if self._stream != 0:
                try:
                    stream_at(self._stream)[].flush()
                except:
                    pass
        elif CompilationTarget.is_macos():
            if self._apple != 0:
                apple_end(self._apple)

    def cancel(mut self):
        """Ends at once and drops the words still being heard (switching notes)."""
        if self.listening():
            self.mic.stop()
        self._close()
        self.state = _IDLE

    def _close(mut self):
        comptime if CompilationTarget.is_linux():
            if self._stream != 0:
                free_stream(self._stream)
                self._stream = 0
        elif CompilationTarget.is_macos():
            if self._apple != 0:
                apple_free(self._apple)
                self._apple = 0

    def _hand_over(mut self) -> Bool:
        """The new samples to the recogniser. False while it can't take them yet (the model still loading)."""
        comptime if CompilationTarget.is_linux():
            if self._stream == 0:
                return False
            var got = self.mic.read(self.since)
            if len(got) > 0:
                var at = self.since + len(got) - 1
                try:
                    stream_at(self._stream)[].feed(got, self.mic.captured_ns(at))
                except e:
                    self.why = "the speech model stopped: " + String(e)
                self.since += len(got)
            return True
        elif CompilationTarget.is_macos():
            if self._apple == 0:
                return False
            var got = self.mic.read(self.since)
            if len(got) > 0:
                apple_feed(self._apple, got)
                self.since += len(got)
            return True
        else:
            return False

    def tick(mut self) -> List[SpeechEvent]:
        """From the app's timer: samples go over, and the words that are ready come back (PARTIAL: still being heard;
        FINAL: finished). After stop(), the last FINAL ends the session."""
        var out = List[SpeechEvent]()
        if self.state == _IDLE:
            return out^
        comptime if CompilationTarget.is_linux():
            if self.state == _LOADING:
                var m = model_at(self._model)
                if m[].failed():
                    try:
                        self.why = "the speech model didn't load: " + m[].why()
                    except:
                        self.why = "the speech model didn't load"
                    self.mic.stop()
                    self.state = _IDLE
                    return out^
                if not m[].ready():
                    return out^
                try:
                    self._stream = alloc_stream(self._model)
                    self.state = _LISTENING
                except e:
                    self.why = "the speech model couldn't listen: " + String(e)
                    self.mic.stop()
                    self.state = _IDLE
                    return out^
            if self.state == _LISTENING:
                _ = self._hand_over()
            try:
                out = stream_at(self._stream)[].poll()
            except e:
                self.why = "the speech model stopped: " + String(e)
        elif CompilationTarget.is_macos():
            if self.state == _LISTENING:
                _ = self._hand_over()
            if self._apple != 0:
                var p = apple_poll(self._apple)
                out = p[0].copy()
                if p[1] != "":
                    self.why = p[1]
        if self.state == _FINISHING:
            var done = now_ns() > self.finish_by
            for e in out:
                if e.kind == FINAL:
                    done = True
            if done:
                self._close()
                self.state = _IDLE
        return out^


# ---- the Linux engine's objects, kept on the heap (Dictation stays Movable without Optional[...] of Python-backed types)

def alloc_model(engine: String) raises -> Int:
    comptime if CompilationTarget.is_linux():
        var m = SpeechModel(engine, "cuda", wait=False)
        var a = alloc(Layout[SpeechModel].single())
        var p = a^.unsafe_leak()
        p.unsafe_write(m^)
        return Int(p)
    else:
        raise Error("no speech model on this host")


def model_at(addr: Int) -> Pointer[SpeechModel, MutUntrackedOrigin]:
    return Pointer[SpeechModel, MutUntrackedOrigin](unsafe_from_address=addr)


def alloc_stream(model: Int) raises -> Int:
    comptime if CompilationTarget.is_linux():
        var s = SpeechStream(model_at(model)[])
        var a = alloc(Layout[SpeechStream].single())
        var p = a^.unsafe_leak()
        p.unsafe_write(s^)
        return Int(p)
    else:
        raise Error("no speech model on this host")


def stream_at(addr: Int) -> Pointer[SpeechStream, MutUntrackedOrigin]:
    return Pointer[SpeechStream, MutUntrackedOrigin](unsafe_from_address=addr)


def free_stream(addr: Int):
    var p = stream_at(addr)
    try:
        p[].close()
    except:
        pass
    p.unsafe_deinit_pointee()
    p.unsafe_free()



def _words_of(text: String) -> List[String]:
    """Lower-case words without punctuation (an apostrophe stays: "polly's")."""
    var out = List[String]()
    var cur = String("")
    for b in text.as_bytes():
        var c = Int(b)
        if c >= 65 and c <= 90:
            c += 32
        if (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 39 or c >= 128:
            cur += chr(c)
        elif cur != "":
            out.append(cur)
            cur = ""
    if cur != "":
        out.append(cur)
    return out^


def word_errors(reference: String, heard: String) -> Tuple[Int, Int]:
    """(substitutions + deletions + insertions, words in the reference): word error rate = first / second. Case and
    punctuation don't count."""
    var r = _words_of(reference)
    var h = _words_of(heard)
    var prev = List[Int](capacity=len(h) + 1)
    for j in range(len(h) + 1):
        prev.append(j)
    for i in range(1, len(r) + 1):
        var cur = List[Int](capacity=len(h) + 1)
        cur.append(i)
        for j in range(1, len(h) + 1):
            var sub = prev[j - 1] + (0 if r[i - 1] == h[j - 1] else 1)
            cur.append(min(sub, min(prev[j] + 1, cur[j - 1] + 1)))
        prev = cur^
    return (prev[len(h)], len(r))
