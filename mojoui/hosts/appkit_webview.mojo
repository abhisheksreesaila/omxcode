# mojoui.hosts.appkit_webview: a WebComponent on the Mac (goal 34b M2). Each widget gets a WKWebView of its own that
# loads the app's own bundles (scripts/web_assets.py --webview into the app's Resources/webview: the web's files, byte
# for byte) and the web host's widget runtime (mojoui-widgets.js) from a local origin, mojoui://app/, served by a
# WKURLSchemeHandler with the web's CSP (frame-src 'none'). Nothing else: no network (a content rule list blocks every
# other scheme's load, and the CSP), no file access (the origin serves a fixed list of files), no navigation away and
# no new windows (the navigation and UI delegates). The model is GTK's (mojoui/hosts/gtk_webview.mojo, D-608–D-626):
# the same page, the same slots, the same message rules.
#
# Across the seam only JSON text travels. Mojo → page: callAsyncJavaScript with the message as its argument m (an
# NSString: data, never code), `return mojoui.native.receive(m)`; page → Mojo: the "mojoui" WKScriptMessageHandler,
# whose message must be a string holding a JSON object naming this view's own widget, from the main frame. The host
# (appkit.mojo) keeps each view across rebuilds by its key (tag, id): a new screen moves the live view into the new box.
#
# WebKit.framework is loaded (NSBundle) when the first WebComponent shows: apps without one never load it. Objective-C
# goes by name at run time, so the app links no new C function (apple/sdk). Callbacks find this struct through the
# view's identifier (its address, as the host's window does).

from std.ffi import c_int
from std.memory import Pointer

from mojoui.json import Json, json_string
from mojoui.webcomponent import is_event_name
from mojoui.hosts.objc import cls, sel, msg, new, protocol, ns_string, ns_number, from_ns, new_class, add_method, add_protocol, register_class, data_block, block_data
from mojoui.hosts.apple_canvas import CGPoint, CGRect, cfunc
from mojoui.hosts.gtk_webview import (
    WebViews, WebSlot, Inbound, IN_EVENT, IN_REPLY, CSP, PAGE_URI, SCHEME, MAX_MESSAGE, plain_file, plain_sri, clip_error, fonts,
    take_text, facts_of, TOOK_NOTHING, TOOK_INBOX, TOOK_SIZE,
)
from mojoui.hosts.devtools import DEVTOOLS

comptime WEBKIT = "/System/Library/Frameworks/WebKit.framework"
# Every network or file load is blocked before it starts (defence in depth: the CSP already holds the page to
# mojoui://app; GTK's equivalent is the dead proxy, D-612). (Content rules' patterns have no alternation: one per scheme.)
comptime RULES = ('[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},'
                  + '{"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"block"}}]')
comptime UTF8 = 4  # NSUTF8StringEncoding


struct MacWebViews(Movable):
    """Every WebComponent view of the window, the Mac's way (on the heap: WebKit's callbacks find it by address)."""

    var core: WebViews  # the slots, inbox and sent commands, as GTK keeps them
    var delegate: Int  # one MojoWebDelegate: scheme handler, message handler, navigation and UI delegate
    var target: Int  # the host's MojoTarget (webInbox:, debugQueued:) and the host's address for it
    var host_addr: Int
    var rules: Int  # the compiled WKContentRuleList (0 while compiling, or if it failed)
    var rules_state: Int  # 0 compiling, 1 ready, -1 failed (views load anyway: the CSP holds)
    var waiting: List[Int]  # views whose page waits for the rule list
    var heights: List[Tuple[Int, Int]]  # (view, its height constraint)
    var images: List[Tuple[Int, Int]]  # (view, its last picture, an NSImage held here): the report draws them in
    var shots_waiting: Int
    var send_block: Int  # completion blocks, made once
    var probe_block: Int
    var rules_block: Int
    var busy: Bool  # (test steps) a probe or a click is in flight
    var kill_view: Int  # (test steps) a view whose process was ended, until it reloads or gives up
    var kill_crashes: Int

    def __init__(out self):
        self.core = WebViews()
        self.delegate = 0
        self.target = 0
        self.host_addr = 0
        self.rules = 0
        self.rules_state = 0
        self.waiting = List[Int]()
        self.heights = List[Tuple[Int, Int]]()
        self.images = List[Tuple[Int, Int]]()
        self.shots_waiting = 0
        self.send_block = 0
        self.probe_block = 0
        self.rules_block = 0
        self.busy = False
        self.kill_view = 0
        self.kill_crashes = 0


