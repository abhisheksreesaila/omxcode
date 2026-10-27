# consolekit: the OMX Console's components on one page, in omxqua (goal 33 M4). Each is the framework's own (mojoui/),
# shown here the way the console uses it: the model table with tick boxes, a CodeBlock to copy, a LogView that follows
# its end, Revoke that asks twice, chips, badges and a pill, skeletons, the breadcrumb trail and the Route (the web
# keeps it in the URL: open #/models/qwen2.5-0.5b/logs), a notebook's Markdown, a Paragraph of styled runs with a link (its
# words that look like markup stay words), a Sparkline and Add a model's Timeline.

from mojoui.view import View, Text, Button, VStack, HStack, Card, Spacer, Divider, CAPTION, HEADLINE, PROMINENT, START, CENTER
from mojoui.app import App, Event
from mojoui.canvas import Surface
from mojoui.effects import Every
from mojoui.theme import Theme
from mojoui.table import Table
from mojoui.codeblock import CodeBlock
from mojoui.logview import LogView
from mojoui.breadcrumbs import Breadcrumbs
from mojoui.chip import Chip, Badge, Pill, BADGE_OK
from mojoui.confirm import TwoStep, ConfirmButton
from mojoui.skeleton import Skeleton
from mojoui.route import Route, Router, Match
from mojoui.markdown import Markdown
from mojoui.paragraph import Paragraph, Plain, Code, Link
from mojoui.sparkline import Sparkline, SparklineView
from mojoui.timeline import Timeline, Stage, STAGE_PENDING, STAGE_RUNNING, STAGE_DONE
from themes.omxqua import omxqua

comptime ROUTE = 1
comptime OPEN_KEYS = 2
comptime COPY = 3
comptime REVOKE = 4
comptime DISARM = 5
comptime ADD_LINES = 6
comptime NEXT_STAGE = 7
comptime OPEN_LOGS = 8
comptime LINK = 9  # a Paragraph's (or the notes') link: event.text = its href, event.number = its run
comptime CRUMB = 10  # + the crumb's place in the trail
comptime TICK_ALL = 99
comptime TICK = 100  # + the row
comptime SPARK = 0  # the sparkline's canvas



def pages() -> Router:
    """The sampler's places, as the console's: a table of patterns and their trails (mojoui.route matches and writes)."""
    return (Router("home").page("home", "/", ["My models"])
            .page("keys", "/keys", ["API keys"])
            .page("model", "/models/:model*/:tab(overview|benchmark|logs|notebook)?", ["My models", ":model"]))


comptime CODE = "curl http://127.0.0.1:11435/v1/models"
comptime NOTES = "## Notes\nRun **qwen2.5-0.5b** with `mxc run qwen2.5-0.5b`, then ask it anything.\n\n- answers stay on this machine\n- [docs](https://example.com/docs)"
comptime STAGES: List[String] = ["Resolve", "Download", "Convert", "Ready"]


