# Web entry point: builds the app module (`app.mojo`, chosen with -I) as a Python
# extension module, `mojoui_app`, which mojoui/hosts/web.py serves with FastHTML.
from std.os import abort
from std.python import PythonObject
from std.python.bindings import PythonModuleBuilder

from app import Main
from mojoui.shared import shared_loads
from mojoui.hosts.web import web_init_shared, web_new, web_title, web_view, web_event, web_image, web_rows, web_close, web_draw, web_gesture, web_frame, web_theme, web_theme_key, web_key, web_cancel, web_describe, web_resize, web_appearance, web_logo, web_poll, web_wake_in


@export
def PyInit_mojoui_app() abi("C") -> PythonObject:
    try:
        var m = PythonModuleBuilder("mojoui_app")
        m.def_function[init_shared]("init_shared", docstring="Build the app's shared data once per process; returns how many times it has been built.")
        m.def_function[new_session]("new_session", docstring="Start an app session; returns its handle.")
        m.def_function[title]("title", docstring="The app's title.")
        m.def_function[view]("view", docstring="The current screen as JSON.")
        m.def_function[event]("event", docstring="A control changed (node, second, text, number); returns what changed as JSON.")
        m.def_function[image]("image", docstring="'address width height' of an image node's RGBA pixels.")
        m.def_function[rows]("rows", docstring="JSON list of a LazyList's row texts (node, first, count).")
        m.def_function[close]("close", docstring="End a session.")
        m.def_function[theme]("theme", docstring="The app's theme: id, body classes, palette CSS variables, style sheet (split by U+001F).")
        m.def_function[theme_key]("theme_key", docstring="The app's theme's key: the page restyles when it changes.")
        m.def_function[logo]("logo", docstring="The app's mark as SVG ('': none).")
        m.def_function[draw]("draw", docstring="Paint a canvas (node, width, height, scale, still: no motion); JSON with the pixels' address and what changed.")
        m.def_function[gesture]("gesture", docstring="A canvas gesture (node, kind, x, y, dx, dy, zoom); returns what changed as JSON.")
        m.def_function[key]("key", docstring="A key on a focused canvas (node, name, modifiers); returns what changed as JSON.")
        m.def_function[cancel]("cancel", docstring="Escape in a field (node, text); returns what changed as JSON.")
        m.def_function[describe]("describe", docstring="A canvas's content as text for an agent (node, first, count); '' when it offers none.")
        m.def_function[appearance]("appearance", docstring="The browser's colour scheme (1 dark, 0 light); returns what changed as JSON.")
        m.def_function[resize]("resize", docstring="The page's viewport (width, height in CSS pixels); returns what changed as JSON.")
        m.def_function[frame]("frame", docstring="A display frame for a canvas (node, microseconds); returns what changed as JSON.")
        m.def_function[poll]("poll", docstring="The tab's due effects (HTTP replies, timer ticks) through update(); returns what changed as JSON.")
        m.def_function[wake_in]("wake_in", docstring="Microseconds until poll() has something to do (-1: nothing until the next event).")
        return m.finalize()
    except e:
        abort(String("mojoui: couldn't create the Python module: ", e))


def init_shared() raises -> PythonObject:
    web_init_shared[Main]()
    return PythonObject(shared_loads())


def new_session() raises -> PythonObject:
    return PythonObject(web_new[Main]())


def title(handle: PythonObject) raises -> PythonObject:
    return PythonObject(web_title[Main](Int(py=handle)))


def view(handle: PythonObject) raises -> PythonObject:
    return PythonObject(web_view[Main](Int(py=handle)))


def event(handle: PythonObject, node: PythonObject, second: PythonObject, text: PythonObject, number: PythonObject) raises -> PythonObject:
    return PythonObject(web_event[Main](Int(py=handle), Int(py=node), Int(py=second) != 0, String(py=text), Int(py=number)))


def rows(handle: PythonObject, node: PythonObject, first: PythonObject, count: PythonObject) raises -> PythonObject:
    return PythonObject(web_rows[Main](Int(py=handle), Int(py=node), Int(py=first), Int(py=count)))


def image(handle: PythonObject, node: PythonObject) raises -> PythonObject:
    return PythonObject(web_image[Main](Int(py=handle), Int(py=node)))


def close(handle: PythonObject) raises -> PythonObject:
    web_close[Main](Int(py=handle))
    return PythonObject(None)


def draw(handle: PythonObject, node: PythonObject, width: PythonObject, height: PythonObject, scale: PythonObject, still: PythonObject) raises -> PythonObject:
    return PythonObject(web_draw[Main](Int(py=handle), Int(py=node), Int(py=width), Int(py=height), Float64(py=scale), Int(py=still) != 0))


def appearance(handle: PythonObject, dark: PythonObject) raises -> PythonObject:
    return PythonObject(web_appearance[Main](Int(py=handle), Int(py=dark) != 0))


def resize(handle: PythonObject, width: PythonObject, height: PythonObject) raises -> PythonObject:
    return PythonObject(web_resize[Main](Int(py=handle), Int(py=width), Int(py=height)))


def gesture(handle: PythonObject, node: PythonObject, kind: PythonObject, x: PythonObject, y: PythonObject, dx: PythonObject, dy: PythonObject, zoom: PythonObject) raises -> PythonObject:
    return PythonObject(web_gesture[Main](Int(py=handle), Int(py=node), Int(py=kind), Float64(py=x), Float64(py=y), Float64(py=dx), Float64(py=dy), Float64(py=zoom)))


def key(handle: PythonObject, node: PythonObject, name: PythonObject, modifiers: PythonObject) raises -> PythonObject:
    return PythonObject(web_key[Main](Int(py=handle), Int(py=node), String(py=name), Int(py=modifiers)))


def cancel(handle: PythonObject, node: PythonObject, text: PythonObject) raises -> PythonObject:
    return PythonObject(web_cancel[Main](Int(py=handle), Int(py=node), String(py=text)))


def describe(handle: PythonObject, node: PythonObject, first: PythonObject, count: PythonObject) raises -> PythonObject:
    return PythonObject(web_describe[Main](Int(py=handle), Int(py=node), Int(py=first), Int(py=count)))


def frame(handle: PythonObject, node: PythonObject, microseconds: PythonObject) raises -> PythonObject:
    return PythonObject(web_frame[Main](Int(py=handle), Int(py=node), Int(py=microseconds)))


def theme(handle: PythonObject) raises -> PythonObject:
    return PythonObject(web_theme[Main](Int(py=handle)))


def theme_key(handle: PythonObject) raises -> PythonObject:
    return PythonObject(web_theme_key[Main](Int(py=handle)))


def logo(handle: PythonObject) raises -> PythonObject:
    return PythonObject(web_logo[Main](Int(py=handle)))



def poll(handle: PythonObject) raises -> PythonObject:
    return PythonObject(web_poll[Main](Int(py=handle)))


def wake_in(handle: PythonObject) raises -> PythonObject:
    return PythonObject(web_wake_in[Main](Int(py=handle)))
