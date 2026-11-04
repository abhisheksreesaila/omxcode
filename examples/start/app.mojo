# start: the getting-started app (docs/start.html). One file: a counter, drawn with each platform's own controls,
# in the Liquid look. Build it: scripts/build.sh start linux (or web, mac); run build/start/linux/start.

from mojoui import App, Event, View, VStack, Text, Button, TITLE, CAPTION, PROMINENT
from mojoui.theme import Theme
from themes.liquid import liquid

comptime TAP = 1


struct Main(App):
    var taps: Int

    def __init__(out self):
        self.taps = 0

    def title(self) -> String:
        return "Hello"

    def theme(self) -> Theme:
        return liquid()

    def update(mut self, event: Event):
        if event.message == TAP:
            self.taps += 1

    def view(self) -> View:
        return VStack(
            Text("Hello from Mojo", style=TITLE),
            Text("Tapped " + String(self.taps) + " times", style=CAPTION),
            Button("Tap me", on_tap=TAP, style=PROMINENT),
            spacing=16,
        )
