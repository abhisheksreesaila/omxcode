"""mojoui.speech_torch: backend of mojoui/speech.mojo (goal 43 M1): Whisper through PyTorch + Hugging Face transformers in
the app's own process. Mojo calls it through `std.python`; nothing here knows about any app.

    m = Model("openai/whisper-large-v3-turbo", device="cuda")   # fp16, warmed up
    text = m.transcribe_address(addr, n)                         # n float32 samples at 16 kHz, read in place
    s = Stream(m)                                                # live dictation: a thread of its own does the work
    s.feed_address(addr, n)                                      # copies n samples (returns at once)
    s.poll()                                                     # [(kind, text, ms, end_ns, shown_ns)] since the last poll

Samples arrive as an address of float32s (ctypes + numpy, no copy until the GPU upload): no file, socket or HTTP.

Stream: an energy voice detector on 20 ms frames. While someone speaks, the utterance so far is transcribed about once
a second (kind "partial"). After SHORT_MS of quiet the whole utterance is transcribed at once (kind "partial" too: this
is the text that will stand if they don't go on); after LONG_MS of quiet the utterance closes (kind "final") with the
text last transcribed, if nobody spoke after it, else a fresh one. A final's `end_ns` is when the last voiced frame
arrived and `shown_ns` when its text was ready, both on time.perf_counter_ns (CLOCK_MONOTONIC, Mojo's now_ns too).
"""

import ctypes
import threading
import time

import numpy as np

torch = None  # imported by the first Model (on its loading thread when it loads in the background)

RATE = 16000
FRAME = 320  # 20 ms
SHORT_MS = 120  # quiet after speech -> transcribe the utterance (the final's text, if they stop here)
LONG_MS = 1300  # quiet after speech -> the utterance is over (the clips pause up to 1.02 s inside a sentence, D-1410)
PARTIAL_MS = 1000  # while speaking: a partial at most this often
PAD_MS = 200  # audio kept before the first and after the last voiced frame
ON_RMS = 0.015  # a frame this loud starts speech
OFF_RMS = 0.006  # quieter than this counts as quiet


def from_address(addr, n):
    """A float32 numpy view of n samples at addr (no copy). The caller keeps the memory alive."""
    if n <= 0:
        return np.zeros(0, dtype=np.float32)
    return np.frombuffer((ctypes.c_float * n).from_address(int(addr)), dtype=np.float32)


class Model:
    """flag: the address of an int64 the caller reads without the interpreter's lock: 0 loading, 1 ready, -1 failed
    (self.error says why). background: load on a thread of its own and return at once."""

    def __init__(self, name, device="cuda", half=True, flag=0, background=False):
        self.name, self.error, self.gpu, self.load_ms, self.last_ms = name, "", "", 0.0, 0.0
        self._flag = ctypes.c_int64.from_address(int(flag)) if flag else ctypes.c_int64(0)
        self._t0 = time.perf_counter()
        if background:
            threading.Thread(target=self._load, args=(device, half), daemon=True).start()
        else:
            self._load(device, half)
            if self.error:
                raise RuntimeError(self.error)

    def _load(self, device, half):
        try:
            self._load_now(self.name, device, half)
            self._flag.value = 1
        except Exception as e:  # shown by the app, never swallowed
            self.error = f"{type(e).__name__}: {e}"
            self._flag.value = -1

    def _load_now(self, name, device, half):
        global torch
        import torch
        from transformers import AutoProcessor, WhisperForConditionalGeneration

        t0 = self._t0
        self.device = torch.device(device if torch.cuda.is_available() else "cpu")
        self.dtype = torch.float16 if (half and self.device.type == "cuda") else torch.float32
        self.processor = AutoProcessor.from_pretrained(name)
        self.model = WhisperForConditionalGeneration.from_pretrained(
            name, dtype=self.dtype, attn_implementation="sdpa").to(self.device).eval()
        self.gpu = torch.cuda.get_device_name(self.device) if self.device.type == "cuda" else "CPU"
        self.lock = threading.Lock()  # one transcription at a time (a stream's thread and direct calls share the GPU)
        self.transcribe(np.zeros(RATE, dtype=np.float32))  # warm-up: CUDA kernels, cuBLAS handles
        self.transcribe(np.zeros(RATE, dtype=np.float32))
        self.load_ms = (time.perf_counter() - t0) * 1000

    def transcribe(self, audio):
        """Text for float32 samples at 16 kHz (up to 30 s: Whisper's window)."""
        t0 = time.perf_counter()
        with self.lock, torch.inference_mode():
            feats = self.processor.feature_extractor(
                audio[: 30 * RATE], sampling_rate=RATE, return_tensors="pt",
                device=str(self.device)).input_features.to(self.device, self.dtype)
            ids = self.model.generate(feats, language="en", task="transcribe", num_beams=1, do_sample=False)
            text = self.processor.batch_decode(ids, skip_special_tokens=True)[0].strip()
        self.last_ms = (time.perf_counter() - t0) * 1000
        return text

    def transcribe_address(self, addr, n):
        return self.transcribe(from_address(addr, n).copy())

    def peak_gpu_mb(self):
        return torch.cuda.max_memory_allocated(self.device) / 1e6 if self.device.type == "cuda" else 0.0


