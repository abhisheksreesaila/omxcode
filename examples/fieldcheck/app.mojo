# Field check (a framework check, D-1321): a field whose every change rebuilds the screen (one row per character, so
# the stack's children change each time). GTK's gtk_editable_set_text (the `type:` step, a paste over a selection)
# changes the text twice, "" then the new text; the "" rebuilds, and the host used to drop the second change while
# that rebuild was pending, so the app's text and the field's differed. Prints on every change
#   FIELDCHECK: app=<the app's text> rows=<n>
# and the test (tests/test_field_queue.py) types several values and wants the app's last text to be the last typed.
# FIELDCHECK_STALL_MS=N: update() holds the UI thread N ms on every change (a deliberate freeze: tests/test_gaps_stall.py
# proves the host's gaps: step sees it, traced or not, D-1324).

from mojoui import App, Event, View, VStack, Text, TextField
from mojoui.clock import now_ns
from mojoui.shared import environment

comptime CHANGE = 1


struct Main(App):
    var text: String

    def __init__(out self):
        self.text = ""

    def title(self) -> String:
        return "Field check"

    def update(mut self, event: Event):
        if event.message == CHANGE:
            self.text = event.text
            var stall = environment("FIELDCHECK_STALL_MS")
            if stall != "":
                try:
                    var until = now_ns() + Int(stall) * 1_000_000
                    while now_ns() < until:
                        pass
                except:
                    pass
            print("FIELDCHECK: app=" + self.text + " rows=" + String(self.text.byte_length()), flush=True)

    def view(self) -> View:
        var items = List[View]()
        items.append(TextField(self.text, "Query", on_change=CHANGE))
        for i in range(self.text.byte_length()):
            items.append(Text("row " + String(i)))
        return VStack(items)
