# mojoui.maptool: the `show_map` agent tool (goal 77 M3), the map card's side of the agent: a title, an area and the stops in the
# order visited (a name as labelled and said, a one-line note, the model's guess of where it is). It is answered at once inside the
# agent (mojoui.llmagent.ToolFn); mojoui.agentui.Screens makes the card from the call's arguments (mojoui.tripmap.trip_ui: a Card
# holding a TripMap), and the result tells the model to walk through the stops in order, naming each as labelled, while the map flies
# to each one. mojoui.visual.Visual.register offers it (in place of the stub it had before the map existed).

from mojoui.llmagent import ToolFn
from mojoui.tripmap import SHOW_MAP, MAP_ABOUT, MAP_PARAMS, show_map_answer


def show_map_tool() -> ToolFn:
    return ToolFn(SHOW_MAP, MAP_ABOUT, MAP_PARAMS, show_map_answer)
