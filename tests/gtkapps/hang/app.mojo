# Goal 81, M5: an app that hangs: its third tick takes 1.2 s in update(), its sixth 0.1 s; then it ends itself.
from std.time import sleep
from std.os import abort
from mojoui import App, Event, View, VStack, Text, TextField
from mojoui.effects import Every
from mojoui.libc import usleep


struct Main(App):
    var ticks: Int

    def __init__(out self):
        self.ticks = 0

    def title(self) -> String:
        return "Private title of /home/someone/diary.txt"

    def every(self) -> List[Every]:
        return [Every(700, 77)]

    def update(mut self, event: Event):
        if event.message == 77:
            self.ticks += 1
            if self.ticks == 4:
                print("HANGING", flush=True)
                _ = usleep(1_200_000)
                print("DONE HANGING", flush=True)
            if self.ticks == 6:
                _ = usleep(100_000)

    def view(self) -> View:
        return VStack(Text("secret words " + String(self.ticks)), TextField("typed secret", "hint"))
