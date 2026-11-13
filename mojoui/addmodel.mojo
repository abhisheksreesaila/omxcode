# mojoui.addmodel: Add a model, like magic (goal 68 M2). Paste a Hugging Face name, drop a model file or folder, or
# let the agent do it (the add-model tool): one line says what it does, whether it fits the GPU and its licence before
# anything downloads (a model that can't run says why, and nothing downloads); a model that runs its own code asks
# first; it downloads with progress, loads, and answers on the row or frame you were looking at the moment it lands;
# then "Run it on all N" fills a column (a table's model, a text embedder) or a table (a picture model on every frame).
# Every model becomes a plugin folder (mojoui.plugins), so it is a script function from then on too.
#
#   var add = AddModel(msg_base=7950)                 # messages 7950 … 7950 + ADD_MESSAGES
#   update(): var did = add.update(event)             # AM_ANSWER: the app calls answer_*; AM_RUN: run_* ; AM_CLOSED
#   frames:   var did = add.poll()                    # while add.busy(): downloads, loading, runs move on
#   view():   if add.open: Dialog("Add a model", VStack(add.view(...)), …)
#   answers:  add.answer_table(sheet, row) · add.answer_picture(px, w, h, what) · add.answer_text(sheet, col, row)
#   run all:  add.run_table(sheet) → a Table to swap in · add.start_video(path) · add.start_texts(sheet, col) → poll
#
# Tags (an agent's tools): add-model (paste + submit), add-model-file (a path), add-it, add-cancel, run-all, show-result,
# add-another, add-model-close. "Allow its code and add" is tagged person-only-…: the agent host makes no tool of it, so
# only a person's click lets a model run its own code (goal 68's review). Trace lines (MOJOUI_TRACE): "MODEL: <name> …" with the stopwatch.

from std.time import perf_counter_ns
from std.os import makedirs
from std.os.path import exists, isdir
from omxcore import Table, TEXT as MX_TEXT, DECIMAL as MX_DECIMAL, INT as MX_INT
from mojoui.app import Event
from mojoui.json import Json
from mojoui.sheet import Sheet, TEXT as SHEET_TEXT
from mojoui.plugins import Plugin, find_plugins, user_plugin_dir
from mojoui.pluginrun import (Preflight, PyJob, py_job, py_cancel, py_download, py_write_plugin, py_load, py_loaded, py_classify,
                              py_detect, py_embed, py_run_video, py_run_texts, py_result_rows, py_similar, py_stats, py_plugin_name,
                              match_columns, tabular_rows, Seen, python_enter, _py)
from mojoui.pygil import python_exit, python_lend, python_reclaim
from mojoui.learn import copy_table
from mojoui.view import (View, Text, Button, TextField, FilePicker, ProgressBar, Image, VStack, HStack, Spacer, CAPTION, HEADLINE,
                         PROMINENT, SUBTLE, CENTER, START, TONE_ACCENT, TONE_WARN, TONE_GOOD)

comptime ADD_MESSAGES = 12
comptime AM_TEXT_MSG = 0
comptime AM_CHECK_MSG = 1
comptime AM_FILE_MSG = 2
comptime AM_ADD_MSG = 3
comptime AM_ALLOW_MSG = 4
comptime AM_CANCEL_MSG = 5
comptime AM_RUN_MSG = 6
comptime AM_CLOSE_MSG = 7
comptime AM_ANOTHER_MSG = 8  # "Try another": the field cleared for the next model

comptime AM_NONE = 0  # what update() and poll() ask the app to do
comptime AM_ANSWER = 1  # the model is ready: answer on the row or frame being looked at
comptime AM_RUN = 2  # run it on all
comptime AM_RAN = 3  # a run on all finished (video rows or text vectors): the app takes them
comptime AM_CLOSED = 4

comptime S_EMPTY = 0
comptime S_CHECKING = 1
comptime S_SAID = 2  # the line is shown (and why it can't run, or what it needs)
comptime S_DOWNLOADING = 3
comptime S_LOADING = 4
comptime S_READY = 5  # loaded: answered (or saying what it needs to answer)
comptime S_RUNNING = 6
comptime S_RAN = 7
comptime S_FAILED = 8


