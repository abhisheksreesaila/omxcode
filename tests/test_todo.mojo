# mojoui.todo (goal 72 M6): a list in a file that the tools and the tick boxes edit, found by number or by words, kept across a restart.
#   scripts/mxbuild.sh tests/test_todo.mojo -o build/test_todo && build/test_todo
from std.os import setenv, unlink, makedirs, listdir
from std.os.path import exists
from std.testing import assert_equal, assert_true
from mojoui.todo import TodoList, todo_add, todo_done, todo_remove, todo_list, todo_functions, TodoCard, todo_path
from mojoui.view import TOGGLE
from mojoui import libc


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

    # a file that can't be read is kept, never written over (D-7306): the garbage moves aside and a new list starts
    with open(path, "w") as f:
        f.write("not json {{ the person's own notes?")
    var odd = TodoList(path)
    assert_equal(len(odd.items), 0)
    assert_true(odd.note.find("couldn't be read") >= 0 and odd.note.find("kept as " + path + ".bad-") >= 0, odd.note)
    assert_true(not exists(path))
    r = todo_add('{"items":["buy milk"]}')
    assert_true(r.startswith('{"added":1,"list":{"open":1,"items":["1. buy milk"]'), r)
    var kept = String("")
    for name in listdir("/tmp"):
        if name.startswith("mojoui-test-todo.json.bad-"):
            with open("/tmp/" + name, "r") as f:
                kept = f.read()
            unlink("/tmp/" + name)
    assert_equal(kept, "not json {{ the person's own notes?")
    unlink(path)
    # JSON that isn't a to-do list is not ours either
    with open(path, "w") as f:
        f.write('{"shopping":["eggs"]}')
    assert_true(TodoList(path).note.find("it has no list of items") >= 0)
    for name in listdir("/tmp"):
        if name.startswith("mojoui-test-todo.json.bad-"):
            unlink("/tmp/" + name)
    # an unreadable file that can't be moved aside (a folder nobody may write to) stays exactly as it is, and the tool says so
    makedirs("/tmp/mojoui-test-todo-ro", exist_ok=True)
    var ro = String("/tmp/mojoui-test-todo-ro/todo.json")
    with open(ro, "w") as f:
        f.write("garbage")
    _ = libc.chmod("/tmp/mojoui-test-todo-ro", 0o500)
    _ = setenv("MOJOUI_TODO", ro, True)
    r = todo_add('{"items":["buy milk"]}')
    assert_true(r.startswith('{"error":"I couldn\'t save the list: the to-do file couldn\'t be read'), r)
    _ = libc.chmod("/tmp/mojoui-test-todo-ro", 0o700)
    with open(ro, "r") as f:
        assert_equal(f.read(), "garbage")
    unlink(ro)
    # a save that fails is said, not swallowed: the model is told the change was not kept
    _ = setenv("MOJOUI_TODO", "/proc/no-such-folder/todo.json", True)
    r = todo_add('{"items":["buy milk"]}')
    assert_true(r.startswith('{"error":"I couldn\'t save the list: '), r)
    assert_true(r.find("The change was not kept; tell the user.") >= 0, r)
    print("todo: ok")
