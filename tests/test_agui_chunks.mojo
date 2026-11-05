# AG-UI's chunk events and the model's reasoning (mojoui.agui): TEXT_MESSAGE_CHUNK, TOOL_CALL_CHUNK and
# REASONING_MESSAGE_CHUNK name their message or call on the first chunk only; the next event of another kind ends them,
# as @ag-ui/client 1.0's transformChunks does (a tool call sent as chunks is then whole: pending() offers it).
# REASONING_* events keep the thinking as a "reasoning" message, sent back with the next run.
from std.testing import assert_equal, assert_true
from mojoui.agui import Agent, Tool, EV_TEXT, EV_TOOL_ARGS, EV_BAD, EV_REASONING, EV_RUN_FINISHED, EV_TEXT_START
from mojoui.app import Event
from mojoui.json import Json
from mojoui.view import View, TEXT, BUTTON, PARAGRAPH
from mojoui.agentchat import AgentChat, C_PIECE, C_ENDED, C_THOUGHT

comptime B = 20_000


def has(v: View, word: String) -> Bool:
    for ref n in v.nodes:
        if (n.kind == TEXT or n.kind == BUTTON or n.kind == PARAGRAPH) and n.text.find(word) >= 0:
            return True
    return False


def feed(mut chat: AgentChat, json: String):
    _ = chat.update(Event(B + C_PIECE, json, 0))


def ev(mut a: Agent, json: String) -> Int:
    return a.on_json(json)


