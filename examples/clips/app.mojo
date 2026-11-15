# clips: mojoui.clipgrid on its own (goal 71), with drawn posters so it needs no data or engine. Tap a poster: it becomes
# the shown clip; press a tile's Pick: it joins the picked set. The line under the title says both (checks read it).
from mojoui import App, Event, View, VStack, Text, TITLE, CAPTION, START
from mojoui.clipgrid import ClipTile, ClipGrid, clip_message, clip_columns, CLIP_MSGS

comptime CLIP_MSG = 100
comptime N = 6


def poster(i: Int, w: Int, h: Int) -> List[UInt32]:
    """A gradient in tile i's own hue."""
    var out = List[UInt32](length=w * h, fill=0)
    for y in range(h):
        for x in range(w):
            var r = (x * 255 // w + i * 40) % 256
            var g = (y * 255 // h) % 256
            var b = (i * 70 + 60) % 256
            out[y * w + x] = UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(255) << 24)
    return out^


struct Main(App):
    var shown: Int
    var picked: List[Bool]
    var posters: List[List[UInt32]]

    def __init__(out self):
        self.shown = -1
        self.picked = List[Bool](length=N, fill=False)
        self.posters = List[List[UInt32]]()
        for i in range(N):
            self.posters.append(poster(i, 160, 120))

    def title(self) -> String:
        return "clips"

    def window_size(self) -> Tuple[Int, Int]:
        return (1000, 760)

    def update(mut self, event: Event):
        var m = event.message
        if CLIP_MSG <= m < CLIP_MSG + N * CLIP_MSGS:
            var c = clip_message(m - CLIP_MSG)
            if c[1]:
                self.picked[c[0]] = not self.picked[c[0]]
            else:
                self.shown = c[0]

    def view(self) -> View:
        var tiles = List[ClipTile]()
        var picks = String()
        for i in range(N):
            var key = "c" + String(i + 1)
            tiles.append(ClipTile(key, "Clip " + String(i + 1), "drawn · " + String(i + 2) + ".0 s", "0.9" + String(9 - i), self.posters[i], 160, 120,
                                  shown=i == self.shown, picked=self.picked[i]))
            if self.picked[i]:
                picks += (", " if picks.byte_length() > 0 else "") + key
        var line = "Like: " + ("c" + String(self.shown + 1) if self.shown >= 0 else "none") + " · Picked: " + (picks if picks.byte_length() > 0 else "none")
        return VStack(Text("clips", TITLE), Text(line, CAPTION).tag("clips-state"), ClipGrid(tiles, CLIP_MSG, clip_columns(940)), spacing=12).padding(24).fill().align(START)
