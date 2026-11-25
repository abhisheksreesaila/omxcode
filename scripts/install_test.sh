#!/usr/bin/env bash
# The Linux installer (linux/install.sh.in) in scratch HOMEs, one a case (review 6 P1, review 7 I1): what a person made or put there
# is never touched, inside the program's folder or out of it; a refusal names the file and changes nothing.
#   scripts/install_test.sh [--mutants]     (the mutants: the installer with one check taken out; the cases must notice each)
set -euo pipefail
cd "$(dirname "$0")/.."
T="${TEMPLATE:-linux/install.sh.in}"
if [ "${1:-}" = --mutants ]; then exec python3 scripts/install_mutants.py; fi
W="$(mktemp -d)"; trap 'cd /; chmod -R u+w "${W:?}"; rm -r "${W:?}"' EXIT
fail() { echo "install_test: $CASE: $*"; exit 1; }
package() {  # package <dir> <version> <extra file…>
  mkdir -p "$1/lib" "$1/fonts/geist"
  printf '#!/bin/sh\necho "app %s $*" | tee -a "$HOME/ran"\n' "$2" > "$1/app"; chmod +x "$1/app"
  echo "icon $2" > "$1/app.png"; echo "lib" > "$1/lib/a.so"; echo "readme $2" > "$1/README.txt"
  echo font > "$1/fonts/geist/Geist[wght] x.ttf"
  for f in "${@:3}"; do mkdir -p "$(dirname "$1/$f")"; echo "$f $2" > "$1/$f"; done
  sed -e "s|@EX@|app|g" -e "s|@COMMENT@|An app|g" -e "s|@CATS@|Utility;|g" -e "s|@MIME@||g" "$T" > "$1/install.sh"; chmod +x "$1/install.sh"
}
home() {  # home <case> [its folder's name]
  CASE="$1"; export HOME="$W/home ${2:-}-${1// /_}"; case "$HOME" in "$W"/*) ;; *) exit 9 ;; esac
  [ -n "${2:-}" ] || export HOME="$W/home-${1// /_}"
  mkdir -p "$HOME/.local/share/app"; echo "my notes" > "$HOME/.local/share/app/notes.db"; echo wal > "$HOME/.local/share/app/notes.db-wal"; echo mine > "$HOME/.local/share/app/unlisted file.txt"
  B="$HOME/.local/bin"; P="$HOME/.local/lib/app"; D="$HOME/.local/share/applications/app.desktop"; I="$HOME/.local/share/icons/hicolor/256x256/apps/app.png"
}
kept() { [ "$(cat "$HOME/.local/share/app/notes.db")" = "my notes" ] && [ "$(cat "$HOME/.local/share/app/notes.db-wal")" = wal ] && [ "$(cat "$HOME/.local/share/app/unlisted file.txt")" = mine ] || fail "$1: the notes were touched"; }
ok() { "$@" > "$W/log" 2>&1 || fail "$* failed: $(tail -2 "$W/log")"; kept "$*"; }
picture() { (cd "$HOME" && find . \( -type f -exec sha256sum {} + \) -o -type l -printf '%p -> %l\n' -o -type d -printf '%p/\n' | LC_ALL=C sort); }
refuses() {  # refuses <installer> <what its message names>
  local before; before="$(picture)"
  ! "$1" > "$W/log" 2>&1 || fail "installed all the same"
  grep -qF -- "$2" "$W/log" || fail "doesn't name $2: $(cat "$W/log")"
  grep -q "nothing was changed" "$W/log" || fail "doesn't say that nothing was changed: $(cat "$W/log")"
  [ "$(picture)" = "$before" ] || fail "said no, and changed something: $(diff <(echo "$before") <(picture))"
}
tidy() { [ -z "$(find "$HOME" \( -name '*.installing*' -o -name '*.??????' \) -newer "$W/v1/app" ! -name '*.so' | grep -E '\.[A-Za-z0-9]{6}$' | grep -v '\.(desktop|manifest)$' || true)" ] || fail "left something half done: $(find "$HOME" -name '*.??????')"; }
package "$W/v1" 1 "only1/old.txt" "data/both.txt"
package "$W/v2" 2 "new2.txt" "data/both.txt"
old_layout() { mkdir -p "$B" "$(dirname "$D")" "$(dirname "$I")"; cp -r "$1/." "$HOME/.local/share/app/"; rm "$HOME/.local/share/app/install.sh"; ln -s "$HOME/.local/share/app/app" "$B/app"
  printf '[Desktop Entry]\nType=Application\nName=app\nExec=%s %%f\nIcon=app\n' "$HOME/.local/share/app/app" > "$D"; cp "$1/app.png" "$I"
  { printf '#!/usr/bin/env bash\n%s "%s" "%s" "%s" "%s" "%s"\n' 'rm -rf' "$HOME/.local/share/app" "$B/app" "$D" "$I" "$B/app-uninstall"; printf '[ "$(readlink "%s")" != "%s" ] || rm -f "%s"\necho "app removed"\n' "$B/omxc" "$HOME/.local/share/app/omxc" "$B/omxc"; } > "$B/app-uninstall"; chmod +x "$B/app-uninstall"; }

# ---------- what it is for
home "install update uninstall"
ok "$W/v1/install.sh"
[ "$("$B/app" x)" = "app 1 x" ] && [ -f "$P/fonts/geist/Geist[wght] x.ttf" ] && [ -f "$P/only1/old.txt" ] && [ "$(cat "$I")" = "icon 1" ] || fail "the program"
grep -qxF "Exec=\"$P/app\" %f" "$D" || fail "the launcher: $(grep Exec "$D")"
echo "mine too" > "$P/mine.txt"; mkdir "$P/data/mydir"; echo x > "$P/data/mydir/y"
ok "$W/v1/install.sh"; ok "$W/v2/install.sh"; tidy
[ "$("$B/app")" = "app 2 " ] && [ ! -e "$P/only1" ] && [ -f "$P/new2.txt" ] && [ "$(cat "$I")" = "icon 2" ] || fail "updated"
[ "$(cat "$P/mine.txt")" = "mine too" ] && [ -f "$P/data/mydir/y" ] || fail "a file that isn't the program's"
ok "$B/app-uninstall"
for x in "$B/app" "$B/app-uninstall" "$D" "$I" "$P/app" "$P/lib" "$P/.manifest"; do [ ! -e "$x" ] || fail "$x is still there"; done
[ "$(cat "$P/mine.txt")" = "mine too" ] && [ -f "$P/data/mydir/y" ] || fail "uninstall: a file that isn't the program's"
home "uninstall leaves nothing"; ok "$W/v1/install.sh"; ok "$B/app-uninstall"; [ ! -e "$P" ] || fail "its folder is still there"; tidy

# ---------- things of these names that aren't its own, outside the program's folder
home "own script in bin"; mkdir -p "$B"; echo "my own script" > "$B/app"; refuses "$W/v1/install.sh" "$B/app"
home "own link in bin"; mkdir -p "$B" "$HOME/tools"; echo mine > "$HOME/tools/app"; ln -s "$HOME/tools/app" "$B/app"; refuses "$W/v1/install.sh" "$B/app"
home "own dangling link in bin"; mkdir -p "$B"; ln -s "$HOME/nowhere" "$B/app"; refuses "$W/v1/install.sh" "$B/app"
home "own folder in bin"; mkdir -p "$B/app"; echo q > "$B/app/q"; refuses "$W/v1/install.sh" "$B/app"
home "own launcher entry"; mkdir -p "$(dirname "$D")"; printf '[Desktop Entry]\nExec=/usr/bin/other app\n' > "$D"; refuses "$W/v1/install.sh" "$D"
home "own launcher entry that only mentions it"; mkdir -p "$(dirname "$D")"; printf '[Desktop Entry]\nExec=env X=1 %s\n' "$P/app" > "$D"; refuses "$W/v1/install.sh" "$D"
home "launcher entry is a link"; mkdir -p "$(dirname "$D")" "$HOME/dot"; printf '[Desktop Entry]\nExec=%s %%f\n' "$P/app" > "$HOME/dot/app.desktop"; ln -s "$HOME/dot/app.desktop" "$D"; refuses "$W/v1/install.sh" "$D"
home "own icon"; mkdir -p "$(dirname "$I")"; echo "my icon" > "$I"; refuses "$W/v1/install.sh" "$I"
home "icon is a link"; mkdir -p "$(dirname "$I")"; echo "icon 1" > "$HOME/pic"; ln -s "$HOME/pic" "$I"; refuses "$W/v1/install.sh" "$I"
home "own uninstall script"; mkdir -p "$B"; echo "mine" > "$B/app-uninstall"; refuses "$W/v1/install.sh" "$B/app-uninstall"
home "icon edited since"; ok "$W/v1/install.sh"; echo "my own drawing" > "$I"; refuses "$W/v2/install.sh" "$I"
home "uninstall keeps what was put in its place"; ok "$W/v1/install.sh"; echo "my own drawing" > "$I"; rm "$B/app"; echo "my own app" > "$B/app"; ok "$B/app-uninstall"
[ "$(cat "$I")" = "my own drawing" ] && [ "$(cat "$B/app")" = "my own app" ] || fail "removed"
home "uninstall keeps a launcher entry put in its place"; ok "$W/v1/install.sh"; rm "$D"; printf '[Desktop Entry]\nExec=/usr/bin/other\n' > "$D"; ok "$B/app-uninstall"; grep -q other "$D" || fail "removed"

# ---------- inside it
home "somebodys file in dest"; mkdir -p "$P"; echo "somebody's" > "$P/app"; refuses "$W/v1/install.sh" "$P/app"
home "a program file edited"; ok "$W/v1/install.sh"; echo "edited" > "$P/README.txt"; refuses "$W/v2/install.sh" "$P/README.txt"
home "a program file edited then uninstall"; ok "$W/v1/install.sh"; echo "edited" > "$P/README.txt"; ok "$B/app-uninstall"; [ "$(cat "$P/README.txt")" = edited ] && [ ! -e "$P/app" ] || fail "the edited one"
home "dest is a link"; mkdir -p "$HOME/.local/lib"; ln -s "$HOME/.local/share/app" "$P"; refuses "$W/v1/install.sh" "$P"
home "a folder in dest is a link"; ok "$W/v1/install.sh"; mkdir -p "$HOME/myfonts/geist"; echo font > "$HOME/myfonts/geist/Geist[wght] x.ttf"; rm -r "${P:?}/fonts"; ln -s "$HOME/myfonts" "$P/fonts"; refuses "$W/v2/install.sh" "$P/fonts/geist"
ok "$B/app-uninstall"; [ "$(cat "$HOME/myfonts/geist/Geist[wght] x.ttf")" = font ] && [ -L "$P/fonts" ] || fail "removed through the link"
home "a file in dest is a link"; ok "$W/v1/install.sh"; echo lib > "$HOME/mylib"; rm "$P/lib/a.so"; ln -s "$HOME/mylib" "$P/lib/a.so"; refuses "$W/v2/install.sh" "$P/lib/a.so"; ok "$B/app-uninstall"; [ "$(cat "$HOME/mylib")" = lib ] && [ -L "$P/lib/a.so" ] || fail "the link"
home "what only the one before had is now behind a link"; ok "$W/v1/install.sh"; mkdir "$HOME/mine1"; cp "$P/only1/old.txt" "$HOME/mine1/"; rm -r "${P:?}/only1"; ln -s "$HOME/mine1" "$P/only1"; ok "$W/v2/install.sh"; [ -f "$HOME/mine1/old.txt" ] || fail "removed through the link"
home "what only the one before had was edited"; ok "$W/v1/install.sh"; echo "my words" > "$P/only1/old.txt"; ok "$W/v2/install.sh"; [ "$(cat "$P/only1/old.txt")" = "my words" ] || fail "removed"
home "lib is a file"; echo f > "$HOME/.local/lib"; refuses "$W/v1/install.sh" "$HOME/.local/lib"
home "a package folder is a file there"; mkdir -p "$P"; echo f > "$P/fonts"; refuses "$W/v1/install.sh" "$P/fonts"

# ---------- its list
home "list that points elsewhere"; ok "$W/v1/install.sh"
n="$(sha256sum < "$HOME/.local/share/app/notes.db")"; n="${n%% *}"
printf '%s  %s\n' "$n" "../../share/app/notes.db" "$n" "$HOME/.local/share/app/notes.db" "$n" "lib/../../../share/app/notes.db" "$n" ".." >> "$P/.manifest"
ok "$W/v2/install.sh"; printf '%s  %s\n' "$n" "../../share/app/notes.db" "$n" "~/../x" >> "$P/.manifest"; ok "$B/app-uninstall"
home "list lost, the same version"; ok "$W/v1/install.sh"; rm "$P/.manifest"; before="$(picture)"; ! "$B/app-uninstall" > "$W/log" 2>&1 && grep -q "is gone: nothing was removed" "$W/log" && [ "$(picture)" = "$before" ] || fail "uninstall: $(cat "$W/log")"
ok "$W/v1/install.sh"; ok "$B/app-uninstall"; [ ! -e "$P" ] || fail "still there"
home "list lost, another version"; ok "$W/v1/install.sh"; rm "$P/.manifest"; refuses "$W/v2/install.sh" "move $P away"; mv "$P" "$HOME/away"; mkdir "$HOME/x"; mv "$B/app-uninstall" "$I" "$HOME/x/"; ok "$W/v2/install.sh"
home "cut short, then again"; ok "$W/v1/install.sh"; mkdir "$HOME/bad"; printf '#!/bin/sh\nn=$(cat "%s/n" 2>/dev/null || echo 0); echo $((n+1)) > "%s/n"; [ $n -lt 4 ] || exit 1; exec /usr/bin/cp "$@"\n' "$HOME/bad" "$HOME/bad" > "$HOME/bad/cp"; chmod +x "$HOME/bad/cp"
! PATH="$HOME/bad:$PATH" "$W/v2/install.sh" > "$W/log" 2>&1 || fail "wasn't cut short"; kept "cut short"; tidy
ok "$W/v2/install.sh"; [ "$("$B/app")" = "app 2 " ] && [ ! -e "$P/only1" ] || fail "after being cut short"
home "cut short, then uninstall"; ok "$W/v1/install.sh"; mkdir "$HOME/bad"; printf '#!/bin/sh\nn=$(cat "%s/n" 2>/dev/null || echo 0); echo $((n+1)) > "%s/n"; [ $n -lt 4 ] || exit 1; exec /usr/bin/cp "$@"\n' "$HOME/bad" "$HOME/bad" > "$HOME/bad/cp"; chmod +x "$HOME/bad/cp"
! PATH="$HOME/bad:$PATH" "$W/v2/install.sh" > "$W/log" 2>&1 || fail "wasn't cut short"
ok "$B/app-uninstall"; [ ! -e "$P" ] || fail "left: $(find "$P")"
home "cut short at once, then somebodys file"; mkdir "$HOME/bad"; printf '#!/bin/sh\nn=$(cat "%s/n" 2>/dev/null || echo 0); echo $((n+1)) > "%s/n"; [ $n -lt 1 ] || exit 1; exec /usr/bin/cp "$@"\n' "$HOME/bad" "$HOME/bad" > "$HOME/bad/cp"; chmod +x "$HOME/bad/cp"
! PATH="$HOME/bad:$PATH" "$W/v1/install.sh" > "$W/log" 2>&1 || fail "wasn't cut short"; echo "my readme" > "$P/README.txt"; refuses "$W/v1/install.sh" "$P/README.txt"

# ---------- the layout of before
home "old layout, the same version"; old_layout "$W/v1"; ok "$W/v1/install.sh"
[ "$(readlink "$B/app")" = "$P/app" ] && [ ! -e "$HOME/.local/share/app/app" ] && [ ! -e "$HOME/.local/share/app/lib" ] && ! grep -q 'rm -rf' "$B/app-uninstall" || fail "the program"
ok "$B/app-uninstall"
home "old layout, another version"; old_layout "$W/v1"; ok "$W/v2/install.sh"
[ "$("$B/app")" = "app 2 " ] && [ "$("$HOME/.local/share/app/app")" = "app 1 " ] && grep -q "older program is still in" "$W/log" && [ "$(cat "$I")" = "icon 2" ] || fail "the program"
home "old layout, a linked folder in it"; old_layout "$W/v1"; mkdir "$HOME/mylib"; echo lib > "$HOME/mylib/a.so"; rm -r "${HOME:?}/.local/share/app/lib"; ln -s "$HOME/mylib" "$HOME/.local/share/app/lib"; ok "$W/v1/install.sh"; [ -f "$HOME/mylib/a.so" ] || fail "removed through the link"
home "old layout, its uninstaller edited"; old_layout "$W/v1"; echo "echo mine" >> "$B/app-uninstall"; refuses "$W/v1/install.sh" "$B/app-uninstall"
home "old layout, a foreign icon"; old_layout "$W/v1"; echo "my icon" > "$I"; refuses "$W/v2/install.sh" "$I"

# ---------- the machine
home "no GNU find"; mkdir "$HOME/nognu"; printf '#!/bin/sh\nfor a in "$@"; do case "$a" in -printf|-newer) echo "find: unrecognized: $a" >&2; exit 1;; esac; done; exec /usr/bin/find "$@"\n' > "$HOME/nognu/find"; chmod +x "$HOME/nognu/find"
PATH="$HOME/nognu:$PATH" "$W/v1/install.sh" > "$W/log" 2>&1 || fail "needs GNU find: $(cat "$W/log")"; kept "no GNU find"
home "no sha256sum"; mkdir "$HOME/few"; for c in bash env sh find sed grep sort cmp cp mv ln mkdir rmdir rm readlink dirname cat chmod mktemp; do ln -s "$(command -v $c)" "$HOME/few/$c"; done
before="$(picture)"; ! PATH="$HOME/few" "$W/v1/install.sh" > "$W/log" 2>&1 && grep -q "this needs the command 'sha256sum'" "$W/log" && [ "$(picture)" = "$before" ] || fail "$(cat "$W/log")"
for odd in 'with space' 'do$lar `tick`' 'back\slash "quote"' '100% of it'; do
  home "odd home $odd" "$odd"; export HOME="$W/odd ${odd}"; mkdir -p "$HOME/.local/share/app"; echo "my notes" > "$HOME/.local/share/app/notes.db"; echo wal > "$HOME/.local/share/app/notes.db-wal"; echo mine > "$HOME/.local/share/app/unlisted file.txt"
  B="$HOME/.local/bin"; P="$HOME/.local/lib/app"; D="$HOME/.local/share/applications/app.desktop"
  ok "$W/v1/install.sh"; ok "$W/v1/install.sh"
  if command -v desktop-file-validate > /dev/null; then desktop-file-validate "$D" > "$W/log" 2>&1 || fail "the launcher entry: $(cat "$W/log")"; fi
  case "$odd" in *%*) grep -qF '100%% of it' "$D" || fail "the launcher entry: $(grep Exec "$D")" ;; esac  # (GLib looks for the program by the name with both percents and finds none: an old fault of its own, the specification's form is kept)
  if command -v gio > /dev/null && [ "$odd" = "${odd/\%/}" ]; then  # (the desktop's own reading of Exec)
    rm -f "$HOME/ran"; gio launch "$D" > "$W/log" 2>&1 || fail "gio launch: $(cat "$W/log")"; for _ in 1 2 3 4 5 6 7 8 9 10; do [ ! -f "$HOME/ran" ] || break; sleep 0.2; done
    grep -q "app 1" "$HOME/ran" 2>/dev/null || fail "the launcher entry doesn't start it: $(grep Exec "$D")"
  fi
  ok "$B/app-uninstall"; [ ! -e "$P" ] && [ ! -e "$D" ] || fail "still there"
done
echo "install_test: ok"
