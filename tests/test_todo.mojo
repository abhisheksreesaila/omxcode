# mojoui.todo (goal 72 M6): a list in a file that the tools and the tick boxes edit, found by number or by words, kept across a restart.
#   scripts/mxbuild.sh tests/test_todo.mojo -o build/test_todo && build/test_todo
from std.os import setenv, unlink
from std.os.path import exists
from std.testing import assert_equal, assert_true
from mojoui.todo import TodoList, todo_add, todo_done, todo_remove, todo_list, todo_functions, TodoCard, todo_path
from mojoui.view import TOGGLE


def main() raises:
    var path = String("/tmp/mojoui-test-todo.json")
    if exists(path):
        unlink(path)
    _ = setenv("MOJOUI_TODO", path, True)
    assert_equal(todo_path(), path)
    assert_equal(TodoList(path).describe(), '{"open":0,"items":[]}')

    # several things said at once land as five items, saved
    var r = todo_add('{"items":["buy milk","call mum.","book the dentist","fix the bike","send the invoice"]}')
    assert_equal(r, '{"added":5,"list":{"open":5,"items":["1. buy milk","2. call mum","3. book the dentist","4. fix the bike","5. send the invoice"]}}')

    # "I called mum" ticks the one about mum, by words
    r = todo_done('{"which":"mum"}')
    assert_equal(r, '{"ticked":"call mum","list":{"open":4,"items":["1. buy milk","2. call mum (done)","3. book the dentist","4. fix the bike","5. send the invoice"]}}')

    # by number (as a number), and a phrase that fits nothing, and a number past the end
    assert_true(todo_done('{"which":1}').startswith('{"ticked":"buy milk"'))
    assert_true(todo_done('{"which":"the dragon"}').startswith('{"error":"nothing on the list fits that'))
    assert_true(todo_done('{"which":"9"}').startswith('{"error"'))

    # a restart: a new reader sees the same list
    var again = TodoList(path)
    assert_equal(len(again.items), 5)
    assert_equal(again.open_count(), 3)
    assert_equal(todo_list("{}"), '{"open":3,"items":["1. buy milk (done)","2. call mum (done)","3. book the dentist","4. fix the bike","5. send the invoice"]}')

    # stop words pick nothing; "bike" picks the one
    assert_equal(again.find("the"), -1)
    assert_equal(again.find("bike"), 3)
    assert_equal(again.remove("bike"), "fix the bike")
    assert_equal(len(TodoList(path).items), 4)
    assert_true(todo_remove('{"which":"nothing like it"}').startswith('{"error"'))

    # ambiguity is refused, not guessed
    _ = todo_add('{"items":["call the bank","call the school"]}')
    assert_true(todo_done('{"which":"call"}').startswith('{"error":"more than one thing fits'))

    # the card is the list: a tick box per thing, the count in its caption, the first box sends tick + 0
    var l = TodoList(path)
    var card = TodoCard(l.items, 500)
    var boxes = 0
    var texts = List[String]()
    var first_msg = -1
    for ref n in card.nodes:
        if n.kind == TOGGLE:
            boxes += 1
            if first_msg < 0:
                first_msg = n.msg
        if n.kind == 1:
            texts.append(n.text)
    assert_equal(boxes, 6)
    assert_equal(texts[1], "4 left of 6")
    assert_equal(first_msg, 500)

    # a tap on a tick box toggles it and the file follows; another reader sees it after refresh()
    var other = TodoList(path)
    l.toggle(2)
    assert_true(other.refresh())
    assert_true(other.items[2].done)
    assert_true(not other.refresh())

    # the tools are offered by name
    var names = String("")
    for ref f in todo_functions():
        names += f.name + ","
    assert_equal(names, "todo_add,todo_done,todo_remove,todo_list,")
    unlink(path)
    print("todo: ok")
