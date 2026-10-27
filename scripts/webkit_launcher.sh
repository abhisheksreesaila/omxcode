#!/usr/bin/env bash
# Writes <out>/<name>: the GTK app's launcher when WebKitGTK 6.0 comes from scripts/webkitgtk.sh (D-608, D-619).
#   scripts/webkit_launcher.sh <out> <name> <webkitgtk dir>      (the app itself is <out>/<name>.bin)
# At run time it lays <webkitgtk dir>/usr/lib over /usr/lib with bubblewrap, but only when that can work: no system
# WebKitGTK (then none is needed), bwrap present and new enough for --overlay-src (0.10+), and the copy still there.
# Otherwise it runs the app directly: it always starts, and a WebComponent shows its `instead` view if WebKit can't load.
set -euo pipefail
out="$1"; name="$2"; wk="$3"
cat > "$out/$name" <<LAUNCHER
#!/bin/sh
# WebKitGTK 6.0 from $wk (scripts/webkitgtk.sh), laid over /usr/lib for this app only (D-608, D-619)
here="\$(dirname "\$0")"
wk='$wk'
if [ ! -e /usr/lib/libwebkitgtk-6.0.so.4 ] && [ -f "\$wk/usr/lib/libwebkitgtk-6.0.so.4" ] && command -v bwrap >/dev/null 2>&1 \\
   && bwrap --help 2>&1 | grep -q -- --overlay-src; then
  exec bwrap --dev-bind / / --overlay-src /usr/lib --overlay-src "\$wk/usr/lib" --ro-overlay /usr/lib --die-with-parent "\$here/$name.bin" "\$@"
fi
exec "\$here/$name.bin" "\$@"
LAUNCHER
chmod +x "$out/$name"
