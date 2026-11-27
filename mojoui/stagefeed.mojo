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
#   StageRow(icon, head, value, tint_hue(tile.tint), key=id, arrive=feed.arrives(id))   # a side row in its tile's colour; one
#                                                                # that just left the stage for this side eases in
#   feed.since(old)                                              # after a re-feed: which side rows just came off the stage

from mojoui.livetiles import Tile
from mojoui.charms import charm_names
from mojoui.clock import now_ns

comptime ARRIVE_MS = 900  # a side row that came off the stage arrives within this of the re-feed (View.arrive takes ~400 ms)

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
    var fresh: List[String]  # side rows whose tiles were on the stage before the last re-feed (since): they ease in
    var fresh_ns: Int  # when (now_ns) they came off

    def __init__(out self):
        self.stage = List[String]()
        self.today = List[String]()
        self.live = List[String]()
        self.pinned = List[String]()
        self.fresh = List[String]()
        self.fresh_ns = 0

    def since(mut self, old: StageFeed):
        """After a re-feed (`old`: the feed shown before it): the Today and Live rows whose tiles stood on the stage then (roomy
        sends two tiles to the sides as the stage shrinks them away) are fresh for ARRIVE_MS: StageRow(…, arrive=arrives(id))
        lets each ease in instead of appearing at once. A row new for any other reason, or at the start, just shows."""
        self.fresh.clear()
        for id in self.today:
            if _has(old.stage, id):
                self.fresh.append(id)
        for id in self.live:
            if _has(old.stage, id):
                self.fresh.append(id)
        self.fresh_ns = now_ns()

    def arrives(self, id: String) -> Bool:
        """Side row `id` came off the stage a moment ago (since): it arrives on the host's spring (View.arrive, once)."""
        return len(self.fresh) > 0 and _has(self.fresh, id) and now_ns() - self.fresh_ns < ARRIVE_MS * 1_000_000

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


def tint_hue(tint: String) -> Int:
    """A tile's tint as the Stage's side colours (StageRow / StageCard hue: stage-kind-1 … 6, the family's data colours violet,
    blue, teal, orange, red, gold; 0 the quiet one), so a tile and its side row wear the same colour."""
    if tint == "purple" or tint == "indigo":
        return 1
    if tint == "blue":
        return 2
    if tint == "teal" or tint == "green":
        return 3
    if tint == "orange":
        return 4
    if tint == "red" or tint == "pink":
        return 5
    if tint == "amber":
        return 6
    return 0
