# mojoui.voiceloop: turn-taking for a voice app (goal 72 M4). It wires the ears and the mouth the framework already has,
# and leaves the brain to the app: Microphone -> Endpointer (Silero VAD) -> SpeechStream (Parakeet) gives the person's
# words; the reply's words go in as the model produces them and come out as Kokoro audio, a clause at a time, on a Speaker.
#
#   var loop = VoiceLoop()                      # loads on threads of their own; the window opens meanwhile
#   update() on a timer (30 ms):
#       for e in loop.tick():                   # what happened: HEARD (their words), STARTED, BARGED, READY, FAILED
#           if e.kind == HEARD: ... start the agent's run with e.text (e.merged: it replaces the unspoken turn before)
#           if e.kind == BARGED or e.kind == STARTED: ... cancel the run in flight
#       loop.say(delta)                         # each piece of the reply as it streams; sentences are spoken as they complete
#       loop.end_reply()                        # the run is over: speak what is left
#   loop.state() / loop.level() drive the screen (an orb); loop.first_audio_ms() etc. are the stamps below.
#
# The rules (omx-local's, which were measured): speech over the speaker's own voice for five frames is a barge-in, which
# stops the speaker and cancels the mouth within the tick; a turn still thinking (no audio yet) when the person goes on
# is merged with the words that follow; a sound that starts over the speaker but never becomes a barge-in is dropped.
# Echo: a desktop microphone hears the speaker too, so use headphones or the browser's echo cancellation (the web host's
# page asks for it); `barge` False turns the interruption off for a room without either.
#
# Pointing (goal 77 M1, mojoui.pointer): `loop.parts = [Part(...)]` (the parts of the cards on screen, as the app lists them), and every
# clause handed to the speaker is matched against them; a clause that names a part gives a POINT event when the audio that names it
# plays, not before: its time is the speaker's play clock for the clause (Speaker.next_start_ns) plus how far into the clause the name
# is (at × the clause's length), and a clause that starts a burst is corrected once the device reports its first sample.
#
# Stamps (now_ns(), CLOCK_MONOTONIC, the clock of the capture times): heard_ns = the last voiced sample of the person's
# words as captured; first_audio_ns = when the first sample of the reply reached the sound device; first_audio_ms() the
# distance, which holds the endpointer's 384 ms of quiet, the recogniser, the model's first sentence and Kokoro; barge_ms
# = from the first voiced sample of the interruption to the speaker having stopped.
# Linux and the web host (the `voice` pixi environment: CPython 3.12 with torch, kokoro, onnx-asr, silero-vad).

from std.math import sqrt
from std.os import setenv
from mojoui.audio import Microphone
from mojoui.clock import now_ns
from mojoui.pointer import Part, match_clause, point_event
from mojoui.speaker import Speaker
from mojoui.speech import SpeechModel, SpeechStream, FINAL
from mojoui.voice import Voice, Endpointer, START as EP_START, BARGE as EP_BARGE, END as EP_END

comptime LOOP_LOADING = 0  # the models are loading
comptime LOOP_LISTENING = 1  # waiting for the person
comptime LOOP_HEARING = 2  # the person is speaking
comptime LOOP_THINKING = 3  # their words are in; the reply hasn't started to sound
comptime LOOP_SPEAKING = 4  # the reply is sounding

comptime HEARD = 0  # the person's words are in: text (merged: they continue the turn before, which wasn't spoken yet)
comptime STARTED = 1  # the person began to speak (a run still thinking may be cancelled now)
comptime BARGED = 2  # they spoke over the reply: the speaker has stopped (ms: how long it took from their first sound)
comptime READY = 3  # the models are loaded and the microphone is on
comptime FAILED = 4  # something couldn't load: text says what
comptime POINT = 5  # a spoken clause named a part of a card (goal 77 M1): text = the AG-UI CUSTOM `point` event, ns = when its audio
#   plays (the speaker's play clock: the device's delay is in it), ms = how far into the clause the name is said

comptime ENV_WINDOW = 480  # samples (20 ms at 24 kHz) per loudness reading of the reply


@fieldwise_init
struct LoopEvent(Copyable, Movable):
    var kind: Int
    var text: String
    var ns: Int
    var ms: Float64
    var merged: Bool


def speech_clean(text: String) -> String:
    """A reply's words as they are said: markdown marks and emphasis dropped, line breaks as spaces."""
    var out = String("")
    for b in text.as_bytes():
        var c = Int(b)
        if c == 42 or c == 35 or c == 96 or c == 95 or c == 126:  # * # ` _ ~
            continue
        out += " " if c == 10 or c == 13 else chr(c)
    return out^


