# mojoui.stagefeed: what goes where on a Stage (goal 77 M7e). Given every tile of the moment, most important first, with
# its kind (centre: belongs on the stage; passive: quiet, the left column's Today; live: ticking, the right column), the
# urgent one and what the person pinned, it says which tiles stand on the stage and in what order, and which go to Today
# and to Live. A day's occasion (school, a game, Thanksgiving, rain, a birthday, a flight) puts its charm on the tile it
# is about. The rules are the owner-approved Stage prototype's (docs/goals/77/stage-prototype.html: stOrder, stSides,
# putCharms):
#
#   1. the urgent tile first, whatever its kind (rain makes the weather the large tile; a near flight the extra large one);
#   2. then every centre tile, in importance order;
#   3. then tiles that may fill (`fills`: photos, a birthday, the calendar) while the stage holds fewer than `room` (5);
#   4. at most `most` (6; 3 when the urgent one is extra large); pinned tiles never stand on the stage;
#   5. the sides take the rest, in importance order: passive ones to Today, the others (live, and centre ones that didn't
#      fit) to Live; pinned ones to Pinned.
#
#   var feed = stage_feed(ranked, urgent, pins)                  # feed.stage, feed.today, feed.live, feed.pinned (ids)
#   tiles.set_tiles(stage_tiles(all, feed))                      # mojoui.livetiles, in that order
#   feed.place(ranked, tiles.layout().ids)                       # the sides again from what the grid really shows (a size
#                                                                # the person chose can push a tile off: it goes to its side)
#   wear_occasion(all, "rain", "weather")                        # the umbrella on the weather tile (occasion_charm())

from mojoui.livetiles import Tile
from mojoui.charms import charm_names

comptime FEED_CENTRE = "centre"
comptime FEED_PASSIVE = "passive"
comptime FEED_LIVE = "live"


@fieldwise_init
struct FeedTile(Copyable, Movable, ImplicitlyCopyable):
    """One tile as the feed sees it: its id, its kind (FEED_CENTRE, FEED_PASSIVE, FEED_LIVE) and whether it may fill the
    stage when there is room."""

    var id: String
    var kind: String
    var fills: Bool


struct StageFeed(Copyable, Movable):
    var stage: List[String]  # on the stage, in order (the first is the large tile)
    var today: List[String]  # the left column's quiet list (passive tiles not on the stage)
    var live: List[String]  # the right column (live tiles, and any other that isn't on the stage)
    var pinned: List[String]  # Pinned, in the order they were pinned

    def __init__(out self):
        self.stage = List[String]()
        self.today = List[String]()
        self.live = List[String]()
        self.pinned = List[String]()

    def place(mut self, ranked: List[FeedTile], shown: List[String]):
        """The stage and the sides again from the ids the grid really shows (LiveTiles.layout().ids): the rest go to Today
        or Live."""
        self.stage.clear()
        for id in shown:
            self.stage.append(id)
        self.today.clear()
        self.live.clear()
        for t in ranked:
            if _has(shown, t.id) or _has(self.pinned, t.id):
                continue
            if t.kind == FEED_PASSIVE:
                self.today.append(t.id)
            else:
                self.live.append(t.id)

    def side_of(self, id: String) -> String:
        """Where tile `id` is: "stage", "today", "live", "pinned" or "" (not in the feed)."""
        if _has(self.stage, id):
            return "stage"
        if _has(self.today, id):
            return "today"
        if _has(self.live, id):
            return "live"
        if _has(self.pinned, id):
            return "pinned"
        return ""


def _has(ids: List[String], id: String) -> Bool:
    for i in ids:
        if i == id:
            return True
    return False


def stage_feed(ranked: List[FeedTile], urgent: String, pins: List[String], room: Int = 5, most: Int = 6) -> StageFeed:
    """The stage's tiles and the sides for this moment (the rules above). `ranked`: every tile, most important first;
    `urgent`: the one that matters most now ("" none); `pins`: the pinned ids; `most`: 6, or 3 for an extra-large lead."""
    var f = StageFeed()
    for p in pins:
        f.pinned.append(p)
    var known = List[String]()
    for t in ranked:
        known.append(t.id)
    if urgent != "" and _has(known, urgent) and not _has(pins, urgent):
        f.stage.append(urgent)
    for t in ranked:
        if t.kind == FEED_CENTRE and not _has(f.stage, t.id) and not _has(pins, t.id):
            f.stage.append(t.id)
    for t in ranked:
        if len(f.stage) >= room:
            break
        if t.fills and not _has(f.stage, t.id) and not _has(pins, t.id):
            f.stage.append(t.id)
    while len(f.stage) > most:
        _ = f.stage.pop()
    var on = f.stage.copy()
    f.place(ranked, on)
    return f^


def stage_tiles(all: List[Tile], feed: StageFeed) -> List[Tile]:
    """The tiles for the stage, in the feed's order (for LiveTiles.set_tiles)."""
    var out = List[Tile]()
    for id in feed.stage:
        for t in all:
            if t.id == id:
                out.append(t.copy())
    return out^


def tile_by_id(all: List[Tile], id: String) -> Tile:
    """The tile called `id` (an empty one when there is none)."""
    for t in all:
        if t.id == id:
            return t.copy()
    return Tile(id, 0, "", "", "")


# ------------------------------------------------------------------------------------------------ occasions


def occasion_names() -> List[String]:
    """A day's occasions, each with its charm: school (a school bag), game (a pennant), thanksgiving (a turkey), rain (an
    umbrella), birthday (a party hat), flight (a luggage tag)."""
    return ["school", "game", "thanksgiving", "rain", "birthday", "flight"]


def occasion_charm(occasion: String) -> String:
    """The charm an occasion hangs on the tile it is about ("" for none)."""
    if occasion == "school":
        return "bag"
    if occasion == "game":
        return "pennant"
    if occasion == "thanksgiving":
        return "turkey"
    if occasion == "rain":
        return "umbrella"
    if occasion == "birthday":
        return "hat"
    if occasion == "flight":
        return "tag"
    return ""


def wear_occasion(mut tiles: List[Tile], occasion: String, about: String):
    """The occasion's charm on tile `about`; every other occasion charm comes off (a "pin" stays: it is the person's)."""
    var charm = occasion_charm(occasion)
    var occasional = charm_names()
    for i in range(len(tiles)):
        if tiles[i].charm != "" and tiles[i].charm != "pin" and _has(occasional, tiles[i].charm):
            tiles[i].charm = ""
        if charm != "" and tiles[i].id == about:
            tiles[i].charm = charm
