#!/usr/bin/env bash
# WebKitGTK 6.0 (the web engine for GTK 4) for a machine that doesn't have it installed (goal 34 M3, D-608).
#   scripts/webkitgtk.sh            → prints the folder whose usr/lib holds it ("" and exit 0: the system has it)
# A GTK app with WebComponents loads libwebkitgtk-6.0.so.4 when it first shows one. conda-forge has no WebKitGTK for
# GTK 4 (only a 2011 GTK 2 build), and installing the distribution's package needs root, so this fetches Arch Linux's
# signed package once, checks it against the SHA-256 pinned below, and unpacks it into build/webkitgtk-6.0/. WebKit looks
# for its helper processes in /usr/lib/webkitgtk-6.0, a path compiled in, so scripts/build.sh's launcher runs the app with
# that folder's usr/lib laid over /usr/lib (bubblewrap, a user namespace: no root; WebKit's own sandbox still runs inside).
# The rest of what it needs (gtk4, libsoup3, gstreamer…) comes from the system, as GTK itself does.
set -euo pipefail
cd "$(dirname "$0")/.."
SYSTEM_LIB=/usr/lib/libwebkitgtk-6.0.so.4
if [ -e "$SYSTEM_LIB" ] || [ -e /usr/lib64/libwebkitgtk-6.0.so.4 ] || [ -e /usr/lib/x86_64-linux-gnu/libwebkitgtk-6.0.so.4 ]; then
  exit 0  # (installed: nothing to lay over)
fi
VERSION=2.52.6-1
FILE="webkitgtk-6.0-$VERSION-x86_64.pkg.tar.zst"
SHA256=1e50283612a5f835d5c505fb7735d2f9cb83dd5d75a9d76328efb68a98a8ee67  # (its Arch signature checked when pinned, D-608)
DEST="${WEBKITGTK_DEST:-$PWD/build/webkitgtk-6.0}"  # (WEBKITGTK_DEST, WEBKITGTK_MIRRORS: tests/test_webkit_launcher.sh)
if [ -f "$DEST/usr/lib/libwebkitgtk-6.0.so.4" ] && [ "$(cat "$DEST/sha256" 2>/dev/null)" = "$SHA256" ]; then
  echo "$DEST"; exit 0
fi
[ "$(uname -m)" = x86_64 ] || { echo "webkitgtk.sh: only x86_64 is pinned; install webkitgtk-6.0 from your distribution" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/dl" "$tmp/x"
got=""
MIRRORS="${WEBKITGTK_MIRRORS:-https://stable-mirror.omarchy.org/extra/os/x86_64 https://geo.mirror.pkgbuild.com/extra/os/x86_64 https://archive.archlinux.org/packages/w/webkitgtk-6.0}"
for base in $MIRRORS; do
  if curl -fsSL --retry 2 --connect-timeout 10 -o "$tmp/dl/$FILE" "$base/$FILE"; then got=$base; break; fi
done
[ -n "$got" ] || { echo "webkitgtk.sh: couldn't download $FILE (install webkitgtk-6.0 from your distribution instead)" >&2; exit 1; }
echo "$SHA256  $tmp/dl/$FILE" | sha256sum -c --quiet - >&2 || { echo "webkitgtk.sh: $FILE from $got doesn't match the pinned SHA-256" >&2; exit 1; }
tar --zstd -xf "$tmp/dl/$FILE" -C "$tmp/x" usr/lib
rm -rf "$DEST"; mkdir -p "$DEST"
mv "$tmp/x/usr" "$DEST/usr"
echo "$SHA256" > "$DEST/sha256"
echo "webkitgtk.sh: WebKitGTK $VERSION unpacked into build/webkitgtk-6.0 (from $got)" >&2
echo "$DEST"
