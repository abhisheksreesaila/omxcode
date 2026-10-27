#!/usr/bin/env bash
# The GTK launcher for apps with WebComponents (scripts/webkit_launcher.sh, D-619): it runs the app under bubblewrap with
# WebKitGTK laid over /usr/lib only when that can work; otherwise it runs the app directly (the widgets then show their
# `instead` views), never failing to start. And scripts/webkitgtk.sh fails cleanly when it can't fetch.
#   bash tests/test_webkit_launcher.sh      # prints "webkit_launcher: ok"
set -euo pipefail
cd "$(dirname "$0")/.."
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/out" "$t/wk/usr/lib" "$t/bin-none" "$t/bin-old" "$t/bin-new"
printf '#!/bin/sh\necho "app ran $*"\n' > "$t/out/demo.bin"; chmod +x "$t/out/demo.bin"
touch "$t/wk/usr/lib/libwebkitgtk-6.0.so.4"
printf '#!/bin/sh\necho "usage: bwrap [OPTIONS...]"\n' > "$t/bin-old/bwrap"  # (an old bubblewrap: no --overlay-src)
printf '#!/bin/sh\ncase "$1" in --help) echo "  --overlay-src SRC";; *) echo "bwrap ran";; esac\n' > "$t/bin-new/bwrap"
chmod +x "$t/bin-old/bwrap" "$t/bin-new/bwrap"
for b in sh dirname grep cat; do ln -s "$(command -v $b)" "$t/bin-none/$b"; ln -s "$(command -v $b)" "$t/bin-old/$b"; ln -s "$(command -v $b)" "$t/bin-new/$b"; done
scripts/webkit_launcher.sh "$t/out" demo "$t/wk"
fail() { echo "webkit_launcher: FAIL: $*" >&2; exit 1; }
sys_has() { [ -e /usr/lib/libwebkitgtk-6.0.so.4 ]; }
got=$(PATH="$t/bin-none" "$t/out/demo" a b); [ "$got" = "app ran a b" ] || fail "no bwrap: $got"
got=$(PATH="$t/bin-old" "$t/out/demo" a); [ "$got" = "app ran a" ] || fail "bwrap without --overlay-src: $got"
want="bwrap ran"; sys_has && want="app ran x"  # (a system WebKitGTK: no launcher needed)
got=$(PATH="$t/bin-new" "$t/out/demo" x); [ "$got" = "$want" ] || fail "bwrap with overlays: $got"
rm "$t/wk/usr/lib/libwebkitgtk-6.0.so.4"
got=$(PATH="$t/bin-new" "$t/out/demo" y); [ "$got" = "app ran y" ] || fail "the WebKitGTK copy is gone: $got"
# webkitgtk.sh: no mirror answers → exit 1 with a reason, nothing half-made (unless the system has WebKitGTK: exit 0, "")
set +e
msg=$(WEBKITGTK_DEST="$t/fetch" WEBKITGTK_MIRRORS="http://127.0.0.1:9" scripts/webkitgtk.sh 2>&1 >/dev/null); rc=$?
set -e
if sys_has; then [ $rc = 0 ] || fail "with a system WebKitGTK: exit $rc"
else [ $rc != 0 ] && [ ! -e "$t/fetch" ] && echo "$msg" | grep -q "couldn't download" || fail "offline fetch: exit $rc, $msg"; fi
echo "webkit_launcher: ok"
