# mojoui.webcomponent: a JavaScript widget in the screen (goal 34). The app places a widget by its custom element's tag,
# hands it props as JSON data, and hears its events in update(); it can ask the widget to run one of its commands, whose
# reply comes back to update() later, as an HTTP reply does (mojoui.http). The widget itself is a script bundle the app
# lists in App.web_assets() (built by scripts/web_assets.py from the app's web/ folder); the web host mounts it once and
# keeps it across rebuilds; GTK runs it in a WebKitGTK view of its own (mojoui/hosts/gtk_webview.mojo). Hosts without a
# web view (the Mac until 34b, GTK without WebKitGTK) show `instead`.
#
#   WebComponent("mx-counter", Props().text("label", "Clicks").number("step", self.step), on_event=COUNTER, id=1)
#   ...
#   def update(mut self, e: Event):
#       if e.message == COUNTER:            # e.id = the widget's id, e.name = its event ("click"), e.text = the payload (JSON)
#           var j = Json.parse(e.text)
#       elif e.message == ASK:
#           self.widgets.call(Command("mx-counter", 1, "read", reply=READ))
#       elif e.message == READ:             # e.text = the command's reply (JSON), e.error = why there's none ("" if there is)
#           ...
#   def commands(mut self) -> List[Command]:
#       return self.widgets.take()
#   @staticmethod
#   def web_assets() -> List[String]:
#       return ["counter.js"]
#
# Security (docs/js.md): props, payloads, command arguments and replies are JSON text, never code or HTML; the host
# refuses a tag that isn't a custom element's name, an event name that isn't a word, and a payload that isn't JSON.

from mojoui.view import View, Node, WEBCOMP, NO_MSG, Text, _container
from mojoui.json import json_string


struct Props(Copyable, Movable):
    """A widget's props: a JSON object built key by key (each key once; a later one with the same name wins in JS)."""

    var parts: List[String]

    def __init__(out self):
        self.parts = List[String]()

    def text(var self, key: String, value: String) -> Self:
        self.parts.append(json_string(key) + ":" + json_string(value))
        return self^

    def number(var self, key: String, value: Int) -> Self:
        self.parts.append(json_string(key) + ":" + String(value))
        return self^

    def real(var self, key: String, value: Float64) -> Self:
        """A number with a fraction (NaN and infinities, which JSON can't hold, are written as null)."""
        var ok = value == value and value - value == 0
        self.parts.append(json_string(key) + ":" + (String(value) if ok else String("null")))
        return self^

    def flag(var self, key: String, value: Bool) -> Self:
        self.parts.append(json_string(key) + ":" + ("true" if value else "false"))
        return self^

    def raw(var self, key: String, json: String) -> Self:
        """A value that is already JSON (a list, an object): the host checks it parses before the page sees it."""
        self.parts.append(json_string(key) + ":" + json)
        return self^

    def json(self) -> String:
        var out = String("{")
        for i in range(len(self.parts)):
            if i > 0:
                out += ","
            out += self.parts[i]
        return out + "}"


def is_widget_tag(tag: String) -> Bool:
    """A custom element's name: starts with a-z, holds a hyphen, only a-z 0-9 - . _ and at most 64 bytes, and isn't one of
    the names HTML keeps for itself (annotation-xml, font-face…). Hosts mount nothing else."""
    var n = tag.byte_length()
    if n < 3 or n > 64:
        return False
    var b = tag.as_bytes()
    if not (Int(b[0]) >= 97 and Int(b[0]) <= 122):
        return False
    var dash = False
    for k in range(n):
        var c = Int(b[k])
        var ok = (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 45 or c == 46 or c == 95
        if not ok:
            return False
        if c == 45:
            dash = True
    if not dash:
        return False
    for reserved in ["annotation-xml", "color-profile", "font-face", "font-face-src", "font-face-uri", "font-face-format",
                     "font-face-name", "missing-glyph"]:
        if tag == reserved:
            return False
    return True


def is_event_name(name: String) -> Bool:
    """A widget's event or command name: a letter, then letters, digits, - _ . : (at most 64 bytes)."""
    var n = name.byte_length()
    if n < 1 or n > 64:
        return False
    var b = name.as_bytes()
    for k in range(n):
        var c = Int(b[k])
        var letter = (c >= 97 and c <= 122) or (c >= 65 and c <= 90)
        var ok = letter or (k > 0 and ((c >= 48 and c <= 57) or c == 45 or c == 95 or c == 46 or c == 58))
        if not ok:
            return False
    return True


def WebComponent(tag: String, props: Props, on_event: Int = NO_MSG, id: Int = 0) -> View:
    """The widget registered as `tag` (defineWidget in its bundle), with `props`; its events come back as `on_event`
    (event.id = `id`, event.name = the event, event.text = its payload as JSON). Hosts without a web view show nothing."""
    return WebComponent(tag, props.json(), Text(""), on_event, id)


def WebComponent(tag: String, props: Props, instead: View, on_event: Int = NO_MSG, id: Int = 0) -> View:
    """As above; hosts without a web view (the Mac until 34b, GTK without WebKitGTK 6.0) show `instead`."""
    return WebComponent(tag, props.json(), instead, on_event, id)


def WebComponent(tag: String, props_json: String, instead: View, on_event: Int = NO_MSG, id: Int = 0) -> View:
    """Props given as JSON text already (an object). The pair (tag, id) is the widget's key: the same key in the next
    screen is the same widget, kept and updated; a new key is a new widget."""
    var items: List[View] = [instead.copy()]
    return _container(Node(WEBCOMP, props_json, msg=on_event, value=id, hint=tag), items)


struct Command(Copyable, Movable):
    """A request to the widget (`tag`, `widget`): run its command `name` with `args` (JSON). `reply` is the message its
    answer comes back as (NO_MSG: no answer wanted); `id` tells replies with the same message apart (event.id)."""

    var tag: String
    var widget: Int
    var name: String
    var args: String
    var reply: Int
    var id: Int
    var seq: Int  # set by the runtime when it takes the command: what the host's reply names

    def __init__(out self, tag: String, widget: Int, name: String, args: String = "null", reply: Int = NO_MSG):
        self.tag = tag
        self.widget = widget
        self.name = name
        self.args = args
        self.reply = reply
        self.id = 0
        self.seq = 0

    def tagged(var self, id: Int) -> Self:
        self.id = id
        return self^

    def json(self) -> String:
        """What the host hands the page: {seq, tag, widget, name, args} (args as JSON: checked by the runtime)."""
        return ('{"seq":' + String(self.seq) + ',"tag":' + json_string(self.tag) + ',"widget":' + String(self.widget)
                + ',"name":' + json_string(self.name) + ',"args":' + self.args + "}")


struct Widgets(Movable):
    """The app's outbox of widget commands (keep one in the state; App.commands() returns its take())."""

    var out: List[Command]

    def __init__(out self):
        self.out = List[Command]()

    def call(mut self, var command: Command):
        self.out.append(command^)

    def take(mut self) -> List[Command]:
        var taken = self.out^
        self.out = List[Command]()
        return taken^


def commands_json(commands: List[Command]) -> String:
    var out = String("[")
    for i in range(len(commands)):
        if i > 0:
            out += ","
        out += commands[i].json()
    return out + "]"


def assets_json(assets: List[String]) -> String:
    var out = String("[")
    for i in range(len(assets)):
        if i > 0:
            out += ","
        out += json_string(assets[i])
    return out + "]"
