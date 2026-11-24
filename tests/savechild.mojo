# A window's saving without the window, for tests/savekill.py to kill: types into a page and a canvas for ever (or `rounds`
# times), each edit saved as the app does; prints what was typed, started and landed.  savechild <db> <rounds> [close]
from std.sys import argv
from std.time import sleep
from mojoui.docstore import clock_us
from webshell import WebShell


def main() raises:
    var s = WebShell(String(argv()[1]), "paper")
    var rounds = Int(String(argv()[2]))
    if len(s.notes) == 0:
        s.create("page", "Page")
        s.page.insert("x " * 200_000)
        s.save_page()
        s.flush()
    var id = s.notes[0].id
    s.open(id)
    s.page.caret_end()
    var base = s.page.markdown()
    var n = 0
    var at = base.rfind(" #")
    if at >= 0:
        n = Int(String(base[byte=at + 2:base.byte_length()]))
    print("READY", n, flush=True)
    var worst = 0
    for _ in range(rounds):
        n += 1
        s.page.insert(" #" + String(n))
        s.save_page()
        print("TYPED", n, flush=True)
        s.saver.due_us = clock_us() - 1
        var t0 = clock_us()
        _ = s.tick()
        worst = max(worst, clock_us() - t0)
        while s.saving():
            t0 = clock_us()
            _ = s.tick()
            worst = max(worst, clock_us() - t0)
            sleep(0.002)
        if s.save_state == "":
            print("LANDED", n, flush=True)
        else:
            print("TOLD", n, s.save_detail, flush=True)
    print("WORST", worst, flush=True)
    print("MAYCLOSE", s.may_close(), flush=True)
    s.close()
    print("CLOSED", flush=True)
