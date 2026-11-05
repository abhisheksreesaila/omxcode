# mojoui.album: pictures an app holds for its agent's UI, by name (D-4759). An agent's render_ui may show one (genui's
# "Picture" component, {"name": "tagus"}) but never sends pixels or a URL: a name the album doesn't hold is refused,
# and the agent hears which names there are in each run's context, with what each one shows.
#
#   var album = Album()
#   album.add("tagus", "pictures/tagus.jpg", "the river at sunset from Senhora do Monte")   # raises: missing or not a picture
#   chat.set_album(album^)                                                                   # (mojoui.agentchat)

from std.memory import ArcPointer
from mojoui.picture import Picture
from mojoui.json import json_string
from mojoui.canvas import Surface


struct Album(Copyable, Movable, Defaultable):
    var names: List[String]
    var abouts: List[String]  # what each shows, for the agent
    var pictures: List[ArcPointer[Picture]]  # (copies of the album share the pixels: every screen holds one)

    def __init__(out self):
        self.names = List[String]()
        self.abouts = List[String]()
        self.pictures = List[ArcPointer[Picture]]()

    def add(mut self, name: String, path: String, about: String) raises:
        """The picture at `path` (PNG, JPEG, WebP…: mojoui.picture), decoded now, shown when an agent names `name`."""
        var p = Picture(path)
        var at = self.find(name)
        if at >= 0:
            self.abouts[at] = about
            self.pictures[at] = ArcPointer(p^)
            return
        self.names.append(name)
        self.abouts.append(about)
        self.pictures.append(ArcPointer(p^))

    def find(self, name: String) -> Int:
        for k in range(len(self.names)):
            if self.names[k] == name:
                return k
        return -1

    def count(self) -> Int:
        return len(self.names)

    def names_text(self) -> String:
        var out = String("")
        for nm in self.names:
            out += (", " if out.byte_length() > 0 else "") + nm
        return out if out.byte_length() > 0 else String("none")

    def describe(self) -> String:
        """The pictures for the agent (a run's context): [{name, shows, width, height}]."""
        var out = String("[")
        for k in range(len(self.names)):
            out += ("," if k > 0 else "") + '{"name":' + json_string(self.names[k]) + ',"shows":' + json_string(self.abouts[k])
            out += ',"width":' + String(self.pictures[k][].width) + ',"height":' + String(self.pictures[k][].height) + "}"
        return out + "]"

    def draw(self, k: Int, mut s: Surface, backdrop: UInt32):
        """Picture k, as large as fits, centred, with rounded corners, `backdrop` around it."""
        self.pictures[k][].draw(s, backdrop)
