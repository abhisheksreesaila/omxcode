# omx's SAMPLE tiles (goal 77 M7f): placeholders for the sources omx doesn't have yet (a calendar, the weather, photos, the
# house). They are SAMPLES, not data: every one says "sample" on its face, Settings turns them off, and each goes the day a
# real source plugs in. The assistant's own tiles (to-do, the job, the news) are real: mojoui.assistant.Assistant.tiles().
# Their ids start "sample_" (never an id the agent would pick); when the agent puts up a tile of the plain name ("weather"),
# its sample leaves the stage and comes back once that tile is gone (mojoui.agentui.Screens.keep's samples).
# OMX_CLEAN=1 (pictures and recordings only, where the page showing them says the day is sample data): no "sample" on the faces.

from mojoui.livetiles import Tile, Face
from mojoui.shared import environment

def _mark() -> String:
    """What says a tile is a sample: " · sample", nothing with OMX_CLEAN=1."""
    return "" if environment("OMX_CLEAN") == "1" else " · sample"


def _sample(id: String, tint: String, icon: String, head: String, big: String, sub: String) -> Tile:
    var t = Tile(id, 0, head, big, sub + _mark(), icon=icon)
    t.tint = tint
    return t^


def sample_tiles() -> List[Tile]:
    """SAMPLE tiles, quiet ones (passive: they fill the stage while it has room, else they sit in Today)."""
    var out = List[Tile]()
    var cal = _sample("sample_cal", "red", "calendar", "Calendar", "Pickup 3:15", "Maya · the side gate")
    cal.faces.append(Face("Then", "Dinner 6:30 · Tennis Sat 10" + _mark()))
    out.append(cal^)
    out.append(_sample("sample_weather", "blue", "cloud-sun", "Weather", "9° · clear", "rain after 4"))
    out.append(_sample("sample_photos", "pink", "image", "Memories", "A year ago today", "38 photos"))
    out.append(_sample("sample_home", "teal", "home", "Home", "Door locked", "21° inside"))
    return out^


def sample_kinds() -> List[String]:
    return ["passive", "passive", "passive", "passive"]


def sample_weather() -> String:
    """The clock's weather line (SAMPLE: no weather source yet)."""
    return "9° · clear · rain after 4" + ("" if _mark() == "" else " (sample)")