def take_sentences(mut pending: String, final: Bool = False) -> List[String]:
    """The sentences that are complete in `pending` (ended by . ! ? or a colon/semicolon, then a space; a long run is cut at
    its last comma), removed from it; `final`: whatever is left is a sentence too. A decimal point or an abbreviation's
    dot followed by no space does not end one."""
    var out = List[String]()
    var text = pending
    var n = text.byte_length()
    var start = 0
    var i = 0
    while i < n:
        var c = Int(text.as_bytes()[i])
        var ends = (c == 46 or c == 33 or c == 63 or c == 58 or c == 59) and i + 1 - start >= 12
        var cut = c == 44 and i + 1 - start >= 90
        if (ends or cut) and i + 1 < n and Int(text.as_bytes()[i + 1]) == 32:
            var piece = String(String(text[byte = start : i + 1]).strip())
            if piece != "":
                out.append(piece)
            start = i + 2
            i += 1
        i += 1
    var rest = String(String(text[byte = min(start, n) :]).strip()) if final else String(text[byte = min(start, n) :])
    if final and rest != "":
        out.append(rest)
        rest = String("")
    pending = rest^
    return out^


@fieldwise_init
struct Scheduled(Copyable, Movable):
    """A point waiting for its audio: the event, when it is due on the play clock, the burst it belongs to."""
    var card: String
    var part: String
    var at_ms: Int
    var due_ns: Int
    var group: Int  # the burst (a run of clauses the device plays without a gap) whose first sample is still to be measured; -1: settled


@fieldwise_init
struct Burst(Copyable, Movable):
    var ref_ns: Int  # the play() that began it
    var est_ns: Int  # when its first sample was expected to sound
    var fixed: Bool


