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
# a bwrap that knows --overlay-src but can't run (user namespaces turned off): the app runs directly (D-625)
mkdir -p "$t/bin-broken"
printf '#!/bin/sh\ncase "$1" in --help) echo "  --overlay-src SRC";; *) echo "bwrap: setting up uid map: Permission denied" >&2; exit 1;; esac\n' > "$t/bin-broken/bwrap"
chmod +x "$t/bin-broken/bwrap"
for b in sh dirname grep cat; do ln -s "$(command -v $b)" "$t/bin-broken/$b"; done
got=$(PATH="$t/bin-broken" "$t/out/demo" z 2>/dev/null); [ "$got" = "app ran z" ] || fail "bwrap that can't run: $got"
# a WebKitGTK folder whose path holds a quote, a space and a $ (D-626)
odd="$t/it's a \$dir"; mkdir -p "$odd/usr/lib" "$t/out2"; touch "$odd/usr/lib/libwebkitgtk-6.0.so.4"
cp "$t/out/demo.bin" "$t/out2/demo.bin"
scripts/webkit_launcher.sh "$t/out2" demo "$odd"
printf '#!/bin/sh\ncase "$1" in --help) echo "  --overlay-src SRC";; *) for a; do [ "$prev" = "--overlay-src" ] && echo "overlay $a"; prev="$a"; done;; esac\n' > "$t/bin-new/bwrap"
want="overlay $odd/usr/lib"; sys_has && want="app ran q"
got=$(PATH="$t/bin-new" "$t/out2/demo" q | grep -v "overlay /usr/lib" | head -1); [ "$got" = "$want" ] || fail "a path with a quote: $got"
rm "$t/wk/usr/lib/libwebkitgtk-6.0.so.4"
got=$(PATH="$t/bin-new" "$t/out/demo" y); [ "$got" = "app ran y" ] || fail "the WebKitGTK copy is gone: $got"
# webkitgtk.sh: no mirror answers → exit 1 with a reason, nothing half-made (unless the system has WebKitGTK: exit 0, "")
set +e
msg=$(WEBKITGTK_DEST="$t/fetch" WEBKITGTK_MIRRORS="http://127.0.0.1:9" scripts/webkitgtk.sh 2>&1 >/dev/null); rc=$?
set -e
if sys_has; then [ $rc = 0 ] || fail "with a system WebKitGTK: exit $rc"
else [ $rc != 0 ] && [ ! -e "$t/fetch" ] && echo "$msg" | grep -q "couldn't download" || fail "offline fetch: exit $rc, $msg"; fi
echo "webkit_launcher: ok"