struct Main(App):
    var path: String
    var ticked: List[Bool]
    var copies: Int
    var keys: TwoStep
    var revoked: Int  # times notes-app was revoked
    var lines: List[String]
    var stage: Int  # the running stage
    var dark: Bool
    var themed: Theme
    var link: String  # the last link tapped

    def __init__(out self):
        self.path = "/"
        self.link = "none"
        self.ticked = [False, False, False]
        self.copies = 0
        self.keys = TwoStep()
        self.revoked = 0
        self.lines = List[String]()
        for k in range(10):
            self.lines.append("12:02:" + String(10 + k) + ".204 INFO: line " + String(k + 1))
        self.stage = 1
        self.dark = False
        self.themed = omxqua(False)

    def title(self) -> String:
        return "consolekit"

    def window_size(self) -> Tuple[Int, Int]:
        return (1440, 900)

    def appearance(mut self, dark: Bool):
        self.dark = dark
        self.themed = omxqua(dark)

    def theme(self) -> Theme:
        return self.themed.copy()

    def update(mut self, event: Event):
        var m = event.message
        if m == ROUTE:
            self.path = pages().canonical(event.text)  # (its canonical form: "#" alone is home, "/")
        elif m == OPEN_KEYS:
            self.path = "/keys"
        elif m == OPEN_LOGS:
            self.path = pages().path_for(Match("model").with_param("model", "qwen2.5-0.5b").with_param("tab", "logs"))
        elif CRUMB <= m < CRUMB + 4:
            if m == CRUMB:
                self.path = "/"
        elif m == TICK_ALL:
            var every = True
            for t in self.ticked:
                every = every and t
            for k in range(len(self.ticked)):
                self.ticked[k] = not every
        elif TICK <= m < TICK + len(self.ticked):
            self.ticked[m - TICK] = event.number == 1
        elif m == COPY:
            self.copies += 1
        elif m == REVOKE:
            if self.keys.tap(0):
                self.revoked += 1
        elif m == DISARM:
            self.keys.disarm()
        elif m == ADD_LINES:
            var n = len(self.lines)
            for k in range(20):
                self.lines.append("12:03:" + String(n + k) + ".551 INFO: 127.0.0.1 - \"POST /v1/chat/completions HTTP/1.1\" 200 OK")
        elif m == LINK:
            self.link = event.text + " (run " + String(event.number) + ")"
        elif m == NEXT_STAGE:
            self.stage = min(self.stage + 1, len(materialize[STAGES]()))

    def every(self) -> List[Every]:
        return self.keys.every(DISARM)

    def draw(mut self, canvas: Int, mut surface: Surface):
        var p = self.themed.palette.copy()
        surface.fill(p.card)
        var values: List[Float64] = [3, 5, 4, 8, 12, 9, 14, 11, 16, 13, 18, 15]
        Sparkline.themed(values, p).draw(surface)

    def stages(self) -> List[Stage]:
        var names = materialize[STAGES]()
        var out = List[Stage]()
        for k in range(len(names)):
            if k < self.stage:
                out.append(Stage(names[k], STAGE_DONE, Float64(1200 + 2100 * k)))
            elif k == self.stage:
                out.append(Stage(names[k], STAGE_RUNNING, 4200, "35 % · 345 MB of 988 MB", "mxc pull qwen2.5-0.5b", 35))
            else:
                out.append(Stage(names[k]))
        return out^

    def view(self) -> View:
        var place = pages().parse(self.path)
        var said = self.path + ": " + (("model " + place["model"] + ", tab " + place["tab"]) if place.page == "model" else place.page)
        var names: List[String] = ["qwen2.5-0.5b", "all-minilm-l6", "llama3.2-1b"]
        var ids: List[String] = ["Qwen/Qwen2.5-0.5B-Instruct", "sentence-transformers/all-MiniLM-L6-v2", "meta-llama/Llama-3.2-1B-Instruct"]
        var cells: List[View] = []
        for r in range(3):
            cells.append(VStack(Text(names[r]), Text(ids[r], CAPTION), spacing=2).align(START))
            cells.append(Badge("Running", BADGE_OK, dot=True) if r == 0 else Badge("Idle"))
            cells.append(HStack(Chip("Chat", hue=1) if r != 1 else Chip("Embeddings", hue=3), Chip("#work"), spacing=4))
            cells.append(Text(["988 MB", "91 MB", "2.5 GB"][r]))
            cells.append(Text("3.1 GB" if r == 0 else "–"))
            cells.append(Text("158" if r == 0 else "–"))
            cells.append(Badge("This machine"))
        var ticked = String("")
        for r in range(3):
            if self.ticked[r]:
                ticked += (", " if ticked != "" else "") + names[r]
        var revoked = String("notes-app (") + String(self.revoked) + (" time)" if self.revoked == 1 else " times)") if self.revoked > 0 else String("none")
        var confirm_state = ("armed" if self.keys.is_armed(0) else "idle") + ", revoked " + ("none" if self.revoked == 0 else "notes-app")
        var done = min(self.stage, len(materialize[STAGES]()))
        var left = Card(
            Breadcrumbs(pages().crumbs(place), on_tap=CRUMB, mono_last=place.page == "model"),
            HStack(Text("route: " + self.path).tooltip(said).tag("route-state"), Spacer(), Button("Open qwen logs", on_tap=OPEN_LOGS), Button("Open keys", on_tap=OPEN_KEYS), spacing=8).align(CENTER).fill(),
            HStack(Text("My models", HEADLINE), Pill("3"), spacing=8).align(CENTER),
            Table(["Model", "State", "Kind · labels", "Size", "Memory", "Tok/s", "Access"], cells, align="LLLRRRL",
                  ticked=self.ticked, on_tick=TICK, on_tick_all=TICK_ALL).fill().tag("models"),
            Text("ticked: " + ticked),
            HStack(Chip("Chat", hue=1), Chip("Vision", hue=2), Chip("#favorites"), Badge("active", BADGE_OK, dot=True), Badge("prefix only"), spacing=6),
            VStack(Skeleton(), Skeleton(width=320), Skeleton(width=180), spacing=8).fill(),
            Divider().fill(),
            VStack(Markdown(NOTES, on_link=LINK)).align(START).fill().tag("sample-markdown"),
            VStack(Paragraph([Plain("Shown as words: "), Code("<b>not bold</b> & <i>", "md-code"), Plain(" then "), Link("release notes", "https://example.com/notes", "md-link")],
                             role="md-p", on_link=LINK)).align(START).fill().tag("sample-paragraph"),
            Text("link: " + self.link),
            spacing=14,
        ).grow()
        var right = Card(
            Text("Copy the endpoint", HEADLINE),
            CodeBlock(CODE, on_copy=COPY, copies=self.copies, copied=self.copies > 0).fill(),
            HStack(Text("notes-app"), Spacer(), ConfirmButton("Revoke", "Click again to revoke", self.keys.is_armed(0), REVOKE, icon="trash"),
                   spacing=8).align(CENTER).fill().tooltip(confirm_state).tag("confirm-state"),
            Text("revoked: " + revoked),
            HStack(Text("log: " + String(len(self.lines)) + " lines"), Spacer(), Button("Add log lines", on_tap=ADD_LINES), spacing=8).align(CENTER).fill(),
            LogView(self.lines, height=180).fill(),
            VStack(SparklineView(SPARK, 1)).fill().tag("sample-sparkline"),
            HStack(Text("timeline: " + String(done) + " of " + String(len(materialize[STAGES]())) + " done"), Spacer(), Button("Next stage", on_tap=NEXT_STAGE),
                   spacing=8).align(CENTER).fill(),
            VStack(Timeline(self.stages())).align(START).fill().tag("sample-timeline"),
            spacing=12,
        ).width(560)
        return VStack(HStack(left, right, spacing=16).align(START).fill(), Route(self.path, ROUTE), spacing=0).padding(16).fill()
