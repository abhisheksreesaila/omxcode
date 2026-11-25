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
  sed -e "s|@EX@|app|g" -e "s|@COMMENT@|An app|g" -e "s|@CATS@|Utility;|g" -e "s|@MIME@||g" -e "s|@DATA@|.apphome/files|g" "$T" > "$1/install.sh"; chmod +x "$1/install.sh"
  relist "$1"
}
relist() { (cd "$1" && find . -type f ! -path ./install.sh ! -path ./files.sha256 | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do echo "$(sha256sum < "$f" | cut -d' ' -f1)  $f"; done) > "$W/list"; mv "$W/list" "$1/files.sha256"; }
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
leaves() {  # leaves <installer> <what it must leave as it is, and name>: installed, and that untouched
  local was; was="$( [ -L "$2" ] && readlink "$2" || sha256sum < "$2")"
  ok "$1"; grep -qF -- "$2 isn't what this program's installer wrote: it is left as it is" "$W/log" || fail "doesn't say that $2 is left: $(cat "$W/log")"
  [ "$( [ -L "$2" ] && readlink "$2" || sha256sum < "$2")" = "$was" ] || fail "$2 was touched"
  [ "$("$B/app")" = "app ${3:-1} " ] || fail "the program"
  ok "$B/app-uninstall"; [ "$( [ -L "$2" ] && readlink "$2" || sha256sum < "$2")" = "$was" ] || fail "uninstall: $2 was touched"
}
tidy() { [ -z "$(find "$HOME" \( -name '*.installing*' -o -name '*.??????' \) -newer "$W/v1/app" ! -name '*.so' | grep -E '\.[A-Za-z0-9]{6}$' | grep -v '\.(desktop|manifest)$' || true)" ] || fail "left something half done: $(find "$HOME" -name '*.??????')"; }
package "$W/v1" 1 "only1/old.txt" "data/both.txt"
package "$W/v2" 2 "new2.txt" "data/both.txt"
old_layout() { mkdir -p "$B" "$(dirname "$D")" "$(dirname "$I")"; cp -r "$1/." "$HOME/.local/share/app/"; rm "$HOME/.local/share/app/install.sh"; ln -s "$HOME/.local/share/app/app" "$B/app"
  printf '[Desktop Entry]\nType=Application\nName=app\nComment=An app\nExec=%s %%f\nIcon=app\nTerminal=false\nCategories=Utility;\nMimeType=\n' "$HOME/.local/share/app/app" > "$D"; cp "$1/app.png" "$I"
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
home "own launcher entry"; mkdir -p "$(dirname "$D")"; printf '[Desktop Entry]\nExec=/usr/bin/other app\n' > "$D"; leaves "$W/v1/install.sh" "$D"
home "own launcher entry that starts it their way"; mkdir -p "$(dirname "$D")"; printf '[Desktop Entry]\nType=Application\nName=Mine\nExec=%s /my/own/file.db\n[Desktop Action x]\nExec=/usr/bin/x\n' "$P/app" > "$D"; leaves "$W/v1/install.sh" "$D"
home "launcher entry edited since"; ok "$W/v1/install.sh"; sed -i 's/^Name=.*/Name=My own name/' "$D"; echo "Keywords=mine" >> "$D"; leaves "$W/v2/install.sh" "$D" 2
home "launcher entry is a link"; mkdir -p "$(dirname "$D")" "$HOME/dot"; printf '[Desktop Entry]\nExec=%s %%f\n' "$P/app" > "$HOME/dot/app.desktop"; ln -s "$HOME/dot/app.desktop" "$D"; h0="$(sha256sum < "$HOME/dot/app.desktop")"; leaves "$W/v1/install.sh" "$D"; [ "$(sha256sum < "$HOME/dot/app.desktop")" = "$h0" ] || fail "written through"
home "launcher entry kept in dotfiles, a link in its place"; ok "$W/v1/install.sh"; mkdir "$HOME/dot"; mv "$D" "$HOME/dot/app.desktop"; ln -s "$HOME/dot/app.desktop" "$D"; h0="$(sha256sum < "$HOME/dot/app.desktop")"; leaves "$W/v1/install.sh" "$D"; [ -L "$D" ] && [ "$(sha256sum < "$HOME/dot/app.desktop")" = "$h0" ] || fail "touched"
home "icon kept elsewhere, a link in its place"; ok "$W/v1/install.sh"; mv "$I" "$HOME/pic"; ln -s "$HOME/pic" "$I"; leaves "$W/v1/install.sh" "$I"; [ -L "$I" ] && [ -f "$HOME/pic" ] || fail "touched"
home "own icon"; mkdir -p "$(dirname "$I")"; echo "my icon" > "$I"; leaves "$W/v1/install.sh" "$I"
home "icon is a link"; mkdir -p "$(dirname "$I")"; echo "icon 1" > "$HOME/pic"; ln -s "$HOME/pic" "$I"; leaves "$W/v1/install.sh" "$I"; [ "$(cat "$HOME/pic")" = "icon 1" ] || fail "written through"
home "own uninstall script"; mkdir -p "$B"; echo "mine" > "$B/app-uninstall"; refuses "$W/v1/install.sh" "$B/app-uninstall"
home "icon edited since"; ok "$W/v1/install.sh"; echo "my own drawing" > "$I"; leaves "$W/v2/install.sh" "$I" 2
home "uninstall keeps what was put in its place"; ok "$W/v1/install.sh"; echo "my own drawing" > "$I"; rm "$B/app"; echo "my own app" > "$B/app"; ok "$B/app-uninstall"
[ "$(cat "$I")" = "my own drawing" ] && [ "$(cat "$B/app")" = "my own app" ] || fail "removed"
home "uninstall keeps a launcher entry put in its place"; ok "$W/v1/install.sh"; rm "$D"; printf '[Desktop Entry]\nExec=/usr/bin/other\n' > "$D"; ok "$B/app-uninstall"; grep -q other "$D" || fail "removed"

# ---------- inside it
home "somebodys file in dest"; mkdir -p "$P"; echo "somebody's" > "$P/app"; refuses "$W/v1/install.sh" "$P/app"
home "a program file edited"; ok "$W/v1/install.sh"; echo "edited" > "$P/README.txt"; refuses "$W/v2/install.sh" "$P/README.txt"
home "a program file edited then uninstall"; ok "$W/v1/install.sh"; echo "edited" > "$P/README.txt"; ok "$B/app-uninstall"; [ "$(cat "$P/README.txt")" = edited ] && [ ! -e "$P/app" ] || fail "the edited one"
home "dest is a link"; mkdir -p "$HOME/.local/lib"; ln -s "$HOME/.local/share/app" "$P"; refuses "$W/v1/install.sh" "$P"
home "dest is a link to a folder of the person's"; mkdir -p "$HOME/.local/lib" "$HOME/elsewhere"; ln -s "$HOME/elsewhere" "$P"; refuses "$W/v1/install.sh" "$P"
home "a folder in dest is a link"; ok "$W/v1/install.sh"; mkdir -p "$HOME/myfonts/geist"; echo font > "$HOME/myfonts/geist/Geist[wght] x.ttf"; rm -r "${P:?}/fonts"; ln -s "$HOME/myfonts" "$P/fonts"; refuses "$W/v2/install.sh" "$P/fonts/geist"
ok "$B/app-uninstall"; [ "$(cat "$HOME/myfonts/geist/Geist[wght] x.ttf")" = font ] && [ -L "$P/fonts" ] || fail "removed through the link"
home "a file in dest is a link"; ok "$W/v1/install.sh"; echo lib > "$HOME/mylib"; rm "$P/lib/a.so"; ln -s "$HOME/mylib" "$P/lib/a.so"; refuses "$W/v2/install.sh" "$P/lib/a.so"; ok "$B/app-uninstall"; [ "$(cat "$HOME/mylib")" = lib ] && [ -L "$P/lib/a.so" ] || fail "the link"
home "a name of the person's things on the package's list"; cp -r "$W/v1" "$HOME/pkg"; echo n > "$HOME/pkg/notes.db"; relist "$HOME/pkg"; refuses "$HOME/pkg/install.sh" "notes.db"
home "what only the one before had is now behind a link"; ok "$W/v1/install.sh"; mkdir "$HOME/mine1"; cp "$P/only1/old.txt" "$HOME/mine1/"; rm -r "${P:?}/only1"; ln -s "$HOME/mine1" "$P/only1"; ok "$W/v2/install.sh"; [ -f "$HOME/mine1/old.txt" ] || fail "removed through the link"
home "what only the one before had was edited"; ok "$W/v1/install.sh"; echo "my words" > "$P/only1/old.txt"; ok "$W/v2/install.sh"; [ "$(cat "$P/only1/old.txt")" = "my words" ] || fail "removed"
home "lib is a file"; echo f > "$HOME/.local/lib"; refuses "$W/v1/install.sh" "$HOME/.local/lib"
home "a package folder is a file there"; mkdir -p "$P"; echo f > "$P/fonts"; refuses "$W/v1/install.sh" "$P/fonts"

# ---------- its list
home "list that points elsewhere"; ok "$W/v1/install.sh"
n="$(sha256sum < "$HOME/.local/share/app/notes.db")"; n="${n%% *}"
printf '%s  %s\n' "$n" "../../share/app/notes.db" "$n" "$HOME/.local/share/app/notes.db" "$n" "lib/../../../share/app/notes.db" "$n" ".." >> "$P/.manifest"
ok "$W/v2/install.sh"; echo precious > "$HOME/precious"; q="$(sha256sum < "$HOME/precious")"; q="${q%% *}"; echo precious > "$P/../p"
printf '%s  %s\n' "$n" "../../share/app/notes.db" "$n" "~/../x" "$n" "~/.local/share/app/notes.db" "$q" "~/precious" "$q" "./../p" "$q" ".//../p" "$q" "lib/..//../p" "$q" "~/./.local/lib/p" >> "$P/.manifest"; printf '%s  ../p' "$q" >> "$P/.manifest"
ok "$B/app-uninstall"; [ "$(cat "$HOME/precious" "$HOME/.local/lib/p")" = "$(printf 'precious\nprecious')" ] || fail "removed what its list had no business naming"
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

# ---------- where the package lies (review 8)
home "K the package is the notes folder"; rm -r "${HOME:?}/.local/share/app"; cp -r "$W/v1" "$HOME/.local/share/app"; echo "my notes" > "$HOME/.local/share/app/notes.db"; echo wal > "$HOME/.local/share/app/notes.db-wal"; echo mine > "$HOME/.local/share/app/unlisted file.txt"; refuses "$HOME/.local/share/app/install.sh" "$HOME/.local/share/app"
home "K2 the notes folder is a link to the package"; rm -r "${HOME:?}/.local/share/app"; cp -r "$W/v1" "$HOME/apps-app"; ln -s "$HOME/apps-app" "$HOME/.local/share/app"; echo "my notes" > "$HOME/apps-app/notes.db"; refuses "$HOME/apps-app/install.sh" "unpack"
home "K3 the package copied over the notes folder"; cp -r "$W/v1/." "$HOME/.local/share/app/"; refuses "$HOME/.local/share/app/install.sh" "$HOME/.local/share/app"
home "the package inside the notes folder"; cp -r "$W/v1" "$HOME/.local/share/app/pkg"; refuses "$HOME/.local/share/app/pkg/install.sh" "$HOME/.local/share/app"
home "the notes folder inside the package"; cp -r "$W/v1" "$HOME/.apphome"; mkdir "$HOME/.apphome/files"; refuses "$HOME/.apphome/install.sh" "$HOME/.apphome/files"
home "the package is the program folder"; mkdir -p "$P"; cp -r "$W/v1/." "$P/"; refuses "$P/install.sh" "$P"
home "the package inside the program folder"; mkdir -p "$P"; cp -r "$W/v1" "$P/pkg"; refuses "$P/pkg/install.sh" "$P"
home "the package inside what the notes folder links to"; rm -r "${HOME:?}/.local/share/app"; mkdir "$HOME/apps-app"; cp -r "$W/v1" "$HOME/apps-app/pkg"; ln -s "$HOME/apps-app" "$HOME/.local/share/app"; refuses "$HOME/apps-app/pkg/install.sh" "$HOME/.local/share/app"
home "the package in its own data folder"; mkdir -p "$HOME/.apphome"; cp -r "$W/v1" "$HOME/.apphome/files"; refuses "$HOME/.apphome/files/install.sh" "$HOME/.apphome/files"
home "the package in the settings folder, through a link"; mkdir -p "$HOME/.config/app"; cp -r "$W/v1" "$HOME/.config/app/pkg"; ln -s "$HOME/.config/app/pkg" "$HOME/short"; refuses "$HOME/short/install.sh" "$HOME/.config/app"
home "notes and program in one folder"; mkdir -p "$HOME/.local/lib/app"; XDG_DATA_HOME="$HOME/.local/lib" refuses "$W/v1/install.sh" "are in one another"
home "notes inside the program folder"; mkdir -p "$P/x"; XDG_DATA_HOME="$P/x" refuses "$W/v1/install.sh" "are in one another"
home "L a person's files in the package's folder"; cp -r "$W/v1" "$HOME/pkg"; echo notes > "$HOME/pkg/notes.db"; echo mine > "$HOME/pkg/mine.txt"; echo m > "$HOME/mine"; ln -s "$HOME/mine" "$HOME/pkg/linked"; ln "$HOME/mine" "$HOME/pkg/hard"; ok "$HOME/pkg/install.sh"; for x in notes.db mine.txt linked hard; do [ ! -e "$P/$x" ] || fail "$x was installed"; done; ok "$B/app-uninstall"; [ ! -e "$P" ] && [ "$(cat "$HOME/pkg/notes.db" "$HOME/pkg/mine.txt" "$HOME/pkg/hard")" = "$(printf 'notes\nmine\nm')" ] || fail "the person's files"
home "a file of the package changed"; cp -r "$W/v1" "$HOME/pkg"; echo x >> "$HOME/pkg/lib/a.so"; refuses "$HOME/pkg/install.sh" "lib/a.so"
home "a file of the package gone"; cp -r "$W/v1" "$HOME/pkg"; rm "$HOME/pkg/lib/a.so"; refuses "$HOME/pkg/install.sh" "lib/a.so"
home "a file of the package is a link"; cp -r "$W/v1" "$HOME/pkg"; mv "$HOME/pkg/lib/a.so" "$HOME/a.so"; ln -s "$HOME/a.so" "$HOME/pkg/lib/a.so"; refuses "$HOME/pkg/install.sh" "lib/a.so"
home "no list in the package"; cp -r "$W/v1" "$HOME/pkg"; rm "$HOME/pkg/files.sha256"; refuses "$HOME/pkg/install.sh" "files.sha256"
for l in '../x' 'lib/../../x' './x' 'lib//x' '~/x' '.manifest' "$W/abs"; do  # (each there, with its very sha256: only the way it is written is wrong)
  home "list names $l"; export HOME="$W/list-$RANDOM$RANDOM"; mkdir -p "$HOME/.local/share/app"; cp -r "$W/v1" "$HOME/pkg"; mkdir -p "$HOME/pkg/~"; for x in "$HOME/x" "$HOME/pkg/x" "$HOME/pkg/lib/x" "$HOME/pkg/~/x" "$HOME/pkg/.manifest" "$W/abs"; do echo x > "$x"; done
  printf '%s  %s\n' "$(echo x | sha256sum | cut -d' ' -f1)" "$l" >> "$HOME/pkg/files.sha256"; refuses "$HOME/pkg/install.sh" "this package"
done

# ---------- what can't be written (review 8): nothing half done
home "V bin can't be written"; mkdir -p "$B" "$HOME/.local/lib"; chmod 555 "$B"; refuses "$W/v1/install.sh" "$B can't be written to"; chmod 755 "$B"
home "X icons is a file"; echo f > "$HOME/.local/share/icons"; refuses "$W/v1/install.sh" "$HOME/.local/share/icons is in the way"
home "Y applications a dangling link"; ln -s "$HOME/nowhere" "$HOME/.local/share/applications"; refuses "$W/v1/install.sh" "$HOME/.local/share/applications is a link to nothing"
home "Z the list is a folder"; mkdir -p "$P/.manifest"; refuses "$W/v1/install.sh" "$P/.manifest"
home "a folder of the program can't be written"; ok "$W/v1/install.sh"; chmod 555 "$P/lib"; refuses "$W/v2/install.sh" "$P/lib can't be written to"; chmod 755 "$P/lib"
home "a program file that can't be read"; ok "$W/v1/install.sh"; chmod 000 "$P/README.txt"; ! "$W/v2/install.sh" > "$W/log" 2>&1 && grep -q "nothing was changed" "$W/log" || fail "$(cat "$W/log")"; chmod 644 "$P/README.txt"
home "U applications and bin are the person's links"; mkdir -p "$HOME/dot/apps" "$HOME/dot/bin"; ln -s "$HOME/dot/apps" "$HOME/.local/share/applications"; ln -s "$HOME/dot/bin" "$B"; echo q > "$HOME/dot/bin/mytool"; ok "$W/v1/install.sh"; ok "$B/app-uninstall"; [ "$(cat "$HOME/dot/bin/mytool")" = q ] && [ -L "$B" ] || fail "their folders"

# ---------- the layout of before
home "old layout, the same version"; old_layout "$W/v1"; ok "$W/v1/install.sh"
[ "$(readlink "$B/app")" = "$P/app" ] && [ ! -e "$HOME/.local/share/app/app" ] && [ ! -e "$HOME/.local/share/app/lib" ] && ! grep -q 'rm -rf' "$B/app-uninstall" || fail "the program"
ok "$B/app-uninstall"
home "old layout, another version"; old_layout "$W/v1"; ok "$W/v2/install.sh"
[ "$("$B/app")" = "app 2 " ] && [ "$("$HOME/.local/share/app/app")" = "app 1 " ] && grep -q "older program is still in" "$W/log" && [ "$(cat "$I")" = "icon 2" ] || fail "the program"
home "old layout, a linked folder in it"; old_layout "$W/v1"; mkdir "$HOME/mylib"; echo lib > "$HOME/mylib/a.so"; rm -r "${HOME:?}/.local/share/app/lib"; ln -s "$HOME/mylib" "$HOME/.local/share/app/lib"; ok "$W/v1/install.sh"; [ -f "$HOME/mylib/a.so" ] || fail "removed through the link"
home "old layout, its uninstaller edited"; old_layout "$W/v1"; echo "echo mine" >> "$B/app-uninstall"; refuses "$W/v1/install.sh" "$B/app-uninstall"
home "old layout, a foreign icon"; old_layout "$W/v1"; echo "my icon" > "$I"; leaves "$W/v2/install.sh" "$I" 2
home "old layout, its launcher entry edited"; old_layout "$W/v1"; echo "Keywords=mine" >> "$D"; ok "$W/v1/install.sh"; grep -q Keywords=mine "$D" || fail "the entry"; [ "$("$HOME/.local/share/app/app")" = "app 1 " ] || fail "what it starts is gone"

# ---------- the machine
home "no find"; mkdir "$HOME/nognu"; printf '#!/bin/sh\nexit 1\n' > "$HOME/nognu/find"; chmod +x "$HOME/nognu/find"
PATH="$HOME/nognu:$PATH" "$W/v1/install.sh" > "$W/log" 2>&1 || fail "needs find: $(cat "$W/log")"; kept "no find"
home "no sha256sum"; mkdir "$HOME/few"; for c in bash env sh sed grep sort cmp cp mv ln mkdir rmdir rm readlink dirname basename cat chmod mktemp; do ln -s "$(command -v $c)" "$HOME/few/$c"; done
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
