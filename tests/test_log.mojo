# Goal 60 M1: mojoui.log without a server: JSON lines that parse, secrets masked (registered values and by shape:
# bearer tokens, Stripe keys, code/state/token query and JSON values, cookies), rotation by size keeping N files.
# The server's request lines and the audit table are proved by docs/goals/60-check.py M1.
from std.os import remove, makedirs
from std.os.path import exists
from mojoui.log import Log, Fields, redact, MASK
from mojoui.json import Json


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def fresh(path: String) raises:
    for suffix in ["", ".1", ".2", ".3", ".4"]:
        if exists(path + suffix):
            remove(path + suffix)


def main() raises:
    if not exists("build/test_log_files"):
        makedirs("build/test_log_files")
    var path = "build/test_log_files/a.log"
    fresh(path)
    # json
    var log = Log.open(path)
    log.info("hello \"quoted\"\nnext", Fields().str("tenant", "t1").int("n", 3).num("ms", 1.25))
    log.request("rid1", "GET", "/auth/callback?code=abc&state=def", 303, 4.5, "127.0.0.1")
    var lines = read(path).strip().split("\n")
    expect(len(lines) == 2, "two lines, got " + String(len(lines)))
    var j = Json.parse(String(lines[0]))
    expect(j.text(j.get(0, "level")) == "info" and j.text(j.get(0, "tenant")) == "t1" and j.number(j.get(0, "n")) == 3, "fields")
    expect(j.text(j.get(0, "msg")) == "hello \"quoted\"\nnext", "an escaped message")
    var r = Json.parse(String(lines[1]))
    expect(r.text(r.get(0, "path")) == "/auth/callback" and r.number(r.get(0, "status")) == 303 and r.text(r.get(0, "rid")) == "rid1", "a request line without its query")
    expect(r.real(r.get(0, "ts")) > 1_700_000_000.0, "a timestamp")
    print("json: ok")
    # redact
    var secrets: List[String] = ["hunter2-smtp-pass"]
    var cases: List[String] = [
        "Authorization: Bearer ya29.a0AfH6SMB-xyz",
        "key sk_test_51Habc123 and whsec_abcdef0123",
        "/auth/callback?code=4/0Ab-x_y&state=s7Tz",
        '{"access_token": "tok-123-abc", "id_token": "e.y.j"}',
        "cookie: saas=v1.abc.def; other=1",
        "password hunter2-smtp-pass sent",
        "client_secret=GOCSPX-abc&grant_type=authorization_code",
    ]
    var leaks: List[String] = ["ya29.a0AfH6SMB-xyz", "sk_test_51Habc123", "whsec_abcdef0123", "4/0Ab-x_y", "s7Tz", "tok-123-abc", "e.y.j", "v1.abc.def", "hunter2-smtp-pass", "GOCSPX-abc"]
    for c in cases:
        var out = redact(c, secrets)
        expect(MASK in out, "nothing masked in " + c + " → " + out)
        for l in leaks:
            expect(l not in out, "leaked " + l + " in " + out)
    expect(redact("postcode=12345 grant_type=authorization_code", secrets) == "postcode=12345 grant_type=authorization_code", "a longer name isn't masked")
    expect("authorization_code" in redact("grant_type=authorization_code", secrets), "plain values stay")
    var log2 = Log.open("build/test_log_files/b.log")
    log2.secret("sk_live_reallysecret")
    log2.info("calling stripe with sk_live_reallysecret", Fields().str("note", "x sk_live_reallysecret y"))
    expect("reallysecret" not in read("build/test_log_files/b.log"), "a registered secret reached the file")
    print("redact: ok")
    # rotate
    var rp = "build/test_log_files/r.log"
    fresh(rp)
    var rl = Log.open(rp, max_bytes=1000, keep=3)
    for i in range(200):
        rl.info("line " + String(i), Fields().str("pad", "x" * 40))
    expect(exists(rp) and exists(rp + ".1") and exists(rp + ".2") and exists(rp + ".3"), "rotated files")
    expect(not exists(rp + ".4"), "kept only 3")
    for suffix in ["", ".1", ".2", ".3"]:
        var text = read(rp + suffix)
        expect(text.byte_length() <= 1000, "a file over its size: " + suffix)
        for l in text.strip().split("\n"):
            _ = Json.parse(String(l))  # (whole lines only)
    expect("line 199" in read(rp), "the newest line is in the live file")
    print("rotate: ok")
