"""mojoui.vad_silero: backend of mojoui/voice.mojo's `Endpointer` (goal 72 M2): turn-taking from Silero VAD, in the app's
own process. Mojo calls it through `std.python`; nothing here knows about any app.

    e = Endpointer()                                  # Silero VAD (ONNX, CPU), a thread of its own judges the frames
    e.feed_address(addr, n, captured_ns, playing)     # n float32 samples at 16 kHz, copied; returns at once
    e.poll()                                          # [(kind, ns, audio)] since the last poll

kinds: "start" (speech began; ns = its first frame; audio holds the playing flag as 1.0/0.0), "barge" (speech lasted
barge_frames while `playing` was true: the person is talking over the assistant; ns = when it was clear), "end"
(silence after speech; ns = the last speech frame's end; audio = the utterance with a little before it). Times are
time.perf_counter_ns (CLOCK_MONOTONIC, Mojo's now_ns too); `captured_ns` (when the last of a feed's samples were
captured, Microphone.captured_ns) lets them say when the words were spoken, 0: when they arrived.
Frames are Silero's 512 samples (32 ms): 2 speech frames start an utterance, 12 quiet ones (384 ms) end it, 5 speech
frames over the speaker's own voice are a barge-in. The rules are omx-local's, which they were measured in.
"""

import ctypes
import threading
import time

import numpy as np

FRAME = 512
RATE = 16000


def from_address(addr, n):
    if n <= 0:
        return np.zeros(0, dtype=np.float32)
    return np.frombuffer((ctypes.c_float * n).from_address(int(addr)), dtype=np.float32).copy()


class Endpointer:
    def __init__(self, start_frames=2, end_frames=12, barge_frames=5, preroll_frames=10, on=0.5, off=0.35):
        import torch
        from silero_vad import load_silero_vad

        self.torch = torch
        self.start_frames, self.end_frames, self.barge_frames = start_frames, end_frames, barge_frames
        self.preroll_frames, self.on, self.off = preroll_frames, on, off
        self.model = load_silero_vad(onnx=True)
        self.model(torch.zeros(FRAME), RATE)  # warm-up
        self.model.reset_states()
        self.cv = threading.Condition()
        self.buf = np.zeros(0, dtype=np.float32)
        self.arrived = []  # (samples fed after a feed, perf_counter_ns of its last sample, playing)
        self.fed = 0
        self.events = []
        self.stopped = False
        self.timed = False
        threading.Thread(target=self._run, daemon=True).start()

    def feed_address(self, addr, n, captured_ns=0, playing=False):
        samples = from_address(addr, n)
        now = int(captured_ns) or time.perf_counter_ns()
        with self.cv:
            self.timed = self.timed or bool(captured_ns)
            self.buf = np.concatenate([self.buf, samples])
            self.fed += n
            self.arrived.append((self.fed, now, bool(playing)))
            self.cv.notify()

    def poll(self):
        with self.cv:
            out, self.events = self.events, []
        return out

    def close(self):
        with self.cv:
            self.stopped = True
            self.cv.notify()

    def _when(self, sample, base):
        """(ns, playing) of absolute `sample` (base: the absolute index of buf[0])."""
        for upto, t, playing in self.arrived:
            if upto > sample:
                return int(t - (upto - 1 - sample) * 1e9 / RATE), playing
        last = self.arrived[-1] if self.arrived else (0, time.perf_counter_ns(), False)
        return last[1], last[2]

    def _emit(self, kind, ns, audio=None):
        with self.cv:
            self.events.append((kind, ns, audio if audio is not None else np.zeros(0, dtype=np.float32)))

    def _run(self):
        in_speech = False
        run = quiet = 0
        barged = False
        pre = []  # (frame, absolute start)
        utt = []
        first = 0  # absolute sample of the utterance's first speech frame
        pos = 0  # absolute index of the next frame
        torch = self.torch
        while True:
            with self.cv:
                while not self.stopped and len(self.buf) < FRAME:
                    self.cv.wait(0.05)
                if self.stopped:
                    return
                frame, self.buf = self.buf[:FRAME], self.buf[FRAME:]
            start, pos = pos, pos + FRAME
            p = float(self.model(torch.from_numpy(frame), RATE).item())
            with self.cv:
                ns, playing = self._when(pos - 1, 0)
            if not in_speech:
                pre.append(frame)
                pre = pre[-self.preroll_frames:]
                run = run + 1 if p >= self.on else 0
                if run >= self.start_frames:
                    in_speech, quiet, barged = True, 0, False
                    utt = list(pre)
                    first_ns, _ = self._when(pos - run * FRAME, 0)
                    self._emit("start", first_ns, np.array([1.0 if playing else 0.0], dtype=np.float32))
            else:
                utt.append(frame)
                if p < self.off:
                    quiet += 1
                    run = 0
                    if quiet >= self.end_frames:
                        in_speech, pre = False, []
                        end_ns, _ = self._when(pos - quiet * FRAME - 1, 0)
                        self._emit("end", end_ns, np.concatenate(utt))
                        utt = []
                        self.model.reset_states()
                else:
                    quiet = 0
                    run += 1
            if in_speech and playing and not barged and run >= self.barge_frames:
                barged = True
                self._emit("barge", ns)
            if self.arrived and self.arrived[0][0] <= start:
                with self.cv:
                    while len(self.arrived) > 1 and self.arrived[1][0] <= start:
                        self.arrived.pop(0)
