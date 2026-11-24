# Goal 81, M3: several LazyLists in a window; Flip and Again change every row's words, Third takes the third list away
# and back, Fewer changes the first one's length.
from mojoui import App, Event, View, VStack, HStack, Text, Button, LazyList


struct Main(App):
    var word: String
    var third: Bool
    var rows: Int

    def __init__(out self):
        self.word = "old"
        self.third = False
        self.rows = 1000

    def title(self) -> String:
        return "Lists"

    def window_size(self) -> Tuple[Int, Int]:
        return (1200, 700)

    def row(self, list_id: Int, index: Int) -> String:
        return String(list_id) + " " + self.word + " " + String(index)

    def update(mut self, event: Event):
        if event.message == 1:
            self.word = "new"
        elif event.message == 2:
            self.word = "newer"
        elif event.message == 3:
            self.third = not self.third
        elif event.message == 4:
            self.rows = 900

    def view(self) -> View:
        var lists: List[View] = [LazyList(self.rows, 1, height=300, row_height=30).tag("a")]
        if self.third:
            lists.append(LazyList(1000, 3, height=300, row_height=30).tag("c"))
        lists.append(LazyList(1000, 2, height=300, row_height=30).tag("b"))
        return VStack(HStack(Button("Flip", 1), Button("Again", 2), Button("Third", 3), Button("Fewer", 4)), HStack(lists))
