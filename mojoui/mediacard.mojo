# mojoui.mediacard: videos and pictures as cards on a page (goal 39 M6). A generic component: omxplorer puts them on its
# sheet's Board beside charts and pivots; any app with a Board (or a plain stack) can. Each card has the sheet objects'
# chrome: a title bar (the file's name, what it is, a close button; drag it to move the card) over the media, which is a
# Player (mojoui.player) for a video and a Picture (mojoui.picture) for a still. Many cards play at once: each owns its
# own block of messages and canvases, allocated when it is added and kept while it lives.
#
#   var media = MediaCards(msg_base=4000, canvas_base=200, most=8)   # messages 4000 … 4000 + 8·CARD_MESSAGES (9), canvases 200 … 215
#   var k = media.add(path, x, y, width)                            # returns at once (raises only when the file is missing): the card
#                                                                   # opens in place (16:9 until the probe lands, then its own shape)
#   jobs / frames: if media.poll(): …                               # takes what the cards' decoder threads finished (sizes, frames)
#   update():   if media.update(event): …                           # True when the event was a card's (a close removes it: media.closed)
#   view():     media.view(k).at(c.x, c.y).width(c.w).height(c.h)   # for k in range(len(media)): c = media.cards[k]
#   draw():     if media.draws(canvas): media.draw(canvas, surface, palette)
#   describe(): media.describe(canvas)                              # a player's time and how to seek, for an agent
#   media.cards[k].actions.append(CardAction("Analyze", "zap", "analyze", "…"))   # up to 3 quiet actions in the title bar (Analyze, Make a reel, Edit)
#   update():   if media.acted >= 0: …                              # card media.acted_card's action media.acted was tapped
#   media.cards[k].status = "Analyzing"; .progress = 42             # work running for the card: its title bar says so (-1: none)
#
# For an agent a video card's controls are the Player's tools: play / pause, seek (set it to a time in seconds), video.

from std.time import sleep
from mojoui.app import Event
from mojoui.canvas import Surface
from mojoui.charts import fixed
from mojoui.files import file_name
from mojoui.picture import Picture
from mojoui.player import Player, clock_text, MESSAGES as PLAYER_MESSAGES, FRAME as PLAYER_FRAME
from mojoui.theme import Palette
from mojoui.view import View, Text, Button, Canvas, VStack, HStack, Spacer, Card, ProgressBar, HEADLINE, CAPTION, ICON_ONLY, SUBTLE, CENTER

comptime OBJ_VIDEO = 3  # (after sheetpage's OBJ_CHART = 1, OBJ_PIVOT = 2: one numbering for what sits on a sheet)
comptime OBJ_IMAGE = 4
comptime CARD_MESSAGES = 9  # a card's block: its Player's messages (0 … 4), then close (5), then its actions (6, 7, 8)
comptime CARD_CLOSE = 5
comptime CARD_ACTION = 6
comptime MAX_ACTIONS = 3
comptime CARD_CANVASES = 2  # a video's picture and scrubber; a still's picture
comptime HEAD_H = 36  # the title bar (the drag handle), as sheet objects have it
comptime CHROME_W = 28  # a card's padding, left and right together
comptime CHROME_H = 132  # what a video card adds to its picture's height: the title bar, the controls, the gaps, the padding
comptime STILL_CHROME_H = 64  # the same for a still: the title bar, the gap, the padding
comptime VIDEO_TYPES = ".mp4,.mov,.m4v,.webm,.mkv,.avi"  # (FilePicker accept lists)
comptime IMAGE_TYPES = ".png,.jpg,.jpeg,.webp,.gif,.bmp"


def extension(path: String) -> String:
    """The file's extension, lower case, with its dot (".mp4"); "" when it has none."""
    var name = file_name(path)
    var dot = name.rfind(".")
    if dot <= 0:
        return String("")
    return String(name[byte=dot:]).lower()


def _listed(ext: String, types: String) -> Bool:
    if ext == "":
        return False
    for t in types.split(","):
        if String(t) == ext:
            return True
    return False


