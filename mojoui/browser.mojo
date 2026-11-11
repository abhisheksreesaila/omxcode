# mojoui.browser: open a page in the system browser, as an effect (goal 57 M4, D-5718). The app asks in update(); the
# runtime takes the URL after the update (http:// and https:// only, mojoui.embed.is_web_url) and the host opens it:
#
#   struct Main(App):
#       var browser: Browser                     # the outbox
#       def update(mut self, e: Event):
#           if e.message == SIGN_IN: self.browser.open("https://example.com/login?…")
#       def opens(mut self) -> List[String]:
#           return self.browser.take()
#
# Hosts: GTK runs xdg-open (or $MOJOUI_OPENER, a check's stand-in browser); AppKit runs macOS's `open` (or
# $MOJOUI_OPENER) through `open_url` here; the web host and the phones don't open pages yet (docs/components.md).
# `open_url` starts the opener with posix_spawnp and the URL as one argument (no shell: nothing in a URL runs), and a
# thread reaps it (no zombie); it never waits for the browser.
from std.os import getenv
from std.sys import CompilationTarget
from mojoui import libc
from mojoui.embed import is_web_url
from mojoui.process import _cstr, _free, _environment


struct Browser(Movable):
    """The pages the app asked to open since the runtime last looked."""

    var out: List[String]

    def __init__(out self):
        self.out = List[String]()

    def open(mut self, url: String):
        self.out.append(url)

    def take(mut self) -> List[String]:
        var urls = self.out^
        self.out = List[String]()
        return urls^


def opener() -> String:
    """$MOJOUI_OPENER, else the platform's: `open` on macOS, xdg-open elsewhere."""
    var own = getenv("MOJOUI_OPENER")
    if own != "":
        return own
    return "open" if CompilationTarget.is_macos() else "xdg-open"


def _reap(p: libc.ThreadArg) -> libc.ThreadArg:
    var status = List[Int32](length=2, fill=0)
    _ = libc.waitpid(Int(p), Int(status.unsafe_ptr()), 0)
    _ = len(status)
    return libc.null_arg()


def open_url(url: String) -> Bool:
    """Starts the opener on `url` (http/https only); False when refused or it couldn't start. Doesn't wait for it."""
    if not is_web_url(url):
        print("mojoui: refused to open " + String(url.split(":")[0]) + ": (not an http or https URL)")
        return False
    var argv: List[String] = [opener(), url]
    var cargs = List[Int]()
    for a in argv:
        cargs.append(_cstr(a))
    cargs.append(0)
    var envs = _environment(List[String]())
    var cenv = List[Int]()
    for e in envs:
        cenv.append(_cstr(e))
    cenv.append(0)
    var pid = List[Int32](length=2, fill=0)
    var file = cargs[0]
    var argv_at = Int(cargs.unsafe_ptr())
    var envp_at = Int(cenv.unsafe_ptr())
    var rc = libc.posix_spawnp(Int(pid.unsafe_ptr()), file, 0, 0, argv_at, envp_at)
    for c in cargs:
        _free(c)
    for c in cenv:
        _free(c)
    if rc != 0:
        print("mojoui: could not run " + argv[0] + " (error " + String(rc) + ")")
        return False
    var tid = List[Int](length=1, fill=0)
    if libc.pthread_create[_reap](Int(pid[0]), Int(tid.unsafe_ptr())) == 0:
        _ = libc.pthread_detach(tid[0])
    _ = len(tid)
    return True
