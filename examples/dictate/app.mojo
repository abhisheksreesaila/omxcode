# Dictate (goal 43 M2): speak, and the words appear as you say them, on this machine's GPU. Composes two components:
# mojoui.audio's Microphone (the sound server, on its own thread) and mojoui.speech's SpeechModel + SpeechStream
# (whisper-large-v3-turbo in this process, samples by address). The UI thread only moves samples and draws: every 30 ms
# it hands the new samples over and takes the words that are ready.
#
# The readout under each transcript: "N ms after you stopped · on <GPU> · on this machine", N = from when the last
# voiced 20 ms of the utterance was captured to when its final text was on screen (the text that stood once the pause
# was long enough; it's shown the moment it is ready). It is a floor (review round 1): it starts when that chunk reached
# Mojo (mojoui.audio stamps a chunk when pa_simple_read returns it, so the sound server's buffering before is uncounted)
# and ends when the event is polled; "stopped" = the stream's frames quieter than RMS 0.006. Each utterance also prints
#   DICTATE FINAL: ms=<N> text=<the words>
# Run it in the speech environment (scripts/build.sh makes build/dictate/linux/dictate a launcher that finds it).

from mojoui import App, Event, View, VStack, HStack, Text, Button, Spacer, Divider, TITLE, CAPTION, HEADLINE, PROMINENT, PLAIN, CENTER
from mojoui.audio import Microphone
from mojoui.speech import SpeechModel, SpeechStream, FINAL, PARTIAL
from mojoui.effects import Every
from mojoui.clock import now_ns
from mojoui.theme import Theme
from themes.liquid import liquid

comptime RECORD = 1
comptime TICK = 2
comptime CLEAR = 3


@fieldwise_init
struct Said(Copyable, Movable):
    var text: String
    var ms: Float64


struct Main(App):
    var mic: Microphone
    var model: Optional[SpeechModel]
    var live: Optional[SpeechStream]
    var recording: Bool
    var since: Int  # the next sample to hand over (the microphone's absolute index)
    var words: String  # the utterance in progress, as last transcribed
    var shown_text: String  # the text on screen since shown_ns (a FINAL with the same text was ready then)
    var shown_ns: Int
    var said: List[Said]
    var gpu: String
    var status: String
    var level: Float64

    def __init__(out self):
        self.mic = Microphone()
        self.model = None
        self.live = None
        self.recording = False
        self.since = 0
        self.words = ""
        self.shown_text = ""
        self.shown_ns = 0
        self.said = List[Said]()
        self.gpu = ""
        self.status = "loading the speech model…"
        self.level = 0.0
        try:
            self.model = SpeechModel(wait=False)  # loads on a thread of its own; the window opens meanwhile
        except e:
            self.status = "no speech model: " + String(e)

    def title(self) -> String:
        return "Dictate"

    def theme(self) -> Theme:
        return liquid()

    def window_size(self) -> Tuple[Int, Int]:
        return (720, 560)

    def every(self) -> List[Every]:
        var out = List[Every]()
        if self.recording or not self.live:
            out.append(Every(30, TICK))
        return out^

    def update(mut self, event: Event):
        if event.message == RECORD:
            if not self.recording:
                self.mic.start()
                self.since = max(self.since, self.mic.total())
                self.recording = True
            else:
                self.recording = False
                self.hand_over()
                try:
                    if self.live:
                        self.live.value().flush()
                except:
                    pass
        elif event.message == CLEAR:
            self.said = List[Said]()
        elif event.message == TICK:
            self.tick()

    def tick(mut self):
        if not self.live and self.model:
            ref m = self.model.value()
            if m.failed():
                try:
                    self.status = "the speech model failed: " + m.why()
                except:
                    self.status = "the speech model failed"
                self.model = None
                return
            if m.ready():
                try:
                    self.gpu = m.gpu()
                    self.live = SpeechStream(m)
                    self.status = "ready · " + m.name
                except e:
                    self.status = "no stream: " + String(e)
        if self.mic.failed():
            self.status = "microphone: " + self.mic.why()
        self.hand_over()
        self.level = self.mic.level()

    def hand_over(mut self):
        """New samples to the stream, ready words from it (a few ms at most: neither waits for the model)."""
        if not self.live:
            return
        try:
            ref live = self.live.value()
            if self.recording:
                var total = self.mic.total()
                if total > self.since:
                    var got = self.mic.read(self.since)
                    live.feed(got, self.mic.captured_ns(total - 1))
                    self.since = total
            for e in live.poll():
                if e.kind == PARTIAL:
                    self.words = e.text
                    if e.end_ns != 0 and e.text != self.shown_text:  # a pause's transcript: on screen from now
                        self.shown_text = e.text
                        self.shown_ns = now_ns()
                else:
                    var shown = self.shown_ns if (e.text == self.shown_text and self.shown_ns > 0) else now_ns()
                    var ms = Float64(shown - e.end_ns) / 1e6
                    print("DICTATE FINAL: ms=" + String(Int(ms + 0.5)) + " text=" + e.text, flush=True)
                    self.said.append(Said(e.text, ms))
                    self.words = ""
                    self.shown_text = ""
                    self.shown_ns = 0
        except e:
            self.status = "speech: " + String(e)

    def view(self) -> View:
        var col = List[View]()
        var head = List[View]()
        head.append(Text("Dictate", TITLE))
        head.append(Spacer())
        head.append(Button("Clear", CLEAR, PLAIN))
        head.append(Button("Stop" if self.recording else "Record", RECORD, PROMINENT))
        col.append(HStack(head^, spacing=8).fill().align(CENTER))
        var bars = Int(self.level * 120.0) if self.recording else 0
        var meter = String("")
        for _ in range(min(bars, 24)):
            meter += "▮"
        col.append(Text(("listening " + meter) if self.recording else self.status, CAPTION))
        col.append(Text(self.words if self.words else ("…" if self.recording else "Press Record and speak."), HEADLINE))
        col.append(Divider())
        var k = len(self.said) - 1
        while k >= 0 and k >= len(self.said) - 6:
            ref s = self.said[k]
            col.append(Text(s.text))
            col.append(Text(String(Int(s.ms + 0.5)) + " ms after you stopped · on " + self.gpu + " · on this machine", CAPTION))
            k -= 1
        if len(self.said) > 0:
            col.append(Text("ms after you stopped is a floor: from your last voiced 20 ms reaching the app (quieter than "
                            + "RMS 0.006 counts as stopped) to the text being taken; the sound server's own buffering "
                            + "before that isn't counted", CAPTION))
        return VStack(col^, spacing=10).padding(20, 24).grow().fill()
