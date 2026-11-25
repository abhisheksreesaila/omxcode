"""The installer with one check taken out at a time (scripts/install_test.sh --mutants): a case must notice each. Every run is in the
test's own scratch HOMEs; a mutant is the template with one line changed, none of them removes more than one listed file."""
import os, subprocess, sys, tempfile
from pathlib import Path
R = Path(__file__).resolve().parents[1]
src = (R / "linux/install.sh.in").read_text()
M = {
    "bin link not looked at": ('*) stop "$bin/$n isn\'t this program\'s" ;; esac', "*) ;; esac"),
    "old layout's bin link not taken for ours": ('"$dest/$n"|"$old/$n") ;;', '"$dest/$n") ;;'),
    "an edited launcher entry is overwritten": ('&& ! cmp -s -- <(entry "$old/@EX@") "$HOME/$desk"; then put_desk=0; fi', '&& ! grep -q "^Exec=.*@EX@" "$HOME/$desk"; then put_desk=0; fi'),
    "a linked launcher entry is replaced": ('if [ -L "$HOME/$desk" ] || [ ! -f "$HOME/$desk" ]; then put_desk=0', 'if [ ! -f "$HOME/$desk" ]; then put_desk=0'),
    "the old layout's launcher entry isn't known": (' && ! cmp -s -- <(entry "$old/@EX@") "$HOME/$desk"', ""),
    "an icon is always ours": ('if there "$HOME/$icon"; then', "if false; then"),
    "a linked icon is replaced": ('if [ -L "$HOME/$icon" ] || [ ! -f "$HOME/$icon" ]; then put_icon=0', 'if [ ! -f "$HOME/$icon" ]; then put_icon=0'),
    "the uninstaller isn't looked at": ('if there "$HOME/$un"; then', "if false; then"),
    "folder links under dest are fine": ('  ! linked "$dest" "$f" || stop "a folder on the way to $dest/$f is a link"\n', ""),
    "file links in dest are fine": ('[ ! -L "$dest/$f" ] && [ -f "$dest/$f" ] || stop "$dest/$f is in the way: it', '[ -f "$dest/$f" ] || stop "$dest/$f is in the way: it'),
    "dest may be a link": ('[ ! -L "$dest" ] || stop "$dest is a link: the program isn\'t installed through it"\n', ""),
    "an edited file is overwritten": ('&& ! ours "$dest/$f" "$f"; then', "&& false; then"),
    "everything in the package's folder is installed": ('listing="$(cat "$here/files.sha256")"', """listing="$(cd "$here" && find . -type f ! -path ./install.sh ! -path ./files.sha256 | sed 's|^./||' | while IFS= read -r f; do echo "$(sha256sum < "$f" | cut -d' ' -f1)  755 $f"; done)\""""),
    "the package's files aren't checked": ('[ "$(sum "$here/$f")" = "$s" ] || stop "this package isn\'t whole: $f isn\'t what the packager put there"', ":"),
    "a link in the package is followed": ('! linked "$here" "$f" && [ ! -L "$here/$f" ] && [ -f "$here/$f" ] ||', '[ -f "$here/$f" ] ||'),
    "the package may list the person's things": ('  ! kept "$f" || stop "this package lists', '  true || stop "this package lists'),
    "the package may lie in its own places": ('  ! inside "$here" "$d" || stop', "  true || stop"),
    "its own places may lie in the package": ('  ! inside "$d" "$here" || stop', "  true || stop"),
    "only names are compared, not folders": ('while :; do [ ! "$p" -ef "$2" ] || return 0;', 'while :; do [ "$p" != "$2" ] || return 0;'),
    "program and notes may be in one another": ('  ! inside "$dest" "$d" && ! inside "$d" "$dest" && [ "$d" != "$dest" ] || stop', "  true || stop"),
    "the app's own data folder isn't known": ('for d in @DATA@; do data+=("$HOME/$d"); done\n', ""),
    "XDG_DATA_HOME isn't known": ('case "${XDG_DATA_HOME:-}" in /*) data+=("$XDG_DATA_HOME/@EX@") ;; esac\n', ""),
    "whether it can be written isn't looked at": ('[ -w "$p" ] && [ -x "$p" ] || stop "$p can\'t be written to"', ":"),
    "links to nothing aren't looked at": ('[ -e "$p" ] || stop "$p is a link to nothing"', ":"),
    "any path is a path": ('''plain() { case "$1" in ''|/*|*//*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|"~"*|*$'\\n'*|*$'\\r'*) return 1 ;; esac; return 0; }''', "plain() { [ -n \"$1\" ]; }"),
    "a list that is a folder is fine": ('[ ! -L "$manifest" ] && [ -f "$manifest" ] && [ -r "$manifest" ] || stop', "true || stop"),
    "both lists not kept (the new one only)": ("""printf '%s\\n%s\\n' "$mine" "$new" | grep""", """printf '%s\\n%s\\n' "$new" "$new" | grep"""),
    "both lists not kept (the old one only)": ("""printf '%s\\n%s\\n' "$mine" "$new" | grep""", """printf '%s\\n%s\\n' "$mine" "$mine" | grep"""),
    "what the one before had: through links": ('|| linked "$dest" "$f" || [ -L "$dest/$f" ]', '|| [ -L "$dest/$f" ]'),
    "what the one before had: whatever it says now": ('if [ "$(sum "$dest/$f" 2>/dev/null || true)" = "$s" ]; then', "if true; then"),
    "old layout: no comparing": (' && [ "$(sum "$old/$1" 2>/dev/null || true)" = "$2" ]; }', "; }"),
    "old layout: through links": (' && ! linked "$old" "$1" &&', " &&"),
    "old layout: taken away from under an entry that was left": ('[ "$put_desk" = 1 ] && [ -d "$old" ]', '[ -d "$old" ]'),
    "old layout: whoever put it there": ('apart="$by_old"; [', "apart=1; ["),
    "old layout: some of it": ('&& ! same_there "$f" "$s"; then apart=0; fi', '&& ! same_there "$f" "$s"; then :; fi'),
    "old layout: its uninstaller isn't known": ('if cmp -s -- <(old_uninstaller 1) "$HOME/$un" || cmp -s -- <(old_uninstaller 0) "$HOME/$un"; then by_old=1; fi\n', ""),
    "an entry that was left: the wrong words": ('if [ "$put_desk" = 1 ]; then say "$was', 'if true; then say "$was'),
    "modes as they come": ('chmod "$3" -- "$half"; ', ""),
    "any mode": ('case "$m" in 644|755) ;;', 'case "$m" in *) ;;'),
    "anyone's HOME": ('[ -O "$HOME" ] || stop', "true || stop"),
    "sudo is fine": ('[ "$EUID" != 0 ] || [ -z "${SUDO_USER:-}" ]', 'true || [ -z "${SUDO_USER:-}" ]'),
    "sudo -u is refused": ('[ "$EUID" != 0 ] || [ -z "${SUDO_USER:-}" ]', '[ -z "${SUDO_USER:-}" ]'),
    "uninstall: any place under HOME": ('''    ''|/*|*//*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|"~"*) continue ;;
    *) if''', '''    "~/"*) root="${HOME:?}"; f="${f#??}" ;;
    ''|/*|*//*|.|..|./*|../*|*/./*|*/../*|*/.|*/..) continue ;;
    *) if'''),
    "uninstall: paths out of the folder": ("""''|/*|*//*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|"~"*) continue ;;\n    *) if""", """''|/*|"~"*) continue ;;\n    *) if"""),
    "uninstall: whatever it says now": ('if [ "$h" != "$s" ]; then grep', 'if false; then grep'),
    "uninstall: through folder links": ('*) if linked "$dest" "$f"; then continue; fi ;;', "*) ;;"),
    "uninstall: file links": ('if [ ! -f "$root/$f" ] || [ -L "$root/$f" ]; then continue; fi', 'if [ ! -f "$root/$f" ]; then continue; fi'),
    "uninstall: any bin link": ('if [ "$(readlink "$bin/$n" 2>/dev/null || true)" = "$dest/$n" ]; then', 'if [ "$n" = "@EX@" ]; then'),
    "Exec not quoted": ('entry "$(quoted "$dest/@EX@")" > "$work/desk"', 'entry "$dest/@EX@" > "$work/desk"'),
    "Exec quoted once": ("-e 's/\\$/\\\\\\\\$/g'", "-e 's/\\$/\\\\$/g'"),
    "a half file left": ('; if [ -n "$half" ]; then rm -f -- "${half:?}"; fi\'', "'"),
    "works without sha256sum": ("basename sha256sum mktemp", "basename mktemp"),
}
bad = 0
for name, (a, b) in M.items():
    if src.count(a) != 1:
        print("BAD  mutant not found:", name, src.count(a)); bad += 1; continue
    with tempfile.NamedTemporaryFile("w", suffix=".in", delete=False) as f:
        f.write(src.replace(a, b))
    r = subprocess.run(["timeout", "90", "scripts/install_test.sh"], cwd=R, env=dict(os.environ, TEMPLATE=f.name), capture_output=True, text=True)
    os.unlink(f.name)
    out = (r.stdout.strip().splitlines() or [r.stderr.strip()[-120:]])[-1]
    noticed = r.returncode not in (0, 124)
    print("ok  " if noticed else "BAD ", name, "|", out[:150], flush=True)
    bad += not noticed
print("install_mutants:", "ok" if not bad else f"BAD {bad}", len(M))
sys.exit(1 if bad else 0)
