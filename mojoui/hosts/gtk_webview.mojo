# mojoui.hosts.gtk_webview: a WebComponent on GTK (goal 34 M3). Each widget gets a WebKitGTK 6.0 view of its own that
# loads the app's own bundles (scripts/web_assets.py --webview: the web's files, byte for byte) and the web host's widget
# runtime (mojoui-widgets.js) from a local origin, mojoui://app/, with the web's CSP. Nothing else: no network (an
# ephemeral session behind a proxy that answers nothing, and the CSP), no file access (the origin serves a fixed list
# of files), no navigation away and no new windows (decide-policy).
#
# Across the seam only JSON text travels. Mojo → page: one function call, `mojoui.native.receive(m)`, with the message
# as its argument (a GVariant string: never code); page → Mojo: the script message handler "mojoui", whose message must
# be a string holding a JSON object naming this view's own widget. The host (gtk.mojo) keeps each view across rebuilds
# by its key (tag, id), as the web does: a new screen moves the live view into the new box; it is never loaded again.
#
# WebKitGTK is loaded when the first WebComponent shows (dlopen): apps without one never need it, and a machine without
# it shows the WebComponent's `instead` view (and says so once). scripts/webkitgtk.sh and scripts/build.sh provide it
# where the distribution's package isn't installed (D-608).

from std.ffi import external_call, c_int, c_char, c_uint
from std.memory import Pointer

from mojoui.json import Json, json_string
from mojoui.webcomponent import is_widget_tag, is_event_name
from mojoui.theme import Theme, palette_css, tokens_css, theme_tokens
from mojoui.look import look_web_css
from mojoui.hosts.devtools import DEVTOOLS

comptime RTLD_NOW = 2
comptime RTLD_GLOBAL = 256
comptime PAGE_URI = "mojoui://app/widget.html"
comptime SCHEME = "mojoui"
comptime MAX_MESSAGE = 1 << 20  # bytes: a message from the page past this is refused
comptime MAX_JSLOGS = 100  # widget errors logged per window (the web host logs 100 per page, D-681)
# The web host's CSP (mojoui/hosts/web.py), with frame-src 'none': a widget's view frames nothing.
comptime CSP = ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; "
                + "connect-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'self'")
comptime POLICY_NAVIGATION = 0
comptime POLICY_NEW_WINDOW = 1
comptime LOAD_FINISHED = 3
comptime PROXY_CUSTOM = 2
comptime HEADERS_RESPONSE = 1  # SOUP_MESSAGE_HEADERS_RESPONSE
comptime IN_EVENT = 0
comptime IN_REPLY = 1


def wk[T: RegisterPassable = Int, *A: AnyType](name: String, *args: *A) -> T:
    """Calls a WebKitGTK (or GLib) function found at run time (WebKitGTK is dlopen'd, so it can't be linked)."""
    var n = name
    var addr = external_call["dlsym", Int](0, n.as_c_string_span())
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr)
    var f = Pointer(to=raw).unsafe_bitcast[def(*a: *A) thin abi("C") -> T]()[]
    return f(*args)


def wk_connect[F: AnyType](obj: Int, signal: String, callback: F, data: Int):
    var s = signal
    _ = wk("g_signal_connect_data", obj, s.as_c_string_span(), callback, data, 0, 0)


def cstr(addr: Int) -> String:
    if addr == 0:
        return ""
    return String(unsafe_from_utf8_ptr=Pointer[c_char, MutUntrackedOrigin](unsafe_from_address=addr))


def word_at(addr: Int) -> Int:
    return Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr)[]


def error_text(err: Int) -> String:
    """A GError's message (GError: domain, code, then the message's address) and the error freed."""
    if err == 0:
        return ""
    var text = cstr(word_at(err + 8))
    external_call["g_error_free", NoneType](err)
    return text


def g_free_fn() -> Int:
    var n = String("g_free")
    return external_call["dlsym", Int](0, n.as_c_string_span())


def read_file(path: String) -> Tuple[Int, Int]:
    """The file's bytes in GLib memory (address, length; the caller frees them with g_free), or (0, 0)."""
    var out = List[Int](length=2, fill=0)  # (contents, length: C writes them; the list stays alive past the call)
    var p = path
    var ok = external_call["g_file_get_contents", c_int](p.as_c_string_span(), Int(out.unsafe_ptr()), Int(out.unsafe_ptr()) + 8, 0)
    var got = (out[0], out[1]) if ok != 0 else (0, 0)
    _ = len(out)
    return got


def file_text(path: String) -> String:
    var f = read_file(path)
    if f[0] == 0:
        return ""
    var text = cstr(f[0])
    external_call["g_free", NoneType](f[0])
    return text


