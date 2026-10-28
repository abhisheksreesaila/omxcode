# Developer tools for JavaScript widgets (goal 34b M1c): on in debug builds only, decided when the app is compiled, so a
# release build can't turn them on (no variable, no flag at run time).
#
#   MOJOUI_DEBUG=1 scripts/build.sh <app> linux     # -D MOJOUI_DEBUG: WebKit's inspector for widget views, source maps
#   scripts/build.sh <app> linux                    # release: neither
#
# GTK (mojoui/hosts/gtk_webview.mojo): each widget view's WebKitSettings get enable-developer-extras = DEVTOOLS (the
# view's context menu then has "Inspect Element"; the test step inspect:<tag>#<id> opens it), and the views may load the
# bundles' source maps only when DEVTOOLS.
#
# Mac (mojoui/hosts/appkit_webview.mojo, goal 34b M2): each widget's WKWebView gets `inspectable = DEVTOOLS` (macOS
# 13.3+: Safari's Develop menu can inspect it) and its scheme handler serves the bundles' `.map` files only when
# DEVTOOLS, as GTK does; release builds leave both off (the Mac run's report says WEBINSPECT: <tag>#<id> 0, D-674).

from std.sys import is_defined

comptime DEVTOOLS = is_defined["MOJOUI_DEBUG"]()
