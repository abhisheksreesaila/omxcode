# mojoui.codeblock: code to read and copy (the console's curl, a key, an endpoint): its lines in the theme's mono on the
# code surface (the framework role "code-block", tag="code-block"), a Copy button beside them (tag="code-copy") that
# says "Copied" while the app says so; the copy itself is a Clipboard view (mojoui.overlays), so every host copies alike.
#
#   CodeBlock(self.curl, on_copy=COPY, copies=self.copies, copied=self.copied)   # update(): self.copies += 1 on COPY

from mojoui.view import View, Text, Button, VStack, HStack, SUBTLE, START
from mojoui.overlays import Clipboard


def keep_spaces(line: String) -> String:
    """A line's leading spaces as no-break spaces, so an indented line keeps its indent where text is reflowed (the web)."""
    var out = String("")
    var leading = True
    for c in line.codepoint_slices():
        if leading and String(c) == " ":
            out += chr(160)
        else:
            leading = False
            out += String(c)
    return out


def code_lines(code: String) -> List[View]:
    var out: List[View] = []
    for line in code.split("\n"):
        out.append(Text(keep_spaces(String(line)) if String(line) != "" else chr(160)))
    return out^


def CodeText(code: String) -> View:
    """Just the lines (the mono and the code colours come from the role of whatever holds them): a notebook's code
    cell, which has no Copy button (mojoui.markdown), and CodeBlock's own text."""
    return VStack(code_lines(code), spacing=0).align(START)


def CodeBlock(code: String, on_copy: Int, copies: Int = 0, copied: Bool = False, title: String = "Copy") -> View:
    """`code` (one or more lines) with a Copy button: tapping it sends `on_copy`; the app counts `copies` up (the
    clipboard's version: each new one copies `code` again) and may show `copied` for a moment (the button then says
    Copied, as the console's does for 1.4 s)."""
    return VStack(
        HStack(
            CodeText(code).grow(),
            Button("Copied" if copied else title, on_copy, style=SUBTLE, icon="copy").tag("code-copy"),
            spacing=8,
        ).align(START).fill(),
        Clipboard(code, copies),
        spacing=0,
    ).tag("code-block")