def plain_file(s: String) -> Bool:
    """A bundler's file name (name.<hash>.js): letters, digits, - _ and single dots, not starting with a dot: no folder,
    no "..", nothing an HTML attribute or a path could read differently (D-620)."""
    if s.byte_length() == 0 or s.byte_length() > 200 or s.startswith(".") or ".." in s:
        return False
    for b in s.as_bytes():
        var c = Int(b)
        var ok = (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c == 45 or c == 95 or c == 46
        if not ok:
            return False
    return True


def plain_sri(s: String) -> Bool:
    """An SRI hash as the bundler writes it: sha256-, sha384- or sha512- and base64 (letters, digits, + / =)."""
    var body = String("")
    for prefix in ["sha256-", "sha384-", "sha512-"]:
        if s.startswith(prefix):
            body = String(s[byte = prefix.byte_length() :])
    if body.byte_length() == 0 or body.byte_length() > 200:
        return False
    for b in body.as_bytes():
        var c = Int(b)
        var ok = (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c == 43 or c == 47 or c == 61
        if not ok:
            return False
    return True


def clip_error(text: String) -> String:
    """A reply's error, at most 500 bytes (as the web host's widget_reply), cut between characters."""
    if text.byte_length() <= 500:
        return text
    var out = String("")
    for c in text.codepoint_slices():
        if out.byte_length() + c.byte_length() > 500:
            break
        out += c
    return out


def fonts() -> List[String]:
    """The app's own fonts (beside the binary, as fonts/): the theme sheets name them as /static/fonts/<name>."""
    return ["Inter-Regular.ttf", "Inter-Medium.ttf", "Inter-SemiBold.ttf", "JetBrainsMono-Regular.ttf", "JetBrainsMono-Bold.ttf",
            "Geist-Variable.ttf", "GeistMono-Variable.ttf"]


def theme_message(t: Theme) -> String:
    """The app's theme for a widget's page, as the web page wears it: the body's classes, the palette, fonts and corners
    as --o-* variables, the theme's sheet (D-260), and the tokens (JSON data) for the widget's theme(el, tokens)."""
    var css = String("")
    if t.id != "":
        css = palette_css(t.palette) + tokens_css(t) + "\n" + t.web_css + look_web_css(t.look, "body." + t.id + " ")
    return '{"theme":{"classes":' + json_string(t.classes) + ',"css":' + json_string(css) + ',"tokens":' + theme_tokens(t) + "}}"


struct WebSlot(Copyable, Movable):
    """One WebComponent's view: its key (tag, id), the view and its message handler, and what it has been told."""

    var tag: String
    var id: Int
    var view: Int  # the WebKitWebView (one reference held here)
    var ucm: Int  # its WebKitUserContentManager (the "mojoui" message handler)
    var loaded: Bool  # the page finished loading: messages go straight in
    var pending: List[String]  # messages waiting for the page
    var props: String  # the props last sent
    var theme: String  # the theme key last sent
    var describe: String  # the widget's own line (describe()), and how many times it mounted, as the page said
    var mounts: Int
    var facts: String  # what the widget says about itself for agents (mojoui-widgets.js facts: a JSON object), "" until told
    var csp: Int  # CSP violations the page reported
    var refused: Int  # messages from the page the host refused
    var blocked: Int  # navigations and new windows refused
    var height: Int  # the widget's height in the page (the view's height), -1 until told
    var seen: Bool  # (sync: still on the screen)
    var crashes: Int  # times its web process ended: the first reloads the page (the widget mounts again with Mojo's
    var gone: Bool  # props and theme), the second gives up: the view hides and the WebComponent's `instead` shows
    var sent_theme: String  # the last theme and widget messages (what a reload sends again)
    var sent_widget: String

    def __init__(out self, tag: String, id: Int, view: Int, ucm: Int):
        self.tag = tag
        self.id = id
        self.view = view
        self.ucm = ucm
        self.loaded = False
        self.pending = List[String]()
        self.props = ""
        self.theme = ""
        self.describe = ""
        self.mounts = 0
        self.facts = ""
        self.csp = 0
        self.refused = 0
        self.blocked = 0
        self.height = -1
        self.seen = True
        self.crashes = 0
        self.gone = False
        self.sent_theme = ""
        self.sent_widget = ""

    def key(self) -> String:
        return self.tag + "#" + String(self.id)


struct Inbound(Copyable, Movable):
    """A message from a page for update(): a widget's event (kind IN_EVENT) or a command's reply (IN_REPLY)."""

    var kind: Int
    var tag: String
    var id: Int
    var name: String
    var data: String
    var seq: Int
    var error: String

    def __init__(out self, kind: Int, tag: String, id: Int, name: String, data: String, seq: Int, error: String):
        self.kind = kind
        self.tag = tag
        self.id = id
        self.name = name
        self.data = data
        self.seq = seq
        self.error = error


struct WebViews(Movable):
    """Every WebComponent view of the window (kept on the heap: WebKit's callbacks get its address)."""

    var state: Int  # 0: not tried yet, 1: WebKitGTK loaded, -1: not there (WebComponents show `instead`)
    var dir: String  # the build's webview/ folder (scripts/web_assets.py --webview)
    var fonts_dir: String
    var page: String  # widget.html: the host's style sheet, the runtime, the app's listed bundles (with SRI)
    var files: List[String]  # the bundle files the page may load (the listed ones in manifest.json)
    var session: Int  # one ephemeral network session for all views
    var slots: List[WebSlot]
    var inbox: List[Inbound]
    var armed: Bool  # an idle callback will hand the inbox to update()
    var probe_done: Bool  # (test steps: webjs's answer)
    var probe_result: String
    var sent: List[Tuple[Int, String, Int]]  # (seq, tag, id) of each command sent that wants a reply: who may answer it
    var tab_at: Int  # when Tab (or Shift+Tab) was last pressed in the window (µs, monotonic), and which way: a view the
    var tab_back: Bool  # keyboard enters right after focuses its first (or last) stop, as a page's own Tab would
    var tab_out: Int  # a page asked to pass the keyboard on (Tab past its last stop): 1 forward, 2 back, 0 none
    var tab_view: Int  # the view that asked
    var jslogs: Int  # widget errors the pages reported, and how many of them reached the log (MAX_JSLOGS at most, D-681)
    var jslogged: Int

    def __init__(out self):
        self.state = 0
        self.dir = ""
        self.fonts_dir = ""
        self.page = ""
        self.files = List[String]()
        self.session = 0
        self.slots = List[WebSlot]()
        self.inbox = List[Inbound]()
        self.armed = False
        self.probe_done = False
        self.probe_result = ""
        self.sent = List[Tuple[Int, String, Int]]()
        self.tab_at = 0
        self.tab_back = False
        self.tab_out = 0
        self.tab_view = 0
        self.jslogs = 0
        self.jslogged = 0

    def sent_to(mut self, seq: Int, tag: String, id: Int):
        """Command `seq` went to widget (tag, id): only its page may answer it (D-620)."""
        self.sent.append((seq, tag, id))
        while len(self.sent) > 256:  # (as the runtime forgets unanswered commands)
            _ = self.sent.pop(0)

    def answers(mut self, seq: Int, tag: String, id: Int) -> Bool:
        """Whether widget (tag, id) may answer command `seq` (once: the answer is taken)."""
        for k in range(len(self.sent)):
            if self.sent[k][0] == seq and self.sent[k][1] == tag and self.sent[k][2] == id:
                _ = self.sent.pop(k)
                return True
        return False

    def lose_commands(mut self, k: Int) -> Int:
        """Slot k's page is gone (its web process ended): every command sent to it that waits for a reply is answered
        now with an error, through the inbox as a page's reply is, so the runtime's waiting entries end (D-680). How many."""
        var lost = 0
        var i = 0
        while i < len(self.sent):
            if self.sent[i][1] == self.slots[k].tag and self.sent[i][2] == self.slots[k].id:
                self.inbox.append(Inbound(IN_REPLY, self.slots[k].tag, self.slots[k].id, "", "null", self.sent[i][0],
                                          "the widget's web process ended before it answered"))
                _ = self.sent.pop(i)
                lost += 1
            else:
                i += 1
        return lost

    def slot_of(self, tag: String, id: Int) -> Int:
        for k in range(len(self.slots)):
            if self.slots[k].tag == tag and self.slots[k].id == id:
                return k
        return -1

    def slot_by(self, obj: Int) -> Int:
        """The slot whose view or message handler `obj` is (-1: none)."""
        for k in range(len(self.slots)):
            if self.slots[k].view == obj or self.slots[k].ucm == obj:
                return k
        return -1


def webviews_at(addr: Int) -> Pointer[WebViews, MutUntrackedOrigin]:
    return Pointer[WebViews, MutUntrackedOrigin](unsafe_from_address=addr)


def start(addr: Int, assets: List[String]) -> Bool:
    """Loads WebKitGTK (once) and readies the origin: the page, the files it may load, the scheme. False: not there."""
    var wv = webviews_at(addr)
    if wv[].state != 0:
        return wv[].state == 1
    wv[].state = -1
    # JavaScriptCore stops threads with SIGUSR1 unless told otherwise, and that is the host's live-report signal
    # (scripts/live.py): in this process it gets SIGPWR (30) instead (read once, when WebKit starts; unset after, so the
    # web processes, which nobody signals, don't each complain about an option they don't know)
    var gc_name = String("JSC_SIGNAL_FOR_GC")
    var gc_sig = String("30")
    _ = external_call["setenv", c_int](gc_name.as_c_string_span(), gc_sig.as_c_string_span(), c_int(0))
    var lib = String("libwebkitgtk-6.0.so.4")
    if external_call["dlopen", Int](lib.as_c_string_span(), c_int(RTLD_NOW | RTLD_GLOBAL)) == 0:
        print("mojoui: WebKitGTK 6.0 didn't load (" + cstr(external_call["dlerror", Int]()) + "): WebComponents show their stand-ins (scripts/webkitgtk.sh)")
        return False
    var exe_link = String("/proc/self/exe")
    var exe = cstr(external_call["g_file_read_link", Int](exe_link.as_c_string_span(), 0))
    var slash = exe.rfind("/")
    var here = String(exe[byte=:slash]) if slash > 0 else String(".")
    var env_name = String("MOJOUI_WEBVIEW")
    var override = cstr(external_call["getenv", Int](env_name.as_c_string_span()))
    wv[].dir = override if override != "" else here + "/webview"
    wv[].fonts_dir = here + "/fonts"
    # The page: the host's sheet, the theme's (filled by the first message), the bundles App.web_assets() lists, by
    # their hashed names with SRI (manifest.json); the runtime before the bundles (they call mojoui.defineWidget).
    var links = String("")
    var scripts = String("")
    try:
        var j = Json.parse(file_text(wv[].dir + "/assets/manifest.json"))
        for name in assets:
            var e = j.get(0, name)
            var file = j.text(j.get(e, "file"))
            var sri = j.text(j.get(e, "integrity"))
            if e < 0 or not plain_file(file) or not plain_sri(sri):
                print("mojoui: web_assets() lists " + name + ", which isn't bundled in " + wv[].dir + "/assets (scripts/build.sh)")
                continue
            wv[].files.append(file)
            var map_file = j.text(j.get(e, "map"))
            if DEVTOOLS and map_file != "" and plain_file(map_file):  # (debug builds: its source map, for the page's error lines)
                wv[].files.append(map_file)
            if name.endswith(".css"):
                links += '<link rel="stylesheet" href="/assets/' + file + '" integrity="' + sri + '">'
            else:
                scripts += '<script src="/assets/' + file + '" integrity="' + sri + '"></script>'
    except e:
        print("mojoui: no bundles for the web views in " + wv[].dir + " (" + String(e) + "): WebComponents show their stand-ins")
        return False
    wv[].page = ('<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="/mojoui.css">'
                 + '<style id="mojoui-theme"></style>'
                 + "<style>html, body { margin: 0 !important; padding: 0 !important; min-height: 0 !important; display: block !important;"
                 + " background: transparent !important; overflow: hidden; } #mojoui-root { padding: 0; margin: 0; width: 100%; max-width: none; display: block; }</style>"
                 + links + '<script src="/mojoui-widgets.js"></script>' + scripts + '</head><body><div id="mojoui-root"></div></body></html>')
    var ctx = wk("webkit_web_context_get_default")
    _ = external_call["unsetenv", c_int](gc_name.as_c_string_span())
    var scheme = String(SCHEME)
    _ = wk("webkit_web_context_register_uri_scheme", ctx, scheme.as_c_string_span(), on_scheme_request, addr, 0)
    var sm = wk("webkit_web_context_get_security_manager", ctx)
    _ = wk("webkit_security_manager_register_uri_scheme_as_secure", sm, scheme.as_c_string_span())
    _ = wk("webkit_security_manager_register_uri_scheme_as_cors_enabled", sm, scheme.as_c_string_span())
    # No network: an ephemeral session (no cookies or cache on disk) whose every http(s) request goes to a proxy that
    # isn't there; the CSP already holds the page to its own origin
    wv[].session = wk("webkit_network_session_new_ephemeral")
    var proxy_uri = String("http://127.0.0.1:9")
    var proxy = wk("webkit_network_proxy_settings_new", proxy_uri.as_c_string_span(), 0)
    _ = wk("webkit_network_session_set_proxy_settings", wv[].session, c_int(PROXY_CUSTOM), proxy)
    _ = wk("webkit_network_proxy_settings_free", proxy)
    wv[].state = 1
    return True


def new_view[F: AnyType, G: AnyType](addr: Int, tag: String, id: Int, on_message: F, on_ended: G, host_addr: Int) -> Int:
    """A view for widget (tag, id), loading the page; its slot is added. Returns the slot's index. `on_ended` (the
    host's) runs after on_terminated when the web process ends: it hands the lost commands' error replies to update()."""
    var wv = webviews_at(addr)
    var settings = wk("webkit_settings_new")
    _ = wk("webkit_settings_set_enable_developer_extras", settings, c_int(1 if DEVTOOLS else 0))  # (debug builds only: WebKit's inspector)
    _ = wk("webkit_settings_set_javascript_can_open_windows_automatically", settings, c_int(0))
    _ = wk("webkit_settings_set_allow_file_access_from_file_urls", settings, c_int(0))
    _ = wk("webkit_settings_set_allow_universal_access_from_file_urls", settings, c_int(0))
    _ = wk("webkit_settings_set_allow_top_navigation_to_data_urls", settings, c_int(0))
    _ = wk("webkit_settings_set_enable_back_forward_navigation_gestures", settings, c_int(0))
    _ = wk("webkit_settings_set_enable_html5_database", settings, c_int(0))
    var trace = String("MOJOUI_TRACE")
    if cstr(external_call["getenv", Int](trace.as_c_string_span())) != "":
        _ = wk("webkit_settings_set_enable_write_console_messages_to_stdout", settings, c_int(1))
    var ucm = wk("webkit_user_content_manager_new")
    var handler = String("mojoui")
    _ = wk("webkit_user_content_manager_register_script_message_handler", ucm, handler.as_c_string_span(), 0)
    wk_connect(ucm, "script-message-received::mojoui", on_message, host_addr)
    var p_ucm = String("user-content-manager")
    var p_session = String("network-session")
    var p_settings = String("settings")
    var view = wk("g_object_new", wk("webkit_web_view_get_type"), p_ucm.as_c_string_span(), ucm, p_session.as_c_string_span(), wv[].session,
                  p_settings.as_c_string_span(), settings, 0)
    _ = wk("g_object_ref_sink", view)  # (the slot owns it: it outlives the boxes it moves between)
    external_call["g_object_unref", NoneType](settings)
    var clear = List[Float32](length=4, fill=0)  # (transparent: the card around it shows through, as on the web)
    _ = wk("webkit_web_view_set_background_color", view, Int(clear.unsafe_ptr()))
    _ = len(clear)
    var key = String("mojoui-webview")
    external_call["g_object_set_data", NoneType](view, key.as_c_string_span(), 1)
    external_call["gtk_widget_set_hexpand", NoneType](view, c_int(1))
    external_call["gtk_widget_set_size_request", NoneType](view, c_int(-1), c_int(1))
    wk_connect(view, "decide-policy", on_decide_policy, addr)
    wk_connect(view, "load-changed", on_load_changed, addr)
    wk_connect(view, "web-process-terminated", on_terminated, addr)
    wk_connect(view, "web-process-terminated", on_ended, host_addr)  # (after on_terminated: connected in this order)
    var focus = external_call["gtk_event_controller_focus_new", Int]()  # (Tab into the view: its first or last stop takes the keyboard)
    wk_connect(focus, "enter", on_view_focus_enter, addr)
    external_call["gtk_widget_add_controller", NoneType](view, focus)
    wv[].slots.append(WebSlot(tag, id, view, ucm))
    var uri = String(PAGE_URI)
    _ = wk("webkit_web_view_load_uri", view, uri.as_c_string_span())
    return len(wv[].slots) - 1


def send(addr: Int, k: Int, message: String):
    """Hands the page of slot k one message (JSON text), now or once it has loaded."""
    var wv = webviews_at(addr)
    if message.startswith('{"theme":'):
        wv[].slots[k].sent_theme = message
    elif message.startswith('{"widget":'):
        wv[].slots[k].sent_widget = message
    if wv[].slots[k].gone:
        return
    if not wv[].slots[k].loaded:
        wv[].slots[k].pending.append(message)
        return
    call(wv[].slots[k].view, "return mojoui.native.receive(m)", message, 0)


def call(view: Int, body: String, message: String, probe_addr: Int):
    """Runs `body` in the view's page as a function whose argument m is `message` (a string: data, never code)."""
    var dict = wk("g_variant_dict_new", 0)
    var m = String("m")
    var text = message
    _ = wk("g_variant_dict_insert_value", dict, m.as_c_string_span(), wk("g_variant_new_string", text.as_c_string_span()))
    var args = wk("g_variant_dict_end", dict)
    var b = body
    _ = wk("webkit_web_view_call_async_javascript_function", view, b.as_c_string_span(), -1, args, 0, 0, 0, on_call_done, probe_addr)
    _ = wk("g_variant_dict_unref", dict)


def probe(addr: Int, k: Int, expression: String):
    """(Test steps: webjs:) Evaluates `expression` in slot k's page; its value (awaited) lands in probe_result as JSON."""
    var wv = webviews_at(addr)
    wv[].probe_done = False
    wv[].probe_result = ""
    call(wv[].slots[k].view, "return (" + expression + ")", "null", addr)


def kill(addr: Int, k: Int):
    """(Test steps: webkill:) Ends slot k's web process, as a crash would."""
    _ = wk("webkit_web_view_terminate_web_process", webviews_at(addr)[].slots[k].view)


def drop(addr: Int, k: Int):
    """Slot k's widget left the screen: its view goes (the page's widget is destroyed with it)."""
    var wv = webviews_at(addr)
    var view = wv[].slots[k].view
    var parent = external_call["gtk_widget_get_parent", Int](view)
    if parent != 0:
        external_call["gtk_box_remove", NoneType](parent, view)
    external_call["g_object_unref", NoneType](wv[].slots[k].ucm)
    external_call["g_object_unref", NoneType](view)
    _ = wv[].slots.pop(k)


# ---------- WebKit's callbacks (data: the WebViews' address) ----------

def respond(request: Int, data: Int, length: Int, media: String):
    """Answers a mojoui:// request with `length` bytes at `data` (GLib memory, freed by the stream) and the web's
    security headers."""
    var stream = external_call["g_memory_input_stream_new_from_data", Int](data, length, g_free_fn())
    var resp = wk("webkit_uri_scheme_response_new", stream, length)
    var m = media
    _ = wk("webkit_uri_scheme_response_set_content_type", resp, m.as_c_string_span())
    var headers = wk("soup_message_headers_new", c_int(HEADERS_RESPONSE))
    var names: List[String] = ["Content-Type", "Content-Security-Policy", "X-Content-Type-Options", "Referrer-Policy", "Cache-Control"]
    var values: List[String] = [media, String(CSP), "nosniff", "same-origin", "no-store"]  # (the headers replace the response's own type)
    for i in range(len(names)):
        _ = wk("soup_message_headers_append", headers, names[i].as_c_string_span(), values[i].as_c_string_span())
    _ = wk("webkit_uri_scheme_response_set_http_headers", resp, headers)  # (it takes the headers)
    _ = wk("webkit_uri_scheme_request_finish_with_response", request, resp)
    external_call["g_object_unref", NoneType](resp)
    external_call["g_object_unref", NoneType](stream)


def refuse(request: Int, why: String):
    var domain = String("mojoui")
    var w = why
    var err = external_call["g_error_new_literal", Int](external_call["g_quark_from_string", c_uint](domain.as_c_string_span()), c_int(404), w.as_c_string_span())
    _ = wk("webkit_uri_scheme_request_finish_error", request, err)
    external_call["g_error_free", NoneType](err)


def on_scheme_request(request: Int, addr: Int) abi("C"):
    """mojoui://app/<path>: the page, the runtime, the host's sheet, a listed bundle, an app font; anything else 404."""
    var wv = webviews_at(addr)
    var uri = cstr(wk("webkit_uri_scheme_request_get_uri", request))
    var path = cstr(wk("webkit_uri_scheme_request_get_path", request))
    if not uri.startswith("mojoui://app/"):
        refuse(request, "not this app's origin")
        return
    var file = String("")
    var media = String("")
    if path == "/widget.html":
        var page = wv[].page
        var copy = external_call["g_strndup", Int](Int(page.unsafe_ptr()), page.byte_length())
        respond(request, copy, page.byte_length(), "text/html; charset=utf-8")
        _ = page.byte_length()
        return
    elif path == "/mojoui-widgets.js" or path == "/mojoui.css":
        file = wv[].dir + path
        media = "text/javascript" if path.endswith(".js") else "text/css"
    elif path.startswith("/assets/"):
        var name = String(path[byte=8:])
        for f in wv[].files:
            if f == name:
                file = wv[].dir + "/assets/" + name
                media = "application/json" if name.endswith(".map") else ("text/javascript" if name.endswith(".js") else "text/css")
    elif path.startswith("/static/fonts/"):
        var name = String(path[byte=14:])
        for f in fonts():
            if f == name:
                file = wv[].fonts_dir + "/" + name
                media = "font/ttf"
    if file == "":
        refuse(request, "not in the bundle")
        return
    var got = read_file(file)
    if got[0] == 0:
        refuse(request, "missing")
        return
    respond(request, got[0], got[1], media)


def on_decide_policy(view: Int, decision: Int, kind: c_int, addr: Int) abi("C") -> c_int:
    """Only the widget's own page loads in its view: other navigations and every new window are refused."""
    var wv = webviews_at(addr)
    var k = wv[].slot_by(view)
    if Int(kind) == POLICY_NAVIGATION or Int(kind) == POLICY_NEW_WINDOW:
        var action = wk("webkit_navigation_policy_decision_get_navigation_action", decision)
        var uri = cstr(wk("webkit_uri_request_get_uri", wk("webkit_navigation_action_get_request", action)))
        if Int(kind) == POLICY_NAVIGATION and uri == PAGE_URI:
            _ = wk("webkit_policy_decision_use", decision)
        else:
            _ = wk("webkit_policy_decision_ignore", decision)
            if k >= 0:
                wv[].slots[k].blocked += 1
        return 1
    return 0  # (responses: WebKit's own default, for the page's own files)


def on_load_changed(view: Int, event: c_int, addr: Int) abi("C"):
    if Int(event) != LOAD_FINISHED:
        return
    var wv = webviews_at(addr)
    var k = wv[].slot_by(view)
    if k < 0 or wv[].slots[k].loaded:
        return
    wv[].slots[k].loaded = True
    var waiting = wv[].slots[k].pending.copy()
    wv[].slots[k].pending = List[String]()
    for m in waiting:
        call(view, "return mojoui.native.receive(m)", m, 0)


def show_instead(view: Int):
    """The view hides and its box's other children (the WebComponent's `instead` view) show."""
    external_call["gtk_widget_set_visible", NoneType](view, c_int(0))
    var parent = external_call["gtk_widget_get_parent", Int](view)
    var c = external_call["gtk_widget_get_first_child", Int](parent) if parent != 0 else 0
    while c != 0:
        if c != view:
            external_call["gtk_widget_set_visible", NoneType](c, c_int(1))
        c = external_call["gtk_widget_get_next_sibling", Int](c)


def on_terminated(view: Int, reason: c_int, addr: Int) abi("C"):
    """Its web process ended (a crash, memory, or a kill): the first time the page loads again and the widget mounts
    afresh with Mojo's props and theme (its own state, a cursor or a count, is lost); the second time the WebComponent
    shows its `instead` view for good (D-621)."""
    var wv = webviews_at(addr)
    var k = wv[].slot_by(view)
    if k < 0:
        return
    wv[].slots[k].crashes += 1
    wv[].slots[k].loaded = False
    wv[].slots[k].mounts = 0
    wv[].slots[k].describe = ""
    wv[].slots[k].facts = ""
    var lost = wv[].lose_commands(k)  # (their replies would never come: each is answered with an error, D-680)
    print("mojoui: " + wv[].slots[k].key() + "'s web process ended (reason " + String(Int(reason)) + ")"
          + (", " + String(lost) + " command(s) answered with an error" if lost > 0 else "")
          + ("; loading it again" if wv[].slots[k].crashes == 1 else "; showing its stand-in"))
    if wv[].slots[k].crashes == 1:
        var again = List[String]()
        if wv[].slots[k].sent_theme != "":
            again.append(wv[].slots[k].sent_theme)
        if wv[].slots[k].sent_widget != "":
            again.append(wv[].slots[k].sent_widget)
        wv[].slots[k].pending = again^  # (commands sent to the old page went with it: answered above with an error)
        _ = wk("webkit_web_view_reload", view)
    else:
        wv[].slots[k].gone = True
        show_instead(view)


def on_call_done(view: Int, result: Int, probe_addr: Int) abi("C"):
    """A call into a page finished: its value is dropped, or (a test's probe) kept as JSON; failures are said."""
    var err = List[Int](length=1, fill=0)
    var value = wk("webkit_web_view_call_async_javascript_function_finish", view, result, Int(err.unsafe_ptr()))
    var why = error_text(err[0])
    _ = len(err)
    var json = String("null")
    if value != 0:
        var j = wk("jsc_value_to_json", value, c_uint(0))
        if j != 0:
            json = cstr(j)
            external_call["g_free", NoneType](j)
        external_call["g_object_unref", NoneType](value)
    if probe_addr != 0:
        var wv = webviews_at(probe_addr)
        wv[].probe_result = json if why == "" else json_string("error: " + why)
        wv[].probe_done = True
    elif why != "":
        print("mojoui: a call into a widget's page failed: " + why)


def on_view_focus_enter(controller: Int, addr: Int) abi("C"):
    """The keyboard entered a widget's view: right after a Tab (Shift+Tab) in the window, the page focuses its first
    (last) stop, so Tab order runs on through the widget as through the web page (goal 34b M1b). A click focuses where
    it lands, as WebKit does."""
    var wv = webviews_at(addr)
    var now = Int(external_call["g_get_monotonic_time", Int64]())
    if wv[].tab_at == 0 or now - wv[].tab_at > 400_000:
        return
    var k = wv[].slot_by(external_call["gtk_event_controller_get_widget", Int](controller))
    if k >= 0:
        send(addr, k, '{"focus":"' + ("last" if wv[].tab_back else "first") + '"}')


def clean(text: String, most: Int) -> String:
    """Text from a page for a log line: control characters as spaces, at most `most` bytes (whole characters)."""
    var out = String("")
    for c in text.codepoint_slices():
        if out.byte_length() + c.byte_length() > most:
            break
        out += " " if c.byte_length() == 1 and (Int(c.as_bytes()[0]) < 0x20 or Int(c.as_bytes()[0]) == 0x7f) else String(c)
    return out


def inspect(addr: Int, tag: String, id: Int) -> String:
    """Opens WebKit's inspector for widget (tag, id)'s view: debug builds only (DEVTOOLS); what happened, for the log."""
    comptime if not DEVTOOLS:
        return "unavailable (a release build: MOJOUI_DEBUG=1 scripts/build.sh <app> linux)"
    var wv = webviews_at(addr)
    var k = wv[].slot_of(tag, id) if wv[].state == 1 else -1
    if k < 0:
        return "no web view " + tag + "#" + String(id)
    var inspector = wk("webkit_web_view_get_inspector", wv[].slots[k].view)
    _ = wk("webkit_web_inspector_show", inspector)
    return "shown " + tag + "#" + String(id) if inspector != 0 else String("no inspector")


comptime TOOK_NOTHING = 0  # take_text's answers: kept here (a line, a CSP report) or refused
comptime TOOK_INBOX = 1  # an event or a reply waits for update()
comptime TOOK_SIZE = 2  # the widget's height changed (the host sizes its view)
comptime TOOK_TAB = 3  # the page passes the keyboard on (tab_out, tab_view)


def take_message(addr: Int, ucm: Int, value: Int) -> Bool:
    """The page's message (the script message handler): a JSC string, checked by take_text. True: something for the
    host's idle turn (an event or reply for update(), or the keyboard passed on)."""
    var wv = webviews_at(addr)
    var k = wv[].slot_by(ucm)
    if k < 0:
        return False
    if wk[c_int]("jsc_value_is_string", value) == 0:
        wv[].slots[k].refused += 1
        return False
    var raw = wk("jsc_value_to_string", value)
    var text = cstr(raw)
    external_call["g_free", NoneType](raw)
    var took = take_text(wv[], k, text)
    if took == TOOK_SIZE:
        external_call["gtk_widget_set_size_request", NoneType](wv[].slots[k].view, c_int(-1), c_int(max(wv[].slots[k].height, 1)))
    return took == TOOK_INBOX or took == TOOK_TAB


def take_text(mut wv: WebViews, k: Int, text: String) -> Int:
    """A page's message for slot k, by one set of rules on every host (GTK's take_message, the Mac's script message
    handler; D-611, D-620): JSON text naming this view's own widget. Events and replies go to the inbox for update()
    (TOOK_INBOX); the widget's height (TOOK_SIZE), its line and facts, CSP reports and errors are kept here; Tab past
    the page's ends asks the host to move the keyboard on (TOOK_TAB). Anything else is refused (counted)."""
    if text.byte_length() > MAX_MESSAGE:
        wv.slots[k].refused += 1
        return TOOK_NOTHING
    try:
        var j = Json.parse(text)
        var path = j.text(j.get(0, "path"))
        if path == "w":
            var tag = j.text(j.get(0, "tag"))
            var id = j.text(j.get(0, "id"))
            var name = j.text(j.get(0, "name"))
            var data = j.text(j.get(0, "data"))
            if tag != wv.slots[k].tag or id != String(wv.slots[k].id) or not is_event_name(name):
                raise Error("not this view's widget, or not an event's name")
            _ = Json.parse(data)  # (the payload is JSON, or refused)
            wv.inbox.append(Inbound(IN_EVENT, tag, wv.slots[k].id, name, data, 0, ""))
            return TOOK_INBOX
        elif path == "reply":
            var seq = j.get(0, "seq")
            var t = wv.slots[k].tag
            var i = wv.slots[k].id
            if not j.is_whole(seq) or not wv.answers(j.number(seq), t, i):
                raise Error("not a command this widget was sent")
            wv.inbox.append(Inbound(IN_REPLY, t, i, "", j.text(j.get(0, "data"), "null"), j.number(seq), clip_error(j.text(j.get(0, "error")))))
            return TOOK_INBOX
        elif path == "size":
            var h = j.number(j.get(0, "height"), -1)
            if h < 0 or h > 100000:
                raise Error("not a height")
            if h != wv.slots[k].height:
                wv.slots[k].height = h
                return TOOK_SIZE
        elif path == "describe":
            var facts = j.text(j.get(0, "facts"))
            if facts != "":  # (for agents: a JSON object naming this view's own widget, or refused)
                var f = Json.parse(facts)
                if f.text(f.get(0, "tag")) != wv.slots[k].tag or f.number(f.get(0, "id"), -1) != wv.slots[k].id:
                    raise Error("facts about another widget")
            wv.slots[k].describe = j.text(j.get(0, "text"))
            wv.slots[k].mounts = j.number(j.get(0, "mounts"))
            wv.slots[k].facts = facts
        elif path == "csp":
            wv.slots[k].csp += 1
        elif path == "jslog":  # a widget's uncaught error: one line in the app's log (its source file and line in debug builds)
            wv.jslogs += 1
            if wv.jslogged >= MAX_JSLOGS:  # (as the web host: at most 100 a page, here a window; the rest counted, not logged)
                if wv.jslogs == MAX_JSLOGS + 1:
                    print("mojoui: more than " + String(MAX_JSLOGS) + " widget errors: the rest aren't logged", flush=True)
                return TOOK_NOTHING
            wv.jslogged += 1
            var src = j.text(j.get(0, "source"))
            print("JS ERROR: " + (clean(src, 200) + ":" + String(j.number(j.get(0, "line"))) + ":" + String(j.number(j.get(0, "column"))) if src != "" else String("(no position)"))
                  + ": " + clean(j.text(j.get(0, "message")), 500) + " (" + wv.slots[k].key() + ")", flush=True)
        elif path == "tab":  # (Tab past the page's last stop, or Shift+Tab before its first: the host moves the keyboard on)
            wv.tab_out = 1 if j.flag(j.get(0, "forward"), True) else 2
            wv.tab_view = wv.slots[k].view
            return TOOK_TAB
        else:
            raise Error("no such message")
    except:
        wv.slots[k].refused += 1
    return TOOK_NOTHING


def facts_json(addr: Int) -> String:
    """What the widgets on the screen say about themselves, for an attached agent: a JSON list of their facts objects."""
    if addr == 0:
        return "[]"
    return facts_of(webviews_at(addr)[])


def facts_of(wv: WebViews) -> String:
    """facts_json for any host's views (the Mac's sit inside its own struct)."""
    var out = String("[")
    var first = True
    for k in range(len(wv.slots)):
        if wv.slots[k].facts == "" or wv.slots[k].gone:
            continue
        if not first:
            out += ","
        first = False
        out += wv.slots[k].facts
    return out + "]"