def mac_at(addr: Int) -> Pointer[MacWebViews, MutUntrackedOrigin]:
    return Pointer[MacWebViews, MutUntrackedOrigin](unsafe_from_address=addr)


def mac_of(view: Int) -> Int:
    """The MacWebViews a WKWebView belongs to (its identifier holds the address), or 0."""
    if view == 0:
        return 0
    var ident = msg(view, "identifier")
    return msg(ident, "longLongValue") if ident != 0 else 0


def is_kind(obj: Int, name: String) -> Bool:
    return obj != 0 and (msg(obj, "isKindOfClass:", cls(name)) & 0xFF) != 0


def call_block(block: Int, value: Int):
    """Calls an Objective-C block that takes one integer (a decision handler's policy)."""
    var invoke = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=block + 16)[]
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=invoke)
    var f = Pointer(to=raw).unsafe_bitcast[def(b: Int, v: Int) thin abi("C") -> Int]()[]
    _ = f(block, value)


def file_string(path: String) -> String:
    var s = msg(cls("NSString"), "stringWithContentsOfFile:encoding:error:", ns_string(path), UTF8, 0)
    return from_ns(s)


def json_of(value: Int) -> String:
    """An Objective-C value from the page (NSString, NSNumber, NSArray, NSDictionary, NSNull or nil) as JSON text."""
    if value == 0 or is_kind(value, "NSNull"):
        return "null"
    var data = msg(cls("NSJSONSerialization"), "dataWithJSONObject:options:error:", value, 4, 0)  # NSJSONWritingFragmentsAllowed
    if data == 0:
        return json_string("(not JSON)")
    var text = msg(msg(msg(cls("NSString"), "alloc"), "initWithData:encoding:", data, UTF8), "autorelease")
    return from_ns(text)


def start(addr: Int, assets: List[String], target: Int, host_addr: Int) -> Bool:
    """Loads WebKit (once) and readies the origin: the page, the files it may load, the delegate, the rule list.
    False: not there (the WebComponents show their `instead` views)."""
    var mw = mac_at(addr)
    if mw[].core.state != 0:
        return mw[].core.state == 1
    mw[].core.state = -1
    mw[].target = target
    mw[].host_addr = host_addr
    var bundle = msg(cls("NSBundle"), "bundleWithPath:", ns_string(WEBKIT))
    if bundle == 0 or (msg(bundle, "load") & 0xFF) == 0 or cls("WKWebView") == 0:
        print("mojoui: WebKit.framework didn't load: WebComponents show their stand-ins")
        return False
    var res = from_ns(msg(msg(cls("NSBundle"), "mainBundle"), "resourcePath"))
    var override = from_ns(msg(msg(msg(cls("NSProcessInfo"), "processInfo"), "environment"), "objectForKey:", ns_string("MOJOUI_WEBVIEW")))
    mw[].core.dir = override if override != "" else res + "/webview"
    mw[].core.fonts_dir = res + "/fonts"
    # The page, as GTK's: the host's sheet, the theme's (filled by the first message), the bundles App.web_assets()
    # lists by their hashed names with SRI (manifest.json); the runtime before the bundles (they call defineWidget)
    var links = String("")
    var scripts = String("")
    try:
        var j = Json.parse(file_string(mw[].core.dir + "/assets/manifest.json"))
        for name in assets:
            var e = j.get(0, name)
            var file = j.text(j.get(e, "file"))
            var sri = j.text(j.get(e, "integrity"))
            if e < 0 or not plain_file(file) or not plain_sri(sri):
                print("mojoui: web_assets() lists " + name + ", which isn't bundled in " + mw[].core.dir + "/assets (scripts/build.sh)")
                continue
            mw[].core.files.append(file)
            var map_file = j.text(j.get(e, "map"))
            if DEVTOOLS and map_file != "" and plain_file(map_file):  # (debug builds: its source map, as GTK serves it)
                mw[].core.files.append(map_file)
            if name.endswith(".css"):
                links += '<link rel="stylesheet" href="/assets/' + file + '" integrity="' + sri + '">'
            else:
                scripts += '<script src="/assets/' + file + '" integrity="' + sri + '"></script>'
    except e:
        print("mojoui: no bundles for the web views in " + mw[].core.dir + " (" + String(e) + "): WebComponents show their stand-ins")
        return False
    mw[].core.page = ('<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="/mojoui.css">'
                      + '<style id="mojoui-theme"></style>'
                      + "<style>html, body { margin: 0 !important; padding: 0 !important; min-height: 0 !important; display: block !important;"
                      + " background: transparent !important; overflow: hidden; } #mojoui-root { padding: 0; margin: 0; width: 100%; max-width: none; display: block; }</style>"
                      + links + '<script src="/mojoui-widgets.js"></script>' + scripts + '</head><body><div id="mojoui-root"></div></body></html>')
    # One delegate object for every view: it answers mojoui:// requests, takes the pages' messages, decides navigations
    var c = cls("MojoWebDelegate")
    if c == 0:
        c = new_class("MojoWebDelegate", "NSObject")
        add_method(c, "webView:startURLSchemeTask:", on_scheme_start, "v@:@@")
        add_method(c, "webView:stopURLSchemeTask:", on_scheme_stop, "v@:@@")
        add_method(c, "userContentController:didReceiveScriptMessage:", on_script_message, "v@:@@")
        add_method(c, "webView:decidePolicyForNavigationAction:decisionHandler:", on_decide_policy, "v@:@@@?")
        add_method(c, "webView:didFinishNavigation:", on_did_finish, "v@:@@")
        add_method(c, "webViewWebContentProcessDidTerminate:", on_terminated, "v@:@")
        add_method(c, "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", on_new_window, "@@:@@@@")
        for p in ["WKURLSchemeHandler", "WKScriptMessageHandler", "WKNavigationDelegate", "WKUIDelegate"]:
            if protocol(p) != 0:  # (a protocol no class in the process names may have no runtime object: WebKit asks by selector)
                add_protocol(c, p)
        register_class(c)
    mw[].delegate = msg(c, "new")
    mw[].send_block = data_block(on_send_done, "v@?@@", addr)
    mw[].probe_block = data_block(on_probe_done, "v@?@@", addr)
    mw[].rules_block = data_block(on_rules_ready, "v@?@@", addr)
    var store = msg(cls("WKContentRuleListStore"), "defaultStore")
    if store != 0:
        _ = msg(store, "compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:", ns_string("mojoui-widgets"), ns_string(RULES), mw[].rules_block)
    else:
        mw[].rules_state = -1
    mw[].core.state = 1
    return True