def _secs(ns: Int) -> String:
    var t = Float64(ns) / 1e9
    return String(Int(t * 10.0 + 0.5) // 10) + "." + String(Int(t * 10.0 + 0.5) % 10) + " s"


def _mb(n: Int) -> String:
    if n >= 1 << 30:
        return String(Int(Float64(n) / Float64(1 << 30) * 10.0 + 0.5) // 10) + "." + String(Int(Float64(n) / Float64(1 << 30) * 10.0 + 0.5) % 10) + " GB"
    return String(max(Int(Float64(n) / Float64(1 << 20) + 0.5), 1)) + " MB"


def _pct(x: Float64) -> String:
    return String(Int(x * 100.0 + 0.5)) + "%"


def _grouped(n: Int) -> String:
    var s = String(n)
    var out = String("")
    var k = 0
    for i in range(s.byte_length() - 1, -1, -1):
        out = String(s[byte = i : i + 1]) + out
        k += 1
        if k % 3 == 0 and i > 0:
            out = "," + out
    return out


struct AddModel(Movable):
    var msg_base: Int
    var open: Bool
    var trace: Bool
    var stage: Int
    var text: String
    var pf: Preflight
    var line: String  # the one line before any download
    var why: String  # why it can't run / what went wrong (with what to do next)
    var needs_consent: Bool  # it runs its own code: Allow first
    var allowed: Bool
    var folder: String
    var name: String
    var kind: String
    var runner: String
    var job: PyJob
    var answer: List[String]  # what it said on the row or frame
    var answer_where: String  # "row 12" / "the frame at 3.2 s"
    var picture: List[UInt32]  # the frame it answered on, with its boxes drawn (a thumbnail)
    var pic_w: Int
    var pic_h: Int
    var run_what: String  # "rows" / "frames" / "texts"
    var run_n: Int
    var ran_said: String
    var lent: Bool
    var t_paste: Int
    var t_landed: Int  # download done
    var t_loaded: Int
    var t_answer: Int
    var downloaded: Int  # bytes
    var timings: List[String]  # every model added this session: its stopwatch line
    var checks: Int  # checks started (each its own job key: a second Check never shows the first's answer)
    var stopwatch: String  # the last one, in words, under its answer

    def __init__(out self, msg_base: Int, trace: Bool = False):
        self.msg_base = msg_base
        self.open = False
        self.trace = trace
        self.stage = S_EMPTY
        self.text = ""
        self.pf = Preflight()
        self.line = ""
        self.why = ""
        self.needs_consent = False
        self.allowed = False
        self.folder = ""
        self.name = ""
        self.kind = ""
        self.runner = ""
        self.job = PyJob("none", 0, 0, "")
        self.answer = List[String]()
        self.answer_where = ""
        self.picture = List[UInt32]()
        self.pic_w = 0
        self.pic_h = 0
        self.run_what = ""
        self.run_n = 0
        self.ran_said = ""
        self.lent = False
        self.t_paste = 0
        self.t_landed = 0
        self.t_loaded = 0
        self.t_answer = 0
        self.downloaded = 0
        self.timings = List[String]()
        self.stopwatch = ""
        self.checks = 0

    def owns(self, m: Int) -> Bool:
        return self.msg_base <= m < self.msg_base + ADD_MESSAGES

    def busy(self) -> Bool:
        return self.stage == S_CHECKING or self.stage == S_DOWNLOADING or self.stage == S_LOADING or self.stage == S_RUNNING

    def plugin(self) -> Plugin:
        try:
            return Plugin.read(self.folder)
        except e:
            var p = Plugin(self.folder)
            p.problem = String(e)
            return p^

    def _lend(mut self):
        """Python's lock to its threads while they work (GTK: the UI thread holds it otherwise; the web host: nothing)."""
        if not self.lent:
            try:
                python_lend()
                self.lent = True
            except:
                pass

    def _reclaim(mut self):
        if self.lent:
            python_reclaim()
            self.lent = False

    def _say(self, s: String):
        if self.trace:
            print("MODEL: " + s, flush=True)

    def reset(mut self):
        self.stage = S_EMPTY
        self.stopwatch = ""
        self.line = ""
        self.why = ""
        self.needs_consent = False
        self.allowed = False
        self.folder = ""
        self.name = ""
        self.answer = List[String]()
        self.picture = List[UInt32]()
        self.ran_said = ""

    # ---------- the flow ----------

    def check(mut self, text: String):
        """A pasted name or link (the Hub, on a thread), or a path to a model file or folder (made a plugin here)."""
        self.reset()
        self.t_paste = Int(perf_counter_ns())
        var t = String(text.strip())
        self.text = t
        if t.startswith("/") or t.startswith("~") or t.startswith("./") or exists(t):
            self.adopt(t)
            return
        try:
            self.checks += 1
            var g = python_enter()
            _ = _py().preflight_start(self._pf_key(), t)
            python_exit(g)
            self.stage = S_CHECKING
            self._lend()
        except e:
            self.fail("Couldn't start the check: " + String(e))

    def _pf_key(self) -> String:
        return "pf" + String(self.checks)

    def adopt(mut self, path: String):
        """A dropped file or folder → a plugin folder (copied into the plugins folder), checked, loaded."""
        try:
            makedirs(user_plugin_dir(), exist_ok=True)
            var g = python_enter()
            var s = String(py=_py().file_plugin(path, user_plugin_dir()))
            python_exit(g)
            var j = Json.parse(s)
            self.line = j.text(j.get(0, "line"))
            self.why = j.text(j.get(0, "why"))
            if self.why != "":
                self.stage = S_SAID
                self._say("refused " + path + ": " + self.why)
                return
            self.folder = j.text(j.get(0, "folder"))
            var p = Plugin.read(self.folder)  # (the same checks as any plugin: names, kinds, paths, no pickle)
            self.name = p.name
            self.kind = p.kind
            self.runner = p.runner
            self.t_landed = Int(perf_counter_ns())
            self.downloaded = 0
            self._load()
        except e:
            self.fail(String(e))

    def fail(mut self, why: String):
        self.why = why
        self.stage = S_FAILED
        self._reclaim()
        self._say("failed: " + why)

    def add(mut self, allow: Bool):
        """Download what preflight said (its own code too only when allowed), on a thread."""
        if not self.pf.can_run:
            return
        if self.pf.remote_code and not allow:
            self.needs_consent = True
            return
        self.allowed = allow
        try:
            var name = py_plugin_name(self.pf.repo)
            var folder = user_plugin_dir() + "/" + name
            var k = 2
            while exists(folder + "/plugin.json"):  # (another repo with the same last name: a folder of its own)
                var same = False
                try:
                    var src = Plugin.read(folder).source
                    same = src == "hf:" + self.pf.repo or src.startswith("hf:" + self.pf.repo + "@")
                except:
                    pass
                if same:
                    break
                name = py_plugin_name(self.pf.repo) + "_" + String(k)
                folder = user_plugin_dir() + "/" + name
                k += 1
            makedirs(folder, exist_ok=True)
            self.folder = folder
            self.name = name
            self.kind = self.pf.kind
            self.runner = "torch"
            py_download(self.pf, folder, allow)
            self.stage = S_DOWNLOADING
            self.job = PyJob("running", 0, self.pf.bytes, "")
            self._lend()
            self._say(self.pf.repo + " downloading " + _mb(self.pf.bytes) + (" (its own code allowed)" if allow else ""))
        except e:
            self.fail("Couldn't start the download: " + String(e))

    def _load(mut self):
        var p = self.plugin()
        if not p.ok():
            self.fail(p.problem)
            return
        if p.runner == "tree" or p.runner == "max":
            self.t_loaded = Int(perf_counter_ns())
            self.stage = S_READY
            return
        try:
            py_load(self.folder)
            self.stage = S_LOADING
            self._lend()
        except e:
            self.fail("Couldn't load it: " + String(e))

    def poll(mut self) -> Int:
        """Moves the flow on (a frame while busy()); AM_ANSWER when it's ready to answer, AM_RAN when a run is done."""
        if self.stage == S_CHECKING:
            var j = py_job(self._pf_key())
            if j.state == "running":
                return AM_NONE
            self._reclaim()
            if j.state != "done":
                self.fail("The check didn't finish: " + j.error)
                return AM_NONE
            try:
                var g = python_enter()
                var s = String(py=_py().result_text(self._pf_key()))
                python_exit(g)
                self.pf = _preflight_of(s)
            except e:
                self.fail(String(e))
                return AM_NONE
            self.line = self.pf.line
            self.why = self.pf.why
            self.needs_consent = self.pf.can_run and self.pf.remote_code
            self.stage = S_SAID
            self._say("checked " + self.pf.repo + " in " + _secs(Int(perf_counter_ns()) - self.t_paste) + ": " + self.line)
            return AM_NONE
        if self.stage == S_DOWNLOADING:
            self.job = py_job("dl:" + self.folder)
            if self.job.state == "running":
                return AM_NONE
            if self.job.state != "done":
                self.fail(("Cancelled: nothing kept but the part already downloaded (Add it again to resume)" if self.job.state == "cancelled"
                           else "The download stopped: " + self.job.error + ". Add it again to resume where it stopped"))
                return AM_NONE
            self.downloaded = self.job.done
            self.t_landed = Int(perf_counter_ns())
            try:
                self.name = py_write_plugin(self.folder, self.pf, self.allowed)
            except e:
                self.fail("Couldn't write its plugin.json: " + String(e))
                return AM_NONE
            self._reclaim()
            self._load()
            return AM_ANSWER if self.stage == S_READY else AM_NONE
        if self.stage == S_LOADING:
            self.job = py_job("load:" + self.folder)
            if self.job.state == "running":
                return AM_NONE
            self._reclaim()
            if self.job.state != "done":
                self.fail("It didn't load: " + self.job.error)
                return AM_NONE
            self.t_loaded = Int(perf_counter_ns())
            self.stage = S_READY
            return AM_ANSWER
        if self.stage == S_RUNNING:
            self.job = py_job("run:" + self.folder)
            if self.job.state == "running":
                return AM_NONE
            self._reclaim()
            if self.job.state != "done":
                self.fail("The run stopped: " + (self.job.error if self.job.error != "" else self.job.state))
                return AM_NONE
            self.stage = S_RAN
            return AM_RAN
        return AM_NONE

    def answered(mut self, lines: List[String], where: String):
        self.answer = lines.copy()
        self.answer_where = where
        if self.t_answer == 0 or self.t_answer < self.t_loaded:
            self.t_answer = Int(perf_counter_ns())
            var after = self.t_answer - self.t_landed
            var line = (self.name + " (" + self.kind + ", " + self.runner + "): paste→first answer " + _secs(self.t_answer - self.t_paste)
                        + "; after the download " + _secs(after) + (" (" + _mb(self.downloaded) + " downloaded in " + _secs(self.t_landed - self.t_paste) + ")" if self.downloaded > 0 else " (nothing downloaded)")
                        + " · answer on " + where + ": " + (lines[0] if len(lines) > 0 else ""))
            self.timings.append(line)
            self.stopwatch = ("Answered " + _secs(self.t_answer - self.t_paste) + " after you asked: " + _secs(self.t_landed - self.t_paste) + " downloading "
                              + _mb(self.downloaded) + ", then " + _secs(after) + " to load and answer") if self.downloaded > 0 else (
                              "Answered " + _secs(self.t_answer - self.t_paste) + " after you asked (nothing downloaded)")
            self._say(line)

    def update(mut self, event: Event) -> Int:
        var m = event.message - self.msg_base
        if m == AM_TEXT_MSG:
            self.text = event.text
        elif m == AM_CHECK_MSG:
            if String(self.text.strip()) == "":
                self.why = "Paste a Hugging Face name (owner/name) or its link, or choose a model file or folder"
                self.stage = S_SAID
                return AM_NONE
            var asked = self.text
            self.check(asked)
            return AM_ANSWER if self.stage == S_READY else AM_NONE  # (a pasted path to a tree file is ready at once)
        elif m == AM_FILE_MSG:
            self.text = event.text
            self.check(event.text)
            return AM_ANSWER if self.stage == S_READY else AM_NONE
        elif m == AM_ADD_MSG:
            self.add(False)
        elif m == AM_ALLOW_MSG:
            self.add(True)
        elif m == AM_CANCEL_MSG:
            if self.stage == S_DOWNLOADING:
                py_cancel("dl:" + self.folder)
            elif self.stage == S_RUNNING:
                py_cancel("run:" + self.folder)
            else:
                self.reset()
        elif m == AM_RUN_MSG:
            return AM_RUN
        elif m == AM_CLOSE_MSG:
            self.open = False
            return AM_CLOSED
        elif m == AM_ANOTHER_MSG:
            self.text = ""
            self.reset()
        return AM_NONE

    # ---------- answers ----------

    def answer_table(mut self, sheet: Sheet, row: Int):
        var p = self.plugin()
        var m = match_columns(p, sheet)
        if not m.ok():
            self.answered(["Can't answer on this table: " + m.said() + " (columns are matched by name and type, never guessed)"], "this table")
            return
        try:
            var rows = List[Int]()
            rows.append(row)
            var a = tabular_rows(p, sheet, m, rows)
            self.run_what = "rows"
            self.run_n = sheet.rows()
            self.answered([a.said(0), m.said()], "row " + _grouped(row + 1))
        except e:
            self.answered(["It couldn't answer: " + String(e)], "row " + _grouped(row + 1))

    def answer_picture(mut self, var px: List[UInt32], w: Int, h: Int, where: String, frames: Int):
        try:
            var seen: List[Seen]
            if self.kind == "detect":
                seen = py_detect(self.folder, px, w, h, self.plugin().param("queries"), 0.5)
            else:
                seen = py_classify(self.folder, px, w, h, 3)
            var lines = List[String]()
            var names = List[String]()
            var counts = List[Int]()
            var bests = List[Float64]()
            for s in seen:  # (a detector's boxes grouped by kind: "person × 2 (best 100%)")
                var k = -1
                for i in range(len(names)):
                    if names[i] == s.label:
                        k = i
                if k < 0:
                    names.append(s.label)
                    counts.append(1)
                    bests.append(s.score)
                else:
                    counts[k] += 1
                    bests[k] = max(bests[k], s.score)
            for i in range(min(len(names), 6)):
                if counts[i] > 1:
                    lines.append(names[i] + " × " + String(counts[i]) + " (best " + _pct(bests[i]) + ")")
                else:
                    lines.append(names[i] + " " + _pct(bests[i]))
            if len(lines) == 0:
                lines.append("nothing it's sure of (over 50%)")
            if self.kind == "detect":
                draw_boxes(px, w, h, seen)
            self.picture = thumbnail(px, w, h, 360)
            self.pic_w = 360
            self.pic_h = len(self.picture) // 360
            self.run_what = "frames"
            self.run_n = frames
            self.answered(lines, where)
        except e:
            self.answered(["It couldn't answer: " + String(e)], where)

    def answer_text(mut self, sheet: Sheet, col: Int, row: Int):
        """The row's text, embedded, against the column's other words: the ones most like it."""
        try:
            var here = sheet.plain_text(col, row)
            var words = List[String]()
            words.append(here)
            for w in range(min(sheet.word_count(col), 2000)):
                var t = sheet.text_of(col, Int64(w))
                if t != here and t != "":
                    words.append(t)
            var e = py_embed(self.folder, words)
            var d = e[1]
            var vec = e[0].copy()
            var best = List[Tuple[Float64, Int]]()
            for i in range(1, len(words)):
                var c = 0.0
                for k in range(d):
                    c += vec[k] * vec[i * d + k]
                best.append((c, i))
            var lines = List[String]()
            lines.append(String(d) + " numbers for \"" + here + "\"; most like it:")
            for _ in range(min(3, len(best))):
                var b = 0
                for i in range(len(best)):
                    if best[i][0] > best[b][0]:
                        b = i
                var c100 = Int(best[b][0] * 100.0 + 0.5)
                lines.append("\"" + words[best[b][1]] + "\" " + String(c100 // 100) + "." + (String(c100 % 100) if c100 % 100 >= 10 else "0" + String(c100 % 100)))
                best[b] = (-9.0, best[b][1])
            self.run_what = "texts"
            self.run_n = sheet.rows()
            self.answered(lines, "row " + _grouped(row + 1) + " (" + sheet.name(col) + ")")
        except e:
            self.answered(["It couldn't answer: " + String(e)], "row " + _grouped(row + 1))

    def needs(mut self, what: String):
        """No row or frame to answer on yet: say what to open."""
        self.answered([what], "nothing yet")

    # ---------- run on all ----------

    def run_table(mut self, sheet: Sheet) raises -> Table:
        """Every row: the sheet's table with <name> and <name> score % columns (replaced when they're there)."""
        var p = self.plugin()
        var m = match_columns(p, sheet)
        if not m.ok():
            raise Error(m.said())
        var t0 = perf_counter_ns()
        var rows = List[Int]()
        for r in range(sheet.rows()):
            rows.append(r)
        var a = tabular_rows(p, sheet, m, rows)
        var drop = List[String]()
        drop.append(self.name)
        drop.append(self.name + " score %")
        var out = copy_table(sheet.frame.bake(), drop)
        if a.regression:
            var c = out.add_column(self.name, MX_DECIMAL, 4)
            for i in range(out.rows()):
                out.append(c, Int64(Int(a.score[i] * 10000.0 + (0.5 if a.score[i] >= 0 else -0.5))) if i < len(rows) else 0)
        else:
            var c = out.add_column(self.name, MX_TEXT)
            var codes = List[Int64]()
            for l in a.labels:
                codes.append(Int64(out.add_word(c, l)))
            var cs = out.add_column(self.name + " score %", MX_INT)
            for i in range(out.rows()):
                out.append(c, codes[a.best[i]] if i < len(rows) else 0)
                out.append(cs, Int64(Int(a.score[i] * 100.0 + 0.5)) if i < len(rows) else 0)
        out.check()
        self.stage = S_RAN
        self.ran_said = "Filled " + self.name + " for all " + _grouped(len(rows)) + " rows in " + _secs(Int(perf_counter_ns() - t0))
        self._say("ran on " + String(len(rows)) + " rows in " + _secs(Int(perf_counter_ns() - t0)))
        return out^

    def start_video(mut self, path: String, every: Int):
        try:
            py_run_video(self.folder, path, every, self.plugin().param("queries"), 0.5)
            self.stage = S_RUNNING
            self.job = PyJob("running", 0, self.run_n, "")
            self._lend()
        except e:
            self.fail("Couldn't start: " + String(e))

    def start_texts(mut self, sheet: Sheet, col: Int):
        var words = List[String]()
        for w in range(sheet.word_count(col)):
            words.append(sheet.text_of(col, Int64(w)))
        try:
            py_run_texts(self.folder, words)
            self.stage = S_RUNNING
            self.job = PyJob("running", 0, len(words), "")
            self._lend()
        except e:
            self.fail("Couldn't start: " + String(e))

    def video_table(mut self) raises -> Table:
        """A finished run over a video: a row per frame (a classifier) or per box (a detector)."""
        var j = Json.parse(py_result_rows("run:" + self.folder))
        var t = Table.empty()
        var det = self.kind == "detect"
        var c_frame = t.add_column("frame", MX_INT)
        var c_t = t.add_column("t", MX_DECIMAL, 3)
        var c_label = t.add_column("kind" if det else "label", MX_TEXT)
        var c_score = t.add_column("score", MX_DECIMAL, 3)
        var boxes = List[Int]()
        if det:
            for n in ["x", "y", "w", "h"]:
                boxes.append(t.add_column(n, MX_INT))
        for i in range(j.size(0)):
            var r = j.at(0, i)
            t.append(c_frame, Int64(Int(j.real(j.at(r, 0)))))
            t.append(c_t, Int64(Int(j.real(j.at(r, 1)) * 1000.0 + 0.5)))
            t.append_text(c_label, j.text(j.at(r, 2)))
            t.append(c_score, Int64(Int(j.real(j.at(r, 3)) * 1000.0 + 0.5)))
            if det:
                for k in range(4):
                    t.append(boxes[k], Int64(Int(j.real(j.at(r, 4 + k)) + 0.5)))
        t.check()
        self.ran_said = String(j.size(0)) + (" boxes" if det else " frames labelled") + " in " + _secs(Int(perf_counter_ns()) - self.t_answer)
        return t^

    def text_table(mut self, sheet: Sheet, col: Int, row: Int) raises -> Table:
        """A finished run over a text column: the sheet's table with "<name> like row N" (every row's cosine to row N's text)."""
        var sims = py_similar("run:" + self.folder, Int(sheet.value(col, row)))
        var label = self.name + " like row " + String(row + 1)
        var drop = List[String]()
        drop.append(label)
        var out = copy_table(sheet.frame.bake(), drop)
        var c = out.add_column(label, MX_DECIMAL, 3)
        for r in range(out.rows()):
            var code = Int(sheet.value(col, r)) if r < sheet.rows() and not sheet.is_null(col, r) else -1
            out.append(c, Int64(Int(sims[code] * 1000.0 + 0.5)) if 0 <= code < len(sims) else 0)
        out.check()
        self.ran_said = "Filled " + label + " for all " + _grouped(out.rows()) + " rows (" + _grouped(len(sims)) + " different texts embedded)"
        return out^

    # ---------- the view ----------

    def view(self, installed: List[Plugin], rows: Int, frames: Int) -> List[View]:
        var b = self.msg_base
        var parts = List[View]()
        parts.append(Text("A model from the Hugging Face Hub, a model file or folder, or ask the agent. It says what it is before anything downloads.", CAPTION).max_width(560))
        if self.stage == S_EMPTY or (self.stage == S_SAID and not self.pf.can_run):
            parts.append(Text("Try hustvl/yolos-tiny (finds people and things on a video frame), google/vit-base-patch16-224 (names what a frame shows), "
                              + "BAAI/bge-small-en-v1.5 (finds rows that mean the same), or a decision tree file (XGBoost JSON, LightGBM text).", CAPTION).max_width(560).tag("add-examples"))
        parts.append(HStack(TextField(self.text, "Paste a model: owner/name, or its huggingface.co link", on_change=b + AM_TEXT_MSG, on_submit=b + AM_CHECK_MSG)
                                .width(330).tag("add-model").label("Model").tooltip("A Hugging Face model's name or link; Return checks it"),
                            Button("Check", b + AM_CHECK_MSG, PROMINENT if self.stage == S_EMPTY else SUBTLE, icon="search").tag("add-check"),
                            FilePicker("File or folder…", b + AM_FILE_MSG, style=SUBTLE, icon="open", accept="folder,.json,.txt,.onnx,.skops").tag("add-model-file")
                                .tooltip("An XGBoost JSON, LightGBM text, ONNX or skops file, Learn's tree, or a model folder"),
                            spacing=8).fill().align(CENTER))
        if self.stage == S_CHECKING:
            parts.append(Text("Asking the Hub what " + self.text + " is… " + _secs(Int(perf_counter_ns()) - self.t_paste), CAPTION).tag("add-progress"))
        if self.line != "" and self.stage != S_CHECKING:
            parts.append(Text(self.line).max_width(560).tag("add-line"))
        if self.why != "":
            parts.append(Text(self.why, CAPTION).tone(TONE_WARN).max_width(560).tag("add-why"))
            if self.stage == S_SAID and not self.pf.can_run or self.stage == S_FAILED:
                parts.append(HStack(Spacer(), Button("Try another", b + AM_ANOTHER_MSG, icon="rotate-ccw").tag("add-another"), spacing=8).fill())
        if self.stage == S_SAID and self.pf.can_run:
            if self.needs_consent:
                parts.append(Text("It runs its own Python code from its repo inside this app, with your files and network: allow it only if you trust " + self.pf.repo + ".", CAPTION)
                             .tone(TONE_WARN).max_width(560).tag("add-consent"))
                parts.append(HStack(Spacer(), Button("Cancel", b + AM_CANCEL_MSG).tag("add-cancel"),
                                    Button("Allow its code and add", b + AM_ALLOW_MSG, PROMINENT, icon="unlock").tag("person-only-allow-code")
                                    .tooltip("Only a person can allow this: an agent has no tool for it"), spacing=8).fill())
            else:
                parts.append(HStack(Spacer(), Button("Add it (" + _mb(self.pf.bytes) + ")", b + AM_ADD_MSG, PROMINENT, icon="download").tag("add-it"), spacing=8).fill())
        if self.stage == S_DOWNLOADING:
            var total = max(self.job.total, self.pf.bytes)
            parts.append(Text("Downloading " + self.pf.repo + ": " + _mb(self.job.done) + " of " + _mb(total), CAPTION).tag("add-progress"))
            parts.append(HStack(ProgressBar(Int(Float64(self.job.done) * 100.0 / Float64(max(total, 1)))).width(480), Spacer(),
                                Button("Cancel", b + AM_CANCEL_MSG, icon="x").tag("add-cancel"), spacing=8).fill().align(CENTER))
        if self.stage == S_LOADING:
            parts.append(Text("Loading " + self.name + "… " + _secs(Int(perf_counter_ns()) - self.t_landed), CAPTION).tag("add-progress"))
        if self.stage >= S_READY and self.stage != S_FAILED and len(self.answer) > 0:
            parts.append(Text(self.name + " on " + self.answer_where, HEADLINE).tag("add-answer-title"))
            var lines = List[View]()
            for l in self.answer:
                lines.append(Text(l).max_width(540))
            parts.append(VStack(lines^, spacing=4).fill().align(START).tag("add-answer"))
            if len(self.picture) > 0:
                parts.append(Image(self.picture.copy(), self.pic_w, self.pic_h).tag("add-picture"))
            if self.stopwatch != "":
                parts.append(Text(self.stopwatch, CAPTION).tag("add-stopwatch"))
            var n = self.run_n
            if self.stage == S_READY and n > 0:
                parts.append(HStack(Spacer(), Button("Run it on all " + _grouped(n) + " " + self.run_what, b + AM_RUN_MSG, PROMINENT, icon="play").tag("run-all"), spacing=8).fill())
        if self.stage == S_RUNNING:
            parts.append(Text("Running " + self.name + ": " + _grouped(self.job.done) + " of " + _grouped(max(self.job.total, self.run_n)) + " " + self.run_what, CAPTION).tag("add-progress"))
            parts.append(HStack(ProgressBar(Int(self.job.share() * 100.0)).width(480), Spacer(), Button("Cancel", b + AM_CANCEL_MSG, icon="x").tag("add-cancel"),
                                spacing=8).fill().align(CENTER))
        if self.ran_said != "":
            parts.append(HStack(Text(self.ran_said, CAPTION).tone(TONE_GOOD).tag("add-ran"), Spacer(),
                                Button("Show it", b + AM_CLOSE_MSG, PROMINENT, icon="table").tag("show-result")
                                .tooltip("Close this and see the filled column or the new table"), spacing=8).fill().align(CENTER))
        if self.stage == S_EMPTY or self.stage == S_RAN:
            var have = List[View]()
            for p in installed:
                if p.ok():
                    have.append(Text(p.name + " · " + (p.about if p.about != "" else p.kind), CAPTION).max_width(560))
            if len(have) > 0:
                parts.append(Text("Your models (each is also a script function)", HEADLINE))
                parts.append(VStack(have^, spacing=2).fill().align(START).tag("add-installed"))
        parts.append(HStack(Spacer(), Button("Close", b + AM_CLOSE_MSG).tag("add-model-close"), spacing=8).fill())
        var out = List[View]()
        out.append(VStack(parts^, spacing=12).fill().align(START).tag("add-model-panel"))
        return out^


def _preflight_of(s: String) raises -> Preflight:
    var j = Json.parse(s)
    var p = Preflight()
    p.json = s
    p.repo = j.text(j.get(0, "repo"))
    p.line = j.text(j.get(0, "line"))
    p.why = j.text(j.get(0, "why"))
    p.kind = j.text(j.get(0, "kind"))
    p.licence = j.text(j.get(0, "licence"))
    p.can_run = j.flag(j.get(0, "can_run"))
    p.remote_code = j.flag(j.get(0, "remote_code"))
    p.bytes = j.number(j.get(0, "bytes"))
    p.files = j.dump(j.get(0, "files")) if j.get(0, "files") >= 0 else "[]"
    p.sizes = j.dump(j.get(0, "sizes")) if j.get(0, "sizes") >= 0 else "{}"
    p.shas = j.dump(j.get(0, "shas")) if j.get(0, "shas") >= 0 else "{}"
    p.sha = j.text(j.get(0, "sha"))
    return p^


def draw_boxes(mut px: List[UInt32], w: Int, h: Int, seen: List[Seen]):
    """Each box's outline (3 px, the accent's green) drawn into the frame."""
    var ink = UInt32(0xFF5AC83C)  # (RGBA in memory: R low)
    for s in seen:
        var x0 = max(Int(s.x), 0)
        var y0 = max(Int(s.y), 0)
        var x1 = min(Int(s.x + s.w), w - 1)
        var y1 = min(Int(s.y + s.h), h - 1)
        for t in range(3):
            for x in range(x0, x1 + 1):
                if 0 <= y0 + t < h:
                    px[(y0 + t) * w + x] = ink
                if 0 <= y1 - t < h:
                    px[(y1 - t) * w + x] = ink
            for y in range(y0, y1 + 1):
                if 0 <= x0 + t < w:
                    px[y * w + x0 + t] = ink
                if 0 <= x1 - t < w:
                    px[y * w + x1 - t] = ink


def thumbnail(px: List[UInt32], w: Int, h: Int, to_w: Int) -> List[UInt32]:
    """The frame at to_w wide (nearest pixel), its height in proportion."""
    var to_h = max(h * to_w // max(w, 1), 1)
    var out = List[UInt32](capacity=to_w * to_h)
    for y in range(to_h):
        var sy = min(y * h // to_h, h - 1)
        for x in range(to_w):
            out.append(px[sy * w + min(x * w // to_w, w - 1)])
    return out^