class Stream:
    def __init__(self, model):
        self.model = model
        self.buf = np.zeros(RATE * 60, dtype=np.float32)
        self.n = 0  # samples fed
        self.arrived = []  # (sample count after a feed, perf_counter_ns of that feed)
        self.events = []
        self.cv = threading.Condition()
        self.stopped = False
        self.flushing = False
        self.timed = False  # feeds carry capture times
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    # ---- the caller's side (quick; under the condition's lock only to append) ----

    def feed_address(self, addr, n, captured_ns=0):
        """captured_ns: when the last of these samples was captured (a microphone's clock, CLOCK_MONOTONIC); 0: now."""
        samples = from_address(addr, n)
        now = int(captured_ns) or time.perf_counter_ns()
        self.timed = self.timed or bool(captured_ns)
        with self.cv:
            if self.n + n > len(self.buf):
                self.buf = np.concatenate([self.buf, np.zeros(max(n, len(self.buf)), dtype=np.float32)])
            self.buf[self.n:self.n + n] = samples
            self.n += n
            self.arrived.append((self.n, now))
            self.cv.notify()

    def poll(self):
        with self.cv:
            out, self.events = self.events, []
        return out

    def flush(self):
        """Closes the utterance in progress now (the person pressed Stop) instead of after LONG_MS of quiet."""
        with self.cv:
            self.flushing = True
            self.cv.notify()

    def close(self):
        with self.cv:
            self.stopped = True
            self.cv.notify()

    # ---- the worker ----

    def _arrival(self, sample):
        """When the feed holding `sample` arrived."""
        for upto, t in self.arrived:
            if upto > sample:
                return int(t - (upto - 1 - sample) * 1e9 / RATE) if self.timed else t
        return self.arrived[-1][1] if self.arrived else time.perf_counter_ns()

    def _emit(self, kind, text, end_ns=0, shown_ns=0):
        with self.cv:
            ms = (shown_ns - end_ns) / 1e6 if end_ns else 0.0
            self.events.append((kind, text, ms, end_ns, shown_ns))

    def _run(self):
        pos = 0  # next frame start to judge
        start = -1  # utterance start (sample), -1: nobody speaking
        last_voiced = -1  # end of the last voiced frame
        loud = 0
        partial_at = 0  # sample count at the last partial
        tentative = None  # (text, covers up to sample, shown_ns)
        while True:
            with self.cv:
                while not self.stopped and not self.flushing and self.n - pos < FRAME:
                    self.cv.wait(0.05)
                if self.stopped:
                    return
                flush, self.flushing = self.flushing, False
                n = self.n
                buf = self.buf
            while pos + FRAME <= n:
                rms = float(np.sqrt(np.mean(np.square(buf[pos:pos + FRAME]))))
                pos += FRAME
                if start < 0:
                    loud = loud + 1 if rms > ON_RMS else 0
                    if loud >= 2:
                        start = max(0, pos - 2 * FRAME - PAD_MS * RATE // 1000)
                        last_voiced = pos
                        partial_at = pos
                        tentative = None
                    continue
                if rms > OFF_RMS:
                    last_voiced = pos
            if start < 0:
                continue
            behind = (self.n - pos) > RATE // 2  # (catching up on a backlog: no partials until level)
            quiet_ms = (pos - last_voiced) * 1000 // RATE
            end = min(pos, last_voiced + PAD_MS * RATE // 1000)
            if quiet_ms >= LONG_MS or flush:
                end_ns = self._arrival(last_voiced - 1)
                if tentative and tentative[1] >= last_voiced:
                    text, shown = tentative[0], tentative[2]
                else:
                    text = self.model.transcribe(buf[start:end].copy())
                    shown = time.perf_counter_ns()
                self._emit("final", text, end_ns, shown)
                start, tentative = -1, None
                # forget what the next utterance won't need
                with self.cv:
                    keep = pos
                    self.buf = np.concatenate([self.buf[keep:self.n], np.zeros(RATE * 60, dtype=np.float32)])
                    self.n -= keep
                    self.arrived = [(u - keep, t) for u, t in self.arrived if u > keep]
                    pos = 0
            elif quiet_ms >= SHORT_MS:
                if not tentative or tentative[1] < last_voiced:
                    text = self.model.transcribe(buf[start:end].copy())
                    tentative = (text, last_voiced, time.perf_counter_ns())
                    self._emit("partial", text, self._arrival(last_voiced - 1), tentative[2])
            elif not behind and (pos - partial_at) * 1000 // RATE >= PARTIAL_MS:
                partial_at = pos
                text = self.model.transcribe(buf[start:pos].copy())
                self._emit("partial", text)
