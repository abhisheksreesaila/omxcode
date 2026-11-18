# mojoui.assistant (goal 72 M6): the parts of the glue that need no model: the messages it owns, the card a tap changes, the
# cards in the shelf's order, a notice only when a job has ended.
#   pixi run mojo build -I . -I vendor tests/test_assistant.mojo -o build/test_assistant && build/test_assistant
from std.os import setenv, unlink
from std.os.path import exists
from std.testing import assert_equal, assert_true
from mojoui.app import Event
from mojoui.assistant import Assistant
from mojoui.todo import todo_add, TodoList
from mojoui.view import TEXT, TOGGLE


def main() raises:
    var path = String("/tmp/mojoui-test-assistant-todo.json")
    if exists(path):
        unlink(path)
    _ = setenv("MOJOUI_TODO", path, True)
    var a = Assistant(500, 8)
    assert_equal(len(a.cards()), 0)  # nothing yet: no to-do card for a list nobody has touched
    assert_equal(a.notice(True), "")  # and no job to announce
    assert_true(a.is_tool("news") and a.is_tool("think_it_through") and not a.is_tool("todo_add"))  # (todo_add runs inside the agent)

    _ = todo_add('{"items":["buy milk","call mum"]}')  # (the model's tool call, in another place than the screen)
    assert_true(a.todo.refresh())
    a.todo_shown = True
    var cards = a.cards()
    assert_equal(len(cards), 1)
    var boxes = String("")
    for ref n in cards[0].nodes:
        if n.kind == TOGGLE:
            boxes += n.text + ("=on," if n.value != 0 else "=off,")
    assert_equal(boxes, "buy milk=off,call mum=off,")

    # a tap on the second tick box: the list, the file and the card agree
    assert_true(a.owns(501) and a.owns(700) and not a.owns(499) and not a.owns(701))
    assert_true(a.handle(Event(501, "", 1)))
    assert_equal(TodoList(path).describe(), '{"open":1,"items":["1. buy milk","2. call mum (done)"]}')
    var again = String("")
    for ref n in a.cards()[0].nodes:
        if n.kind == TOGGLE:
            again += n.text + ("=on," if n.value != 0 else "=off,")
    assert_equal(again, "buy milk=off,call mum=on,")
    var lines = a.take_log()
    assert_equal(len(lines), 1)
    assert_equal(lines[0], "TODO: tick open=1 total=2 items=[ ] buy milk | [x] call mum")
    assert_equal(len(a.take_log()), 0)  # taken once

    # Dismiss with no job is harmless
    assert_true(a.handle(Event(700, "", 0)))
    unlink(path)
    print("assistant: ok")
