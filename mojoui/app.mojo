# What an app provides, and the platform-independent loop every host runs.

from mojoui.view import View, CANVAS, BOARD, FIELD, WEBCOMP, NO_MSG, PAN, ZOOM, KEY
from mojoui.look import resolve_layout
from mojoui.diff import Diff, diff
from mojoui.canvas import Surface
from mojoui.scene import Scene
from mojoui.theme import Theme
from mojoui.http import Request
from mojoui.effects import Every, Timer, InFlight, start, Backend, POLL_US
from mojoui.webcomponent import Command, is_event_name, is_widget_tag
from mojoui.json import Json, json_string


struct Event(Copyable, Movable):
    """What happened: which message, plus any value it carries.

    Buttons: just `message`. TextField: `text` = the field's contents.
    Toggle: `number` = 1 or 0. Dropdown: `number` = index, `text` = option.
    Slider: `number` = 0–100.
    Canvas gestures: `number` = PAN, ZOOM, TAP, PRESS, RELEASE, DOUBLE or KEY (`text` = the key); `x`, `y` = pointer position in the canvas
    (points from its top-left); PAN: `dx`, `dy` = movement in points; ZOOM: `zoom` = scale factor; PRESS, PAN, RELEASE:
    `pressure` = the pen's pressure, 0–1 (0: the device has none: a mouse, a finger; mojoui.ink then takes one from speed).
    Canvas frames: `number` = microseconds since the previous frame.
    HTTP replies (mojoui.http): `message` = the request's msg, `id` = its id, `number` = the status (0: no reply),
    `text` = the body, `error` = why there's no reply ("" when there is one, a 500 too).
    HTTP streams (Request.stream(end)): each piece: `message` = the request's msg, `id`, `name` = the SSE event's type
    ("message") or "chunk", `text` = its data, `number` = 1, 2, …; then the end: `message` = end, `number` = the status,
    `text` = the body (a status that isn't 2xx), `error` = why it stopped early ("cancelled", "timed out…", "ended early…").
    Timers (App.every): `message` = the timer's msg, `number` = how many ticks so far (1, 2, …).
    Widgets (mojoui.webcomponent): an event: `message` = on_event, `id` = the widget's id, `name` = the event, `text` = its
    payload (JSON). A command's reply: `message` = its reply msg, `id` = its id, `name` = the command, `text` = the answer
    (JSON), `number` = 1 (0 when there's none), `error` = why there's none.
    """

    var message: Int
    var text: String
    var number: Int
    var x: Float64
    var y: Float64
    var dx: Float64
    var dy: Float64
    var zoom: Float64
    var id: Int
    var error: String
    var name: String
    var pressure: Float64

    def __init__(
        out self, message: Int, text: String, number: Int,
        x: Float64 = 0, y: Float64 = 0, dx: Float64 = 0, dy: Float64 = 0, zoom: Float64 = 1,
        id: Int = 0, error: String = "", name: String = "", pressure: Float64 = 0,
    ):
        self.message = message
        self.text = text
        self.number = number
        self.x = x
        self.y = y
        self.dx = dx
        self.dy = dy
        self.zoom = zoom
        self.id = id
        self.error = error
        self.name = name
        self.pressure = pressure


