# Which GPU 2D backend (mojoui.gpu2d over GL or Metal) this process's host draws `Canvas(…).gpu()` canvases with (goal
# 75). The host says so once, as early as it knows (the AppKit host: before the app is made, after probing Metal); an
# app reads it, e.g. pnote's `PNOTE GPU:` line. Process-wide through an environment variable, so neither side needs a
# global or a reference to the other:
#
#   set_backend_name("gpu2d-Metal")          # host: the GPU path is ready ("" or "cpu …": it isn't, and why)
#   var name = backend_name()                # app: "gpu2d-Metal", "gpu2d-GL", or "" when no host said
#
# A host that can't draw on the GPU sets "cpu <why>" (e.g. "cpu (no Metal device)"), so an app can print the reason.

from std.os import getenv, setenv

comptime BACKEND_VAR = "MOJOUI_GPU2D_BACKEND"


def set_backend_name(name: String):
    """The host's GPU 2D backend ("gpu2d-Metal", "gpu2d-GL"), or "cpu <why>" when it draws on the CPU."""
    _ = setenv(BACKEND_VAR, name, True)


def backend_name() -> String:
    """What the host said (set_backend_name), or "" when it said nothing (a host without a GPU 2D path)."""
    return getenv(BACKEND_VAR, "")


def on_gpu() -> Bool:
    """The host draws .gpu() canvases on the GPU."""
    var n = backend_name()
    return n.startswith("gpu2d")