def main() raises:
    # text: later chunks without an id go on the open one; a new id starts another message
    var a = Agent("http://x/", 1, 2)
    _ = ev(a, '{"type":"RUN_STARTED","threadId":"t","runId":"r"}')
    assert_equal(ev(a, '{"type":"TEXT_MESSAGE_CHUNK","messageId":"m1","delta":"Hel"}'), EV_TEXT)
    assert_equal(ev(a, '{"type":"TEXT_MESSAGE_CHUNK","delta":"lo"}'), EV_TEXT, "a chunk without its id continues the open one")
    assert_equal(ev(a, '{"type":"TEXT_MESSAGE_CHUNK","messageId":"m2","delta":"Two"}'), EV_TEXT)
    assert_equal(len(a.messages), 2)
    assert_equal(a.messages[0].content, "Hello")
    assert_equal(a.messages[1].content, "Two")
    _ = ev(a, '{"type":"STEP_STARTED","stepName":"s"}')  # (another kind of event: the chunks end)
    assert_equal(ev(a, '{"type":"TEXT_MESSAGE_CHUNK","delta":"lost"}'), EV_BAD, "after another event, a chunk must name its message again")
    assert_equal(a.messages[1].content, "Two")
    print("text chunks: ok")

    # tool calls: the first chunk names the call and the tool; the call is whole once another event comes
    var b = Agent("http://x/", 1, 2)
    b.offer(Tool("render_ui", "Show UI", "{}"))
    _ = ev(b, '{"type":"RUN_STARTED","threadId":"t","runId":"r"}')
    assert_equal(ev(b, '{"type":"TOOL_CALL_CHUNK","delta":"{}"}'), EV_BAD, "the first chunk must name its call")
    assert_equal(ev(b, '{"type":"TOOL_CALL_CHUNK","toolCallId":"c1","delta":"{}"}'), EV_BAD, "the first chunk must name its tool")
    assert_equal(ev(b, '{"type":"TOOL_CALL_CHUNK","toolCallId":"c1","toolCallName":"render_ui","parentMessageId":"a1","delta":"{\\"ui\\":"}'), EV_TOOL_ARGS)
    assert_equal(ev(b, '{"type":"TOOL_CALL_CHUNK","delta":"{\\"component\\":\\"Text\\","}'), EV_TOOL_ARGS)
    assert_equal(ev(b, '{"type":"TOOL_CALL_CHUNK","toolCallId":"c1","delta":"\\"text\\":\\"Hi\\"}}"}'), EV_TOOL_ARGS, "the same id continues it")
    assert_equal(len(b.pending()), 0, "not whole while its chunks may still come")
    assert_equal(ev(b, '{"type":"RUN_FINISHED","threadId":"t","runId":"r"}'), EV_RUN_FINISHED)
    assert_true(b.closed_call, "the event that ended the chunks says it closed a call")
    var p = b.pending()
    assert_equal(len(p), 1)
    assert_equal(p[0].arguments, '{"ui":{"component":"Text","text":"Hi"}}')
    assert_equal(b.messages[0].id, "a1")
    # two calls in a row: the second one's first chunk ends the first
    var c = Agent("http://x/", 1, 2)
    _ = ev(c, '{"type":"TOOL_CALL_CHUNK","toolCallId":"c1","toolCallName":"a","delta":"{}"}')
    _ = ev(c, '{"type":"TOOL_CALL_CHUNK","toolCallId":"c2","toolCallName":"b","delta":"{"}')
    assert_true(c.closed_call)
    assert_true(c.messages[0].calls[0].done and not c.messages[1].calls[0].done)
    assert_equal(ev(c, '{"type":"TOOL_CALL_CHUNK","toolCallId":"c1","toolCallName":"a","delta":"{}"}'), EV_BAD, "an id already used")
    # the stream ends with chunks open (no RUN_FINISHED): the call is whole too
    var d = Agent("http://x/", 1, 2)
    _ = ev(d, '{"type":"TOOL_CALL_CHUNK","toolCallId":"c1","toolCallName":"a","delta":"{}"}')
    _ = d.handle(Event(2, "", 200))
    assert_true(d.messages[0].calls[0].done and d.closed_call)
    # interleaved: a tool chunk ends the open text chunks; a text chunk without its id then has nothing to go on
    var e = Agent("http://x/", 1, 2)
    _ = ev(e, '{"type":"TEXT_MESSAGE_CHUNK","messageId":"m1","delta":"a"}')
    _ = ev(e, '{"type":"TOOL_CALL_CHUNK","toolCallId":"c1","toolCallName":"t","parentMessageId":"m1","delta":"{}"}')
    assert_equal(ev(e, '{"type":"TEXT_MESSAGE_CHUNK","delta":"b"}'), EV_BAD, "the open chunks are the tool call's, not the text's")
    assert_true(e.messages[0].calls[0].done and e.closed_call, "and the tool call ended")
    assert_equal(ev(e, '{"type":"TEXT_MESSAGE_CHUNK","messageId":"m1","delta":"b"}'), EV_TEXT)
    assert_equal(e.messages[0].content, "ab")
    print("tool chunks: ok")

    # reasoning: its own message, between the question and the answer; written until REASONING_MESSAGE_END
    var r = Agent("http://x/", 1, 2)
    r.say("Plan a day")
    _ = ev(r, '{"type":"RUN_STARTED","threadId":"t","runId":"r"}')
    assert_equal(ev(r, '{"type":"REASONING_START","messageId":"th"}'), EV_REASONING)
    assert_equal(ev(r, '{"type":"REASONING_MESSAGE_START","messageId":"th1","role":"reasoning"}'), EV_REASONING)
    assert_equal(ev(r, '{"type":"REASONING_MESSAGE_CONTENT","messageId":"th1","delta":"Lisbon: "}'), EV_REASONING)
    assert_equal(ev(r, '{"type":"REASONING_MESSAGE_CONTENT","messageId":"th1","delta":"trams first."}'), EV_REASONING)
    assert_equal(r.reasoning_open, "th1")
    assert_equal(ev(r, '{"type":"REASONING_MESSAGE_END","messageId":"th1"}'), EV_REASONING)
    assert_equal(r.reasoning_open, "")
    _ = ev(r, '{"type":"REASONING_END","messageId":"th"}')
    assert_equal(ev(r, '{"type":"TEXT_MESSAGE_START","messageId":"th1","role":"assistant"}'), EV_BAD, "a reasoning id isn't the answer's")
    _ = ev(r, '{"type":"TEXT_MESSAGE_START","messageId":"a1","role":"assistant"}')
    _ = ev(r, '{"type":"TEXT_MESSAGE_CONTENT","messageId":"a1","delta":"Start at Belém."}')
    assert_equal(len(r.messages), 3)
    assert_equal(r.messages[1].role, "reasoning")
    assert_equal(r.messages[1].content, "Lisbon: trams first.")
    assert_equal(r.last_text(), "Start at Belém.", "the answer is the assistant's words, not the thinking")
    var sent = Json.parse(r.input_json())
    var m1 = sent.at(sent.get(0, "messages"), 1)
    assert_equal(sent.text(sent.get(m1, "role")), "reasoning", "the thinking goes back with the next run")
    var hidden = Agent("http://x/", 1, 2)
    hidden.send_reasoning = False
    hidden.say("Plan a day")
    _ = ev(hidden, '{"type":"REASONING_MESSAGE_CONTENT","messageId":"th1","delta":"x"}')
    var sent2 = Json.parse(hidden.input_json())
    assert_equal(sent2.size(sent2.get(0, "messages")), 1, "send_reasoning = False: the thinking stays here")
    # thinking without its END: anything else ends it
    var n = Agent("http://x/", 1, 2)
    _ = ev(n, '{"type":"REASONING_MESSAGE_START","messageId":"th1","role":"reasoning"}')
    _ = ev(n, '{"type":"TEXT_MESSAGE_START","messageId":"a1","role":"assistant"}')
    assert_equal(n.reasoning_open, "", "the answer began: the thinking is over")
    # reasoning chunks
    var q = Agent("http://x/", 1, 2)
    assert_equal(ev(q, '{"type":"REASONING_MESSAGE_CHUNK","messageId":"k1","delta":"a"}'), EV_REASONING)
    assert_equal(ev(q, '{"type":"REASONING_MESSAGE_CHUNK","delta":"b"}'), EV_REASONING)
    assert_equal(q.reasoning_open, "k1")
    assert_equal(ev(q, '{"type":"TEXT_MESSAGE_START","messageId":"a1","role":"assistant"}'), EV_TEXT_START)
    assert_equal(q.reasoning_open, "", "another event ends reasoning sent as chunks")
    assert_equal(q.messages[0].content, "ab")
    print("reasoning: ok")

    # the chat: thinking live, then folded; a screen sent as chunks is drawn once the chunks end
    var chat = AgentChat("http://unused/", base=B, canvas_base=2000)
    chat.send("Plan a day in Lisbon")
    feed(chat, '{"type":"RUN_STARTED","threadId":"t","runId":"r"}')
    feed(chat, '{"type":"REASONING_MESSAGE_CHUNK","messageId":"th1","delta":"Trams first, then "}')
    feed(chat, '{"type":"REASONING_MESSAGE_CHUNK","delta":"Belém by noon."}')
    var live = chat.view()
    assert_true(has(live, "Thinking…") and has(live, "Belém by noon."), "while it thinks: Thinking… over its newest words")
    feed(chat, '{"type":"TEXT_MESSAGE_CHUNK","messageId":"a1","delta":"Here is your day."}')
    feed(chat, '{"type":"TOOL_CALL_CHUNK","toolCallId":"c1","toolCallName":"render_ui","parentMessageId":"a1","delta":"{\\"ui\\":{\\"component\\":\\"Card\\","}')
    feed(chat, '{"type":"TOOL_CALL_CHUNK","delta":"\\"title\\":\\"Lisbon day\\",\\"children\\":[{\\"component\\":\\"Text\\",\\"text\\":\\"Tram 28\\"}]}}"}')
    feed(chat, '{"type":"RUN_FINISHED","threadId":"t","runId":"r"}')
    _ = chat.update(Event(B + C_ENDED, "", 200))
    var done = chat.view()
    assert_true(not has(done, "Thinking…") and has(done, "Thought"), "then a folded Thought")
    assert_true(not has(done, "Belém by noon."), "folded: its words hidden")
    assert_true(has(done, "Tram 28") and has(done, "Lisbon day"), "the screen sent as chunks is drawn")
    assert_equal(len(chat.agent.pending()), 1, "and waits for the person (not refused)")
    _ = chat.update(Event(B + C_THOUGHT + 1, "", 0))
    assert_true(has(chat.view(), "Belém by noon."), "unfolded: all of it")
    _ = chat.update(Event(B + C_THOUGHT + 1, "", 0))
    assert_true(not has(chat.view(), "Belém by noon."))
    print("chat: ok")
