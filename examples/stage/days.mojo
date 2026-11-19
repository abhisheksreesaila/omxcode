# The Stage's sample days (goal 77 M7e): the tiles of a kitchen counter's day and the moments of the approved prototype
# (docs/goals/77/stage-prototype.html MOMENTS, TILES, KIND), as data. Placeholder content: no model, no real calendar.

from mojoui.livetiles import Tile, Face
from mojoui.stagefeed import FeedTile, FEED_CENTRE, FEED_PASSIVE, FEED_LIVE


struct Moment(Copyable, Movable):
    """A moment of the day: its tiles most important first, the urgent one and why, its occasion (and the tile it is
    about), and whether the urgent tile is extra large."""

    var id: String
    var label: String
    var urgent: String
    var why: String
    var occasion: String
    var about: String
    var big: Bool
    var rank: List[String]

    def __init__(out self, id: String, label: String, why: String, occasion: String, about: String, big: Bool, var rank: List[String]):
        self.id = id
        self.label = label
        self.urgent = rank[0]
        self.why = why
        self.occasion = occasion
        self.about = about
        self.big = big
        self.rank = rank^


def moments() -> List[Moment]:
    var out = List[Moment]()
    out.append(Moment("am", "7:45 school run", "you leave in 20 minutes", "", "", False,
                      ["traffic", "todo", "cal", "weather", "timer", "photos", "bday", "flight", "home", "cam", "lisbon"]))
    out.append(Moment("school", "First day of school", "it's the first day of school", "school", "school", False,
                      ["school", "traffic", "todo", "weather", "cal", "timer", "photos", "bday", "home", "cam", "lisbon"]))
    out.append(Moment("rain", "2:30 rain at 4", "rain starts before pickup", "rain", "weather", False,
                      ["weather", "cal", "traffic", "todo", "timer", "photos", "bday", "flight", "home", "cam", "lisbon"]))
    out.append(Moment("game", "Game tonight", "you asked me to remind you", "game", "game", False,
                      ["game", "todo", "cal", "weather", "timer", "traffic", "photos", "bday", "home", "cam", "lisbon"]))
    out.append(Moment("bday", "Thu · birthday Sat", "it's in two days", "birthday", "bday", False,
                      ["bday", "todo", "photos", "cal", "weather", "timer", "traffic", "flight", "home", "cam", "lisbon"]))
    out.append(Moment("thanks", "Thanksgiving", "it's Thanksgiving", "thanksgiving", "feast", False,
                      ["feast", "todo", "weather", "cal", "timer", "photos", "traffic", "bday", "home", "cam", "lisbon"]))
    out.append(Moment("airport", "Fri 7:20 · near the airport", "you're 6 minutes from the airport", "flight", "flight", True,
                      ["flight", "weather", "todo", "lisbon", "cal", "timer", "traffic", "photos", "bday", "home", "cam"]))
    return out^


def kind_of(id: String) -> String:
    """Where a tile belongs when it isn't urgent (the prototype's KIND)."""
    if id == "weather" or id == "cal" or id == "bday" or id == "home" or id == "photos" or id == "lisbon":
        return FEED_PASSIVE
    if id == "timer" or id == "traffic" or id == "flight" or id == "game":
        return FEED_LIVE
    return FEED_CENTRE


def ranked(m: Moment) -> List[FeedTile]:
    var out = List[FeedTile]()
    for id in m.rank:
        out.append(FeedTile(id, kind_of(id), id == "photos" or id == "bday" or id == "cal"))
    return out^


