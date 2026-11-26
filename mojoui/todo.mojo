# mojoui.todo: a to-do list that lives in a file, for an app whose voice, agent and screen all edit it (goal 72 M6, D-7260).
#
#   var list = TodoList(todo_path())             # $MOJOUI_TODO, else ~/.local/share/mojoui/todo.json; loads what's there
#   list.add(["buy milk", "call mum"])           # saved at once (written beside, then renamed: a crash keeps the old file)
#   list.done("mum")                             # by number ("2"), or by words ("call mum", "the milk"); "" when it can't tell which
#   list.remove("1"); list.toggle(0); list.refresh()    # refresh(): True when another writer changed the file
#   TodoCard(list.items, TICK)                   # the card: a tick box per thing (message TICK + its index), "n left"
#   todo_functions()                             # the agent's tools: todo_add (several at once), todo_done, todo_remove, todo_list
#
# A save that fails is said (list.save_error; the tools answer "I couldn't save the list: …"), and a file that can't be read
# (not JSON, not a list of items) is moved aside to todo.json.bad-<time> before anything is written, never overwritten (D-7257).
#
# The tools keep no state of their own: each call opens the file, changes it and says what is on the list now, so a tool the
# model calls and a tick box the person taps edit the same thing, and a list survives the app (or the agent) restarting. An
# app notices the model's change with refresh() on its timer and shows TodoCard from its items.

from std.os import makedirs
from std.os.path import exists
from mojoui.utf8 import head
from mojoui import libc
from mojoui.clock import wall_seconds
from mojoui.json import Json, json_string, J_ARRAY, J_STRING, J_NUMBER
from mojoui.llmagent import ToolFn
from mojoui.shared import environment
from mojoui.view import View, Text, Toggle, Card, VStack, HEADLINE, CAPTION
from mojoui.watch import file_stamp

comptime MAX_ITEMS = 200
comptime MAX_TEXT = 200


struct TodoItem(Copyable, Movable):
    var text: String
    var done: Bool

    def __init__(out self, text: String, done: Bool = False):
        self.text = text
        self.done = done


def todo_path() -> String:
    """Where the list is kept: $MOJOUI_TODO, else $XDG_DATA_HOME (or ~/.local/share)/mojoui/todo.json."""
    var own = environment("MOJOUI_TODO")
    if own != "":
        return own
    var data = environment("XDG_DATA_HOME")
    if data == "":
        data = environment("HOME") + "/.local/share"
    return data + "/mojoui/todo.json"


