# Streaming generative UI (goal 48 M1): render_ui's arguments drawn while they arrive (mojoui.partialjson, genui's
# partial_ui, Screens.preview), tool calls' stages, the run's steps, and bound UI that follows the shared state.
from std.testing import assert_equal, assert_true
from mojoui.app import Event
from mojoui.json import Json, json_string
from mojoui.view import View, TEXT, BUTTON, FIELD
from mojoui.partialjson import complete
from mojoui.genui import GenUi, partial_ui, sample, catalog
from mojoui.jsonpatch import JDoc
from mojoui.agentchat import AgentChat, status_of, C_PIECE, C_ENDED

comptime B = 20_000

comptime DASHBOARD = '{"ui":{"component":"VStack","children":[{"component":"Text","text":"Q3 \\"sales\\" — résumé","style":"title"},{"component":"Grid","columns":3,"children":[{"component":"KpiView","label":"Revenue","value":"$1.24M","note":"+8%","tone":"good","spark":[1,2,3.5,4]},{"component":"KpiView","label":"Orders","value":"18,204"},{"component":"Meter","label":"Target","value":72}]},{"component":"ChartView","kind":"bar","title":"By region","labels":["North","South"],"values":[420,380]},{"component":"Table","columns":["Region","Sales"],"rows":[["North",420],["South",380.5]]},{"component":"Button","label":"Export","action":"export","style":"prominent"}]}}'


def has(v: View, word: String) -> Bool:
    for ref n in v.nodes:
        if (n.kind == TEXT or n.kind == BUTTON) and n.text.find(word) >= 0:
            return True
    return False


def skeletons(v: View) -> Int:
    var k = 0
    for ref n in v.nodes:
        if n.name == "skeleton":
            k += 1
    return k


def ev(mut chat: AgentChat, json: String):
    _ = chat.update(Event(B + C_PIECE, json, 0))