trait App(Movable, Deinitable):
    comptime HTTP: Bool = False
    """True: the app sends HTTP requests (requests()), so its build links the transport (mojoui.effects.Backend: libc
    sockets and threads). Apps that don't keep their binaries free of both (the Apple stubs list no socket calls)."""
    comptime GPU_CANVAS: Bool = False
    """True: a canvas draws on the GPU (mojoui.gpu). A desktop host may then show its pictures straight from the GPU
    (mojoui.present): it probes CUDA↔GL before the app is made and, when that works, asks GTK for its GL renderer and
    points the app's GPU work at the display's GPU (D-737, D-738). Other apps keep the host's defaults (D-752).
    Opt-in on purpose: a GPU canvas that doesn't declare it (examples/gpu, examples/lens today) still works, through
    the CPU copy; declaring it is a one-line change once an app is checked on the zero-copy path."""

    def __init__(out self):
        """The starting state. Hosts create the app themselves."""
        ...

    @staticmethod
    def init_shared():
        """Builds what every session of a process shares (large read-only data, GPU buffers), once,
        before the first session; see mojoui.shared. Sessions find it with get_shared()."""
        pass

    def title(self) -> String:
        """The window title."""
        ...

    def update(mut self, event: Event):
        """Changes the state in response to an event (a tap, typing, a toggle…)."""
        ...

    def view(self) -> View:
        """Describes the whole screen for the current state."""
        ...

    def row(self, list_id: Int, index: Int) -> String:
        """The text of one row of a LazyList (hosts ask only for rows on screen)."""
        return ""

    def describe(self, canvas: Int, first: Int, count: Int) -> String:
        """Canvas `canvas`'s content as text, for an agent (D-163): `count` rows from shown row `first`
        (count 0: what's on screen), tab-separated; "" when the canvas has no text to offer."""
        return ""

    def draw(mut self, canvas: Int, mut surface: Surface):
        """Paints Canvas `canvas` into `surface` (its real pixel size). May update state
        shown elsewhere on screen (e.g. how long drawing took); hosts refresh it afterwards."""
        surface.fill(0)

    def draw_scene(mut self, canvas: Int, mut scene: Scene) -> Bool:
        """Canvas `canvas` as a display list (goal 26): hosts with a GPU path draw it (GTK: render nodes) instead of
        pixels. Returns False (the default) when the canvas only paints pixels (draw())."""
        return False

    def window_size(self) -> Tuple[Int, Int]:
        """The window's starting size in points, on desktops."""
        return (480, 560)

    def resize(mut self, width: Int, height: Int):
        """The window's content area is now width × height points: hosts say so when it opens and whenever it
        changes (a person resizing it, a tiling desktop, a phone turning). Apps that lay out to the window keep
        it; size changes reach the screen as patches, not rebuilds. The default ignores it."""
        pass

    def records(self) -> Bool:
        """True asks the host to record a report from launch (the Mac host: pictures and a view dump of every change,
        in ~/Desktop/omxcode-report-<app>/). Every app can still start one from the Debug menu. The default: no."""
        return False

    def appearance(mut self, dark: Bool):
        """The system is in dark (or light) mode: hosts say so when the window opens and whenever the person switches.
        An app with no theme of its own draws its canvases to match (Theme.native(dark)). The default ignores it."""
        pass

    def logo(self) -> String:
        """The app's mark as SVG ("": none): hosts install it as the icon "app-logo" (Icon("app-logo", 18))."""
        return ""

    def closing(mut self):
        """The app is about to close: the person closed its window (or chose Quit), the system is quitting it, a web page's
        session ended, or a test's `quit` step closed the window as a window manager does. Finish what must not be lost
        (a pending save) before returning: it runs on the UI thread, once, and the process may end right after. The
        default does nothing."""
        pass

    def background(self) -> Bool:
        """True keeps the app running when its window is closed (goal 45): the window hides instead of closing, the app
        keeps its state, timers, jobs and folder watchers, an item in the system tray (mojoui.tray) opens the window
        again, and mojoui.notify can still tell the person things. closing() then runs only when the process really
        ends. The default: False (closing the window ends the app)."""
        return False

    def window_shown(mut self, shown: Bool):
        """Background mode only: the window was closed (False; the app keeps running) or opened again from the tray
        (True). What it changes shows at the next update(). The default ignores it."""
        pass

    def jobs_message(self) -> Int:
        """A message update() gets on the UI thread as soon as a background job started with mojoui.jobs.start_ui_job
        ends (0: none; the app polls its jobs on its own, e.g. at display frames). Every host watches the jobs' wake
        pipe on its main loop, so the result reaches the screen at the next frame the display allows, not a frame
        later. The event says only "a job ended": update() polls its jobs as it would on a frame. The default: 0."""
        return 0

    def input_lines(self) -> Int:
        """A message for the lines another program writes to this one's standard input (0: stdin isn't read). Desktop
        hosts (GTK) watch stdin on their main loop: each whole line reaches update() as Event(message, text=line),
        between the toolkit's own events, with no polling delay; the end of the input comes once as number = -1. For a
        driver (a benchmark harness, a test) that steps the app from outside. The default: 0."""
        return 0

    def requests(mut self) -> List[Request]:
        """The HTTP requests asked for since the runtime last looked (it looks after every update() and once at the
        start): keep a mojoui.http.Http outbox and return its take(). Each reply comes back to update() as an Event."""
        return List[Request]()

    def every(self) -> List[Every]:
        """The timers the app wants now: Every(ms, msg) sends a `msg` event every `ms` milliseconds (number = the tick's
        count), from the first poll after it appears until the app stops listing it. Asked after every update()."""
        return List[Every]()

    def commands(mut self) -> List[Command]:
        """The widget commands asked for since the runtime last looked (after every update()): keep a
        mojoui.webcomponent.Widgets outbox and return its take(). Each answer comes back to update() as an Event."""
        return List[Command]()

    @staticmethod
    def web_assets() -> List[String]:
        """The script and style bundles the app's web page loads ("editor.js", "editor.css"): built from the app's
        web/widgets/ by scripts/web_assets.py, served by their content hash; the build fails on one not listed here."""
        return List[String]()

    def theme(self) -> Theme:
        """How the app looks (mojoui.theme.Theme: CSS classes, a palette, a GTK and a web style sheet), built by a theme
        module outside the framework (this repo's themes/, or yours); hosts restyle whenever its key changes (a skin
        picked, a mode's tint). The default is no theme: each platform's own look. Called often: return a kept value."""
        return Theme.native()


