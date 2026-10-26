# mojoui.words: lines of words in the theme's voices (goal 33 M7, D-415): a quiet line, a few strong words, a mono line
# (quiet, faint, strong, a table cell's), the command that shows the same thing ($ mxc ls). Type and colour come from
# the theme's roles.
#
#   QuietText("3 models · 1 running")     MonoLine("Qwen/Qwen2.5-0.5B-Instruct")     CommandLine("mxc ls")

from mojoui.view import View, Text, HStack, VStack, CENTER, START, SPACE_XXS, SPACE_XS


def QuietText(text: String) -> View:
    """Words in the quiet ink, a little smaller (role quiet)."""
    return Text(text).tag("quiet")


def Strong(text: String) -> View:
    """A few strong words (role strong)."""
    return Text(text).tag("strong")


def MonoLine(text: String, quiet: Bool = False) -> View:
    """A line in the mono, in the quiet ink (role mono-line; mono-faint fainter still)."""
    return Text(text).tag("mono-faint" if quiet else "mono-line")


def MonoStrong(text: String) -> View:
    """A figure or a name in the mono, strong (role mono-strong)."""
    return Text(text).tag("mono-strong")


def MonoText(text: String) -> View:
    """Words in the mono at the size of a table's cells, quiet (role mono-text)."""
    return Text(text).tag("mono-text")


def CommandLine(command: String) -> View:
    """The command that shows the same thing, after a faint $ (roles command-line, command-dollar)."""
    return HStack(Text("$").tag("command-dollar"), Text(command), spacing=SPACE_XS).align(CENTER).tag("command-line")


def CommandLines(commands: List[String]) -> View:
    """Commands one under another, each a CommandLine (role command-lines)."""
    var lines: List[View] = []
    for c in commands:
        lines.append(CommandLine(c))
    return VStack(lines^, spacing=SPACE_XXS).align(START).tag("command-lines")


def ErrorLine(text: String) -> View:
    """What went wrong, in the bad colour (role error-line)."""
    return Text(text).tag("error-line")


def WarnLine(text: String) -> View:
    """A caution, in the warning colour (role warn-line)."""
    return Text(text).tag("warn-line")


def Muted(text: String, mono: Bool = False) -> View:
    """Words at the body's size in the quiet ink (roles muted, mono-muted)."""
    return Text(text).tag("mono-muted" if mono else "muted")


def MonoParagraph(text: String) -> View:
    """A paragraph in the mono, quiet, with room between its lines (role mono-paragraph)."""
    return Text(text).tag("mono-paragraph")


def Mono(text: String) -> View:
    """Words in the mono at the size and colour of what holds them (a table's cell; role mono)."""
    return Text(text).tag("mono")


def Hint(text: String) -> View:
    """A sentence of advice in the quiet ink, kept to a readable width, with room above it of its own (role hint: a
    page's note, margin 10 0 0): put it in a flowing body (CardBody(flow=True)), where margins set the space."""
    return Text(text).tag("hint")


def CellText(text: String, mono: Bool = False, quiet: Bool = False, strong: Bool = False) -> View:
    """Words at the size of the table cell that holds them: plain or in the mono, quiet, strong (roles cell-text,
    cell-text-quiet, cell-mono, cell-mono-quiet, cell-mono-strong, cell-text-strong)."""
    var role = String("cell-mono") if mono else String("cell-text")
    return Text(text).tag(role + ("-strong" if strong else ("-quiet" if quiet else "")))
