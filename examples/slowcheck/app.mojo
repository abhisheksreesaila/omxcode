# slowcheck: the slow-frame watchdog's check app (goal 41 M1). Two buttons: "slow" makes update() sleep 80 ms, which
# breaks rule 1 of docs/ui-threads.md on purpose; "fast" doesn't. Run with MOJOUI_BUDGET_MS=50 and every host prints
# `SLOW: update msg=1 80.xx ms` after tapping slow, and nothing after tapping fast.

from std.time import sleep
from mojoui import App, Event, View, VStack, Text, Button, TITLE, CAPTION

comptime SLOW = 1
comptime FAST = 2


struct Main(App):
    var taps: Int

    def __init__(out self):
        self.taps = 0

    def title(self) -> String:
        return "slowcheck"

    def update(mut self, event: Event):
        if event.message == SLOW:
            sleep(0.08)  # (on purpose: the watchdog must name it)
            self.taps += 1
        elif event.message == FAST:
            self.taps += 1

    def view(self) -> View:
        return VStack(
            Text("Slow-frame watchdog", style=TITLE),
            Text("taps: " + String(self.taps), style=CAPTION),
            Button("slow", on_tap=SLOW),
            Button("fast", on_tap=FAST),
            spacing=12,
        )
