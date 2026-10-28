# widgets: a note with JavaScript inside (goal 34). The note's editor is CodeMirror 6 from npm (web/package.json, its
# widget in TypeScript: web/widgets/editor.ts); its word count and a small chart of the count over edits are Mojo. A
# vendored counter widget (web/widgets/counter.js) proves the seam both ways: its props come from Mojo, its clicks reach
# update(), Mojo asks it for its count (a command) and hears the answer. Apache ECharts from npm (web/widgets/chart.ts)
# draws the same word-count series Mojo keeps (props), and a click on one of its points comes back to update(). Every line of state is Mojo; each widget is a
# script bundle the app lists in web_assets() (scripts/web_assets.py builds them).

from mojoui.view import View, Text, Button, VStack, HStack, Card, Spacer, CAPTION, HEADLINE, TITLE, PROMINENT, START, SPACE_XS, SPACE_S, SPACE_M, SPACE_L
from mojoui.app import App, Event
from mojoui.canvas import Surface
from mojoui.theme import Theme
from mojoui.json import Json
from mojoui.sparkline import Sparkline, SparklineView
from mojoui.webcomponent import WebComponent, Props, Command, Widgets
from themes.omxqua import omxqua

comptime COUNTER = 2  # the counter's events (event.name "click" or "change", event.text {"count", "step"})
comptime BIGGER = 3
comptime ASK = 4
comptime READ = 5  # the counter's answer to "read"
comptime DETAILS = 6
comptime EDITED = 7  # the editor's events (event.name "change", event.text {"text"})
comptime LOAD = 8
comptime PICK = 9  # a point picked on the ECharts chart (event.name "pick", event.text {"index", "value"})
comptime LONG = 5  # past this many words the note says so (a line appears: the screen is rebuilt around the editor)
comptime CHART = 0  # the word-count chart's canvas
comptime SAMPLE = "The quick brown fox jumps over the lazy dog"
comptime COUNTER_LABEL = "Clicks & <b>counts</b> <img src=x>"  # (shown as text by the widget: props are data, never HTML)


def word_count(text: String) -> Int:
    var n = 0
    var inside = False
    for b in text.as_bytes():
        var space = Int(b) == 32 or Int(b) == 10 or Int(b) == 9 or Int(b) == 13
        if not space and not inside:
            n += 1
        inside = not space
    return n


