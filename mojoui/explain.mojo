# mojoui.explain: the `explain` agent tool (goal 77 M4): "how does X work?" becomes a small isometric diagram (mojoui.iso) on a
# card, and the model is told to walk through its steps in order, naming each block as it is labelled, so the pointer follows.
#
#   agent.add_function(explain_tool())                      (mojoui.visual.Visual.register does it for an assistant)
#   screens.adopt_with(client, EXPLAIN, explain_ui)         the app shows the call as a card, as it shows render_ui's
#
# The tool is answered inside the agent (a plain function): the arguments become render_ui's card (explain_ui) and go through the
# catalog's validator (every link and step must name one of the blocks); a refusal says why, so the model fixes it and calls again.

from mojoui.genui import GenUi
from mojoui.iso import IsoDiagram, explain_ui, walk_text
from mojoui.json import Json, json_string
from mojoui.llmagent import ToolFn

comptime EXPLAIN = "explain"

comptime EXPLAIN_ABOUT = (
    "Show how something works as a small isometric diagram card: 3 to 6 blocks (the things involved, each labelled in one to three "
    "plain words, with a kind), arrows from block to block with a short label of what moves along them, and 3 to 6 numbered steps "
    "in order, each naming the block it happens at by that block's label. Call it first, then walk through the steps in order in "
    "one or two sentences, saying each block's label as it is written on the card."
)
comptime EXPLAIN_PARAMS = (
    '{"type":"object","properties":{'
    '"title":{"type":"string","description":"what is explained, a few words (How a heat pump works)"},'
    '"blocks":{"type":"array","minItems":3,"maxItems":6,"items":{"type":"object","properties":{'
    '"label":{"type":"string","description":"one to three plain words, unique"},'
    '"kind":{"type":"string","enum":["process","device","store","person","place","energy","thing"]}},"required":["label"]}},'
    '"links":{"type":"array","maxItems":10,"items":{"type":"object","properties":{'
    '"from":{"type":"string","description":"a block label"},"to":{"type":"string","description":"a block label"},'
    '"label":{"type":"string","description":"what moves along it, one to three words"}},"required":["from","to"]}},'
    '"steps":{"type":"array","minItems":3,"maxItems":8,"items":{"type":"object","properties":{'
    '"block":{"type":"string","description":"the label of the block where it happens"},'
    '"text":{"type":"string","description":"one short sentence"}},"required":["block","text"]}}},'
    '"required":["title","blocks","links","steps"]}'
)


def explain_tool() -> ToolFn:
    return ToolFn(EXPLAIN, EXPLAIN_ABOUT, EXPLAIN_PARAMS, explain_call)


def explain_call(args: String) -> String:
    """The tool's answer: the card is shown ({"shown": true, …} with the order to walk the blocks in), or why it can't be."""
    var ui = explain_ui(args)
    if ui == "":
        return '{"error":"refused: the arguments are not a JSON object"}'
    var screen = GenUi(ui, 0, 0)
    if screen.problem != "":
        return '{"error":' + json_string("refused: " + screen.problem) + "}"
    var d: IsoDiagram
    try:
        var j = Json.parse(ui)
        d = IsoDiagram.parse(j, j.at(j.get(j.get(0, "ui"), "children"), 0))
    except:
        return '{"error":"refused: the arguments are not a JSON object"}'
    if len(d.steps) < 3:
        return '{"error":"refused: give at least 3 steps, each naming a block by its label"}'
    var say = ("The diagram is on the screen. Now walk through it in one or two short sentences, in this order, saying each block's "
               "label exactly as written: " + walk_text(d) + ". Do not read the steps out word for word.")
    return '{"shown":true,"say":' + json_string(say) + "}"
