# A grid of clips (goal 71): each tile a poster you tap, a title, a line of detail, a badge (a score, a length) and a pick
# toggle. One tile can be "shown" (the clip the rest are compared with: outlined, and its poster may be a playing loop's
# current frame); any can be "picked" (a set to act on: More like these, Export). Built from Image(on_tap), Text, Badge,
# Button and Grid, so every host that draws those draws it, and agents read its words.
#   var tiles = List[ClipTile]()
#   tiles.append(ClipTile("lerobot/libero:7", "put the bowl in the drawer", "Panda · 12.4 s", "0.993", pic.pixels, pic.w, pic.h))
#   ClipGrid(tiles, CLIP_MSG, columns=4)        # CLIP_MSG + 2 i: tile i's poster tapped; CLIP_MSG + 2 i + 1: its pick toggled
#   clip_message(msg - CLIP_MSG) -> (i, picked?)
from mojoui.view import (View, Text, Button, Image, Grid, VStack, HStack, Spacer, Card, CAPTION, BODY, ICON_ONLY, ICON_ON,
                         CARD, CARD_GOOD, START, CENTER)
from mojoui.chip import Badge, BADGE_PLAIN, BADGE_OK

comptime CLIP_MSGS = 2           # messages a tile uses (poster, pick)


struct ClipTile(Copyable, Movable):
    var key: String
    var title: String
    var detail: String
    var badge: String            # "" for none
    var tip: String              # the poster's tooltip ("" : "Episodes like this")
    var pixels: List[UInt32]     # the poster (RGBA, Image's format)
    var w: Int
    var h: Int
    var shown: Bool
    var picked: Bool

    def __init__(out self, key: String, title: String, detail: String, badge: String, pixels: List[UInt32], w: Int, h: Int,
                 shown: Bool = False, picked: Bool = False, tip: String = ""):
        self.key = key
        self.tip = tip
        self.title = title
        self.detail = detail
        self.badge = badge
        self.pixels = pixels.copy()
        self.w = w
        self.h = h
        self.shown = shown
        self.picked = picked


def clip_message(offset: Int) -> Tuple[Int, Bool]:
    """A ClipGrid message's offset from its base: (the tile, True when its pick toggle was pressed, False for its poster)."""
    return (offset // CLIP_MSGS, offset % CLIP_MSGS == 1)


def clip_columns(width: Int, tile: Int = 220, spacing: Int = 12) -> Int:
    """How many tiles of about `tile` points fit across `width` (at least 1, at most 6)."""
    return max(1, min(6, (width + spacing) // (tile + spacing)))


def ClipTileView(t: ClipTile, i: Int, msg_base: Int, tag: String, pick: Bool = True) -> View:
    var poster = Image(t.pixels, t.w, t.h, on_tap=msg_base + i * CLIP_MSGS).tag(tag + "-" + String(i)).tooltip(t.tip if t.tip.byte_length() > 0 else "Episodes like this")
    var row: List[View] = [Text(t.detail, CAPTION).grow()]
    if t.shown:
        row.append(Badge("shown", BADGE_OK, dot=True).tag(tag + "-shown"))
    elif t.badge.byte_length() > 0:
        row.append(Badge(t.badge, BADGE_PLAIN))
    if pick:
        row.append(Button("Unpick" if t.picked else "Pick", msg_base + i * CLIP_MSGS + 1, ICON_ON if t.picked else ICON_ONLY,
                          icon="check" if t.picked else "plus").tag(tag + "-pick-" + String(i)).tooltip("Pick it for More like these and Export"))
    var body: List[View] = [poster^, Text(t.title, BODY).tag(tag + "-title-" + String(i)), HStack(row^, spacing=8).align(CENTER).fill()]
    return Card(body^, spacing=8, tone=CARD_GOOD if (t.shown or t.picked) else CARD).fill().tag(tag + "-tile-" + String(i))


def ClipGrid(tiles: List[ClipTile], msg_base: Int, columns: Int, pick: Bool = True, tag: String = "clip") -> View:
    """The tiles in rows of `columns` (clip_columns(width) picks it from the width: one column on a phone)."""
    var items = List[View]()
    for i in range(len(tiles)):
        items.append(ClipTileView(tiles[i], i, msg_base, tag, pick))
    return Grid(items^, columns=max(1, columns), spacing=12).fill().tag(tag + "-grid")
