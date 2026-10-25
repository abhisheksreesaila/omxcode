# themes: one screen of everyday controls, and the theme it's drawn in, switched live (goal 27, D-260). "Native" is no
# theme at all: each platform's own look. The others are modules in themes/ (Paper is the one to copy for your own):
# the framework knows none of them.

from mojoui.view import (View, Text, Button, TextField, Toggle, Dropdown, Segmented, ProgressBar, Canvas, VStack, HStack, Card,
                         Spacer, Divider, TITLE, HEADLINE, CAPTION, PROMINENT, SUBTLE, START, CENTER, TONE_ACCENT, TONE_GOOD,
                         TONE_WARN, CARD_GOOD)
from mojoui.overlays import Checkbox
from mojoui.app import App, Event
from mojoui.canvas import Surface
from mojoui.draw import rect
from mojoui.theme import Theme, Palette
from themes.paper import paper
from themes.liquid import liquid
from themes.skins import ledger, graphite
from themes.omxqua import omxqua

comptime PICK = 1
comptime NAME = 2
comptime NOTIFY = 3
comptime TIDY = 4
comptime SIZE = 5
comptime SAVE = 6
comptime NAMES: List[String] = ["Native", "Paper", "Liquid", "Ledger", "Graphite", "omxqua"]
comptime OMXQUA = 5  # (follows the system's light or dark, as the original console does)


def theme_at(i: Int, dark: Bool = False) -> Theme:
    if i == OMXQUA:
        return omxqua(dark)
    if i == 1:
        return paper()
    if i == 2:
        return liquid()
    if i == 3:
        return ledger()
    if i == 4:
        return graphite()
    return Theme.native()


struct Main(App):
    var at: Int
    var dark: Bool  # the system's mode (App.appearance): what Native draws its canvas in
    var look: Theme
    var name: String
    var notify: Bool
    var tidy: Bool
    var size: Int
    var saved: Int
    var version: Int

    def __init__(out self):
        self.at = 0
        self.dark = False
        self.look = Theme.native()
        self.name = "Ada"
        self.notify = True
        self.tidy = False
        self.size = 1
        self.saved = 0
        self.version = 1

    def title(self) -> String:
        return "themes"

    def window_size(self) -> Tuple[Int, Int]:
        return (900, 760)

    def theme(self) -> Theme:
        return self.look.copy()

    def appearance(mut self, dark: Bool):
        self.dark = dark
        if self.at == 0 or self.at == OMXQUA:
            self.look = Theme.native(dark) if self.at == 0 else theme_at(self.at, dark)
            self.version += 1

    def update(mut self, event: Event):
        var m = event.message
        if m == PICK and 0 <= event.number < len(materialize[NAMES]()):
            self.at = event.number
            self.look = theme_at(self.at, self.dark) if self.at != 0 else Theme.native(self.dark)
            self.version += 1
        elif m == NAME:
            self.name = event.text
        elif m == NOTIFY:
            self.notify = event.number == 1
        elif m == TIDY:
            self.tidy = event.number == 1
        elif m == SIZE:
            self.size = event.number
        elif m == SAVE:
            self.saved += 1

    def draw(mut self, canvas: Int, mut surface: Surface):
        """The theme's series: drawn views (charts, grids) take the palette, so they match the controls."""
        var pal = self.look.palette.copy()
        surface.fill(pal.card)
        var k = surface.scale
        var w = Float64(surface.width) / 8
        for i in range(8):
            var h = Float64(surface.height) * (0.35 + 0.08 * Float64((i * 5) % 8))
            rect(surface, Float64(i) * w + 4 * k, Float64(surface.height) - h, w - 8 * k, h, pal.data(i), 3 * k)

    def view(self) -> View:
        var who = materialize[NAMES]()[self.at]
        return VStack(
            Segmented(materialize[NAMES](), self.at, PICK).tag("theme-picker"),
            Text(who, TITLE),
            Text("Native is no theme: the platform's own look. The rest are modules outside the framework." if self.at == 0
                 else "themes/" + (String("omxqua") if self.at == OMXQUA else self.look.id) + ".mojo: a palette, a GTK style sheet and a web style sheet.", CAPTION),
            Card(
                HStack(Text("Profile", HEADLINE), Spacer(), Text("saved " + String(self.saved) + "×" if self.saved > 0 else "not saved", CAPTION).tone(TONE_ACCENT), spacing=8).fill().align(CENTER),
                TextField(self.name, "Your name", on_change=NAME).fill(),
                Toggle("Notifications", self.notify, NOTIFY).fill(),
                Checkbox("Tidy the columns on save", self.tidy, TIDY),
                Dropdown(["Small", "Medium", "Large"], self.size, SIZE).fill(),
                ProgressBar(40 + 20 * self.size).fill(),
                Divider().fill(),
                HStack(Button("Cancel", SAVE, SUBTLE), Spacer(), Button("Preview", SAVE), Button("Save", SAVE, PROMINENT), spacing=8).fill(),
                spacing=12).fill().tag("profile"),
            HStack(Text("Synced", CAPTION).tone(TONE_GOOD), Text("2 warnings", CAPTION).tone(TONE_WARN), spacing=16),
            Canvas(1, self.version).fill().height(90).tag("series"),
            spacing=14).align(START).max_width(560)
