"""mojoui.voice_kokoro: backend of mojoui/voice.mojo's `Voice` (goal 72 M2): Kokoro-82M text to speech in the app's own
process. Mojo calls it through `std.python`; nothing here knows about any app.

    v = Voice(voice="af_heart", device="cuda", flag=addr, background=False)    # loaded and warmed up
    job = v.say("Hello there. How are you?")        # returns at once; a thread of its own speaks it clause by clause
    v.poll()                                        # [(job, seq, done, text, say_ns, ready_ns, samples)] since the last poll
    v.cancel()                                      # barge-in: the clause in hand is the last (nothing queued runs)

A chunk is one clause's audio (float32 mono, RATE Hz, a numpy array); `ready_ns` is when it was finished and `say_ns`
when say() was called, both on time.perf_counter_ns (CLOCK_MONOTONIC, Mojo's now_ns too). A job ends with a chunk that
has no samples and done=True. Text is split into sentences (and long ones at commas) so the first audio is out after
the first clause only.
"""

import ctypes
import queue
import re
import threading
import time

import numpy as np

RATE = 24000
VOICE = "af_heart"
SPEED = 1.05

torch = None


def clauses(text):
    """Speakable pieces: sentences, and sentences over 140 characters at their commas."""
    parts = [p.strip() for p in re.split(r"(?<=[.!?;:])\s+|\n+", text) if p.strip()]
    out = []
    for p in parts:
        if len(p) > 140:
            out += [c.strip() for c in re.split(r"(?<=,)\s+", p) if c.strip()]
        else:
            out.append(p)
    return out


class Voice:
    """flag: the address of an int64 the caller reads without the interpreter's lock: 0 loading, 1 ready, -1 failed
    (self.error says why). background: load on a thread of its own and return at once."""

    def __init__(self, voice=VOICE, device="cuda", flag=0, background=False):
        self.voice, self.error, self.gpu, self.load_ms = voice or VOICE, "", "", 0.0
        self._flag = ctypes.c_int64.from_address(int(flag)) if flag else ctypes.c_int64(0)
        self._t0 = time.perf_counter()
        self.jobs = queue.Queue()
        self.out = []
        self.cv = threading.Lock()
        self.cancelled = 0  # jobs up to this id are dropped
        self.next_job = 0
        if background:
            threading.Thread(target=self._load, args=(device,), daemon=True).start()
        else:
            self._load(device)
            if self.error:
                raise RuntimeError(self.error)

    def _load(self, device):
        try:
            global torch
            import torch
            from kokoro import KPipeline

            dev = device if torch.cuda.is_available() and device == "cuda" else "cpu"
            self.pipe = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M", device=dev)
            self.gpu = torch.cuda.get_device_name(torch.device(dev)) if dev == "cuda" else "CPU"
            for _ in range(3):  # warm-up: CUDA kernels, the first-call graph
                for _a in self._synth("Warming up."):
                    pass
            threading.Thread(target=self._run, daemon=True).start()
            self.load_ms = (time.perf_counter() - self._t0) * 1000
            self._flag.value = 1
        except Exception as e:  # shown by the app, never swallowed
            self.error = f"{type(e).__name__}: {e}"
            self._flag.value = -1

    def _synth(self, piece, voice=None, speed=0.0):
        for _, _, audio in self.pipe(piece, voice=voice or self.voice, speed=speed or SPEED, split_pattern=None):
            if audio is not None:
                yield audio.detach().cpu().numpy().astype(np.float32)

    # ---- the caller's side ----

    def say(self, text, voice="", speed=0.0):
        """Queues `text`; returns its job id."""
        with self.cv:
            self.next_job += 1
            job = self.next_job
        self.jobs.put((job, text, voice, speed, time.perf_counter_ns()))
        return job

    def cancel(self):
        """Drops every job so far: the clause being made is the last one that comes out of the jobs before this call."""
        with self.cv:
            self.cancelled = self.next_job

    def poll(self):
        with self.cv:
            out, self.out = self.out, []
        return out

    # ---- the worker ----

    def _emit(self, *item):
        with self.cv:
            self.out.append(item)

    def _run(self):
        while True:
            job, text, voice, speed, say_ns = self.jobs.get()
            seq = 0
            try:
                for piece in clauses(text):
                    if job <= self.cancelled:
                        break
                    for audio in self._synth(piece, voice, speed):
                        if job <= self.cancelled:
                            break
                        self._emit(job, seq, False, piece, say_ns, time.perf_counter_ns(), audio)
                        seq += 1
            except Exception as e:
                self.error = f"{type(e).__name__}: {e}"
            self._emit(job, seq, True, "", say_ns, time.perf_counter_ns(), np.zeros(0, dtype=np.float32))
