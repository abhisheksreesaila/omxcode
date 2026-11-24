# Goal 81, M1: a window of random screens (tests/randomview.mojo). Step: the next one. $G81_SEED picks which.
from std.os import getenv
from mojoui import App, Event, View, VStack, HStack, Text, Button
from mojoui.canvas import Surface
from tests.randomview import random_screen, mix


struct Main(App):
    var seed: Int
    var epoch: Int

    def __init__(out self):
        self.seed = 1
        self.epoch = 0
        try:
            self.seed = Int(getenv("G81_SEED"))
        except:
            pass

    def title(self) -> String:
        return "Random screens"

    def row(self, list_id: Int, index: Int) -> String:
        return "row " + String(list_id) + "/" + String(index) + " of " + String(self.epoch)

    def update(mut self, event: Event):
        if event.message == 777:
            self.epoch += 1

    def view(self) -> View:
        var far = self.epoch % 7 == 6
        var body = random_screen(self.seed + (1000 if far else 0), self.epoch, 1)
        return VStack(HStack(Button("Step", 777), Text("screen " + String(self.epoch))), body^)
