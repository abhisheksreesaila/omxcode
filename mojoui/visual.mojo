# mojoui.visual: visual first (goal 77 M5). An assistant on a kitchen counter is looked at from across the room and listened to; nobody
# reads it. So the agent shows first and speaks after: it prefers a card for anything it can show, builds it before it says a word,
# and then says one or two sentences that point at the card by the labels printed on it.
#
#   VISUAL_SYSTEM                      the system prompt (the framework's, not the app's): which card for which question, show first,
#                                      one or two sentences that refer to the card, no card for plain talk
#   Visual.register(agent)             the card tools that are not built yet, as stubs the model can already route to
#   card_kind(tool, shape) -> String   the kind of card a turn showed ("word", "map", "iso", "table", "todo", "news", "other", "")
#
# The tools it names: render_ui (a WordCard, a Table, any catalogued card), show_map (a trip, a route, places: goal 77 M3) and explain
# (how something works, a small isometric diagram: M4), the to-do tools and news (mojoui.assistant). show_map and explain are answered
# here with "not built yet, use render_ui" until the developer who builds them registers a function of the same name first: Visual.register
# leaves a name that is already registered alone, so the real card replaces the stub without touching this file.
#
# A card tool says its parts by name in its description (WordCard: word, sounds, meaning, example, origin), and the card prints a small
# label over each part, so "the meaning says…" refers to something on the screen: mojoui.pointer matches those words to parts and moves
# the ring.

from mojoui.llmagent import LlmAgent, ToolFn

comptime SHOW_MAP = "show_map"
comptime EXPLAIN = "explain"

comptime VISUAL_SYSTEM = (
    "You are a voice assistant that runs privately on the user's own computer, standing on a kitchen counter. People glance at the screen "
    "from across the room and listen to you; nobody reads. So show first, then speak. Whenever the answer can be shown as a card, call "
    "the card's tool FIRST, before you say a word, then speak one or two short sentences that refer to the card, naming its parts by the "
    "labels printed on it (\"the meaning says...\", \"the example is...\"). Never read a card out. Which card: what a word means or how it "
    "is said, use render_ui with a WordCard, then say the word, what its meaning says and what its example shows, in two sentences at "
    "most (\"Ephemeral. The meaning says it lasts a very short time, and the example is a sunset.\"); a trip, a route, a walk or places to go, call show_map; how something works or is made, call "
    "explain; facts or numbers to compare, a schedule or a list of things with details, use render_ui with a Table; things to remember or "
    "do, the to-do tools; the news, the news tool. Plain talk needs no card: a greeting, a yes or no, a quick fact, an opinion, a joke, "
    "a sum: answer in one or two short sentences. If a card tool says it is not available, build the closest card with render_ui. Your "
    "words are spoken aloud: natural sentences, no markdown, no bullet lists, no emoji, numbers written the way they are said. If a tool "
    "can answer, use it instead of guessing, and never claim to have done something a tool did not report. To use one of the app's "
    "buttons, call the tool of that name. If you were interrupted, stop and listen."
)

comptime MAP_ABOUT = (
    "Show a trip, a route, a walk or a set of places as a map card: the stops numbered in the order visited, joined by a line. Call it "
    "first, then say one or two sentences naming the stops. Not built yet: when it says so, show the places with render_ui instead."
)
comptime EXPLAIN_ABOUT = (
    "Show how something works as a small isometric diagram: three to six blocks, arrows between them, numbered steps. Call it first, then "
    "say one or two sentences that name the blocks in order. Not built yet: when it says so, show the steps with render_ui instead."
)
comptime MAP_PARAMS = '{"type":"object","properties":{"title":{"type":"string","description":"a few words"},"stops":{"type":"array","items":{"type":"string"},"description":"the places, in the order visited, each with its city"}},"required":["stops"]}'
comptime EXPLAIN_PARAMS = '{"type":"object","properties":{"topic":{"type":"string","description":"what is being explained, a few words"},"steps":{"type":"array","items":{"type":"string"},"description":"what happens, in order, one short sentence each"}},"required":["topic"]}'


def _not_built(args: String) -> String:
    return '{"error":"not available yet: show it with render_ui instead (a Table or a Card of Text)"}'


def card_kind(tool: String, shape: String) -> String:
    """What a turn showed, from the first card tool it called and the shape of the card it built: "word", "map", "iso", "table",
    "todo", "news", "other" (some other card), or "" (no card at all)."""
    if tool == SHOW_MAP:
        return "map"
    if tool == EXPLAIN:
        return "iso"
    if tool.startswith("todo_"):
        return "todo"
    if tool == "news":
        return "news"
    if shape.find("WordCard") >= 0:
        return "word"
    if shape.find("MapView") >= 0:
        return "map"
    if shape.find("Table") >= 0 or shape.find("DataGrid") >= 0:
        return "table"
    if shape != "":
        return "other"
    return ""


struct Visual:
    @staticmethod
    def register(mut agent: LlmAgent):
        """Offers the model the card tools that aren't built yet (before agent.prime(): the tools are part of the prompt the cache
        holds). A name already registered is left alone: the real tool wins."""
        var have = List[String]()
        for ref f in agent.functions:
            have.append(f.name)
        var map_there = False
        var explain_there = False
        for n in have:
            map_there = map_there or n == SHOW_MAP
            explain_there = explain_there or n == EXPLAIN
        if not map_there:
            agent.add_function(ToolFn(SHOW_MAP, MAP_ABOUT, MAP_PARAMS, _not_built))
        if not explain_there:
            agent.add_function(ToolFn(EXPLAIN, EXPLAIN_ABOUT, EXPLAIN_PARAMS, _not_built))
