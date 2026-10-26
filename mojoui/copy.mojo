# mojoui.copy: things to read and copy (goal 33 M7, D-415): a row with a small-caps tag, a value in the mono and a copy
# button, a name with its value and a link, code with a small copy button over its corner, a secret shown once. The
# copy itself is the app's (a mojoui.overlays.Clipboard, or CodePanel's own). Sizes and colours come from the theme.
#
#   CopyRow("local", url, COPY_URL)      CopyRow("https · lan", url, COPY_URL, "Copy")      LabeledValue("API key", "$MXC_API_KEY", "manage keys", KEYS)
#   CodePanel(curl, COPY_CURL, copies=self.copies)       SecretField(secret)

from mojoui.view import View, Text, Button, VStack, HStack, Spacer, SUBTLE, PLAIN, ICON_ONLY, CENTER, START, SPACE_XXS, SPACE_S, SPACE_M
from mojoui.table import capitals
from mojoui.codeblock import CodeText
from mojoui.overlays import Clipboard


def CopyRow(tag: String, value: String, on_copy: Int, copy_title: String = "") -> View:
    """A value to copy: a small-caps tag, the value in the mono, then a round copy button (or, with `copy_title`, a
    small text button saying it), in a hairline box (roles copy-row, copy-tag, copy-value, copy-icon, copy-text)."""
    var button = Button("Copy", on_copy, ICON_ONLY, icon="copy").tag("copy-icon") if copy_title == "" else Button(copy_title, on_copy, PLAIN, "copy").tag("copy-text")
    return HStack(Text(capitals(tag)).tag("copy-tag"), Text(value).tag("copy-value").grow(), button^, spacing=SPACE_M).align(CENTER).fill().tag("copy-row")


def LabeledValue(label: String, value: String, link: String = "", on_tap: Int = -1) -> View:
    """A name in the quiet ink, its value in the mono, a link after them (roles labeled-value, value-label, value-text,
    link)."""
    var items: List[View] = [Text(label).tag("value-label"), Text(value).tag("value-text")]
    if link != "":
        items.append(Button(link, on_tap, SUBTLE).tag("link"))
    return HStack(items^, spacing=SPACE_S).align(CENTER).tag("labeled-value")


def CodePanel(code: String, on_copy: Int, copies: Int = 0, copied: Bool = False, title: String = "copy") -> View:
    """Code to copy, its small copy button over the top corner (roles code-panel: the code's surface and type,
    code-panel-copy, code-panel-lines: where the lines sit)."""
    return VStack(HStack(Spacer(), Button("copied" if copied else title, on_copy, SUBTLE).tag("code-panel-copy"), spacing=0).fill(),
                  VStack(CodeText(code), spacing=0).align(START).fill().tag("code-panel-lines"), Clipboard(code, copies),
                  spacing=SPACE_XXS).align(START).tag("code-panel")


def SecretField(text: String, copy_title: String = "", on_copy: Int = -1) -> View:
    """A secret shown once: the mono on the dark code surface, wrapping anywhere (role secret), a small button to copy it
    beside it when `copy_title` is set (roles secret-row, small-tonal)."""
    if copy_title == "":
        return Text(text).grow().tag("secret")
    return HStack(Text(text).grow().tag("secret"), Button(copy_title, on_copy, PLAIN, "copy").tag("small-tonal"), spacing=SPACE_M).align(CENTER).fill().tag("secret-row")
