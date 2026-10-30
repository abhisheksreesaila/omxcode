# Accessibility check (a framework check): a screen with every way a view gets its screen-reader name (mojoui.a11y),
# and one control left unnamed on purpose. Each host hands the names to its platform's accessibility API:
#   GTK:  MOJOUI_TEST="a11y" GTK_A11Y=test build/a11ycheck/linux/a11ycheck   (A11Y: lines, as GTK reports them)
#   web:  scripts/check_a11y.py reads Chromium's accessibility tree
# Tap "Rename" and the chart's words change in place (a tooltip is a patch): its accessible name follows.

from mojoui import App, Event, View, Surface, VStack, HStack, Text, Button, Dropdown, Slider, Canvas, TextField
from mojoui.view import ICON_ONLY

comptime DELETE = 1
comptime REGION = 2
comptime ZOOM = 3
comptime RENAME = 4
comptime SEARCH = 5


struct Main(App):
    var region: Int
    var zoom: Int
    var average: Bool
    var query: String

    def __init__(out self):
        self.region = 0
        self.zoom = 40
        self.average = False
        self.query = ""

    def title(self) -> String:
        return "Accessibility check"

    def update(mut self, event: Event):
        if event.message == REGION:
            self.region = event.number
        elif event.message == ZOOM:
            self.zoom = event.number
        elif event.message == RENAME:
            self.average = not self.average
        elif event.message == SEARCH:
            self.query = event.text

    def draw(mut self, canvas: Int, mut s: Surface):
        s.fill(UInt32(0xFFE0D0C0))

    def view(self) -> View:
        var words = ("Average" if self.average else "Sum") + " of amount by region, as bars"
        return VStack(
            Text("Sales"),
            HStack(
                Button("Delete", DELETE, ICON_ONLY, icon="trash").tag("delete"),  # an icon: its title is its name
                Button("Rename", RENAME).tag("rename"),  # its own words
                spacing=8,
            ),
            Dropdown(["East", "West"], self.region, REGION).label("Region").tag("region"),  # .label(): never shown
            TextField(self.query, placeholder="Search", on_change=SEARCH).tag("search"),  # its placeholder
            Slider(self.zoom, ZOOM).tag("zoom"),  # unnamed on purpose: the audit lists it
            Canvas(1, 0).tooltip(words).tag("chart").width(240).height(120),  # a drawn view: its words
            spacing=10,
        ).padding(16)