def new_view(addr: Int, tag: String, id: Int) -> Int:
    """A WKWebView for widget (tag, id), its page loading (once the rule list is ready); its slot is added. Returns the
    slot's index."""
    var mw = mac_at(addr)
    var config = msg(msg(cls("WKWebViewConfiguration"), "new"), "autorelease")
    _ = msg(config, "setURLSchemeHandler:forURLScheme:", mw[].delegate, ns_string(SCHEME))
    _ = msg(config, "setWebsiteDataStore:", msg(cls("WKWebsiteDataStore"), "nonPersistentDataStore"))  # (nothing on disk)
    var prefs = msg(config, "preferences")
    _ = msg(prefs, "setJavaScriptCanOpenWindowsAutomatically:", 0)
    var ucc = msg(config, "userContentController")
    _ = msg(ucc, "addScriptMessageHandler:name:", mw[].delegate, ns_string("mojoui"))
    var view = msg(msg(cls("WKWebView"), "alloc"), "initWithFrame:configuration:", Float64(0), Float64(0), Float64(100), Float64(1), config)
    _ = msg(view, "setIdentifier:", ns_string(String(addr)))  # (the delegate's callbacks find this struct by it)
    _ = msg(view, "setNavigationDelegate:", mw[].delegate)
    _ = msg(view, "setUIDelegate:", mw[].delegate)
    _ = msg(view, "setTranslatesAutoresizingMaskIntoConstraints:", 0)
    comptime if DEVTOOLS:  # (debug builds only: Safari's Develop menu can inspect the widget, macOS 13.3+; release never)
        if (msg(view, "respondsToSelector:", sel("setInspectable:")) & 0xFF) != 0:
            _ = msg(view, "setInspectable:", 1)
    if (msg(view, "respondsToSelector:", sel("_setDrawsBackground:")) & 0xFF) != 0:  # (transparent: the card shows through, as on the web)
        _ = msg(view, "_setDrawsBackground:", 0)
    var tall = msg(msg(view, "heightAnchor"), "constraintEqualToConstant:", Float64(1))
    _ = msg(tall, "setActive:", 1)
    mw[].heights.append((view, tall))
    mw[].core.slots.append(WebSlot(tag, id, view, ucc))
    if mw[].rules_state == 0:
        mw[].waiting.append(view)
    else:
        load(addr, view)
    return len(mw[].core.slots) - 1