def is_video_file(path: String) -> Bool:
    return _listed(extension(path), VIDEO_TYPES)


def is_image_file(path: String) -> Bool:
    return _listed(extension(path), IMAGE_TYPES)


def is_media_file(path: String) -> Bool:
    return is_video_file(path) or is_image_file(path)


@fieldwise_init
struct CardAction(Copyable, Movable):
    """A quiet action in a card's title bar: its label and icon, its tag (an agent's tool name) and its tooltip."""

    var label: String
    var icon: String
    var tag: String
    var tip: String


struct MediaCard(Movable):
    """One card: where it sits, what it shows, and its slot (which block of messages and canvases it owns)."""
    var kind: Int  # OBJ_VIDEO, OBJ_IMAGE
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var path: String
    var slot: Int
    var player: Optional[Player]
    var picture: Optional[Picture]
    var actions: List[CardAction]  # up to MAX_ACTIONS, shown in the title bar while nothing runs
    var status: String  # work running for the card ("Analyzing"), shown instead of its actions ("": none)
    var progress: Int  # that work's percent (-1: not known)

    def __init__(out self, path: String, slot: Int, msg: Int, canvas: Int, x: Int, y: Int, w: Int) raises:
        self.path = path
        self.actions = List[CardAction]()
        self.status = ""
        self.progress = -1
        self.slot = slot
        self.x = x
        self.y = y
        self.w = w
        self.player = None
        self.picture = None
        if is_image_file(path):
            self.kind = OBJ_IMAGE
            self.picture = Picture.opening(path)  # (decoded on a thread: the card shows its frame until it lands)
        else:
            self.kind = OBJ_VIDEO
            self.player = Player(path, msg, canvas)
        self.h = 0
        self.h = self.height_for(w)

    def media_size(self) -> Tuple[Int, Int]:
        """The media's pixels; 16 × 9 until its decoder has said (the card's shape meanwhile)."""
        if self.player and self.player.value().ready():
            return (self.player.value().info.width, self.player.value().info.height)
        if self.picture and self.picture.value().ready():
            return (self.picture.value().width, self.picture.value().height)
        return (16, 9)

    def ready(self) -> Bool:
        """Its decoder has said what the media is (size, length)."""
        if self.player:
            return self.player.value().ready()
        return Bool(self.picture) and self.picture.value().ready()

    def problem(self) -> String:
        """Why it can't be shown ("": opening or fine)."""
        if self.player:
            return self.player.value().problem()
        if self.picture:
            return self.picture.value().problem
        return String("")

    def poll(mut self) -> Bool:
        """Takes what its decoder finished; True when the card changed (its height follows the media's shape)."""
        var changed = False
        if self.player:
            changed = self.player.value().poll()
        elif self.picture:
            changed = self.picture.value().poll()
        if changed:
            var h = self.height_for(self.w)
            if h != self.h:
                self.h = h
        return changed

    def height_for(self, width: Int) -> Int:
        """The card's height at `width` points: the media at its own proportions, with the card's chrome."""
        var size = self.media_size()
        var inner = max(width - CHROME_W, 1) * size[1] // max(size[0], 1)
        return inner + (CHROME_H if self.kind == OBJ_VIDEO else STILL_CHROME_H)

    def title(self) -> String:
        return file_name(self.path)

    def facts(self) -> String:
        """What it is, in a few words: "0:29 · 1280×720", or "1280×720 PNG"."""
        if self.problem() != "":
            return "can't be opened"
        if not self.ready():
            return "opening…"
        var size = self.media_size()
        var dims = String(size[0]) + "×" + String(size[1])
        if self.player:
            return clock_text(self.player.value().state.duration) + " · " + dims
        return dims + " " + extension(self.path).upper().replace(".", "")


