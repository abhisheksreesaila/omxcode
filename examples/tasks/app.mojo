# tasks: the todo app built in docs/tasks.html, one part at a time. Its tasks are kept in SQLite at
# <config>/tasks/tasks.db (~/.config/tasks; OMX_CONFIG moves it, as the checks do), so they're there next time.
# Build it: scripts/build.sh tasks linux (or web, mac); run build/tasks/linux/tasks. Checked by scripts/tutorials.py.

from mojoui import App, Event, View, VStack, HStack, Text, Button, TextField, TITLE, CAPTION, PROMINENT
from mojoui.overlays import Checkbox
from mojoui.files import config_dir
from mojoui.shared import make_dir
from mojoui.sqlite import Database
from mojoui.theme import Theme
from themes.liquid import liquid

comptime TYPING = 1
comptime ADD = 2
comptime TICK = 1_000_000  # TICK + a task's id: its box was ticked or cleared
comptime REMOVE = 2_000_000  # REMOVE + a task's id: its Remove button


@fieldwise_init
struct Task(Copyable, Movable):
    var id: Int
    var title: String
    var done: Bool


def open_db() raises -> Database:
    make_dir(config_dir("tasks"))
    var db = Database(config_dir("tasks") + "/tasks.db")
    db.exec("CREATE TABLE IF NOT EXISTS tasks(id INTEGER PRIMARY KEY, title TEXT, done INTEGER)")
    return db^


def load(db: Database) raises -> List[Task]:
    var tasks = List[Task]()
    var q = db.prepare("SELECT id, title, done FROM tasks ORDER BY id")
    while q.step():
        tasks.append(Task(q.int(0), q.text(1), q.int(2) == 1))
    return tasks^


struct Main(App):
    var tasks: List[Task]
    var draft: String
    var problem: String

    def __init__(out self):
        self.tasks = List[Task]()
        self.draft = ""
        self.problem = ""
        try:
            self.tasks = load(open_db())
        except e:
            self.problem = String(e)

    def title(self) -> String:
        return "Tasks"

    def theme(self) -> Theme:
        return liquid()

    def update(mut self, event: Event):
        var m = event.message
        if m == TYPING:
            self.draft = event.text
            return
        self.problem = ""
        try:
            var db = open_db()
            if m == ADD:
                var title = String(self.draft.strip())
                if title != "":
                    var add = db.prepare("INSERT INTO tasks(title, done) VALUES (?, 0)")
                    add.bind(1, title)
                    add.run()
                self.draft = ""
            elif m >= REMOVE:
                var remove = db.prepare("DELETE FROM tasks WHERE id = ?")
                remove.bind(1, m - REMOVE)
                remove.run()
            elif m >= TICK:
                var tick = db.prepare("UPDATE tasks SET done = ? WHERE id = ?")
                tick.bind(1, event.number)
                tick.bind(2, m - TICK)
                tick.run()
            self.tasks = load(db)
        except e:
            self.problem = String(e)

    def view(self) -> View:
        var rows = List[View]()
        var left = 0
        for t in self.tasks:
            if not t.done:
                left += 1
            rows.append(HStack(
                Checkbox(t.title, t.done, on_toggle=TICK + t.id).grow(),
                Button("Remove", on_tap=REMOVE + t.id).tooltip("Remove " + t.title),
            ).fill())
        if len(rows) == 0:
            rows.append(Text("Nothing to do yet", style=CAPTION))
        if self.problem != "":
            rows.append(Text(self.problem, style=CAPTION))
        return VStack(
            Text("Tasks", style=TITLE),
            HStack(
                TextField(self.draft, placeholder="What needs doing?", on_change=TYPING, on_submit=ADD).grow(),
                Button("Add", on_tap=ADD, style=PROMINENT),
            ).fill(),
            VStack(rows^, spacing=8).fill(),
            Text(String(left) + " left", style=CAPTION),
            spacing=16,
        ).padding(8).width(360)