struct Main(App):
    var text: String  # the note, as the editor last said
    var loaded: String  # the text Mojo last gave the editor (its doc prop)
    var rev: Int  # moves on when Mojo sets the text: the editor takes doc only then
    var history: List[Float64]  # the word count after each edit (the chart)
    var clicks: Int  # counter events heard
    var last_count: Int
    var step: Int
    var replied: String
    var details: Bool
    var picked: String  # the chart's point last clicked
    var widgets: Widgets
    var dark: Bool
    var themed: Theme

    def __init__(out self):
        self.text = ""
        self.loaded = ""
        self.rev = 0
        self.history = List[Float64]()
        self.clicks = 0
        self.last_count = 0
        self.step = 1
        self.replied = "(not asked)"
        self.details = False
        self.picked = "tap a point"
        self.widgets = Widgets()
        self.dark = False
        self.themed = omxqua(False)

    def title(self) -> String:
        return "widgets"

    def window_size(self) -> Tuple[Int, Int]:
        return (1100, 760)

    @staticmethod
    def web_assets() -> List[String]:
        return ["counter.js", "counter.css", "editor.js", "editor.css", "chart.js", "chart.css"]

    def appearance(mut self, dark: Bool):
        self.dark = dark
        self.themed = omxqua(dark)

    def theme(self) -> Theme:
        return self.themed.copy()

    def commands(mut self) -> List[Command]:
        return self.widgets.take()

    def set_text(mut self, text: String):
        self.text = text
        self.history.append(Float64(word_count(text)))
        if len(self.history) > 60:
            _ = self.history.pop(0)

    def update(mut self, event: Event):
        var m = event.message
        if m == EDITED and event.name == "change":
            try:
                var j = Json.parse(event.text)
                self.set_text(j.text(j.get(0, "text")))
            except:
                pass
        elif m == LOAD:
            self.loaded = SAMPLE
            self.rev += 1
            self.set_text(SAMPLE)
        elif m == COUNTER and event.name == "change":  # (its count was set: by an agent, through the widget's field)
            try:
                var j = Json.parse(event.text)
                self.last_count = j.number(j.get(0, "count"))
            except:
                pass
        elif m == COUNTER and event.name == "click":
            self.clicks += 1
            try:
                var j = Json.parse(event.text)
                self.last_count = j.number(j.get(0, "count"))
            except:
                pass
        elif m == BIGGER:
            self.step += 1
        elif m == ASK:
            self.widgets.call(Command("mx-counter", 1, "read", reply=READ))
        elif m == READ:
            if event.error != "":
                self.replied = "error: " + event.error
            else:
                try:
                    var j = Json.parse(event.text)
                    self.replied = "count " + String(j.number(j.get(0, "count")))
                except:
                    self.replied = "(not JSON)"
        elif m == DETAILS:
            self.details = not self.details
        elif m == PICK and event.name == "pick":
            try:
                var j = Json.parse(event.text)
                self.picked = "edit " + String(j.number(j.get(0, "index")) + 1) + ", " + String(j.number(j.get(0, "value"))) + " words"
            except:
                pass

    def draw(mut self, canvas: Int, mut surface: Surface):
        var p = self.themed.palette.copy()
        surface.fill(p.card)
        Sparkline.themed(self.history, p).draw(surface)

    def series(self) -> String:
        """The word count after each edit, as a JSON list (the chart's data)."""
        var out = String("[")
        for i in range(len(self.history)):
            if i > 0:
                out += ","
            out += String(Int(self.history[i]))
        return out + "]"

    def view(self) -> View:
        var words = word_count(self.text)
        var edits = len(self.history)
        var note_items: List[View] = [Text("Note", style=HEADLINE)]
        if words > LONG:  # (a line that comes and goes: the screen is rebuilt around the editor, which keeps its cursor)
            note_items.append(Text("Long note", CAPTION).tag("long"))
        note_items.append(WebComponent("mx-editor", Props().text("doc", self.loaded).number("rev", self.rev).text("placeholder", "Write a note"),
                                       on_event=EDITED, id=1).fill().tag("editor"))
        note_items.append(HStack(Text("Words: " + String(words)), Text("words after each of " + String(edits) + (" edit" if edits == 1 else " edits"), CAPTION), Spacer(),
                                 Button("Load sample", on_tap=LOAD), spacing=SPACE_S).fill().tag("note-bar"))
        note_items.append(SparklineView(CHART, len(self.history)))
        var note = Card(note_items, spacing=SPACE_S).align(START).fill().grow()
        var counter_items: List[View] = [
            Text("Counter", style=HEADLINE),
            Text("A vendored plain-JS widget: its count is its own; its label and step come from Mojo.", CAPTION),
            WebComponent("mx-counter", Props().text("label", COUNTER_LABEL).number("step", self.step), on_event=COUNTER, id=1).fill().tag("counter"),
            HStack(Button("Bigger steps", on_tap=BIGGER), Button("Ask the counter", on_tap=ASK, style=PROMINENT),
                   Button("Hide details" if self.details else "Show details", on_tap=DETAILS), spacing=SPACE_S).tag("counter-bar"),
            Text("Clicks seen by Mojo: " + String(self.clicks)),
            Text("Last count: " + String(self.last_count)),
            Text("Step: " + String(self.step)),
            Text("Counter replied: " + self.replied),
        ]
        if self.details:
            counter_items.append(Text("Details shown"))
            counter_items.append(Text("The page was rebuilt around the widget: it kept its element, its count and its focus.", CAPTION))
        var counter = Card(counter_items, spacing=SPACE_S).align(START).fill()
        var chart = Card(
            Text("Words over edits", style=HEADLINE),
            Text("Apache ECharts from npm, drawing the series Mojo keeps. Tap a point.", CAPTION),
            WebComponent("mx-chart", Props().raw("series", self.series()), on_event=PICK, id=1).fill().tag("chart"),
            Text("Picked: " + self.picked).tag("picked"),
            spacing=SPACE_S,
        ).align(START).fill()
        var side = VStack(counter, chart, spacing=SPACE_L).align(START).width(440)
        return VStack(
            VStack(Text("Widgets", style=TITLE), Text("A note with JavaScript inside: every line of state is Mojo.", CAPTION), spacing=SPACE_XS).align(START),
            HStack(note, side, spacing=SPACE_L).align(START).fill(),
            spacing=SPACE_M,
        ).align(START).padding(32).fill().grow()
