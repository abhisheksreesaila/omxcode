# Goal 55: a download whose connection drops is picked up where it stopped (mojoui.http_flare.fetch_to_file's `tries`;
# Hugging Face's CDN resets long downloads on a slow line). Needs tests/resume_server.py:
#   RESUME_TEST_URL=http://127.0.0.1:PORT/ build/test_resume
#   scripts/mojo_flare.sh build tests/test_resume.mojo -o build/test_resume
from std.os import getenv, makedirs
from std.os.path import exists, getsize
from mojoui.http import Request
from mojoui.http_flare import fetch_to_file, Transfer
from mojoui.files import remove_tree

comptime DIR = "build/g55/test_resume"
comptime SIZE = 3_000_000


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def whole(path: String) raises -> Bool:
    """The file is the server's: SIZE bytes, byte i = i % 251."""
    if not exists(path) or getsize(path) != SIZE:
        return False
    with open(path, "r") as f:
        var b = f.read_bytes()
        for i in range(SIZE):
            if Int(b[i]) != i % 251:
                return False
    return True


def main() raises:
    var base = getenv("RESUME_TEST_URL")
    check(base != "", "set RESUME_TEST_URL (tests/resume_server.py)")
    remove_tree(DIR)
    makedirs(DIR, exist_ok=True)
    # a drop mid-file, tries=3: one resume, and the file is whole and right
    var t = Transfer()
    var r = fetch_to_file(Request.get(0, base + "drop"), DIR + "/a.bin", t, tries=3)
    check(r.error == "" and r.status == 200, "drop: " + r.error + " " + String(r.status))
    check(t.resumes() == 1 and whole(DIR + "/a.bin") and not exists(DIR + "/a.bin.part"), "drop: resumes " + String(t.resumes()))
    t.free()
    # one try (the default): the drop is an error, and the part stays for a later resume
    var t2 = Transfer()
    r = fetch_to_file(Request.get(0, base + "always-drop"), DIR + "/b.bin", t2)
    var kept = getsize(DIR + "/b.bin.part") if exists(DIR + "/b.bin.part") else 0
    check(r.error != "" and r.status == 0 and t2.resumes() == 0 and kept > 0 and kept < SIZE and not exists(DIR + "/b.bin"),
          "one try: error '" + r.error + "', part " + String(kept))
    t2.free()
    # it keeps dropping: tries=3 gives up after two resumes, each one further on
    var t3 = Transfer()
    r = fetch_to_file(Request.get(0, base + "always-drop"), DIR + "/b.bin", t3, tries=3)
    var later = getsize(DIR + "/b.bin.part") if exists(DIR + "/b.bin.part") else 0
    check(r.error != "" and t3.resumes() == 2 and later > kept and later < SIZE, "gives up: resumes " + String(t3.resumes()) + ", part " + String(later))
    t3.free()
    # a cancel before it starts: no tries at all
    var t4 = Transfer()
    t4.cancel()
    r = fetch_to_file(Request.get(0, base + "whole"), DIR + "/c.bin", t4, tries=5)
    check(r.error == "cancelled" and t4.resumes() == 0, "cancel: '" + r.error + "' resumes " + String(t4.resumes()))
    t4.free()
    remove_tree(DIR)
    print("resume: ok (a dropped download resumes from its part; one try keeps the part; tries run out; a cancel never retries)")
