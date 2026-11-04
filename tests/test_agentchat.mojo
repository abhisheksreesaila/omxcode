# mojoui.agentchat (goal 48 M3): the chat's behaviours, driven with AG-UI events and the chat's own messages, read
# from the views it builds (no host): Markdown and code with Copy, the typing indicator, Stop, the list that follows,
# suggestion chips (the app's and the agent's), Regenerate, Retry after an error, arrival on a spring, the layouts.
from std.testing import assert_equal, assert_true
from mojoui.app import Event
from mojoui.view import View, TEXT, BUTTON, SCROLL, CLIPBOARD, OVERLAY, FIELD
from mojoui.markdown import parse_markdown, MD_TABLE, MD_P
from mojoui.agui import Tool
from mojoui.agentchat import (
    AgentChat, segments, CHAT_PANEL, CHAT_SIDEBAR, CHAT_POPUP, C_SEND, C_TYPED, C_PIECE, C_ENDED, C_STOP, C_RETRY,
    C_REGENERATE, C_SUGGEST, C_COPY, C_CODE, C_OPEN,
)

comptime B = 20_000


def texts(v: View) -> List[String]:
    var out = List[String]()
    for ref n in v.nodes:
        if n.kind == TEXT or n.kind == BUTTON:
            out.append(n.text)
    return out^


def has(v: View, word: String) -> Bool:
    for t in texts(v):
        if t.find(word) >= 0:
            return True
    return False


def button(v: View, title: String) -> Int:
    """The message of the button titled `title` (-1: none)."""
    for ref n in v.nodes:
        if n.kind == BUTTON and n.text == title:
            return n.msg
    return -1


def ev(mut chat: AgentChat, json: String):
    _ = chat.update(Event(B + C_PIECE, json, 0))


def finish(mut chat: AgentChat, error: String = ""):
    _ = chat.update(Event(B + C_ENDED, "", 200, error=error))


def reply(mut chat: AgentChat, id: String, text: String):
    ev(chat, '{"type":"RUN_STARTED","threadId":"t","runId":"r"}')
    ev(chat, '{"type":"TEXT_MESSAGE_START","messageId":"' + id + '","role":"assistant"}')
    ev(chat, '{"type":"TEXT_MESSAGE_CONTENT","messageId":"' + id + '","delta":' + text + "}")
    ev(chat, '{"type":"TEXT_MESSAGE_END","messageId":"' + id + '"}')
    ev(chat, '{"type":"RUN_FINISHED","threadId":"t","runId":"r"}')
    finish(chat)


