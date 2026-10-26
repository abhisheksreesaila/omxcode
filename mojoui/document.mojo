# mojoui.document: a document of cells to read (goal 33 M7, D-415; a notebook): markdown cells, code cells with their
# run count, an outline of its chapters to jump to, key-value rows in the mono, and the three-column layout (the
# outline, the cells, an aside) that folds to one column when compact. Sizes come from the theme's roles.
#
#   DocLayout(Outline("Chapters", titles, levels, CHAPTER), VStack(cells), VStack(aside cards), compact=phone)

from mojoui.view import View, Text, Button, VStack, HStack, Scroll, Divider, SUBTLE, CENTER, START, STRETCH, BASELINE, SPACE_XXS, SPACE_XS, SPACE_S, SPACE_M, SPACE_L
from mojoui.markdown import Markdown
from mojoui.codeblock import CodeText
from mojoui.table import capitals
from mojoui.panel import Card


def MarkdownCell(text: String) -> View:
    """A markdown cell: its text set as a card (roles markdown-cell; the words mojoui.markdown's)."""
    return Card([VStack(Markdown(text, line_chars=86), spacing=0).align(START).fill().tag("markdown-cell")])


def CodeCell(label: String, code: String) -> View:
    """A code cell: its run count ([3]) beside its code on the dark code surface, as a card (roles code-cell,
    code-cell-label, code-cell-code)."""
    return Card([HStack(Text(label).tag("code-cell-label"), VStack(CodeText(code), spacing=0).align(START).grow().tag("code-cell-code"),
                        spacing=0).align(STRETCH).fill().tag("code-cell")])


def Outline(title: String, titles: List[String], levels: List[Int], on_tap: Int) -> View:
    """A document's chapters to jump to, numbered, indented by level (1, 2); chapter k sends on_tap + k (roles outline,
    outline-head, outline-row-1, outline-row-2, outline-number, chapter-1, chapter-2)."""
    var items: List[View] = [Text(capitals(title)).tag("outline-head")]
    for k in range(len(titles)):
        var level = String(min(max(levels[k] if k < len(levels) else 1, 1), 2))
        items.append(HStack(Text(String(k + 1)).tag("outline-number"), Button(titles[k], on_tap + k, SUBTLE).align(START).grow().tag("chapter-" + level),
                            spacing=SPACE_S).align(BASELINE).fill().tag("outline-row-" + level))
    return VStack(items^, spacing=SPACE_XXS).align(START).fill().tag("outline")


def SpecRows(keys: List[String], values: List[String]) -> View:
    """Key-value rows in the mono, the keys in a column (roles spec-rows, spec-row, spec-key)."""
    var rows: List[View] = []
    for k in range(len(keys)):
        rows.append(HStack(Text(keys[k]).tag("spec-key"), Text(values[k] if k < len(values) else String("")).tag("mono-line"), spacing=SPACE_M).align(START).justify(START).fill().tag("spec-row"))
    return VStack(rows^, spacing=SPACE_S).align(START).fill().tag("spec-rows")


def DocLayout(outline: View, cells: View, aside: View, compact: Bool = False) -> View:
    """The outline, a rule, the cells (scrolling, taking the rest) and an aside side by side (roles doc-layout,
    doc-outline, doc-main, doc-aside: the side columns' widths and every column's insets); compact: the cells over the
    aside, no outline (doc-layout-compact)."""
    if compact:
        return VStack(cells.copy(), aside.copy().fill(), spacing=SPACE_M).align(START).fill().tag("doc-layout-compact")
    return HStack(HStack(outline.copy(), spacing=0).align(START).tag("doc-outline"), Divider().fill(),
                  Scroll(HStack(cells.copy().grow(), spacing=0).align(START).fill().tag("doc-main"), height=0).grow(),
                  HStack(aside.copy().grow(), spacing=0).align(START).tag("doc-aside"), spacing=0).align(STRETCH).fill().grow().tag("doc-layout")
