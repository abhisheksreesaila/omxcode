# mojoui.agentui.Screens.adopt (goal 72 M4): the cards an in-process agent (mojoui.llmagent.LlmAgent) already ran render_ui for.
# Events in the order a run sends them; a screen per answered, valid call, once; a refused call shows nothing.
#   pixi run mojo build -I . tests/test_agentui_adopt.mojo -o build/test_agentui_adopt && build/test_agentui_adopt
from std.testing import assert_equal, assert_true
from mojoui.agui import Agent, EV_TOOL_RESULT
from mojoui.agentui import Screens
from mojoui.json import json_string

comptime CARD = '{"ui":{"component":"Card","title":"Planets","children":[{"component":"Text","text":"Jupiter is 143000 km across."}]}}'
comptime BAD = '{"ui":{"component":"Nonsense"}}'
comptime HEAT = '{"title":"How a heat pump works","blocks":[{"label":"Outdoor coil","kind":"device"},{"label":"Compressor"},{"label":"Indoor coil"}],"links":[{"from":"Outdoor coil","to":"Compressor"},{"from":"Compressor","to":"Indoor coil"}],"steps":[{"block":"Outdoor coil","text":"It takes heat from the air."},{"block":"Compressor","text":"It squeezes the gas."},{"block":"Indoor coil","text":"It warms the room."}]}'


def call(mut agent: Agent, id: String, args: String, result: String, tool: String = "render_ui"):
    _ = agent.on_json('{"type":"TEXT_MESSAGE_START","messageId":"m-' + id + '","role":"assistant"}')
    _ = agent.on_json('{"type":"TOOL_CALL_START","toolCallId":"' + id + '","toolCallName":"' + tool + '","parentMessageId":"m-' + id + '"}')
    _ = agent.on_json('{"type":"TOOL_CALL_ARGS","toolCallId":"' + id + '","delta":' + json_string(args) + "}")
    _ = agent.on_json('{"type":"TOOL_CALL_END","toolCallId":"' + id + '"}')
    if result != "":
        _ = agent.on_json('{"type":"TOOL_CALL_RESULT","messageId":"r-' + id + '","toolCallId":"' + id + '","content":' + json_string(result) + ',"role":"tool"}')


def main() raises:
    var agent = Agent("", 0, 0, "t")
    var screens = Screens(20_000, 2000)
    call(agent, "c1", CARD, "")  # (its result hasn't come yet: not shown)
    assert_equal(screens.adopt(agent), 0)
    _ = agent.on_json('{"type":"TOOL_CALL_RESULT","messageId":"r-c1","toolCallId":"c1","content":"{\\"shown\\":true}","role":"tool"}')
    assert_equal(screens.adopt(agent), 1)
    assert_equal(len(screens.uis), 1)
    assert_equal(screens.uis[0].summary(), "Card(Text)")
    assert_equal(screens.adopt(agent), 0)  # once each
    call(agent, "c2", BAD, '{"error":"refused: unknown component Nonsense"}')  # (the agent told its model; nothing to show)
    assert_equal(screens.adopt(agent), 0)
    assert_equal(len(screens.uis), 1)
    assert_true(screens.was_refused("c2"))
    call(agent, "c3", CARD, '{"shown":true}')
    assert_equal(screens.adopt(agent), 1)
    assert_equal(len(screens.uis), 2)
    assert_equal(screens.calls[1], "c3")
    # a framework card tool's call (explain; show_map is test_tripmap's) is shown by adopt() too, through tool_card (D-7735)
    call(agent, "c4", HEAT, '{"shown":true}', "explain")
    call(agent, "c5", HEAT, '{"shown":true}', "some_app_tool")  # (a tool adopt doesn't know: left alone)
    assert_equal(screens.adopt(agent), 1)
    assert_equal(screens.calls[2], "c4")
    assert_true(screens.uis[2].summary().find("Iso") >= 0)
    print("agentui adopt: ok")
