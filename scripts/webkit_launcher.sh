#!/usr/bin/env bash
# Writes <out>/<name>: the GTK app's launcher when WebKitGTK 6.0 comes from scripts/webkitgtk.sh (D-608, D-619).
#   scripts/webkit_launcher.sh <out> <name> <webkitgtk dir>      (the app itself is <out>/<name>.bin)
# At run time it lays <webkitgtk dir>/usr/lib over /usr/lib with bubblewrap, but only when that can work: no system
# WebKitGTK (then none is needed), the copy still there, bwrap new enough for --overlay-src (0.10+), and a trial run of
# bwrap with the same overlay succeeding (user namespaces can be turned off, D-625). Otherwise it runs the app directly:
# it always starts, and a WebComponent shows its `instead` view if WebKit can't load. The folder's path is kept in
# <out>/<name>.webkitgtk and read at run time, so no quote or $ in it is ever shell code (D-626).
set -euo pipefail
out="$1"; name="$2"; wk="$3"
printf '%s' "$wk" > "$out/$name.webkitgtk"
cat > "$out/$name" <<LAUNCHER
#!/bin/sh
# WebKitGTK 6.0 from the folder named in $name.webkitgtk (scripts/webkitgtk.sh), laid over /usr/lib for this app only (D-608, D-619)
here="\$(dirname "\$0")"
wk="\$(cat "\$here/$name.webkitgtk" 2>/dev/null)"
if [ ! -e /usr/lib/libwebkitgtk-6.0.so.4 ] && [ -n "\$wk" ] && [ -f "\$wk/usr/lib/libwebkitgtk-6.0.so.4" ] && command -v bwrap >/dev/null 2>&1 \\
   && bwrap --help 2>&1 | grep -q -- --overlay-src \\
   && bwrap --dev-bind / / --overlay-src /usr/lib --overlay-src "\$wk/usr/lib" --ro-overlay /usr/lib true >/dev/null 2>&1; then
  exec bwrap --dev-bind / / --overlay-src /usr/lib --overlay-src "\$wk/usr/lib" --ro-overlay /usr/lib --die-with-parent "\$here/$name.bin" "\$@"
fi
exec "\$here/$name.bin" "\$@"
LAUNCHER
chmod +x "$out/$name"