struct MediaCards(Movable, Sized):
    """The cards on a page, each with its own messages and canvases (so several players run at once)."""
    var cards: List[MediaCard]
    var msg_base: Int
    var canvas_base: Int
    var most: Int  # how many cards at once (the blocks reserved)
    var closed: Int  # the card the last update() removed (its index then), else -1
    var acted_card: Int  # the card whose action the last update() was (its index), else -1
    var acted: Int  # which of its actions, else -1

    def __init__(out self, msg_base: Int, canvas_base: Int, most: Int = 8):
        self.cards = List[MediaCard]()
        self.msg_base = msg_base
        self.canvas_base = canvas_base
        self.most = most
        self.closed = -1
        self.acted_card = -1
        self.acted = -1

    def __len__(self) -> Int:
        return len(self.cards)

    def _free_slot(self) -> Int:
        for s in range(self.most):
            var used = False
            for k in range(len(self.cards)):  # (indexed: a card isn't Copyable, so the list can't be iterated)
                if self.cards[k].slot == s:
                    used = True
            if not used:
                return s
        return -1

    def add(mut self, path: String, x: Int, y: Int, width: Int) raises -> Int:
        """A card for the file at (x, y), `width` points wide (its height follows the media's shape); its index."""
        var slot = self._free_slot()
        if slot < 0:
            raise Error("A page holds up to " + String(self.most) + " videos and pictures: close one first")
        self.cards.append(MediaCard(path, slot, self.msg_base + slot * CARD_MESSAGES, self.canvas_base + slot * CARD_CANVASES, x, y, width))
        return len(self.cards) - 1

    def remove(mut self, k: Int):
        if 0 <= k < len(self.cards):
            _ = self.cards.pop(k)

    def clear(mut self):
        self.cards = List[MediaCard]()

    def msg(self, k: Int) -> Int:
        """Card k's first message."""
        return self.msg_base + self.cards[k].slot * CARD_MESSAGES

    def canvas(self, k: Int) -> Int:
        """Card k's first canvas."""
        return self.canvas_base + self.cards[k].slot * CARD_CANVASES

    def owns(self, message: Int) -> Bool:
        return self.msg_base <= message < self.msg_base + self.most * CARD_MESSAGES

    def card_of(self, path: String) -> Int:
        """The card showing `path`, else -1."""
        for k in range(len(self.cards)):
            if self.cards[k].path == path:
                return k
        return -1

    def video_paths(self) -> List[String]:
        """The videos on the page, oldest first (a log looks for its video among them: trackcard.video_for_log)."""
        var out = List[String]()
        for k in range(len(self.cards)):
            if self.cards[k].kind == OBJ_VIDEO:
                out.append(self.cards[k].path)
        return out^

    def poll(mut self) -> Bool:
        """Takes what every card's decoder thread finished (a probe, a frame, a picture): call it on the app's
        jobs_message (the decoders wake it) or any event. True when a card changed."""
        var changed = False
        for k in range(len(self.cards)):
            if self.cards[k].poll():
                changed = True
        return changed

    def settle(mut self, seconds: Float64 = 10.0) -> Bool:
        """Waits until every card has opened and shows the frame it wants (tests, an agent's render: never update() or
        draw()). False when it timed out."""
        var waited = 0.0
        while waited < seconds:
            _ = self.poll()
            var done = True
            for k in range(len(self.cards)):
                if self.cards[k].player:
                    ref pl = self.cards[k].player.value()
                    if pl.problem() == "" and not (pl.ready() and pl.have == pl.state.frame and not pl.feed.decoding()):
                        done = False
                elif self.cards[k].picture and self.cards[k].picture.value().pending():
                    done = False
            if done:
                return True
            sleep(0.001)
            waited += 0.001
        return False

    def pending(self) -> Bool:
        """A card is still opening or a frame it wants hasn't landed."""
        for k in range(len(self.cards)):
            if self.cards[k].player and self.cards[k].player.value().pending():
                return True
            if self.cards[k].picture and self.cards[k].picture.value().pending():
                return True
        return False

    def _card_of_canvas(self, canvas: Int) -> Int:
        for k in range(len(self.cards)):
            var c0 = self.canvas(k)
            if c0 <= canvas < c0 + CARD_CANVASES:
                return k
        return -1

    def update(mut self, event: Event) -> Bool:
        """True when `event` was a card's: its player moved, or its close button removed it (closed = its index)."""
        self.closed = -1
        self.acted_card = -1
        self.acted = -1
        if not self.owns(event.message):
            return False
        for k in range(len(self.cards)):
            var m0 = self.msg(k)
            if m0 <= event.message < m0 + CARD_MESSAGES:
                if event.message - m0 == CARD_CLOSE:
                    self.remove(k)
                    self.closed = k
                elif event.message - m0 >= CARD_ACTION:
                    if event.message - m0 - CARD_ACTION < len(self.cards[k].actions):
                        self.acted_card = k
                        self.acted = event.message - m0 - CARD_ACTION
                elif self.cards[k].player:
                    _ = self.cards[k].player.value().update(event)
                    _ = self.cards[k].poll()  # (the probe may have landed: the card takes the video's shape)
                elif self.cards[k].picture and event.message - m0 == PLAYER_FRAME:  # (a still's display frames while it opens)
                    _ = self.cards[k].poll()
                return True
        return True  # (a card closed since: its late frames are dropped)

    def draws(self, canvas: Int) -> Bool:
        return self._card_of_canvas(canvas) >= 0

    def draw(mut self, canvas: Int, mut s: Surface, pal: Palette):
        """Card media on their own canvases; the space around the media is the card's colour, so it sits in the card."""
        var k = self._card_of_canvas(canvas)
        if k < 0:
            return
        if self.cards[k].player:
            self.cards[k].player.value().draw(canvas, s, pal.card, pal)
        elif self.cards[k].picture:
            _ = self.cards[k].picture.value().poll()
            self.cards[k].picture.value().draw(s, pal.card)  # (the card's colour until it lands: draw_fitted paints only the backdrop)

    def describe(self, canvas: Int) -> String:
        var k = self._card_of_canvas(canvas)
        if k < 0:
            return ""
        ref c = self.cards[k]
        if c.player:
            return c.title() + ": " + c.player.value().describe()
        return c.title() + ": a picture, " + c.facts()

    def view(self, k: Int) -> View:
        """Card k: its title bar (the file's name, what it is, close) over its player or picture, filling the card."""
        ref c = self.cards[k]
        var parts = List[View]()
        var roomy = c.w >= (640 if len(c.actions) <= 2 else 820) or len(c.actions) == 0  # (a narrow card with actions keeps its facts in the title's tooltip)
        parts.append(Text(c.title(), HEADLINE).tag("media-title").tooltip(c.facts()))
        parts.append(Spacer())
        if c.status != "":  # (work running for it: what and how far, in place of its actions)
            parts.append(Text(c.status + (" · " + String(c.progress) + "%" if c.progress >= 0 else String("")), CAPTION).tag("media-status"))
            if c.progress >= 0:
                parts.append(ProgressBar(c.progress).width(96).label(c.status + " " + c.title()))
        else:
            for i in range(min(len(c.actions), MAX_ACTIONS)):
                ref a = c.actions[i]
                parts.append(Button(a.label, self.msg(k) + CARD_ACTION + i, SUBTLE, icon=a.icon).tag(a.tag).tooltip(a.tip))
            if roomy:
                parts.append(Text(c.facts(), CAPTION))
        parts.append(Button("Remove", self.msg(k) + CARD_CLOSE, ICON_ONLY, icon="close").tooltip("Close " + c.title()))
        var head = HStack(parts^, spacing=8).fill().align(CENTER).height(HEAD_H)
        var body: View
        if c.problem() != "":
            body = VStack(Text("Couldn't open " + c.title(), HEADLINE), Text(c.problem(), CAPTION), spacing=4).grow().fill().tag("media-problem")
        elif c.player:
            body = c.player.value().view(0)
        else:
            var opening = c.picture.value().pending()
            body = Canvas(self.canvas(k), 2 if c.ready() else 1, on_frame=self.msg(k) + PLAYER_FRAME if opening else 0).fill().grow().tag("image")
            body = body^.label("Picture " + c.title() + ("" if c.ready() else ", opening"))
        return Card(head^, body^, spacing=4)
