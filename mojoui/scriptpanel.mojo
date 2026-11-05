# mojoui.scriptpanel: the Script window (goal 49). The UI is a shell that writes the script: a person (or an agent, through
# the same tools) types statements and runs them; picks a section of a video and taps a function (Apply), which writes
# `apply_1 = regions(episode, 3.0, 8.0);` into the script and runs it; Exports the run as a recipe (mojoui.recipe); opens
# a saved one and answers its ${questions}. Any app with tables and videos can host it; mojoui.script runs what it holds.
#
#   var panel = ScriptPanel(msg_base=3360)                     # messages 3360 … 3360 + SCRIPT_MESSAGES
#   panel.offer(videos, playheads, functions)                  # the videos (SQL names), where each is, what Apply can call
#   update():  var did = panel.update(event)                   # SP_RUN: run panel.script(); SP_EXPORT, SP_OPEN: the app's jobs
#   view():    if panel.open: out.append(panel.view("fleet, telemetry, episode (video)"))
#   landed:    panel.ran(log, problem, names)                  # a run's log and results (Export writes these)
#
# Tags (an agent's tools): script-text, run-script, script-close, script-video, range-from, range-to, apply-<function>,
# export-recipe, open-recipe, recipe-path, recipe-<param> (a reopened recipe's questions).

from mojoui.app import Event
from mojoui.overlays import Dialog
from mojoui.script import params_of, bind_params, strip_comments, last_call
from mojoui.view import (View, Text, Button, TextField, TextArea, Dropdown, VStack, HStack, Spacer, CAPTION, PROMINENT, CENTER, START,
                         TONE_ACCENT, TONE_WARN)

comptime SCRIPT_MESSAGES = 16  # text, run, close, video, from, to, export, open, recipe path, then params (4), then Apply (3)
comptime SP_TEXT = 0
comptime SP_RUN_MSG = 1
comptime SP_CLOSE = 2
comptime SP_VIDEO = 3
comptime SP_FROM = 4
comptime SP_TO = 5
comptime SP_EXPORT_MSG = 6
comptime SP_OPEN_MSG = 7
comptime SP_PATH = 8
comptime SP_PARAM = 9  # … 12: a reopened recipe's questions, in order
comptime SP_APPLY = 13  # … 15: the functions Apply offers, in order
comptime MAX_PARAMS = 4
comptime MAX_APPLY = 3

comptime SP_NONE = 0  # what update() asks the app to do
comptime SP_RUN = 1
comptime SP_EXPORT = 2
comptime SP_OPEN = 3
comptime SP_CLOSED = 4


def _seconds(s: String) -> Float64:
    try:
        return Float64(String(s.strip()))
    except:
        return -1.0


