# Gallery: every mojoui component, wired to a little state. Same file on every platform.

from mojoui import (
    App, Event, View, VStack, HStack, Text, Button, TextField, Toggle, Dropdown, Slider, ProgressBar, Divider, Image,
    TITLE, HEADLINE, CAPTION, PROMINENT,
)
from mojoui.theme import Theme
from mojoui.shared import environment
from themes.skins import skin, ledger_palette, graphite_palette, blueprint_palette
from themes.liquid import liquid

comptime NAME = 1
comptime RESET = 2
comptime NOTIFY = 3
comptime SIZE = 4
comptime VOLUME = 5
comptime GREET = 6


def swatch(volume: Int) -> List[UInt32]:
    """A 120×40 gradient whose colour follows the volume (pixels made in plain Mojo)."""
    var pixels = List[UInt32](capacity=120 * 40)
    for y in range(40):
        for x in range(120):
            var r = UInt32(volume * 255 // 100)
            var g = UInt32(x * 255 // 119)
            var b = UInt32(255 - y * 4)
            pixels.append(r | (g << 8) | (b << 16) | (UInt32(255) << 24))
    return pixels^


struct Main(App):
    var name: String
    var greeted: Int
    var notify: Bool
    var size: Int
    var volume: Int
    var look: Theme  # GALLERY_SKIN=ledger|graphite|blueprint|liquid|liquid-dark: the components in a skin (unset: each platform's own look)
    var skin_name: String  # (liquid follows the system's light or dark: App.appearance)

    def __init__(out self):
        var name = environment("GALLERY_SKIN")
        self.skin_name = name
        self.look = (skin(name, graphite_palette() if name == "graphite" else (blueprint_palette() if name == "blueprint" else ledger_palette()))
                     if name == "graphite" or name == "ledger" or name == "blueprint" else (liquid(name == "liquid-dark") if name == "liquid" or name == "liquid-dark" else Theme.native()))
        self.name = ""
        self.greeted = 0
        self.notify = False
        self.size = 1
        self.volume = 30

    def title(self) -> String:
        return "Gallery"

    def theme(self) -> Theme:
        return self.look.copy()

    def appearance(mut self, dark: Bool):
        if self.skin_name == "liquid":
            self.look = liquid(dark)

    def update(mut self, event: Event):
        if event.message == NAME:
            self.name = event.text
        elif event.message == RESET:
            self.name = ""
        elif event.message == GREET:
            self.greeted += 1
        elif event.message == NOTIFY:
            self.notify = event.number == 1
        elif event.message == SIZE:
            self.size = event.number
        elif event.message == VOLUME:
            self.volume = event.number

    def view(self) -> View:
        var sizes: List[String] = ["Small", "Medium", "Large"]
        var hello = "Type your name below" if self.name == "" else "Hello, " + self.name
        return VStack(
            Text("Components", style=TITLE),
            Text(hello, style=HEADLINE),
            HStack(
                TextField(self.name, placeholder="Your name", on_change=NAME, on_submit=GREET),
                Button("Reset", on_tap=RESET),
            ),
            Divider(),
            Toggle("Notifications", self.notify, on_toggle=NOTIFY),
            Text("Notifications are " + ("on" if self.notify else "off"), style=CAPTION),
            HStack(Text("Text size"), Dropdown(sizes, self.size, on_select=SIZE)),
            Divider(),
            Text("Volume " + String(self.volume), style=CAPTION),
            Slider(self.volume, on_change=VOLUME),
            ProgressBar(self.volume),
            Image(swatch(self.volume), 120, 40),
            Button("Say hello (" + String(self.greeted) + ")", on_tap=GREET, style=PROMINENT),
            spacing=14,
        )
