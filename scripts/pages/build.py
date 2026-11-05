"""Builds the pages that show real code: docs/learn/index.html (the deck) and docs/tasks.html (tutorial 2).

    pixi run python scripts/pages/build.py

{{BLOCK file a-b}} pastes lines a..b of a repository file, dedented and highlighted; scripts/tutorials.py then holds
the page to that file (a block that stops matching fails the check). {{SAMPLE name}} pastes an illustrative sample
from scripts/pages/samples/ (typical code from other stacks, for comparison; not checked against anything).
"""
import html, re, textwrap
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
MOJO = r"\b(from|import|comptime|struct|var|def|return|if|elif|else|for|in|while|try|except|raises|not|and|or)\b"
C = (r"\b(__global__|__device__|void|int|float|unsigned|const|return|if|else|for|while|struct|auto|uniform|in|out|vec2|vec4|"
     r"sampler2D|uint|kernel|device|texture2d|access|let|var|func|import|class|override|guard|self|true|false|nullptr)\b")


def hl(line, kw, comment):
    """One line: its comment, then strings, then keywords."""
    code, com = line, ""
    m = re.search(comment, line)
    if m and line.count('"', 0, m.start()) % 2 == 0:
        code, com = line[:m.start()], line[m.start():]
    out = ""
    for i, p in enumerate(re.split(r'("(?:[^"\\]|\\.)*")', code)):
        if i % 2:
            out += '<span class="s">' + html.escape(p, quote=False) + "</span>"
        else:
            out += re.sub(kw, r'<span class="k">\1</span>', html.escape(p, quote=False))
    if com:
        out += '<span class="c">' + html.escape(com, quote=False) + "</span>"
    return out


def mojo_lines(lines):
    """Mojo or Python, with docstrings shown as comments."""
    out, inside = [], False
    for l in lines:
        if inside or l.strip().startswith('"""'):
            out.append('<span class="c">' + html.escape(l, quote=False) + "</span>")
            n = l.count('"""')
            inside = (n == 0) if inside else (n == 1)
        else:
            out.append(hl(l, MOJO, r"  # |^# |^\s*# "))
    return out


def block(path, a, b):
    src = (ROOT / path).read_text().splitlines()
    return "\n".join(mojo_lines(textwrap.dedent("\n".join(src[a - 1:b])).split("\n")))


def sample(name):
    lines = (HERE / "samples" / name).read_text().rstrip("\n").split("\n")
    return "\n".join(hl(l, C, r"//") for l in lines)


def render(tpl, style, out):
    s = (HERE / tpl).read_text().replace("{{STYLE}}", (HERE / style).read_text().rstrip("\n"))
    s = re.sub(r"\{\{BLOCK (\S+) (\d+)-(\d+)\}\}", lambda m: block(m.group(1), int(m.group(2)), int(m.group(3))), s)
    s = re.sub(r"\{\{SAMPLE (\S+)\}\}", lambda m: sample(m.group(1)), s)
    (ROOT / out).write_text(s)
    print("built", out)


if __name__ == "__main__":
    render("tasks.tpl.html", "tasks-style.html", "docs/tasks.html")
    render("deck.tpl.html", "deck-style.html", "docs/learn/index.html")
