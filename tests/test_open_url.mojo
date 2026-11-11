# Goal 57 M4: open_url as an effect. (1) An app's Browser outbox reaches the host through the runtime after update(),
# each URL once, javascript:/file: refused there. (2) mojoui.browser.open_url starts the opener ($MOJOUI_OPENER here: a
# stand-in browser that writes its argument to a file) with the URL as one argument, exactly (no shell between), and
# refuses what isn't http(s). (3) With the caller's own $MOJOUI_OPENER (the checker's stand-in), it starts too.
from std.os import getenv, setenv, makedirs
from std.os.path import exists
from mojoui.process import output
from mojoui.app import App, Event, Runtime
from mojoui import View, Text
from mojoui.browser import Browser, open_url
from mojoui.clock import now_ns
from mojoui import libc

comptime OPEN = 1
comptime URL = "https://example.com/login?client=desktop&redirect=http%3A%2F%2F127.0.0.1%3A5173%2Fcb&x=$(id)`id`;y'q"


struct Opener(App):
    var browser: Browser

    def __init__(out self):
        self.browser = Browser()

    def title(self) -> String:
        return "open_url probe"

    def update(mut self, e: Event):
        if e.message == OPEN:
            self.browser.open(URL)
            self.browser.open("javascript:alert(1)")
            self.browser.open("file:///etc/passwd")

    def view(self) -> View:
        return Text("probe")

    def opens(mut self) -> List[String]:
        return self.browser.take()


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def read(path: String) -> String:
    try:
        with open(path, "r") as f:
            return f.read()
    except:
        return ""


def main() raises:
    var rt = Runtime(Opener())
    expect(len(rt.take_opens()) == 0, "opens before any update")
    _ = rt.dispatch(OPEN)
    var urls = rt.take_opens()
    expect(len(urls) == 1 and urls[0] == URL, "the runtime handed over " + String(len(urls)) + " URLs")
    expect(len(rt.take_opens()) == 0, "a URL was handed over twice")
    print("effect: ok")
    var theirs = getenv("MOJOUI_OPENER")
    var dir = String("build/test_open_url.d")
    _ = libc.unlink(dir + "/got")
    var own = dir + "/opener.sh"
    if not exists(dir):
        makedirs(dir)
    with open(own, "w") as f:
        f.write('#!/bin/sh\nprintf "%s" "$1" > "$(dirname "$0")/got"\n')
    var argv: List[String] = ["chmod", "755", own]
    _ = output(argv)
    _ = setenv("MOJOUI_OPENER", own)
    expect(not open_url("javascript:alert(1)") and not open_url("file:///etc/passwd"), "opened a non-web URL")
    expect(open_url(URL), "the opener didn't start")
    var t0 = now_ns()
    while read(dir + "/got") != URL and now_ns() - t0 < 5_000_000_000:
        _ = libc.poll(0, 0, 20)
    expect(read(dir + "/got") == URL, "the opener got " + read(dir + "/got"))
    if theirs != "":
        _ = setenv("MOJOUI_OPENER", theirs)
        expect(open_url("https://example.com/from-test_open_url"), "the caller's opener didn't start")
    print("open_url: ok")
