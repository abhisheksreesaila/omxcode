# widgets: a note with JavaScript inside (goal 34). The note's editor, its word count and a small chart of the count
# over edits are the app; a vendored counter widget (web/widgets/counter.js) proves the seam both ways: its props come
# from Mojo, its clicks reach update(), Mojo asks it for its count (a command) and hears the answer. Every line of state
# is Mojo; each widget is a script bundle the app lists in web_assets() (scripts/web_assets.py builds them).

from mojoui.view import View, Text, Button, TextArea, VStack, HStack, Card, CAPTION, HEADLINE, TITLE, PROMINENT, START, SPACE_XS, SPACE_S, SPACE_M, SPACE_L
from mojoui.app import App, Event
from mojoui.canvas import Surface
from mojoui.theme import Theme
from mojoui.json import Json
from mojoui.sparkline import Sparkline, SparklineView
from mojoui.webcomponent import WebComponent, Props, Command, Widgets
from themes.omxqua import omxqua

comptime TYPED = 1  # the note's text changed (event.text)
comptime COUNTER = 2  # the counter's events (event.name "click", event.text {"count", "step"})
comptime BIGGER = 3
comptime ASK = 4
comptime READ = 5  # the counter's answer to "read"
comptime DETAILS = 6
comptime CHART = 0  # the word-count chart's canvas
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
    var text: String
    var history: List[Float64]  # the word count after each edit (the chart)
    var clicks: Int  # counter events heard
    var last_count: Int
    var step: Int
    var replied: String
    var details: Bool
    var widgets: Widgets
    var dark: Bool
    var themed: Theme

    def __init__(out self):
        self.text = ""
        self.history = List[Float64]()
        self.clicks = 0
        self.last_count = 0
        self.step = 1
        self.replied = "(not asked)"
        self.details = False
        self.widgets = Widgets()
        self.dark = False
        self.themed = omxqua(False)

    def title(self) -> String:
        return "widgets"

    def window_size(self) -> Tuple[Int, Int]:
        return (1100, 760)

    @staticmethod
    def web_assets() -> List[String]:
        return ["counter.js", "counter.css"]

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
        if m == TYPED:
            self.set_text(event.text)
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

    def draw(mut self, canvas: Int, mut surface: Surface):
        var p = self.themed.palette.copy()
        surface.fill(p.card)
        Sparkline.themed(self.history, p).draw(surface)

    def view(self) -> View:
        var words = word_count(self.text)
        var note = Card(
            Text("Note", style=HEADLINE),
            TextArea(self.text, placeholder="Write a note", on_change=TYPED, height=220).fill().tag("editor"),
            HStack(Text("Words: " + String(words)), Text("words after each edit", CAPTION), spacing=SPACE_S),
            SparklineView(CHART, len(self.history)),
            spacing=SPACE_S,
        ).align(START).fill().grow()
        var counter_items: List[View] = [
            Text("Counter", style=HEADLINE),
            Text("A vendored plain-JS widget: its count is its own; its label and step come from Mojo.", CAPTION),
            WebComponent("mx-counter", Props().text("label", COUNTER_LABEL).number("step", self.step), on_event=COUNTER, id=1).fill().tag("counter"),
            HStack(Button("Bigger steps", on_tap=BIGGER), Button("Ask the counter", on_tap=ASK, style=PROMINENT),
                   Button("Hide details" if self.details else "Show details", on_tap=DETAILS), spacing=SPACE_S),
            Text("Clicks seen by Mojo: " + String(self.clicks)),
            Text("Last count: " + String(self.last_count)),
            Text("Step: " + String(self.step)),
            Text("Counter replied: " + self.replied),
        ]
        if self.details:
            counter_items.append(Text("Details shown"))
            counter_items.append(Text("The page was rebuilt around the widget: it kept its element, its count and its focus.", CAPTION))
        var counter = Card(counter_items, spacing=SPACE_S).align(START).width(440)
        return VStack(
            VStack(Text("Widgets", style=TITLE), Text("A note with JavaScript inside: every line of state is Mojo.", CAPTION), spacing=SPACE_XS).align(START),
            HStack(note, counter, spacing=SPACE_L).align(START).fill(),
            spacing=SPACE_M,
        ).align(START).padding(32).fill().grow()