def _secs_text(x: Float64) -> String:
    """Seconds as a script writes them: one decimal place (3.0, 12.5)."""
    var tenths = Int(x * 10.0 + 0.5)
    return String(tenths // 10) + "." + String(tenths % 10)


struct ScriptPanel(Movable):
    var msg_base: Int
    var open: Bool
    var text: String
    var said: String
    var log: List[String]
    var results: List[String]  # the last run's result names, in order (Export writes each as CSV)
    var videos: List[String]
    var playheads: List[Float64]
    var functions: List[String]
    var video: Int
    var from_s: String
    var to_s: String
    var applied: Int  # Apply statements written so far (apply_1, apply_2 …)
    var recipe_path: String  # Open recipe: the folder (or its script.sql)
    var params: List[String]  # the script's ${questions} …
    var answers: List[String]  # … and their answers
    var bound: String  # the script with its answers in, as the last run ran it

    def __init__(out self, msg_base: Int):
        self.msg_base = msg_base
        self.open = False
        self.text = ""
        self.said = ""
        self.log = List[String]()
        self.results = List[String]()
        self.videos = List[String]()
        self.playheads = List[Float64]()
        self.functions = List[String]()
        self.video = 0
        self.from_s = ""
        self.to_s = ""
        self.applied = 0
        self.recipe_path = ""
        self.params = List[String]()
        self.answers = List[String]()
        self.bound = ""

    def owns(self, message: Int) -> Bool:
        return self.msg_base <= message < self.msg_base + SCRIPT_MESSAGES

    def offer(mut self, var videos: List[String], var playheads: List[Float64], var functions: List[String]):
        """The videos a section can come from (SQL names), where each one's playhead is, and the functions Apply offers.
        An empty section starts at the playhead and runs five seconds."""
        self.videos = videos^
        self.playheads = playheads^
        self.functions = functions^
        if self.video >= len(self.videos):
            self.video = 0
        if self.from_s == "" and len(self.playheads) > self.video:
            self.from_s = _secs_text(self.playheads[self.video])
            self.to_s = _secs_text(self.playheads[self.video] + 5.0)

    def set_text(mut self, text: String):
        """The script's text (an opened recipe's, an agent's); its ${questions} are asked again."""
        self.text = text
        var asked = params_of(text)
        var answers = List[String]()
        for p in asked:
            var old = -1
            for i in range(len(self.params)):
                if self.params[i] == p:
                    old = i
            answers.append(self.answers[old] if old >= 0 else String(""))
        self.params = asked^
        self.answers = answers^

    def script(mut self) raises -> String:
        """The script to run: its text with each ${question} answered, comments left out (raises when one has no answer
        yet, or it asks more than this window has fields for)."""
        if len(self.params) > MAX_PARAMS:
            raise Error("This script asks " + String(len(self.params)) + " questions (${…}); the window answers up to " + String(MAX_PARAMS) + ": write the rest in")
        var values = Dict[String, String]()
        for i in range(len(self.params)):
            if String(self.answers[i].strip()) != "":
                values[self.params[i]] = String(self.answers[i].strip())
        self.bound = bind_params(strip_comments(self.text), values)
        return self.bound

    def apply_statement(mut self, function: String) raises -> String:
        """`apply_N = function(video, from, to);` for the picked section (raises when it isn't one)."""
        if len(self.videos) == 0:
            raise Error("Open a video first: Apply works on a section of one")
        var a = _seconds(self.from_s)
        var b = _seconds(self.to_s)
        if a < 0 or b <= a:
            raise Error("A section is From < To, in seconds")
        self.applied += 1
        return "apply_" + String(self.applied) + " = " + function + "(" + self.videos[self.video] + ", " + _secs_text(a) + ", " + _secs_text(b) + ");"

    def section(self) -> Tuple[Float64, Float64]:
        return (_seconds(self.from_s), _seconds(self.to_s))

    def applied_section(self) -> Optional[Tuple[String, Float64, Float64]]:
        """The video and seconds the last run's script applied a function to (its last call to one of the offered
        functions: what Export cuts), whatever the section fields say now. None: it applied nothing."""
        var st = last_call(self.bound, self.functions)
        if not st or len(st.value().args) < 1:
            return None
        ref a = st.value().args
        var from_s = _seconds(a[1]) if len(a) > 1 else 0.0
        var to_s = _seconds(a[2]) if len(a) > 2 else -1.0
        return (a[0], max(from_s, 0.0), to_s)

    def ran(mut self, var log: List[String], problem: String, var names: List[String]):
        """A run landed: its log, its result names, what to say."""
        self.log = log^
        self.results = names^
        self.said = problem if problem != "" else String(len(self.results)) + " results"

    def update(mut self, event: Event) -> Int:
        if not self.owns(event.message):
            return SP_NONE
        var m = event.message - self.msg_base
        if m == SP_TEXT:
            self.set_text(event.text)
        elif m == SP_RUN_MSG:
            return SP_RUN
        elif m == SP_CLOSE:
            self.open = False
            return SP_CLOSED
        elif m == SP_VIDEO:
            self.video = max(0, min(event.number, len(self.videos) - 1))
        elif m == SP_FROM:
            self.from_s = event.text
        elif m == SP_TO:
            self.to_s = event.text
        elif m == SP_EXPORT_MSG:
            return SP_EXPORT
        elif m == SP_OPEN_MSG:
            return SP_OPEN
        elif m == SP_PATH:
            self.recipe_path = event.text
        elif SP_PARAM <= m < SP_PARAM + MAX_PARAMS:
            var i = m - SP_PARAM
            if i < len(self.answers):
                self.answers[i] = event.text
        elif SP_APPLY <= m < SP_APPLY + MAX_APPLY:
            var i = m - SP_APPLY
            if i < len(self.functions):
                try:
                    var fn_name = self.functions[i]
                    var line = self.apply_statement(fn_name)
                    var t = String(self.text.rstrip())
                    self.set_text((t + "\n" if t != "" else String("")) + line)
                    return SP_RUN
                except e:
                    self.said = String(e)
        return SP_NONE

    def view(self, tables: String) -> View:
        """The window: what the script can read, its text, its questions, Run; a video's section and Apply; Export and
        Open recipe; the last run's log."""
        var b = self.msg_base
        var lines = List[View]()
        lines.append(Text("Statements, run in order: name = SELECT …; or name = function(…);. Each result is a card later statements can read. Tables: " + tables + ".", CAPTION))
        lines.append(TextArea(self.text, "frames = SELECT * FROM episode;", b + SP_TEXT, height=200).fill().tag("script-text"))
        for i in range(min(len(self.params), MAX_PARAMS)):
            lines.append(HStack(Text("${" + self.params[i] + "}", CAPTION).width(150),
                                TextField(self.answers[i], "its value", on_change=b + SP_PARAM + i, on_submit=b + SP_RUN_MSG).width(240).tag("recipe-" + self.params[i])
                                    .label(self.params[i]).tooltip("This recipe asks for " + self.params[i] + ": its value is put in wherever the script says ${" + self.params[i] + "}"),
                                spacing=10).align(CENTER))
        if len(self.videos) > 0:
            var apply = List[View]()
            apply.append(Text("Section of", CAPTION))
            apply.append(Dropdown(self.videos, self.video, b + SP_VIDEO).tag("script-video").label("Video"))
            apply.append(TextField(self.from_s, "from s", on_change=b + SP_FROM).width(80).tag("range-from").label("From (seconds)"))
            apply.append(TextField(self.to_s, "to s", on_change=b + SP_TO).width(80).tag("range-to").label("To (seconds)"))
            apply.append(Spacer())
            for i in range(min(len(self.functions), MAX_APPLY)):
                apply.append(Button("Apply " + self.functions[i], b + SP_APPLY + i, icon="zap").tag("apply-" + self.functions[i])
                                 .tooltip("Write " + self.functions[i] + "(video, from, to) for this section into the script and run it"))
            lines.append(HStack(apply^, spacing=10).fill().align(CENTER))
        lines.append(HStack(Text(self.said, CAPTION).tone(TONE_WARN if self.said.startswith("line ") or self.said.startswith("A ") else TONE_ACCENT).tag("script-said"), Spacer(),
                            Button("Export", b + SP_EXPORT_MSG, icon="download").tag("export-recipe")
                                .tooltip("A folder in your documents: the script, each result as CSV, and the applied section of the video as a clip"),
                            Button("Close", b + SP_CLOSE).tag("script-close"), Button("Run", b + SP_RUN_MSG, PROMINENT, icon="play").tag("run-script"),
                            spacing=10).fill().align(CENTER))
        lines.append(HStack(TextField(self.recipe_path, "a recipe folder", on_change=b + SP_PATH, on_submit=b + SP_OPEN_MSG).fill().tag("recipe-path").label("Recipe folder"),
                            Button("Open recipe", b + SP_OPEN_MSG, icon="file").tag("open-recipe")
                                .tooltip("A saved recipe's script, here to run again: on this sheet's tables and videos, with its questions answered anew"),
                            spacing=10).fill().align(CENTER))
        for l in self.log:
            lines.append(Text(l, CAPTION))
        return Dialog("Script", VStack(lines^, spacing=12).align(START).fill(), on_close=b + SP_CLOSE, width=760)
