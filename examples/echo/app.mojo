# Echo (goal 72 M5): the smallest app that uses a microphone and a speaker, to show that the same Mojo code runs on the desktop
# and on a tablet's browser (the web host carries the page's microphone in and the speaker out, docs/web-audio.md).
# Listen records; Play back says it again; Tone plays a 440 Hz tone for three seconds; Stop sound stops it at once.
# $ECHO_WAV (a 16 kHz .wav): what the microphone should hear; the screen says how well it matched (the checks use it).
from mojoui import App, Event, View, VStack, HStack, Text, Button, Spacer, TITLE, CAPTION, HEADLINE, PROMINENT, PLAIN, CENTER
from mojoui.audio import Microphone, load_wav, best_match, RATE
from mojoui.speaker import Speaker, OUT_RATE
from mojoui.effects import Every
from mojoui.shared import environment
from mojoui.theme import Theme
from themes.liquid import liquid
from std.math import sin

comptime LISTEN = 1
comptime BACK = 2
comptime TONE = 3
comptime QUIET = 4
comptime TICK = 5


struct Main(App):
    var mic: Microphone
    var speaker: Speaker
    var listening: Bool
    var heard: List[Float32]
    var status: String
    var level: Float64

    def __init__(out self):
        self.mic = Microphone()
        self.speaker = Speaker()
        self.listening = False
        self.heard = List[Float32]()
        self.status = "Press Listen."
        self.level = 0.0

    def title(self) -> String:
        return "Echo"

    def theme(self) -> Theme:
        return liquid()

    def window_size(self) -> Tuple[Int, Int]:
        return (480, 360)

    def every(self) -> List[Every]:
        var out = List[Every]()
        if self.listening:
            out.append(Every(50, TICK))
        return out^

    def update(mut self, event: Event):
        if event.message == LISTEN:
            if not self.listening:
                self.mic.start()
                self.listening = True
                self.status = "listening…"
            else:
                self.finish()
        elif event.message == TICK:
            if self.mic.failed():
                self.listening = False
                self.status = "microphone: " + self.mic.why()
            else:
                self.level = self.mic.level()
                self.status = "listening · " + String(self.mic.total()) + " samples"
        elif event.message == BACK:
            self.speaker.play(self.heard, RATE)
        elif event.message == TONE:
            var tone = List[Float32]()
            for i in range(OUT_RATE * 3):
                tone.append(Float32(0.5 * sin(2.0 * 3.141592653589793 * 440.0 * Float64(i) / Float64(OUT_RATE))))
            self.speaker.play(tone, OUT_RATE)
            self.status = "tone playing"
        elif event.message == QUIET:
            self.speaker.stop()
            self.status = "sound stopped"

    def finish(mut self):
        """Stops listening and says what arrived: how many samples, and how well they match $ECHO_WAV."""
        self.mic.stop()
        self.listening = False
        self.heard = self.mic.read(0)
        var words = "heard " + String(len(self.heard)) + " samples"
        var path = environment("ECHO_WAV")
        if path != "" and len(self.heard) > 0:
            try:
                var want = load_wav(path)
                var m = best_match(self.heard, want)
                words += " · match " + String(Int(m[0] * 100.0 + 0.5)) + " %"
            except e:
                words += " · no reference: " + String(e)
        self.status = words

    def view(self) -> View:
        var buttons = List[View]()
        buttons.append(Button("Stop listening" if self.listening else "Listen", LISTEN, PROMINENT))
        buttons.append(Button("Play back", BACK, PLAIN))
        buttons.append(Button("Tone", TONE, PLAIN))
        buttons.append(Button("Stop sound", QUIET, PLAIN))
        var col = List[View]()
        col.append(Text("Echo", TITLE))
        col.append(HStack(buttons^, spacing=8).align(CENTER))
        col.append(Text(self.status, HEADLINE))
        col.append(Text("level " + String(Int(self.level * 1000.0)) + " / 1000", CAPTION))
        return VStack(col^, spacing=14).padding(20, 24).grow().fill()