def clock_text(seconds: Int) -> String:
    var s = max(seconds, 0)
    var sec = s % 60
    return String(s // 60) + ":" + ("0" if sec < 10 else "") + String(sec)


def _tile(id: String, tint: String, icon: String, head: String, big: String, sub: String) -> Tile:
    var t = Tile(id, 0, head, big, sub, icon=icon)
    t.tint = tint
    return t^


def day_tiles(m: Moment, timer_s: Int) -> List[Tile]:
    """Every tile of moment `m`, in its order, its faces for that moment (the urgent one with its why, and big when the
    moment says so)."""
    var out = List[Tile]()
    for id in m.rank:
        var t: Tile
        if id == "traffic":
            if m.id == "am":
                t = _tile(id, "green", "car", "Traffic", "Leave by 8:05", "Bridge is slow · +18 min to school")
                t.faces.append(Face("26 min to school", "via the river road · 2 incidents"))
            elif m.id == "airport":
                t = _tile(id, "green", "car", "Traffic", "Airport 38 min", "at 6:10 tomorrow")
            elif m.id == "rain":
                t = _tile(id, "green", "car", "Traffic", "Pickup drive 22 min", "slower in rain")
            else:
                t = _tile(id, "green", "car", "Traffic", "Roads are clear", "12 min to school")
            t.actions = ["Directions to the car", "Tell school"]
        elif id == "weather":
            if m.id == "rain":
                t = _tile(id, "blue", "cloud-rain", "Weather", "Rain from 4", "Pickup at 3:15 will be wet · take the umbrella")
                t.faces.append(Face("Heavy at 5", "then dry by 7"))
            elif m.id == "airport":
                t = _tile(id, "blue", "cloud-sun", "Weather", "Lisbon 22° tomorrow", "sunny · pack light")
                t.faces.append(Face("Here 9°", "clear tonight"))
            elif m.id == "bday":
                t = _tile(id, "blue", "cloud-sun", "Weather", "Saturday 17°", "sunny for the party")
            else:
                t = _tile(id, "blue", "cloud-sun", "Weather", "9° · clear", "rain after 4")
            t.actions = ["Remind me at 3", "Hourly"]
        elif id == "todo":
            t = _tile(id, "orange", "list-todo", "To do", "3 to do", "Call mum · Pick up Maya · Water bill")
            t.faces.append(Face("Next: call mum", "it's her birthday Saturday"))
        elif id == "cal":
            if m.id == "airport":
                t = _tile(id, "red", "calendar", "Calendar", "Fri 9:40 · TP1351", "Lisbon · gate at the airport")
            else:
                t = _tile(id, "red", "calendar", "Calendar", "Pickup 3:15", "Maya · the side gate")
                t.faces.append(Face("Then", "Dinner 6:30 · Tennis Sat 10"))
        elif id == "timer":
            t = _tile(id, "amber", "timer", "Pasta", clock_text(timer_s), "left on the timer")
        elif id == "photos":
            t = _tile(id, "pink", "image", "Memories", "Lisbon, a year ago", "38 photos")
            t.faces.append(Face("Alfama at sunset", "you, Maya and the tram"))
        elif id == "bday":
            if m.id == "bday":
                t = _tile(id, "purple", "gift", "Birthday", "Mum turns 64 on Saturday", "She loved the Lisbon photos · a photo book arrives Friday if you order today")
                t.faces.append(Face("Last year", "flowers + lunch at Alfama Café"))
            else:
                t = _tile(id, "purple", "gift", "Birthday", "Mum · Saturday", "turns 64")
            t.actions = ["Order the photo book", "Remind me Friday"]
        elif id == "flight":
            if m.id == "airport":
                t = _tile(id, "indigo", "plane", "Flight", "Gate B12 · boarding 9:05", "TP1351 to Lisbon · on time · security is 12 min, you're 6 min away")
                t.faces.append(Face("Seat 14A", "boarding pass ready · 1 bag to drop at desk 34"))
            else:
                t = _tile(id, "indigo", "plane", "Flight", "Lisbon · Friday", "TP1351 · 9:40")
            t.actions = ["Boarding pass", "Directions to gate"]
        elif id == "game":
            if m.id == "game":
                t = _tile(id, "green", "trophy", "Game night", "Kick-off 7:30", "Home v Away · on the TV")
                t.faces.append(Face("The score", "goes up here the moment it starts"))
            else:
                t = _tile(id, "green", "trophy", "Game night", "Sat 3:00", "Home v Away")
            t.actions = ["Remind me at 7:15", "Check the scores"]
        elif id == "school":
            t = _tile(id, "blue", "backpack", "School", "First day!", "bag packed · lunch in the fridge · leave by 8:05")
            t.faces.append(Face("Homework", "reading log · 10 minutes tonight"))
            t.actions = ["Checklist", "Tell Maya"]
        elif id == "feast":
            t = _tile(id, "amber", "utensils", "Thanksgiving", "Dinner at 4 · 12 people", "turkey in at 11 · pie from Sam · two extra chairs")
            t.faces.append(Face("Turkey", "5.5 kg · 3 h 40 min at 180°"))
            t.actions = ["Start the turkey timer", "Shopping list"]
        elif id == "home":
            t = _tile(id, "teal", "home", "Home", "Door locked", "21° inside")
            t.faces.append(Face("Lights off", "upstairs"))
        elif id == "cam":
            t = _tile(id, "slate", "camera", "Counter", "Banana nearly ripe", "seen 7:12")
        else:  # lisbon
            t = _tile(id, "teal", "map-pin", "Lisbon", "A day in Lisbon", "3 stops" if m.id != "airport" else "for Saturday")
        if id == m.urgent:
            t.why = m.why
            t.big = m.big
        out.append(t^)
    return out^