def load(addr: Int, view: Int):
    var mw = mac_at(addr)
    if mw[].rules != 0:
        _ = msg(msg(msg(view, "configuration"), "userContentController"), "addContentRuleList:", mw[].rules)
    var url = msg(cls("NSURL"), "URLWithString:", ns_string(PAGE_URI))
    _ = msg(view, "loadRequest:", msg(cls("NSURLRequest"), "requestWithURL:", url))


def send(addr: Int, k: Int, message: String):
    """Hands the page of slot k one message (JSON text), now or once it has loaded."""
    var mw = mac_at(addr)
    if message.startswith('{"theme":'):
        mw[].core.slots[k].sent_theme = message
    elif message.startswith('{"widget":'):
        mw[].core.slots[k].sent_widget = message
    if mw[].core.slots[k].gone:
        return
    if not mw[].core.slots[k].loaded:
        mw[].core.slots[k].pending.append(message)
        return
    call(mw[].core.slots[k].view, "return mojoui.native.receive(m)", message, mw[].send_block)


def call(view: Int, body: String, message: String, block: Int):
    """Runs `body` in the view's page as a function whose argument m is `message` (a string: data, never code)."""
    var args = msg(cls("NSDictionary"), "dictionaryWithObject:forKey:", ns_string(message), ns_string("m"))
    _ = msg(view, "callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:", ns_string(body), args, 0,
            msg(cls("WKContentWorld"), "pageWorld"), block)


def drop(addr: Int, k: Int):
    """Slot k's widget left the screen: its view goes (the page's widget is destroyed with it)."""
    var mw = mac_at(addr)
    var view = mw[].core.slots[k].view
    _ = msg(view, "removeFromSuperview")
    _ = msg(msg(msg(view, "configuration"), "userContentController"), "removeScriptMessageHandlerForName:", ns_string("mojoui"))
    for q in range(len(mw[].heights)):
        if mw[].heights[q][0] == view:
            _ = mw[].heights.pop(q)
            break
    for q in range(len(mw[].images)):
        if mw[].images[q][0] == view:
            _ = msg(mw[].images[q][1], "release")
            _ = mw[].images.pop(q)
            break
    _ = msg(view, "setNavigationDelegate:", 0)
    _ = msg(view, "setUIDelegate:", 0)
    _ = msg(view, "release")
    _ = mw[].core.slots.pop(k)


def show_instead(view: Int):
    """The view hides and its box's other views (the WebComponent's `instead` view) show."""
    _ = msg(view, "setHidden:", 1)
    var box = msg(view, "superview")
    if box == 0 or not is_kind(box, "NSStackView"):
        return
    var views = msg(box, "arrangedSubviews")
    for j in range(msg(views, "count")):
        var v = msg(views, "objectAtIndex:", j)
        if v != view:
            _ = msg(v, "setHidden:", 0)


def instead_shows(view: Int) -> Bool:
    var box = msg(view, "superview")
    if box == 0 or not is_kind(box, "NSStackView"):
        return False
    var views = msg(box, "arrangedSubviews")
    for j in range(msg(views, "count")):
        var v = msg(views, "objectAtIndex:", j)
        if v != view and (msg(v, "isHidden") & 0xFF) == 0:
            return True
    return False


def set_height(addr: Int, view: Int, h: Int):
    var mw = mac_at(addr)
    for q in mw[].heights:
        if q[0] == view:
            _ = msg(q[1], "setConstant:", Float64(max(h, 1)))


def arm_inbox(addr: Int):
    """update() hears the inbox on the next run-loop turn (never inside WebKit's callback)."""
    var mw = mac_at(addr)
    if mw[].core.armed or mw[].target == 0:
        return
    mw[].core.armed = True
    _ = msg(mw[].target, "performSelector:withObject:afterDelay:", sel("webInbox:"), ns_number(mw[].host_addr), Float64(0))


def report_lines(addr: Int) -> String:
    """Each view as the host saw it and the widget's own line (GTK's WEBVIEW:/WIDGET: lines; instead=1: its stand-in shows)."""
    var mw = mac_at(addr)
    var out = String("")
    for ref slot in mw[].core.slots:
        var ready = slot.loaded and slot.mounts >= 1
        var state = " gone" if slot.gone else (" ready" if ready else " loading")
        out += ("WEBVIEW: " + slot.key() + state + " mounts=" + String(slot.mounts) + " csp=" + String(slot.csp)
                + " refused=" + String(slot.refused) + " blocked=" + String(slot.blocked) + " h=" + String(slot.height)
                + " crashes=" + String(slot.crashes) + " instead=" + ("1" if instead_shows(slot.view) else "0") + "\n")
        out += "WIDGET: " + slot.key() + ": " + slot.describe + "\n"
        var inspectable = (msg(slot.view, "respondsToSelector:", sel("isInspectable")) & 0xFF) != 0 and (msg(slot.view, "isInspectable") & 0xFF) != 0
        out += "WEBINSPECT: " + slot.key() + " " + ("1" if inspectable else "0") + "\n"  # (debug builds only, D-664's hook)
    out += "WIDGETFACTS: " + facts_of(mw[].core) + "\n"  # (what an agent reads: describe()'s JSON and the fields, M0)
    return out