def _words(text: String) -> List[String]:
    """Lower-case letters and digits (and any non-ASCII letter's bytes), split at anything else."""
    var out = List[String]()
    var cur = List[UInt8]()
    for b in text.as_bytes():
        var c = Int(b)
        if c >= 65 and c <= 90:
            c += 32
        if (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c >= 128:
            cur.append(UInt8(c))
        elif len(cur) > 0:
            out.append(String(from_utf8_lossy=Span(cur)))
            cur = List[UInt8]()
    if len(cur) > 0:
        out.append(String(from_utf8_lossy=Span(cur)))
    return out^


def _stop(w: String) -> Bool:
    for s in ["the", "a", "an", "to", "my", "and", "of", "for", "on", "in", "it", "that", "one", "this", "thing", "item", "task", "off", "up"]:
        if w == s:
            return True
    return False


struct TodoList(Movable):
    var path: String
    var items: List[TodoItem]
    var seen_stamp: Int  # the file's modified time (ns) as last read or written
    var save_error: String  # why the last save didn't happen ("" when it did)
    var note: String  # what happened to a file that couldn't be read ("" when it could)
    var blocked: Bool  # the file can't be read and can't be moved aside: nothing is written

    def __init__(out self, path: String):
        self.path = path
        self.items = List[TodoItem]()
        self.seen_stamp = 0
        self.save_error = String("")
        self.note = String("")
        self.blocked = False
        self.load()

    # --- the file -------------------------------------------------------------------------------------------------

    def load(mut self):
        self.items = List[TodoItem]()
        self.seen_stamp = file_stamp(self.path)[0]
        self.note = String("")
        self.blocked = False
        if not exists(self.path):
            return
        try:
            var text: String
            with open(self.path, "r") as f:
                text = f.read()
            var j = Json.parse(text)
            var xs = j.get(0, "items")
            if xs < 0 or j.kind(xs) != J_ARRAY:
                raise Error("it has no list of items")
            for i in range(min(j.size(xs), MAX_ITEMS)):
                var x = j.at(xs, i)
                self.items.append(TodoItem(j.text(j.get(x, "text")), j.flag(j.get(x, "done"))))
        except e:
            self.items = List[TodoItem]()  # (a file that isn't ours: kept aside, never written over)
            self.set_aside(String(e))

    def set_aside(mut self, why: String):
        """The file couldn't be read: it moves to <path>.bad-<time> (the first name that is free) and the list starts empty."""
        var stamp = String(Int(wall_seconds()))
        var to = self.path + ".bad-" + stamp
        var k = 2
        while exists(to):
            to = self.path + ".bad-" + stamp + "-" + String(k)
            k += 1
        if libc.rename(self.path, to) == 0:
            self.note = "the to-do file couldn't be read (" + why + "); it was kept as " + to + " and this list starts empty"
        else:
            self.note = "the to-do file couldn't be read (" + why + ") and couldn't be set aside, so nothing will be written over it"
            self.blocked = True
        self.seen_stamp = file_stamp(self.path)[0]

    def save(mut self) -> Bool:
        var out = String('{"items":[')
        for i in range(len(self.items)):
            out += ("," if i > 0 else "") + '{"text":' + json_string(self.items[i].text) + ',"done":' + ("true" if self.items[i].done else "false") + "}"
        out += "]}"
        if self.blocked:  # (an unreadable file that couldn't be moved aside stays as it is)
            self.save_error = self.note
            return False
        self.save_error = String("")
        try:
            var slash = self.path.rfind("/")
            if slash > 0:
                makedirs(String(self.path[byte = :slash]), exist_ok=True)
            var tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                f.write(out)
            if libc.rename(tmp, self.path) != 0:
                self.save_error = "the file couldn't be moved into place"
        except e:
            self.save_error = String(e)
        self.seen_stamp = file_stamp(self.path)[0]
        return self.save_error == ""

    def refresh(mut self) -> Bool:
        """Reads the file again when someone else changed it since (a tool call while the screen was showing it)."""
        var now = file_stamp(self.path)[0]
        if now == self.seen_stamp:
            return False
        self.load()
        return True

    # --- the list -------------------------------------------------------------------------------------------------

    def open_count(self) -> Int:
        var n = 0
        for ref i in self.items:
            if not i.done:
                n += 1
        return n

    def add(mut self, texts: List[String]) -> Int:
        """Puts each non-empty text at the end (a full stop dropped, 200 letters at most); how many were added."""
        var n = 0
        for t in texts:
            var s = String(t.strip())
            while s.endswith("."):
                var shorter = String(s[byte = : s.byte_length() - 1])
                s = shorter^
            if s == "" or len(self.items) >= MAX_ITEMS:
                continue
            self.items.append(TodoItem(head(s, MAX_TEXT)))
            n += 1
        if n > 0:
            self.save()
        return n

    def find(self, which: String) -> Int:
        """The index `which` means: a number ("2" is the second thing, done or not), or words that fit exactly one thing
        that isn't done yet ("mum", "call mum", "the milk"). -1 when none fits, -2 when several do."""
        var w = String(which.strip())
        if w != "":
            var digits = True
            var n = 0
            for b in w.as_bytes():
                if Int(b) < 48 or Int(b) > 57:
                    digits = False
                elif n < 100000:
                    n = n * 10 + Int(b) - 48
            if digits:
                return n - 1 if n >= 1 and n <= len(self.items) else -1
        var words = List[String]()
        for x in _words(w):
            if not _stop(x):
                words.append(x)
        if len(words) == 0:
            return -1
        var best = -1
        var best_score = 0
        var tie = False
        for i in range(len(self.items)):
            if self.items[i].done:
                continue
            var have = _words(self.items[i].text)
            var score = 0
            for x in words:
                for h in have:
                    if h == x:
                        score += 1
            if score > best_score:
                best = i
                best_score = score
                tie = False
            elif score == best_score and score > 0:
                tie = True
        if best_score == 0:
            return -1
        return -2 if tie else best

    def done(mut self, which: String) -> Int:
        """Ticks the thing `which` means (see find); its index, or find's -1 / -2."""
        var i = self.find(which)
        if i >= 0:
            self.items[i].done = True
            self.save()
        return i

    def toggle(mut self, i: Int):
        if i >= 0 and i < len(self.items):
            self.items[i].done = not self.items[i].done
            self.save()

    def remove(mut self, which: String) -> String:
        """Takes away the thing `which` means; its text, or "" when no single thing fits."""
        var i = self.find(which)
        if i < 0:
            return String("")
        var gone = self.items[i].text
        var rest = List[TodoItem]()
        for k in range(len(self.items)):
            if k != i:
                rest.append(self.items[k].copy())
        self.items = rest^
        self.save()
        return gone

    def describe(self) -> String:
        """The list as a tool result: {"open": n, "items": ["1. buy milk", "2. call mum (done)"]}."""
        var out = String('{"open":') + String(self.open_count()) + ',"items":['
        for i in range(len(self.items)):
            out += ("," if i > 0 else "") + json_string(String(i + 1) + ". " + self.items[i].text + (" (done)" if self.items[i].done else ""))
        return out + "]" + (',"note":' + json_string(self.note) if self.note != "" else "") + "}"


# ---------------------------------------------------------------------------------------------------------------------
# the card
# ---------------------------------------------------------------------------------------------------------------------

def TodoCard(items: List[TodoItem], tick: Int) -> View:
    """The list as a card: its title with how many are left, a tick box per thing (tapping it sends tick + its index; the box is
    tagged todo-1, todo-2…). Build it from the list's items each time: it is the list, so it changes in place."""
    var open = 0
    for ref i in items:
        if not i.done:
            open += 1
    var rows = List[View]()
    rows.append(Text("To do", HEADLINE))
    rows.append(Text("Nothing here yet" if len(items) == 0 else (String(open) + " left of " + String(len(items))), CAPTION))
    for i in range(len(items)):
        rows.append(Toggle(items[i].text, items[i].done, tick + i).tag("todo-" + String(i + 1)))
    return Card(rows^).tag("todo").fill()


# ---------------------------------------------------------------------------------------------------------------------
# the agent's tools
# ---------------------------------------------------------------------------------------------------------------------

def _which(j: Json) -> String:
    """The "which" argument: a number or words."""
    for key in ["which", "number", "item", "text"]:
        var n = j.get(0, String(key))
        if n >= 0:
            return String(j.number(n)) if j.kind(n) == J_NUMBER else j.text(n)
    return String("")


def _unsaved(list: TodoList) -> String:
    """The tool's answer when the list changed in memory but the file couldn't be written: the model must not say it is done."""
    return '{"error":' + json_string("I couldn't save the list: " + list.save_error + ". The change was not kept; tell the user.") + ',"list":' + list.describe() + "}"


def todo_add(args: String) -> String:
    try:
        var j = Json.parse(args)
        var texts = List[String]()
        var xs = j.get(0, "items")
        if xs >= 0 and j.kind(xs) == J_ARRAY:
            for i in range(j.size(xs)):
                texts.append(j.text(j.at(xs, i)))
        elif xs >= 0 and j.kind(xs) == J_STRING:
            texts.append(j.text(xs))
        var one = j.get(0, "item")
        if one >= 0:
            texts.append(j.text(one))
        var list = TodoList(todo_path())
        var n = list.add(texts)
        if n == 0:
            return '{"error":"nothing to add: give items as a list of short phrases"}'
        if list.save_error != "":
            return _unsaved(list)
        return '{"added":' + String(n) + ',"list":' + list.describe() + "}"
    except e:
        return '{"error":' + json_string("the arguments aren't JSON: " + String(e)) + "}"


def todo_done(args: String) -> String:
    try:
        var j = Json.parse(args)
        var which = _which(j)
        var list = TodoList(todo_path())
        var i = list.done(which)
        if i == -2:
            return '{"error":"more than one thing fits; use its number","list":' + list.describe() + "}"
        if i < 0:
            return '{"error":"nothing on the list fits that; use its number","list":' + list.describe() + "}"
        if list.save_error != "":
            return _unsaved(list)
        return '{"ticked":' + json_string(list.items[i].text) + ',"list":' + list.describe() + "}"
    except e:
        return '{"error":' + json_string("the arguments aren't JSON: " + String(e)) + "}"


def todo_remove(args: String) -> String:
    try:
        var j = Json.parse(args)
        var which = _which(j)
        var list = TodoList(todo_path())
        var gone = list.remove(which)
        if gone == "":
            return '{"error":"nothing on the list fits that; use its number","list":' + list.describe() + "}"
        if list.save_error != "":
            return _unsaved(list)
        return '{"removed":' + json_string(gone) + ',"list":' + list.describe() + "}"
    except e:
        return '{"error":' + json_string("the arguments aren't JSON: " + String(e)) + "}"


def todo_list(args: String) -> String:
    return TodoList(todo_path()).describe()


def todo_functions() -> List[ToolFn]:
    """The four tools for LlmAgent.add_function: a spoken list of things becomes todo_add with several items at once."""
    var out = List[ToolFn]()
    out.append(ToolFn("todo_add", "Put things on the user's to-do list. Pass every thing the user named, one short phrase each, in one call.",
                      '{"type":"object","properties":{"items":{"type":"array","items":{"type":"string"},"description":"short phrases, one per thing"}},"required":["items"]}', todo_add))
    out.append(ToolFn("todo_done", "Tick a thing off the to-do list as done. `which` is its number on the list, or a few of its words.",
                      '{"type":"object","properties":{"which":{"type":"string","description":"the number or some of the words"}},"required":["which"]}', todo_done))
    out.append(ToolFn("todo_remove", "Take a thing off the to-do list for good (not the same as done). `which` is its number or a few of its words.",
                      '{"type":"object","properties":{"which":{"type":"string","description":"the number or some of the words"}},"required":["which"]}', todo_remove))
    out.append(ToolFn("todo_list", "Read the to-do list: what is on it and how many are still open. Use it to answer what is left.",
                      '{"type":"object","properties":{}}', todo_list))
    return out^
