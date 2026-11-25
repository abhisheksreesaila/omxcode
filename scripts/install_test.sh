#!/usr/bin/env bash
# The Linux installer (linux/install.sh.in) in a scratch HOME (review 6, P1): what a person made is never touched, by an install, an
# update, an uninstall or the move from the layout of before (~/.local/share/<app>, where pnote keeps its notes).
set -euo pipefail
cd "$(dirname "$0")/.."
W="$(mktemp -d)"; trap 'rm -r "$W"' EXIT
fail() { echo "install_test: $*"; exit 1; }
package() {  # package <dir> <version> <extra file…>
  mkdir -p "$1/lib" "$1/fonts/geist"
  printf '#!/bin/sh\necho app %s\n' "$2" > "$1/app"; chmod +x "$1/app"
  echo icon > "$1/app.png"; echo "lib" > "$1/lib/a.so"; echo "readme $2" > "$1/README.txt"
  echo font > "$1/fonts/geist/Geist[wght] x.ttf"
  for f in "${@:3}"; do mkdir -p "$(dirname "$1/$f")"; echo "$f $2" > "$1/$f"; done
  sed -e "s|@EX@|app|g" -e "s|@COMMENT@|An app|g" -e "s|@CATS@|Utility;|g" -e "s|@MIME@||g" linux/install.sh.in > "$1/install.sh"; chmod +x "$1/install.sh"
}
home() { export HOME="$W/home-$1"; mkdir -p "$HOME/.local/share/app"; echo "my notes" > "$HOME/.local/share/app/notes.db"; echo wal > "$HOME/.local/share/app/notes.db-wal"; echo mine > "$HOME/.local/share/app/unlisted file.txt"; }
kept() { [ "$(cat "$HOME/.local/share/app/notes.db")" = "my notes" ] && [ "$(cat "$HOME/.local/share/app/notes.db-wal")" = wal ] && [ "$(cat "$HOME/.local/share/app/unlisted file.txt")" = mine ] || fail "$1: the notes were touched"; }
package "$W/v1" 1 "only1/old.txt" "data/both.txt"
package "$W/v2" 2 "new2.txt" "data/both.txt"
P=.local/lib/app

home a  # install, update, uninstall
"$W/v1/install.sh" > "$W/log"; kept "install"
[ "$("$HOME/.local/bin/app")" = "app 1" ] && [ -f "$HOME/$P/fonts/geist/Geist[wght] x.ttf" ] && [ -f "$HOME/$P/only1/old.txt" ] || fail "install: the program"
grep -q "Exec=$HOME/$P/app" "$HOME/.local/share/applications/app.desktop" || fail "install: the launcher"
echo "mine too" > "$HOME/$P/mine.txt"; mkdir "$HOME/$P/data/mydir"; echo x > "$HOME/$P/data/mydir/y"
"$W/v1/install.sh" > "$W/log"; kept "the same again"
"$W/v2/install.sh" > "$W/log"; kept "update"
[ "$("$HOME/.local/bin/app")" = "app 2" ] && [ ! -e "$HOME/$P/only1" ] && [ -f "$HOME/$P/new2.txt" ] || fail "update: the program"
[ "$(cat "$HOME/$P/mine.txt")" = "mine too" ] && [ -f "$HOME/$P/data/mydir/y" ] || fail "update: a file that isn't the program's"
[ -z "$(find "$HOME" -name '*.installing' -o -name '.manifest.new')" ] || fail "update: left something half done"
"$HOME/.local/bin/app-uninstall" > "$W/log"; kept "uninstall"
[ ! -e "$HOME/.local/bin/app" ] && [ ! -e "$HOME/.local/bin/app-uninstall" ] && [ ! -e "$HOME/.local/share/applications/app.desktop" ] && [ ! -e "$HOME/$P/app" ] && [ ! -e "$HOME/$P/lib" ] || fail "uninstall: the program is still there"
[ "$(cat "$HOME/$P/mine.txt")" = "mine too" ] && [ -f "$HOME/$P/data/mydir/y" ] || fail "uninstall: a file that isn't the program's"

home b  # the layout of before, the same version: what is byte for byte the program's goes, the rest stays; its uninstaller is replaced
mkdir -p "$HOME/.local/bin"; cp -r "$W/v1/." "$HOME/.local/share/app/"; rm "$HOME/.local/share/app/install.sh"; ln -s "$HOME/.local/share/app/app" "$HOME/.local/bin/app"
printf '#!/bin/sh\nrm -rf "%s"\n' "$HOME/.local/share/app" > "$HOME/.local/bin/app-uninstall"; chmod +x "$HOME/.local/bin/app-uninstall"
"$W/v1/install.sh" > "$W/log"; kept "from the old layout"
[ "$(readlink "$HOME/.local/bin/app")" = "$HOME/$P/app" ] && [ ! -e "$HOME/.local/share/app/app" ] && [ ! -e "$HOME/.local/share/app/lib" ] || fail "old layout: the program"
! grep -q "rm -rf" "$HOME/.local/bin/app-uninstall" || fail "old layout: the old uninstaller is still there"
"$HOME/.local/bin/app-uninstall" > "$W/log"; kept "uninstall after the old layout"

home c  # the layout of before, another version: nothing that isn't provably the program's goes
mkdir -p "$HOME/.local/bin"; cp -r "$W/v1/." "$HOME/.local/share/app/"; ln -s "$HOME/.local/share/app/app" "$HOME/.local/bin/app"
"$W/v2/install.sh" > "$W/log"; kept "from an older version's old layout"
[ "$("$HOME/.local/bin/app")" = "app 2" ] && [ "$("$HOME/.local/share/app/app")" = "app 1" ] && grep -q "older program is still in" "$W/log" || fail "old layout, another version"

home d  # a file of the program's name that isn't the program's; a link in the way: nothing is changed
mkdir -p "$HOME/$P"; echo "somebody's" > "$HOME/$P/app"
! "$W/v1/install.sh" > "$W/log" 2>&1 || fail "installed over somebody's file"
[ "$(cat "$HOME/$P/app")" = "somebody's" ] && [ ! -e "$HOME/$P/lib" ] && [ ! -e "$HOME/.local/bin/app" ] || fail "refused, yet changed something"
home e; mkdir -p "$HOME/.local/lib"; ln -s "$HOME/.local/share/app" "$HOME/$P"
! "$W/v1/install.sh" > "$W/log" 2>&1 || fail "installed through a link"
kept "a link"

home f  # a manifest that names files elsewhere; an update that was cut short
"$W/v1/install.sh" > "$W/log"
printf '%s\n' "../../share/app/notes.db" "/$HOME/.local/share/app/notes.db" "lib/../../../share/app/notes.db" ".." >> "$HOME/$P/.manifest"
printf 'new2.txt\n' >> "$HOME/$P/.manifest"; echo half > "$HOME/$P/new2.txt"
"$W/v2/install.sh" > "$W/log"; kept "a manifest that points elsewhere"
[ "$(cat "$HOME/$P/new2.txt")" = "new2.txt 2" ] && [ ! -e "$HOME/$P/only1" ] || fail "after an update cut short"
printf '%s\n' "../../share/app/notes.db" >> "$HOME/$P/.manifest"
"$HOME/.local/bin/app-uninstall" > "$W/log"; kept "its uninstaller"
! grep -nE 'rm -[a-z]*r' linux/install.sh.in || fail "the installer removes folders"
echo "install_test: ok"
