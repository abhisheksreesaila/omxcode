# One SaveOutbox driven by lines on stdin (tests/outboxkill.py; review 5's probe).
from std.sys import argv
from mojoui.docstore import SaveOutbox, Unsaved
from mojoui.libc import getpid

def main() raises:
    var o = SaveOutbox(String(argv()[1]), String(argv()[2]))
    print("PID", getpid(), flush=True)
    while True:
        var line: String
        try:
            line = input()
        except:
            return
        var p = line.split(" ")
        var op = String(p[0])
        if op == "load":
            o.load()
            for u in o.items.copy():
                print("HAVE", u.id, u.revision, u.content, flush=True)
            while len(o.extras) > 0:
                print("COPY", o.extras[0].id, o.extras[0].content, flush=True)
                o.extra_done(0)
            print("END", flush=True)
        elif op == "put" or op == "spill":
            var u = Unsaved(Int(String(p[1])), "page", Int(String(p[2])), String(p[3]), "", "w", True)
            var ok = o.put(u^) if op == "put" else o.spill(u) > 0
            print("END", "ok" if ok else "NO", flush=True)
        elif op == "drop":
            o.drop(Int(String(p[1])))
            print("END", flush=True)
        elif op == "owner":
            print("END", o.owner, o.lock.held(), flush=True)
        elif op == "quit":
            return
