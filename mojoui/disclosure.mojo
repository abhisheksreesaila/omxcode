# mojoui.disclosure: a section that folds: a quiet header with a chevron (tag="disclosure-head"), and its body under
# it while open (tag="disclosure-body"). The app keeps whether it's open; tapping the header sends on_toggle. The whole
# is tag="disclosure". (AgentChat's reasoning, "Thought"; an FAQ, details under a summary.)
#
#   Disclosure("Thought", self.open, on_toggle=TOGGLE, [Markdown(text)])

from mojoui.view import View, Button, VStack, SUBTLE, START, SPACE_XS


def Disclosure(title: String, open: Bool, on_toggle: Int, var body: List[View]) -> View:
    """`title` with a chevron (down while open, right while folded), then `body` when open, set in a little."""
    var parts = List[View]()
    parts.append(Button(title, on_toggle, style=SUBTLE, icon="chevron" if open else "chevron-right")
                 .tag("disclosure-head"))
    if open:
        parts.append(VStack(body^, spacing=SPACE_XS).align(START).fill().padding(0, 20).tag("disclosure-body"))
    return VStack(parts^, spacing=SPACE_XS).align(START).fill().tag("disclosure")