def main() raises:
    # Markdown, and code blocks cut out with their own Copy
    var segs = segments("Intro **bold**\n\n```bash\npixi run hello\n```\nAfter.\n```py\nopen = 1")
    assert_equal(len(segs), 4)
    assert_true(not segs[0].code and segs[1].code and segs[1].language == "bash" and segs[1].text == "pixi run hello")
    assert_true(segs[3].code and segs[3].text == "open = 1", "a fence still streaming is code to the end")
    var md = parse_markdown(tables=True, src="Intro\n| Area | Change |\n|---|:--|\n| Chat | **Stop** |\n| Charts | bars |\nAfter")
    assert_equal(len(md), 3)
    assert_true(md[0].kind == MD_P and md[1].kind == MD_TABLE and md[1].level == 2 and len(md[1].items) == 6, "a pipe table")
    assert_true(md[1].items[3][0].text == "Stop" and md[1].items[3][0].bold, "its cells keep their inline styles")
    var chat = AgentChat("http://unused/", base=B, canvas_base=2000)
    chat.suggest("Show me sales as a chart")
    var v = chat.view()
    assert_true(has(v, "Show me sales as a chart"), "the welcome offers the app's suggestions")
    _ = chat.update(Event(button(v, "Show me sales as a chart"), "", 0))
    assert_true(chat.agent.running, "a suggestion chip sends its words and runs the agent")
    assert_equal(chat.agent.messages[0].content, "Show me sales as a chart")
    print("suggestions: ok (the app's)")
    # typing: while the agent hasn't said anything yet
    v = chat.view()
    assert_true(has(v, "Thinking"), "a typing indicator while the agent runs and hasn't spoken")
    assert_true(has(v, "Stop") and not has(v, "Send"), "Send becomes Stop while it runs")
    print("typing: ok")
    ev(chat, '{"type":"RUN_STARTED","threadId":"t","runId":"r"}')
    ev(chat, '{"type":"TEXT_MESSAGE_START","messageId":"a1","role":"assistant"}')
    ev(chat, '{"type":"TEXT_MESSAGE_CONTENT","messageId":"a1","delta":"# Sales\\n\\nUp **8%**.\\n\\n```bash\\npixi run sales\\n```\\n"}')
    v = chat.view()
    assert_true(not has(v, "Thinking"), "the indicator goes once words arrive")
    assert_true(not has(v, "Regenerate"), "no actions on a reply still streaming")
    var code_copy = -1
    for ref n in v.nodes:
        if n.kind == BUTTON and n.msg == B + C_CODE + 1 * 8 + 0:
            code_copy = n.msg
    assert_true(code_copy > 0, "the code block has its own Copy")
    print("markdown: ok")
    ev(chat, '{"type":"TEXT_MESSAGE_END","messageId":"a1"}')
    ev(chat, '{"type":"CUSTOM","name":"suggestions","value":["Break it down by region","Compare with last year"]}')
    ev(chat, '{"type":"RUN_FINISHED","threadId":"t","runId":"r"}')
    finish(chat)
    v = chat.view()
    assert_true(has(v, "Copy") and has(v, "Regenerate"), "a finished reply has Copy and Regenerate")
    assert_true(button(v, "Break it down by region") > 0 and button(v, "Show me sales as a chart") < 0, "the agent's suggestions replace the app's")
    print("suggestions: ok (the agent's)")
    # copy: the reply's words, then the code block's, go to the clipboard (its version counts up)
    _ = chat.update(Event(B + C_COPY + 1, "", 0))  # (the reply is message 1; the first "Copy" button is its code block's)
    v = chat.view()
    var clip = String("")
    var clip_version = 0
    for ref n in v.nodes:
        if n.kind == CLIPBOARD:
            clip = n.text
            clip_version = n.value
    assert_true(clip.find("Up **8%**") >= 0 and clip_version == 1, "Copy puts the reply on the clipboard")
    assert_true(has(v, "Copied"), "the button says Copied")
    _ = chat.update(Event(code_copy, "", 0))
    v = chat.view()
    for ref n in v.nodes:
        if n.kind == CLIPBOARD:
            clip = n.text
            clip_version = n.value
    assert_equal(clip, "pixi run sales")
    assert_equal(clip_version, 2)
    print("copy: ok")
    # the list follows the newest words and lets go when the reader scrolls up (a pinned Scroll: hosts do the rest)
    var pinned = False
    for ref n in v.nodes:
        if n.kind == SCROLL and n.value == 1:
            pinned = True
    assert_true(pinned, "the conversation is a pinned Scroll")
    print("scroll: ok")
    # regenerate: everything after the last question goes, the same question runs again once
    _ = chat.update(Event(B + C_REGENERATE, "", 0))
    assert_true(chat.agent.running)
    var users = 0
    for ref m in chat.agent.messages:
        if m.role == "user":
            users += 1
    assert_equal(users, 1)
    assert_equal(len(chat.agent.messages), 1, "the old answer is gone")
    print("regenerate: ok")
    # stop: the run is cancelled and the chat says so
    _ = chat.update(Event(B + C_STOP, "", 0))
    finish(chat, "cancelled")
    v = chat.view()
    assert_true(not chat.agent.running and has(v, "Stopped") and not has(v, "Something went wrong"), "Stop cancels and says Stopped, not an error")
    print("stop: ok")
    # an error, then Retry runs again
    _ = chat.update(Event(B + C_TYPED, "Hello", 0))
    _ = chat.update(Event(B + C_SEND, "", 0))
    ev(chat, '{"type":"RUN_STARTED","threadId":"t","runId":"r"}')
    ev(chat, '{"type":"RUN_ERROR","message":"the model is down"}')
    finish(chat)
    v = chat.view()
    assert_true(has(v, "Something went wrong") and has(v, "the model is down") and has(v, "Retry"), "an error card with Retry")
    _ = chat.update(Event(button(v, "Retry"), "", 0))
    assert_true(chat.agent.running, "Retry runs the agent again")
    print("retry: ok")
    # spring: new messages and the agent's screens arrive (.arrive())
    finish(chat)
    reply(chat, "a9", '"Hi there."')
    v = chat.view()
    var arriving = 0
    for ref n in v.nodes:
        if n.arrives:
            arriving += 1
    assert_true(arriving >= 2, "messages arrive on a spring")
    print("spring: ok")
    # layouts: a panel, a sidebar (with a close button), a popup (a button, then the chat floating over the content)
    var side = AgentChat("http://unused/", base=B, canvas_base=2000, layout=CHAT_SIDEBAR)
    var sv = side.view()
    assert_true(button(sv, "Close") > 0 and sv.nodes[0].w == 420)
    var pop = AgentChat("http://unused/", base=B, canvas_base=2000, layout=CHAT_POPUP)
    var closed = pop.over(chat.view())
    assert_true(closed.nodes[0].kind == OVERLAY and button(closed, "Assistant") > 0, "a closed popup is its button")
    _ = pop.update(Event(B + C_OPEN, "", 0))
    var opened = pop.over(chat.view())
    var fields = 0
    for ref n in opened.nodes:
        if n.kind == FIELD:
            fields += 1
    assert_true(fields >= 2, "the open popup floats a chat (its composer) over the content")
    print("layouts: ok")
    # human in the loop: a confirm tool waits for Approve or Reject; an interrupt resumes the run with the pick
    var hitl = AgentChat("http://unused/", base=B, canvas_base=2000)
    hitl.offer(Tool("refund_order", "Refund an order", '{"type":"object"}'), confirm=True)
    hitl.send("Refund order 1042")
    ev(hitl, '{"type":"RUN_STARTED","threadId":"t","runId":"r"}')
    ev(hitl, '{"type":"TOOL_CALL_START","toolCallId":"c1","toolCallName":"refund_order","parentMessageId":"a1"}')
    ev(hitl, '{"type":"TOOL_CALL_ARGS","toolCallId":"c1","delta":"{\\"order\\":\\"1042\\",\\"amount\\":42}"}')
    ev(hitl, '{"type":"TOOL_CALL_END","toolCallId":"c1"}')
    ev(hitl, '{"type":"RUN_FINISHED","threadId":"t","runId":"r"}')
    finish(hitl)
    var hv = hitl.view()
    assert_true(has(hv, "Refund an order") and has(hv, "1042") and button(hv, "Approve") > 0 and button(hv, "Reject") > 0)
    assert_true(not hitl.agent.running and not hitl.agent.answered("c1"), "nothing runs until the person answers")
    _ = hitl.update(Event(button(hv, "Reject"), "", 0))
    assert_true(hitl.agent.answered("c1") and hitl.agent.running, "the answer is the call's result, and the agent runs on")
    assert_true(hitl.agent.messages[len(hitl.agent.messages) - 1].content.find('"rejected"') >= 0)
    finish(hitl)
    hv = hitl.view()
    assert_true(has(hv, "Rejected") and button(hv, "Approve") < 0)
    ev(hitl, '{"type":"RUN_STARTED","threadId":"t","runId":"r2"}')
    ev(hitl, '{"type":"CUSTOM","name":"on_interrupt","value":{"question":"Deploy to…","options":["Staging","Production"]}}')
    ev(hitl, '{"type":"RUN_FINISHED","threadId":"t","runId":"r2"}')
    finish(hitl)
    hv = hitl.view()
    assert_true(has(hv, "Deploy to") and button(hv, "Staging") > 0 and button(hv, "Production") > 0)
    _ = hitl.update(Event(button(hv, "Production"), "", 0))
    assert_true(hitl.agent.running and hitl.agent.forwarded == "", "the resume went with the run")
    assert_true(hitl.agent.input_json().find('"forwardedProps":{}') >= 0, "only that run carried it")
    finish(hitl)
    assert_true(has(hitl.view(), "You chose Production"))
    print("hitl: ok")
    print("test_agentchat: done")