def ms(ns: Int) -> String:
    """Nanoseconds as milliseconds with two decimals (for TRACE lines)."""
    var hundredths = Int(ns) // 10_000
    var frac = hundredths % 100
    return String(hundredths // 100) + "." + ("0" if frac < 10 else "") + String(frac)


struct Runtime[A: App](Movable):
    """Holds the app and the screen last shown. Hosts call dispatch() on every event."""

    var app: Self.A
    var shown: View
    var trace: Bool  # MOJOUI_TRACE=1: hosts print each change's time and kind (TRACE: lines); the runtime keeps no clock (Android and iOS link no timing symbols here)
    var inflight: List[InFlight]  # HTTP requests out on their workers
    var undeliverable: List[Event]  # replies made without sending (an app with HTTP = False), handed over at the next poll
    var timers: List[Timer]
    var commands_out: List[Command]  # widget commands for the host to take (take_commands)
    var awaiting: List[Command]  # sent, waiting for their answer (reply)
    var command_seq: Int
    var closed: Bool  # App.closing was told

    def __init__(out self, var app: Self.A):
        self.shown = app.view()
        resolve_layout(self.shown, app.theme().look)
        self.app = app^
        self.trace = False  # (hosts that can read the environment turn it on: GTK reads MOJOUI_TRACE; iOS has no getenv)
        self.inflight = List[InFlight]()
        self.undeliverable = List[Event]()
        self.timers = List[Timer]()
        self.commands_out = List[Command]()
        self.awaiting = List[Command]()
        self.command_seq = 0
        self.closed = False
        self.take_effects()  # (what the starting state asks for)

    def take_effects(mut self):
        """The requests the last update asked for go out; the timers follow what the app lists now."""
        var reqs = self.app.requests()
        for i in range(len(reqs)):
            if reqs[i].cancels:  # (Http.cancel: the runtime ends it at its next poll)
                for k in range(len(self.inflight)):
                    if self.inflight[k].id == reqs[i].id and not self.inflight[k].cancelled:
                        self.inflight[k].cancel()
                continue
            comptime if Self.A.HTTP:
                self.inflight.append(start[Backend](reqs[i].copy()))
            else:
                self.undeliverable.append(Event(reqs[i].msg, "", 0, id=reqs[i].id, error="this app doesn't send HTTP (set comptime HTTP = True in it)"))
        var wanted = self.app.every()
        var next = List[Timer]()
        for w in wanted:
            var kept = False
            for t in self.timers:
                if t.msg == w.msg and t.ms == w.ms:
                    next.append(t.copy())
                    kept = True
                    break
            if not kept:
                next.append(Timer(w.ms, w.msg))
        self.timers = next^
        var cmds = self.app.commands()
        for i in range(len(cmds)):
            var c = cmds[i].copy()
            self.command_seq += 1
            c.seq = self.command_seq
            var problem = String("")
            if not is_widget_tag(c.tag):
                problem = "the command's widget tag isn't a custom element's name"
            elif not is_event_name(c.name):
                problem = "the command's name isn't a word"
            else:
                try:
                    _ = Json.parse(c.args)
                except:
                    problem = "the command's args aren't JSON"
            if problem == "":
                self.commands_out.append(c^)
            elif c.reply != NO_MSG:
                self.undeliverable.append(Event(c.reply, "", 0, id=c.id, error=problem, name=c.name))

    def take_commands(mut self) -> List[Command]:
        """The widget commands asked for since the host last took them (each once, numbered by seq); the ones that
        want an answer wait for reply()."""
        var out = self.commands_out^
        self.commands_out = List[Command]()
        for c in out:
            if c.reply != NO_MSG:
                self.awaiting.append(c.copy())
        while len(self.awaiting) > 256:  # (a page that never answers: the oldest are forgotten)
            _ = self.awaiting.pop(0)
        return out^

    def set_widget(mut self, tag: String, id: Int, field: String, value: String) -> Bool:
        """An agent's set (goal 34b): asks widget (tag, id) on the screen to set its field `field` to `value` (JSON), as
        the built-in command "mojoui.set" {field, value}. The page's runtime runs only a field the widget declares, with
        a value of its declared JSON type, and the widget reports the change as its own event. False (nothing sent): no
        such widget on the screen, a field name that isn't a word, or a value that isn't JSON."""
        if not is_widget_tag(tag) or not is_event_name(field):
            return False
        try:
            _ = Json.parse(value)
        except:
            return False
        var shown = False
        for n in self.shown.nodes:
            if n.kind == WEBCOMP and n.hint == tag and n.value == id:
                shown = True
        if not shown:
            return False
        self.command_seq += 1
        var c = Command(tag, id, "mojoui.set", '{"field":' + json_string(field) + ',"value":' + value + "}")
        c.seq = self.command_seq
        self.commands_out.append(c^)
        return True

    def knows_reply(self, seq: Int) -> Bool:
        for c in self.awaiting:
            if c.seq == seq:
                return True
        return False

    def reply(mut self, seq: Int, text: String, error: String) -> Diff:
        """The answer to command `seq` (or why there's none): update() hears it once, as the command's reply message.
        An answer that isn't JSON arrives as an error; an unknown or answered seq changes nothing."""
        for k in range(len(self.awaiting)):
            if self.awaiting[k].seq == seq:
                var c = self.awaiting.pop(k)
                var why = error
                if why == "":
                    try:
                        _ = Json.parse(text)
                    except:
                        why = "the widget's reply isn't JSON"
                return self.dispatch(Event(c.reply, text if why == "" else String(""), 1 if why == "" else 0, id=c.id, error=why, name=c.name))
        return Diff(False, [])

    def accepts_widget_event(self, node: Int, name: String, payload: String) -> Bool:
        """Whether node `node` is a widget that listens, `name` a word and `payload` JSON."""
        if node < 0 or node >= len(self.shown.nodes) or self.shown.nodes[node].kind != WEBCOMP or self.shown.nodes[node].msg == NO_MSG:
            return False
        if not is_event_name(name):
            return False
        try:
            _ = Json.parse(payload)
        except:
            return False
        return True

    def widget_event(mut self, node: Int, name: String, payload: String) -> Diff:
        """Widget node `node` emitted `name` with `payload` (JSON): its on_event message, with its id and the event's
        name. Anything accepts_widget_event refuses changes nothing."""
        if not self.accepts_widget_event(node, name, payload):
            return Diff(False, [])
        var msg = self.shown.nodes[node].msg
        var id = self.shown.nodes[node].value
        return self.dispatch(Event(msg, payload, 0, id=id, name=name))

    def closing(mut self):
        """The app is closing (App.closing): told once, whichever way it closes."""
        if self.closed:
            return
        self.closed = True
        self.app.closing()

    def busy(self) -> Bool:
        """Requests are out or timers run: the host should keep polling (wake_in)."""
        return len(self.inflight) > 0 or len(self.undeliverable) > 0 or len(self.timers) > 0

    def wake_in(self, now_us: Int) -> Int:
        """Microseconds until the host should poll() again; -1: nothing to wait for (until the next event)."""
        var best = -1
        if len(self.undeliverable) > 0:
            return 0
        if len(self.inflight) > 0:
            best = POLL_US
        for t in self.timers:
            if t.start_us < 0:
                return 0
            var w = max(t.due_us() - now_us, 0)
            best = w if best < 0 else min(best, w)
        return best

    def timer_wake_in(self, now_us: Int) -> Int:
        """Like wake_in, for the timers alone (-1: none): hosts give a timer's poll a higher priority than the
        few-ms polls for replies, which must yield to drawing."""
        var best = -1
        for t in self.timers:
            var w = 0 if t.start_us < 0 else max(t.due_us() - now_us, 0)
            best = w if best < 0 else min(best, w)
        return best

    def poll(mut self, now_us: Int) -> Diff:
        """Hands finished requests and due timer ticks to update(), then returns what changed on screen. `now_us`: the
        host's monotonic clock in microseconds (the same clock every call)."""
        var changed = False
        for ref t in self.timers:
            if t.start_us < 0:
                t.start_us = now_us
        while len(self.undeliverable) > 0:
            var e = self.undeliverable.pop(0)
            self.app.update(e)
            self.take_effects()
            changed = True
        var i = 0
        while i < len(self.inflight):  # (update() may add requests; they join the end of the list)
            if self.inflight[i].cancelled:  # its end now, nothing of it after (the worker stops and frees on its own)
                var f = self.inflight.pop(i)
                var end = f.stream_end if f.stream_end >= 0 else f.msg
                self.app.update(Event(end, "", 0, id=f.id, error="cancelled"))
                self.take_effects()
                changed = True
                continue
            var done = self.inflight[i].ready()  # (read before the pieces: every piece pushed before it is there)
            if self.inflight[i].stream_end >= 0:
                var pieces = self.inflight[i].take_pieces()
                var seq = self.inflight[i].pieces - len(pieces)
                for ref p in pieces:
                    if self.inflight[i].cancelled:
                        break
                    seq += 1
                    self.app.update(Event(self.inflight[i].msg, p.data, seq, id=self.inflight[i].id, name=p.name))
                    self.take_effects()
                    changed = True
                if self.inflight[i].cancelled:
                    continue
            if not done:
                i += 1
                continue
            var f = self.inflight.pop(i)
            var r = f.response()
            self.app.update(Event(f.stream_end if f.stream_end >= 0 else f.msg, r.text(), r.status, id=f.id, error=r.error))
            self.take_effects()
            changed = True
        var due = List[Tuple[Int, Int]]()  # (msg, count): ticks to deliver, decided before any update changes the list
        for ref t in self.timers:
            if t.start_us >= 0 and now_us >= t.due_us():
                t.count = (now_us - t.start_us) // (t.ms * 1000)  # (a host that slept past several ticks: one event, the count jumps)
                due.append((t.msg, t.count))
        for d in due:
            self.app.update(Event(d[0], "", d[1]))
            self.take_effects()
            changed = True
        if not changed:
            return Diff(False, [])
        return self.refresh()

    def view(self) -> View:
        """The app's screen with its spacing tokens in the theme's points (what every host shows)."""
        var v = self.app.view()
        resolve_layout(v, self.app.theme().look)
        return v^

    def dispatch(mut self, event: Event) -> Diff:
        self.app.update(event)
        self.take_effects()
        var next = self.view()
        var d = diff(self.shown, next)
        self.shown = next^
        return d^

    def dispatch(mut self, message: Int) -> Diff:
        """A plain message with no value (a button tap)."""
        return self.dispatch(Event(message, "", 0))

    def refresh(mut self) -> Diff:
        """The screen again after state changed outside update() (e.g. in draw())."""
        var next = self.view()
        var d = diff(self.shown, next)
        self.shown = next^
        return d^

    def resize(mut self, width: Int, height: Int) -> Diff:
        """The window's content area changed size: the app hears it, then the screen catches up."""
        self.app.resize(width, height)
        return self.refresh()

    def appearance(mut self, dark: Bool) -> Diff:
        """The system's light or dark mode: the app hears it, then the screen catches up."""
        self.app.appearance(dark)
        return self.refresh()

    def draw_scene(mut self, node: Int, mut scene: Scene) -> Tuple[Bool, Diff]:
        """Canvas node `node` as a display list, if the app records one; then what else changed on screen."""
        if node < 0 or node >= len(self.shown.nodes) or self.shown.nodes[node].kind != CANVAS:
            return (False, Diff(False, []))
        if not self.app.draw_scene(self.shown.nodes[node].style, scene):
            return (False, Diff(False, []))
        return (True, self.refresh())

    def draw(mut self, node: Int, mut surface: Surface) -> Diff:
        """Paints canvas node `node`, then returns what else changed on screen."""
        if node < 0 or node >= len(self.shown.nodes) or self.shown.nodes[node].kind != CANVAS:
            return Diff(False, [])
        self.app.draw(self.shown.nodes[node].style, surface)
        return self.refresh()

    def gesture(mut self, node: Int, kind: Int, x: Float64, y: Float64, dx: Float64, dy: Float64, zoom: Float64, pressure: Float64 = 0) -> Diff:
        """A gesture on canvas node `node` (PAN, ZOOM or TAP; PRESS, PAN and RELEASE carry the pen's pressure, 0: none);
        on a Board node, a child moved (PAN: x = the child's index, dx/dy = how far) or resized (ZOOM: the same fields)."""
        if node < 0 or node >= len(self.shown.nodes):
            return Diff(False, [])
        ref n = self.shown.nodes[node]
        if n.kind == BOARD:
            var msg = n.msg if kind == PAN else (n.msg2 if kind == ZOOM else 0)
            if msg == 0:
                return Diff(False, [])
            return self.dispatch(Event(msg, "", Int(x), x, y, dx, dy, zoom))
        if n.kind != CANVAS or n.msg == 0:
            return Diff(False, [])
        return self.dispatch(Event(n.msg, "", kind, x, y, dx, dy, zoom, pressure=pressure))

    def key(mut self, node: Int, name: String, modifiers: Int) -> Diff:
        """A key pressed while canvas node `node` had focus: its gesture message with number = KEY,
        text = the key's name (or the character typed), dx = modifiers (SHIFT, CTRL, ALT)."""
        if node < 0 or node >= len(self.shown.nodes):
            return Diff(False, [])
        ref n = self.shown.nodes[node]
        if n.kind != CANVAS or n.msg == 0:
            return Diff(False, [])
        return self.dispatch(Event(n.msg, name, KEY, 0, 0, Float64(modifiers), 0, 1))

    def cancel(mut self, node: Int, text: String) -> Diff:
        """Escape in field node `node`: its on_cancel message (event.text = the field's text)."""
        if node < 0 or node >= len(self.shown.nodes) or self.shown.nodes[node].kind != FIELD or self.shown.nodes[node].size == 0:
            return Diff(False, [])
        return self.dispatch(Event(self.shown.nodes[node].size, text, 0))

    def frame(mut self, node: Int, microseconds: Int) -> Diff:
        """One display frame for canvas node `node` (only if it asked for frames)."""
        if node < 0 or node >= len(self.shown.nodes) or self.shown.nodes[node].kind != CANVAS or self.shown.nodes[node].msg2 == 0:
            return Diff(False, [])
        return self.dispatch(Event(self.shown.nodes[node].msg2, "", microseconds))