struct VoiceLoop(Movable):
    var mic: Microphone
    var speaker: Speaker
    var voice: Optional[Voice]
    var ears: Optional[SpeechModel]
    var broken: String  # why the models couldn't even start ("" when they did): tick() says it once
    var stream: Optional[SpeechStream]
    var ep: Optional[Endpointer]
    var barge: Bool  # speech over the speaker interrupts it
    var muted: Bool  # the microphone is on but nothing is heard (the app's mute button)
    var hold: Bool  # the app isn't ready for the first question (its model is still warming): READY and the microphone wait
    var loaded: Bool
    var failed_told: Bool
    var _state: Int
    var since: Int  # the microphone's next sample to hand over
    var pending: String  # the reply's words not yet complete as a sentence
    var last_job: Int  # the newest say() job's id
    var floor: Int  # jobs up to this id were cancelled: their clauses are dropped
    var said: Int  # say() jobs of this reply handed to the mouth
    var finished: Int  # ... that the mouth has finished
    var closed: Bool  # end_reply() was called
    var spoken: Bool  # a sample of this turn's reply reached the sound device
    var handed: Bool  # a clause of this turn's reply was given to the speaker (it may not have reached the device yet)
    var active: Bool  # a turn is open: heard, not yet finished speaking
    var turn_text: String
    var recognising: Bool
    var over_speaker: Bool  # the utterance under way started while the speaker played
    var barged: Bool
    var start_ns: Int  # the utterance's first voiced sample
    var heard_ns: Int  # the last voiced sample of the turn's words
    var dispatch_ns: Int  # when the words went to the app
    var first_ns: Int  # the first sample of the reply reached the device (0: not yet)
    var stopped_ns: Int
    var env: List[Float32]  # loudness of the reply's audio per 20 ms, from the burst's start
    var burst_ns: Int
    var heard_text_ms: Float64  # the endpointer's END -> the words, as the recogniser took them
    var bargings: Int
    var barge_ms_: Float64
    var parts: List[Part]  # the parts of the cards on screen that a clause may name (the app sets them)
    var due: List[Scheduled]  # points waiting for the audio that names them
    var bursts: List[Burst]
    var last_point: String  # the part last pointed at (the same one is not sent twice running)

    def __init__(out self, sink: String = "", parakeet_dir: String = ""):
        """sink: the speaker's output ($MOJOUI_AUDIO_SINK if empty); parakeet_dir: the recogniser's files, unless
        $MOJOUI_PARAKEET_DIR already says. Never raises: what can't start is a FAILED event from the first tick()."""
        if parakeet_dir != "":
            _ = setenv("MOJOUI_PARAKEET_DIR", parakeet_dir, False)
        self.mic = Microphone()
        self.speaker = Speaker(sink)
        self.ep = None
        self.voice = None
        self.ears = None
        self.broken = String("")
        try:
            self.ep = Endpointer()  # (loads Silero: a second; the windows open after)
            self.voice = Voice(wait=False)
            self.ears = SpeechModel("parakeet", wait=False)
        except e:
            self.broken = String(e)
        self.stream = None
        self.barge = True
        self.muted = False
        self.hold = False
        self.loaded = False
        self.failed_told = False
        self._state = LOOP_LOADING
        self.since = 0
        self.pending = String("")
        self.last_job = 0
        self.floor = 0
        self.said = 0
        self.finished = 0
        self.closed = False
        self.spoken = False
        self.handed = False
        self.active = False
        self.turn_text = String("")
        self.recognising = False
        self.over_speaker = False
        self.barged = False
        self.start_ns = 0
        self.heard_ns = 0
        self.dispatch_ns = 0
        self.first_ns = 0
        self.stopped_ns = 0
        self.env = List[Float32]()
        self.burst_ns = 0
        self.heard_text_ms = 0.0
        self.bargings = 0
        self.barge_ms_ = 0.0
        self.parts = List[Part]()
        self.due = List[Scheduled]()
        self.bursts = List[Burst]()
        self.last_point = String("")

    def state(self) -> Int:
        return self._state

    def gpu(self) -> String:
        try:
            return self.ears.value().gpu() if self.ears else String("")
        except:
            return String("")

    def first_audio_ms(self) -> Float64:
        """The last turn: from the person's last voiced sample to the reply's first sample at the device (-1: none yet)."""
        return Float64(self.first_ns - self.heard_ns) / 1e6 if self.first_ns > 0 and self.heard_ns > 0 else -1.0

    def barge_ms(self) -> Float64:
        """The last interruption: from their first voiced sample to the speaker having stopped (-1: none)."""
        return self.barge_ms_ if self.bargings > 0 else -1.0

    def level(self) -> Float64:
        """0…1 for an orb: the person's voice while they speak, the reply's own loudness while it sounds."""
        if self._state == LOOP_SPEAKING and len(self.env) > 0:
            var at = (now_ns() - self.burst_ns - Int(self.speaker.latency_ms() * 1e6)) // 20_000_000
            if at >= 0 and at < len(self.env):
                return min(Float64(self.env[at]) * 3.5, 1.0)
            return 0.0
        if self._state == LOOP_HEARING:
            return min(self.mic.level() * 7.0, 1.0)
        return 0.0

    # --- the person's side ---------------------------------------------------------------------------------------

    def tick(mut self) -> List[LoopEvent]:
        """Call every ~30 ms from update(): never waits for a model."""
        var out = List[LoopEvent]()
        if not self.loaded:
            self.load(out)
            if not self.loaded:
                return out^
        try:
            self.listen(out)
            self.recognise(out)
            self.mouth()
        except e:
            out.append(LoopEvent(FAILED, String(e), now_ns(), 0.0, False))
        self.points(out)
        self.settle()
        return out^

    def load(mut self, mut out: List[LoopEvent]):
        if self.failed_told:
            return
        if self.broken != "":
            self.failed_told = True
            out.append(LoopEvent(FAILED, self.broken, now_ns(), 0.0, False))
            return
        try:
            ref ears = self.ears.value()
            ref voice = self.voice.value()
            if ears.failed():
                self.failed_told = True
                out.append(LoopEvent(FAILED, "the speech model: " + ears.why(), now_ns(), 0.0, False))
                return
            if voice.failed():
                self.failed_told = True
                out.append(LoopEvent(FAILED, "the voice: " + voice.why(), now_ns(), 0.0, False))
                return
            if not (ears.ready() and voice.ready()) or self.hold:
                return
            self.stream = SpeechStream(ears)
        except e:
            self.failed_told = True
            out.append(LoopEvent(FAILED, String(e), now_ns(), 0.0, False))
            return
        self.mic.start()
        self.since = self.mic.total()
        self.loaded = True
        self._state = LOOP_LISTENING
        out.append(LoopEvent(READY, "", now_ns(), 0.0, False))

    def listen(mut self, mut out: List[LoopEvent]) raises:
        if self.mic.failed():
            if not self.failed_told:
                self.failed_told = True
                out.append(LoopEvent(FAILED, "microphone: " + self.mic.why(), now_ns(), 0.0, False))
            return
        var total = self.mic.total()
        if total <= self.since:
            return
        if self.muted:
            self.since = total
            return
        var got = self.mic.read(self.since)
        self.since = total
        ref ep = self.ep.value()
        ep.feed(got, self.mic.captured_ns(total - 1), self.speaker.playing() and self.barge)
        for e in ep.poll():
            if e.kind == EP_START:
                self.over_speaker = len(e.samples) > 0 and e.samples[0] > 0.5
                self.barged = False
                self.start_ns = e.ns
                if not self.over_speaker:
                    self._state = LOOP_HEARING
                    out.append(LoopEvent(STARTED, "", e.ns, 0.0, False))
            elif e.kind == EP_BARGE:
                if self.barge:
                    self.barged = True
                    self.stop_speaking()
                    self.bargings += 1
                    self.barge_ms_ = Float64(self.stopped_ns - self.start_ns) / 1e6
                    self._state = LOOP_HEARING
                    out.append(LoopEvent(BARGED, "", self.stopped_ns, self.barge_ms_, False))
            elif e.kind == EP_END:
                if self.over_speaker and not self.barged:
                    continue  # (a sound over the reply that never became an interruption: the room, not a person)
                self.heard_ns = e.ns
                self.recognising = True
                self._state = LOOP_THINKING
                ref s = self.stream.value()
                s.feed(e.samples, e.ns)
                s.flush()

    def recognise(mut self, mut out: List[LoopEvent]) raises:
        if not self.recognising or not self.stream:
            return
        for e in self.stream.value().poll():
            if e.kind != FINAL:
                continue
            self.recognising = False
            if e.text.strip() == "":
                self._state = LOOP_LISTENING if not self.active else self._state
                continue
            self.heard_text_ms = Float64(now_ns() - self.heard_ns) / 1e6
            out.append(self.turn(String(e.text.strip()), self.heard_ns))

    def turn(mut self, text: String, heard_ns: Int) -> LoopEvent:
        """A person's words become the turn: merged with the one before when that hasn't made a sound yet."""
        var merged = self.active and not self.spoken
        var words = (self.turn_text + " " + text) if merged else text
        self.turn_text = words
        self.active = True
        self.spoken = False
        self.handed = False
        self.said = 0
        self.finished = 0
        self.closed = False
        self.pending = String("")
        self.first_ns = 0
        self.due = List[Scheduled]()
        self.bursts = List[Burst]()
        self.last_point = String("")
        self.dispatch_ns = now_ns()
        self._state = LOOP_THINKING
        return LoopEvent(HEARD, words, heard_ns, Float64(self.dispatch_ns - heard_ns) / 1e6, merged)

    def typed(mut self, text: String) -> LoopEvent:
        """Words typed instead of spoken: the same turn (no stamps for the speech: heard_ns is now)."""
        self.stop_speaking()
        return self.turn(text, now_ns())

    # --- the reply's side ----------------------------------------------------------------------------------------

    def idle(self) -> Bool:
        """Nobody is talking and nothing is being said: the person isn't speaking, no turn is open, the speaker is quiet."""
        return self.loaded and self._state == LOOP_LISTENING and not self.active and not self.recognising and not self.speaker.playing()

    def announce(mut self, text: String) -> Bool:
        """Says `text` on its own (a job that finished, a heads-up), as a turn of its own: only when idle() (False: nothing
        was said, ask again later). The person's next words interrupt it like any reply."""
        if not self.idle():
            return False
        self.heard_ns = now_ns()  # (first_audio_ms counts from here: there were no words to answer)
        self.active = True
        self.spoken = False
        self.handed = False
        self.said = 0
        self.finished = 0
        self.closed = False
        self.pending = String("")
        self.first_ns = 0
        self.dispatch_ns = now_ns()
        self._state = LOOP_THINKING
        self.say(text + " ")
        self.end_reply()
        return True

    def say(mut self, delta: String):
        """The reply's next words as the model produces them: each complete sentence goes to the mouth."""
        if not self.loaded:
            return
        self.pending = self.pending + speech_clean(delta)  # (not `+=`: on a String field that crossed ~192 bytes it crashed the app, D-7245)
        for s in take_sentences(self.pending):
            self.speak(s)

    def end_reply(mut self):
        """The run is over: what is left is spoken, and the turn ends once it has sounded."""
        for s in take_sentences(self.pending, True):
            self.speak(s)
        self.closed = True

    def speak(mut self, sentence: String):
        try:
            self.last_job = self.voice.value().say(sentence)
            self.said += 1
        except:
            pass

    def mouth(mut self) raises:
        """Hands the mouth's finished clauses to the speaker, and stamps the first sound of the reply."""
        if not self.voice:
            return
        for c in self.voice.value().poll():
            if c.job <= self.floor:
                continue  # (a clause of a reply that was cancelled: nothing of it is played or counted)
            if c.done:
                self.finished += 1
                continue
            var fresh = not self.speaker.playing()
            var start_ns = self.speaker.next_start_ns()
            if fresh:  # (a new burst: its loudness readings start here)
                self.env = List[Float32]()
                self.burst_ns = now_ns()
            var k = 0
            while k < len(c.samples):
                var sq = Float64(0)
                var m = min(ENV_WINDOW, len(c.samples) - k)
                for j in range(m):
                    var v = Float64(c.samples[k + j])
                    sq += v * v
                self.env.append(Float32(sqrt(sq / Float64(m))))
                k += ENV_WINDOW
            self.schedule(c.text, Float64(len(c.samples)) * 1000.0 / Float64(max(c.rate, 1)), start_ns, fresh)
            self.speaker.play(c.samples, c.rate)
            self.handed = True
        if self.active and not self.spoken and self.speaker.first_ns() > self.dispatch_ns and self.said > 0:
            self.spoken = True
            self.first_ns = self.speaker.first_ns()

    def schedule(mut self, clause: String, length_ms: Float64, start_ns: Int, fresh: Bool):
        """Matches the clause against the parts on screen; each part it names is due when that name is said."""
        if len(self.parts) == 0:
            return
        var group = -1  # (a clause joining a burst the device is already playing is timed from its tail: nothing to correct)
        if fresh:  # (every burst is measured, named or not: a later clause may join it before the device reports its first sample)
            self.bursts.append(Burst(now_ns(), start_ns, False))
            group = len(self.bursts) - 1
        elif len(self.bursts) > 0 and not self.bursts[len(self.bursts) - 1].fixed:
            group = len(self.bursts) - 1  # (the burst's first sample isn't measured yet: its points move with it)
        var hits = match_clause(clause, self.parts)
        for h in hits:
            var at_ms = Int(h.at * length_ms)
            self.due.append(Scheduled(h.card, h.part, at_ms, start_ns + at_ms * 1_000_000, group))

    def points(mut self, mut out: List[LoopEvent]):
        """POINT events for the parts whose audio is playing now (the play clock has reached them)."""
        if len(self.due) == 0:
            return
        var now = now_ns()
        for g in range(len(self.bursts)):  # (a burst's first sample is measured: its estimate is corrected once)
            if not self.bursts[g].fixed and self.speaker.first_ns() >= self.bursts[g].ref_ns:
                var real = self.speaker.first_ns() + Int(self.speaker.latency_ms() * 1e6)
                var delta = real - self.bursts[g].est_ns
                self.bursts[g].fixed = True
                for k in range(len(self.due)):
                    if self.due[k].group == g:
                        self.due[k].due_ns += delta
                        self.due[k].group = -1
        var keep = List[Scheduled]()
        for k in range(len(self.due)):
            ref d = self.due[k]
            if d.group < 0 and d.due_ns <= now:
                var tag = d.card + "." + d.part
                if tag != self.last_point:
                    self.last_point = tag
                    out.append(LoopEvent(POINT, point_event(d.card, d.part, d.at_ms), d.due_ns, Float64(d.at_ms), False))
            else:
                keep.append(d.copy())
        self.due = keep^

    def settle(mut self):
        if not self.loaded:
            return
        if self._state == LOOP_THINKING and self.spoken:
            self._state = LOOP_SPEAKING
        var sounded = not self.handed or self.speaker.failed() or (self.spoken and not self.speaker.playing())  # (the device opens a moment after play())
        if self.active and self.closed and self.finished >= self.said and sounded and not self.recognising:
            self.active = False  # the reply has been said, every clause of it
            if self._state == LOOP_SPEAKING or self._state == LOOP_THINKING:
                self._state = LOOP_LISTENING
        if self._state == LOOP_SPEAKING and not self.speaker.playing() and not self.active:
            self._state = LOOP_LISTENING

    def stop_speaking(mut self):
        """Silence now: the speaker's queue and device buffer, the mouth's unmade clauses, the sentence in hand."""
        self.speaker.stop()
        try:
            if self.voice:
                self.voice.value().cancel()
        except:
            pass
        self.floor = self.last_job
        self.handed = False
        self.due = List[Scheduled]()
        self.bursts = List[Burst]()
        self.stopped_ns = now_ns()
        self.pending = String("")
        self.finished = self.said
        self.env = List[Float32]()
        if self._state == LOOP_SPEAKING:
            self._state = LOOP_LISTENING