def main() raises:
    # partial: every cut of the arguments either waits or shows something the validator accepts; never a crash
    assert_equal(complete('{"ui":{"component":"Card","title":"Sal'), '{"ui":{"component":"Card","title":"Sal"}}')
    assert_equal(complete('{"a":[1,2'), '{"a":[1]}', "a number may still be growing: cut")
    assert_equal(complete('{"a":[1,2,'), '{"a":[1,2]}')
    assert_equal(complete('{"a":"x","b'), '{"a":"x"}', "a key without its value goes")
    assert_equal(complete('{"a":"x\\'), '{"a":"x"}', "a lone backslash goes")
    assert_equal(complete('{"a":"\\u00'), '{"a":""}', "half a \\u escape goes")
    assert_equal(complete('{"children":[{"x":1},', "children", "S"), '{"children":[{"x":1},S]}')
    assert_equal(complete("tr"), "")
    var shown = 0
    var b = DASHBOARD.as_bytes()
    var last_skeletons = 0
    var cuts = 0
    for cut in range(len(b) + 1):
        if cut < len(b) and b[cut] >= 128 and b[cut] < 192:
            continue  # (inside a character: a delta is a JSON string, always whole characters)
        cuts += 1
        var prefix = String(DASHBOARD[byte = : cut]) if cut < len(b) else String(DASHBOARD)
        var args = partial_ui(prefix)
        var ui = GenUi(args, 10_000, 100)
        assert_equal(ui.problem, "", "cut " + String(cut) + ": " + args)
        var v = ui.view(JDoc(), 0)
        if len(v.nodes) > 0:
            shown += 1
        if cut == len(b) // 2:
            last_skeletons = skeletons(v)
    assert_equal(shown, cuts)
    print("partial: ok " + String(cuts) + " cuts")
    # skeleton: halfway, what hasn't come yet is a Skeleton; once whole, none
    assert_true(last_skeletons >= 1, "halfway there's a Skeleton where more is coming")
    var whole = GenUi(partial_ui(DASHBOARD), 10_000, 100)
    assert_equal(skeletons(whole.view(JDoc(), 0)), 0)
    assert_true(has(whole.view(JDoc(), 0), "Export"))
    print("skeleton: ok")
    # status: a render_ui call streaming is previewed and "in progress"; a backend tool executing, then complete
    var chat = AgentChat("http://unused/", base=B, canvas_base=2000)
    chat.send("Build me a dashboard")
    ev(chat, '{"type":"RUN_STARTED","threadId":"t","runId":"r"}')
    ev(chat, '{"type":"STEP_STARTED","stepName":"search"}')
    ev(chat, '{"type":"TOOL_CALL_START","toolCallId":"s1","toolCallName":"search_sales","parentMessageId":"a1"}')
    ev(chat, '{"type":"TOOL_CALL_ARGS","toolCallId":"s1","delta":"{\\"quarter\\":\\"Q3\\"}"}')
    assert_equal(status_of(chat.agent.messages[1].calls[0], False), "in progress")
    var v = chat.view()
    assert_true(has(v, "search_sales") and has(v, "in progress"))
    ev(chat, '{"type":"TOOL_CALL_END","toolCallId":"s1"}')
    v = chat.view()
    assert_true(has(v, "executing"), "a finished call without its result is executing")
    ev(chat, '{"type":"TOOL_CALL_RESULT","messageId":"r1","toolCallId":"s1","content":"{\\"rows\\":4}","role":"tool"}')
    v = chat.view()
    assert_true(has(v, "complete") and has(v, "rows"), "with its result it's complete, and the result shows")
    print("status: ok")
    # steps: a live progress list
    assert_true(has(v, "search"), "the running step is listed")
    ev(chat, '{"type":"STEP_FINISHED","stepName":"search"}')
    ev(chat, '{"type":"STEP_STARTED","stepName":"design"}')
    assert_equal(len(chat.agent.steps), 2)
    assert_true(chat.agent.steps_done[0] and not chat.agent.steps_done[1])
    v = chat.view()
    assert_true(has(v, "design"))
    print("steps: ok")
    # the render_ui call previews as it streams: more of it each piece, then the final screen
    ev(chat, '{"type":"TOOL_CALL_START","toolCallId":"u1","toolCallName":"render_ui","parentMessageId":"a1"}')
    v = chat.view()
    assert_true(has(v, "Building UI") and skeletons(v) >= 1, "a screen starts as a Skeleton")
    var step = len(b) // 6
    var at = 0
    var grew = 0
    var before = len(chat.view().nodes)
    while at < len(b):
        var end = min(at + step, len(b))
        while end < len(b) and b[end] >= 128 and b[end] < 192:
            end += 1
        ev(chat, '{"type":"TOOL_CALL_ARGS","toolCallId":"u1","delta":' + json_string(String(DASHBOARD[byte = at : end])) + "}")
        at = end
        var now = len(chat.view().nodes)
        if now > before:
            grew += 1
        before = now
    assert_true(grew >= 3, "the screen grows as its arguments arrive (" + String(grew) + " times)")
    ev(chat, '{"type":"TOOL_CALL_END","toolCallId":"u1"}')
    v = chat.view()
    assert_true(not has(v, "Building UI") and has(v, "Export") and skeletons(v) == 0, "the final screen replaces the preview")
    assert_equal(len(chat.screens.uis), 1, "one screen, not a preview and a copy")
    # state: bound UI follows STATE_SNAPSHOT and STATE_DELTA in place
    var form = GenUi('{"ui":{"component":"Card","children":[{"component":"TextField","bind":"/trip/city"},{"component":"Sparkline","bind":"/trend"}]}}', 10_000, 100)
    var st = JDoc.parse('{"trip":{"city":"Lisbon"},"trend":[1,2]}')
    var field = String("")
    for ref n in form.view(st, 0).nodes:
        if n.kind == FIELD:
            field = n.text
    assert_equal(field, "Lisbon")
    ev(chat, '{"type":"STATE_SNAPSHOT","snapshot":{"trip":{"city":"Lisbon"}}}')
    ev(chat, '{"type":"STATE_DELTA","delta":[{"op":"replace","path":"/trip/city","value":"Porto"}]}')
    for ref n in form.view(chat.agent.state, chat.version).nodes:
        if n.kind == FIELD:
            field = n.text
    assert_equal(field, "Porto")
    assert_true(chat.version >= 2, "a state change moves the version on (canvases redraw)")
    print("state: ok")
    print("test_agui_stream: done")