# ---------- test steps (MOJOUI_TEST): probes, real clicks and keys, a crash ----------

def probe(addr: Int, k: Int, expression: String):
    """(webjs:) Evaluates `expression` in slot k's page; its value (awaited) lands in probe_result as JSON."""
    var mw = mac_at(addr)
    mw[].core.probe_done = False
    mw[].core.probe_result = ""
    mw[].busy = True
    call(mw[].core.slots[k].view, "return (" + expression + ")", "null", mw[].probe_block)


def view_point(view: Int, x: Float64, y_from_top: Float64) -> CGPoint:
    """A point in the view (y counted from its top, as the page counts) in its window's coordinates."""
    var b = msg[CGRect](view, "bounds")
    var y = y_from_top if (msg(view, "isFlipped") & 0xFF) != 0 else b.height - y_from_top
    return msg[CGPoint](view, "convertPoint:toView:", x, y, 0)


def uptime() -> Float64:
    return msg[Float64](msg(cls("NSProcessInfo"), "processInfo"), "systemUptime")


def click_at(view: Int, x: Float64, y_from_top: Float64):
    """A real left click (mouse down, then up) at that point of the view, through its window (as the person's would)."""
    var window = msg(view, "window")
    if window == 0:
        return
    var p = view_point(view, x, y_from_top)
    var number = msg(window, "windowNumber")
    for kind in [1, 2]:  # NSEventTypeLeftMouseDown, LeftMouseUp
        var e = msg(cls("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:",
                    kind, p.x, p.y, 0, uptime(), number, 0, 0, 1, Float32(1.0 if kind == 1 else 0.0))
        _ = msg(window, "sendEvent:", e)


def key_code(c: String) -> Int:
    """The US keyboard's key for a letter or a space (what a real key event carries beside its characters)."""
    var letters = "asdfhgzxcv bqweryt"
    if c == " ":
        return 49
    var codes: List[Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, -1, 11, 12, 13, 14, 15, 16, 17]
    var at = letters.find(c)
    if at >= 0 and codes[at] >= 0:
        return codes[at]
    var more: List[Tuple[String, Int]] = [("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46)]
    for m in more:
        if m[0] == c:
            return m[1]
    return 0


def type_text(addr: Int, k: Int, text: String):
    """(webtype:) Clicks into slot k's view near its top left, then types `text` as real key events (down and up for
    each character) through the window, as a person's typing reaches the page."""
    var mw = mac_at(addr)
    var view = mw[].core.slots[k].view
    var window = msg(view, "window")
    if window == 0:
        print("mojoui: webtype: the view isn't in a window")
        return
    _ = msg(msg(cls("NSApplication"), "sharedApplication"), "activateIgnoringOtherApps:", 1)
    _ = msg(window, "makeKeyAndOrderFront:", 0)
    var b = msg[CGRect](view, "bounds")
    click_at(view, min(Float64(40), b.width / 2), min(Float64(16), b.height / 2))
    _ = msg(window, "makeFirstResponder:", view)
    var p = view_point(view, Float64(10), Float64(10))
    var number = msg(window, "windowNumber")
    for ch in text.codepoint_slices():
        var c = String(ch)
        var s = ns_string(c)
        for kind in [10, 11]:  # NSEventTypeKeyDown, KeyUp
            var e = msg(cls("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:",
                        kind, p.x, p.y, 0, uptime(), number, 0, s, s, 0, key_code(c))
            _ = msg(window, "sendEvent:", e)


def click(addr: Int, k: Int, selector: String):
    """(webclick:) A real click at the middle of the first element matching `selector` (CSS) in slot k's page: the
    page says where it is (the selector goes in as data), then the click goes through the window."""
    var mw = mac_at(addr)
    var view = mw[].core.slots[k].view
    mw[].busy = True
    var block = data_block(on_click_place, "v@?@@", view)  # (one per click: it carries the view; test runs only)
    call(view, "const e = document.querySelector(m); if (!e) return null; const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2];",
         selector, block)


def kill(addr: Int, k: Int):
    """(webkill:) Ends slot k's web content process (SIGKILL), as a crash would."""
    var mw = mac_at(addr)
    var view = mw[].core.slots[k].view
    if (msg(view, "respondsToSelector:", sel("_webProcessIdentifier")) & 0xFF) == 0:
        print("mojoui: webkill: this WebKit doesn't say its web process")
        return
    var pid = msg[c_int](view, "_webProcessIdentifier")
    mw[].kill_view = view
    mw[].kill_crashes = mw[].core.slots[k].crashes
    if Int(pid) > 0:
        _ = cfunc[c_int]("kill", pid, c_int(9))


def step_busy(addr: Int) -> Bool:
    """(test steps) A probe, a click or a crash's reload is still under way: the next step waits."""
    var mw = mac_at(addr)
    if mw[].busy:
        return True
    if mw[].kill_view != 0:
        for ref s in mw[].core.slots:
            if s.view == mw[].kill_view:
                if s.gone or (s.crashes > mw[].kill_crashes and s.loaded and s.mounts >= 1):
                    mw[].kill_view = 0
                    return False
                return True
        mw[].kill_view = 0
    return False


def pages_ready(addr: Int) -> Bool:
    """Every view's page loaded, its widget mounted and measured (or given up)."""
    var mw = mac_at(addr)
    for ref s in mw[].core.slots:
        if not s.gone and (not s.loaded or s.mounts < 1 or s.height < 0):
            return False
    return True


# ---------- the report's pictures: a WKWebView draws out of process, so each is pictured by WebKit and drawn in ----------

def shoot(addr: Int) -> Int:
    """Asks every shown view for its picture; the last answer queues the report's snapshot again. Returns how many."""
    var mw = mac_at(addr)
    if mw[].core.state != 1:
        return 0
    var n = 0
    for ref s in mw[].core.slots:
        if s.loaded and not s.gone and msg(s.view, "window") != 0 and (msg(s.view, "isHiddenOrHasHiddenAncestor") & 0xFF) == 0:
            n += 1
    mw[].shots_waiting = n
    for ref s in mw[].core.slots:
        if s.loaded and not s.gone and msg(s.view, "window") != 0 and (msg(s.view, "isHiddenOrHasHiddenAncestor") & 0xFF) == 0:
            _ = msg(s.view, "takeSnapshotWithConfiguration:completionHandler:", 0, data_block(on_shot, "v@?@@", s.view))
    return n


def paint_shots(addr: Int, rep: Int, root: Int):
    """Draws each view's last picture where the view is, into a picture of `root` (a bitmap made by cacheDisplayInRect:)."""
    if addr == 0:
        return
    var mw = mac_at(addr)
    if len(mw[].images) == 0:
        return
    var ctx = msg(cls("NSGraphicsContext"), "graphicsContextWithBitmapImageRep:", rep)
    if ctx == 0:
        return
    _ = msg(cls("NSGraphicsContext"), "saveGraphicsState")
    _ = msg(cls("NSGraphicsContext"), "setCurrentContext:", ctx)
    var rb = msg[CGRect](root, "bounds")
    for q in mw[].images:
        var view = q[0]
        if (msg(view, "isHiddenOrHasHiddenAncestor") & 0xFF) != 0 or (msg(view, "isDescendantOf:", root) & 0xFF) == 0:
            continue
        var b = msg[CGRect](view, "bounds")
        var r = msg[CGRect](view, "convertRect:toView:", b.x, b.y, b.width, b.height, root)
        var y = (rb.height - (r.y - rb.y + r.height)) if (msg(root, "isFlipped") & 0xFF) != 0 else r.y - rb.y
        _ = msg(q[1], "drawInRect:", r.x - rb.x, y, r.width, r.height)
    _ = msg(cls("NSGraphicsContext"), "restoreGraphicsState")


# ---------- WebKit's callbacks ----------

def respond(task: Int, url: Int, data: Int, media: String):
    """Answers a mojoui:// request with `data` (NSData) and the web's security headers."""
    var headers = msg(cls("NSMutableDictionary"), "dictionary")
    var names: List[String] = ["Content-Type", "Content-Security-Policy", "X-Content-Type-Options", "Referrer-Policy", "Cache-Control"]
    var values: List[String] = [media, String(CSP), "nosniff", "same-origin", "no-store"]
    for i in range(len(names)):
        _ = msg(headers, "setObject:forKey:", ns_string(values[i]), ns_string(names[i]))
    var resp = msg(msg(msg(cls("NSHTTPURLResponse"), "alloc"), "initWithURL:statusCode:HTTPVersion:headerFields:", url, 200, ns_string("HTTP/1.1"), headers), "autorelease")
    _ = msg(task, "didReceiveResponse:", resp)
    _ = msg(task, "didReceiveData:", data)
    _ = msg(task, "didFinish")


def refuse(task: Int, why: String):
    var info = msg(cls("NSDictionary"), "dictionaryWithObject:forKey:", ns_string(why), ns_string("NSLocalizedDescription"))
    _ = msg(task, "didFailWithError:", msg(cls("NSError"), "errorWithDomain:code:userInfo:", ns_string("mojoui"), 404, info))


def on_scheme_start(obj: Int, cmd: Int, view: Int, task: Int) abi("C"):
    """mojoui://app/<path>: the page, the runtime, the host's sheet, a listed bundle, an app font; anything else fails."""
    var addr = mac_of(view)
    if addr == 0:
        refuse(task, "no such view")
        return
    var mw = mac_at(addr)
    var url = msg(msg(task, "request"), "URL")
    var uri = from_ns(msg(url, "absoluteString"))
    var path = from_ns(msg(url, "path"))
    if not uri.startswith("mojoui://app/"):
        refuse(task, "not this app's origin")
        return
    var file = String("")
    var media = String("")
    if path == "/widget.html":
        respond(task, url, msg(ns_string(mw[].core.page), "dataUsingEncoding:", UTF8), "text/html; charset=utf-8")
        return
    elif path == "/mojoui-widgets.js" or path == "/mojoui.css":
        file = mw[].core.dir + path
        media = "text/javascript" if path.endswith(".js") else "text/css"
    elif path.startswith("/assets/"):
        var name = String(path[byte=8:])
        for f in mw[].core.files:
            if f == name:
                file = mw[].core.dir + "/assets/" + name
                media = "application/json" if name.endswith(".map") else ("text/javascript" if name.endswith(".js") else "text/css")
    elif path.startswith("/static/fonts/"):
        var name = String(path[byte=14:])
        for f in fonts():
            if f == name:
                file = mw[].core.fonts_dir + "/" + name
                media = "font/ttf"
    if file == "":
        refuse(task, "not in the bundle")
        return
    var data = msg(cls("NSData"), "dataWithContentsOfFile:", ns_string(file))
    if data == 0:
        refuse(task, "missing")
        return
    respond(task, url, data, media)


def on_scheme_stop(obj: Int, cmd: Int, view: Int, task: Int) abi("C"):
    pass  # (every request is answered at once: nothing to stop)


def on_script_message(obj: Int, cmd: Int, ucc: Int, message: Int) abi("C"):
    """A page's message (the "mojoui" message handler): from the main frame, a string, checked by take_text."""
    var view = msg(message, "webView")
    var addr = mac_of(view)
    if addr == 0:
        return
    var mw = mac_at(addr)
    var k = mw[].core.slot_by(view)
    if k < 0:
        return
    var body = msg(message, "body")
    var frame = msg(message, "frameInfo")
    if not is_kind(body, "NSString") or frame == 0 or (msg(frame, "isMainFrame") & 0xFF) == 0:
        mw[].core.slots[k].refused += 1
        return
    var took = take_text(mw[].core, k, from_ns(body))  # (GTK's rules, one function: D-661's debt paid, D-672)
    if took == TOOK_SIZE:
        set_height(addr, view, mw[].core.slots[k].height)
    elif took == TOOK_INBOX:
        arm_inbox(addr)


def on_decide_policy(obj: Int, cmd: Int, view: Int, action: Int, handler: Int) abi("C"):
    """Only the widget's own page loads in its view, in its main frame: other navigations and new windows are refused."""
    var uri = from_ns(msg(msg(msg(action, "request"), "URL"), "absoluteString"))
    var frame = msg(action, "targetFrame")
    var allow = uri == PAGE_URI and frame != 0 and (msg(frame, "isMainFrame") & 0xFF) != 0
    call_block(handler, 1 if allow else 0)  # WKNavigationActionPolicyAllow, Cancel
    if not allow:
        var addr = mac_of(view)
        if addr != 0:
            var k = mac_at(addr)[].core.slot_by(view)
            if k >= 0:
                mac_at(addr)[].core.slots[k].blocked += 1


def on_new_window(obj: Int, cmd: Int, view: Int, config: Int, action: Int, features: Int) abi("C") -> Int:
    var addr = mac_of(view)
    if addr != 0:
        var k = mac_at(addr)[].core.slot_by(view)
        if k >= 0:
            mac_at(addr)[].core.slots[k].blocked += 1
    return 0  # (no new window)


def on_did_finish(obj: Int, cmd: Int, view: Int, navigation: Int) abi("C"):
    var addr = mac_of(view)
    if addr == 0:
        return
    var mw = mac_at(addr)
    var k = mw[].core.slot_by(view)
    if k < 0 or mw[].core.slots[k].loaded:
        return
    mw[].core.slots[k].loaded = True
    var waiting = mw[].core.slots[k].pending.copy()
    mw[].core.slots[k].pending = List[String]()
    for m in waiting:
        call(view, "return mojoui.native.receive(m)", m, mw[].send_block)


def on_terminated(obj: Int, cmd: Int, view: Int) abi("C"):
    """Its web content process ended (a crash, memory, or a kill): the first time the page loads again and the widget
    mounts afresh with Mojo's props and theme (its own state is lost); the second time the WebComponent shows its
    `instead` view for good (D-621, as on GTK)."""
    var addr = mac_of(view)
    if addr == 0:
        return
    var mw = mac_at(addr)
    var k = mw[].core.slot_by(view)
    if k < 0:
        return
    mw[].core.slots[k].crashes += 1
    mw[].core.slots[k].loaded = False
    mw[].core.slots[k].mounts = 0
    mw[].core.slots[k].describe = ""
    print("mojoui: " + mw[].core.slots[k].key() + "'s web process ended" + ("; loading it again" if mw[].core.slots[k].crashes == 1 else "; showing its stand-in"))
    if mw[].core.slots[k].crashes == 1:
        var again = List[String]()
        if mw[].core.slots[k].sent_theme != "":
            again.append(mw[].core.slots[k].sent_theme)
        if mw[].core.slots[k].sent_widget != "":
            again.append(mw[].core.slots[k].sent_widget)
        mw[].core.slots[k].pending = again^  # (commands sent to the old page are lost with it: their replies never come)
        _ = msg(view, "reload")
    else:
        mw[].core.slots[k].gone = True
        show_instead(view)


def on_send_done(block: Int, result: Int, error: Int) abi("C"):
    if error != 0:
        print("mojoui: a call into a widget's page failed: " + from_ns(msg(error, "localizedDescription")))


def on_probe_done(block: Int, result: Int, error: Int) abi("C"):
    var mw = mac_at(block_data(block))
    mw[].core.probe_result = json_of(result) if error == 0 else json_string("error: " + from_ns(msg(error, "localizedDescription")))
    mw[].core.probe_done = True
    mw[].busy = False


def on_click_place(block: Int, result: Int, error: Int) abi("C"):
    var view = block_data(block)
    var addr = mac_of(view)
    if addr == 0:
        return
    if error == 0 and is_kind(result, "NSArray") and msg(result, "count") == 2:
        var x = msg[Float64](msg(result, "objectAtIndex:", 0), "doubleValue")
        var y = msg[Float64](msg(result, "objectAtIndex:", 1), "doubleValue")
        click_at(view, x, y)
    else:
        print("mojoui: webclick: no such element in the page")
    mac_at(addr)[].busy = False


def on_rules_ready(block: Int, rules: Int, error: Int) abi("C"):
    var addr = block_data(block)
    var mw = mac_at(addr)
    if rules != 0:
        mw[].rules = msg(rules, "retain")
        mw[].rules_state = 1
    else:
        mw[].rules_state = -1
        print("mojoui: the web views' rule list didn't compile (" + (from_ns(msg(error, "localizedDescription")) if error != 0 else String("no reason")) + "): the CSP alone keeps them offline")
    var waiting = mw[].waiting.copy()
    mw[].waiting = List[Int]()
    for v in waiting:
        load(addr, v)


def on_shot(block: Int, image: Int, error: Int) abi("C"):
    var view = block_data(block)
    var addr = mac_of(view)
    if addr == 0:
        return
    var mw = mac_at(addr)
    if image != 0:
        var kept = False
        for q in range(len(mw[].images)):
            if mw[].images[q][0] == view:
                _ = msg(mw[].images[q][1], "release")
                mw[].images[q] = (view, msg(image, "retain"))
                kept = True
        if not kept:
            mw[].images.append((view, msg(image, "retain")))
    mw[].shots_waiting -= 1
    if mw[].shots_waiting == 0 and mw[].target != 0:
        _ = msg(mw[].target, "performSelector:withObject:afterDelay:", sel("debugQueued:"), ns_number(mw[].host_addr), Float64(0))
