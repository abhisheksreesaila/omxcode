"""The installer with one check taken out at a time (scripts/install_test.sh --mutants): a case must notice each. Every run is in the
test's own scratch HOMEs; a mutant is the template with one line changed, none of them removes more than one listed file."""
import os, subprocess, sys, tempfile
from pathlib import Path
R = Path(__file__).resolve().parents[1]
src = (R / "linux/install.sh.in").read_text()
M = {
    "bin link not looked at": ('*) stop "$bin/$n isn\'t this program\'s" ;; esac', "*) ;; esac"),
    "old layout's bin link not taken for ours": ('"$dest/$n"|"$old/$n") ;;', '"$dest/$n") ;;'),
    "launcher entry not looked at": ('outside "$desk"; ', ""),
    "icon not looked at": ('outside "$icon"; ', ""),
    "uninstaller not looked at": ('; outside "$un"\n', "\n"),
    "any Exec that mentions it": ('"Exec=$p"|"Exec=$p "*', '*"$p"*'),
    "a link outside is fine": ('[ ! -L "$f" ] && [ -f "$f" ] || stop "$f isn\'t', '[ -f "$f" ] || stop "$f isn\'t'),
    "no proof by the list outside": ('! listed "$(sum "$f")" "~/$1" || return 0\n', "\n"),
    "folder links under dest are fine": ('! linked "$dest" "$f" || stop "a folder on the way to $dest/$f is a link"\n', "\n"),
    "file links in dest are fine": ('[ ! -L "$dest/$f" ] && [ -f "$dest/$f" ] || stop "$dest/$f is in the way: it', '[ -f "$dest/$f" ] || stop "$dest/$f is in the way: it'),
    "dest may be a link": ('[ ! -L "$dest" ] || stop "$dest is a link: the program isn\'t installed through it"\n', "\n"),
    "an edited file is overwritten": ('&& ! listed "$(sum "$dest/$f")" "$f"; then', "&& false; then"),
    "both lists not kept (the new one only)": ("""printf '%s\\n%s\\n' "$mine" "$new" | grep""", """printf '%s\\n%s\\n' "$new" "$new" | grep"""),
    "both lists not kept (the old one only)": ("""printf '%s\\n%s\\n' "$mine" "$new" | grep""", """printf '%s\\n%s\\n' "$mine" "$mine" | grep"""),
    "what the one before had: guard off": ("case \"$f\" in ''|\"~/\"*|/*|..|../*|*/../*|*/..) continue ;; esac  # (a list", "case \"$f\" in '') continue ;; esac  # (a list"),
    "what the one before had: through links": ('|| linked "$dest" "$f" || [ -L "$dest/$f" ]', '|| [ -L "$dest/$f" ]'),
    "what the one before had: whatever it says now": ('if [ "$(sum "$dest/$f")" = "$s" ]; then', "if true; then"),
    "old layout: no comparing": ('&& ! linked "$old" "$f" && cmp -s -- "$here/$f" "$old/$f"; then', '&& ! linked "$old" "$f"; then'),
    "old layout: through links": ('&& ! linked "$old" "$f" && cmp', "&& cmp"),
    "uninstall: the list's guard off": ("""case "$f" in ''|/*|..|../*|*/../*|*/..) continue ;; esac\n  root=""", """case "$f" in '') continue ;; esac\n  root="""),
    "uninstall: whatever it says now": ('if [ "$h" != "$s" ]; then grep', 'if false; then grep'),
    "uninstall: through folder links": ('if [ "$root" = "$dest" ] && linked "$root" "$f"; then continue; fi\n', "\n"),
    "uninstall: file links": ('if [ ! -f "$root/$f" ] || [ -L "$root/$f" ]; then continue; fi', 'if [ ! -f "$root/$f" ]; then continue; fi'),
    "uninstall: any bin link": ('if [ "$(readlink "$bin/$n" 2>/dev/null || true)" = "$dest/$n" ]; then', 'if [ "$n" = "@EX@" ]; then'),
    "Exec not quoted": ('Exec=$(quoted "$dest/@EX@") %f', "Exec=$dest/@EX@ %f"),
    "Exec quoted once": ("-e 's/\\$/\\\\\\\\$/g'", "-e 's/\\$/\\\\$/g'"),
    "a half file left": ('; if [ -n "$half" ]; then rm -f -- "${half:?}"; fi\'', "'"),
    "works without sha256sum": ("dirname sha256sum mktemp", "dirname mktemp"),
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
