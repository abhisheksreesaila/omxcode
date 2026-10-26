# mojoui.breadcrumbs: where you are, as a plain trail (the console's top bar: My models › qwen2.5-0.5b). Earlier parts are
# quiet buttons that go there (tag="crumb"), a chevron between them (tag="crumb-sep"), the last is text: where you are
# (tag="crumb-here", or tag="crumb-here-mono" for a name in the mono). The trail itself is tag="breadcrumbs".
#
#   Breadcrumbs(["My models", "qwen2.5-0.5b"], on_tap=CRUMB, mono_last=True)   # CRUMB + 0: My models

from mojoui.view import View, Text, Button, Icon, HStack, SUBTLE, CENTER, START


def Breadcrumbs(items: List[String], on_tap: Int, mono_last: Bool = False, compact: Bool = False) -> View:
    """The trail: tapping part k (not the last) sends on_tap + k; `compact`: only where you are, a little larger
    (tag="crumb-here-compact"; a narrow bar)."""
    if compact and len(items) > 0:
        var here = Text(items[len(items) - 1]).tag("crumb-here-compact")
        if mono_last:
            here = Text(items[len(items) - 1]).tag("crumb-here-compact-mono")
        var last: List[View] = [here^]
        return HStack(last^, spacing=4).align(CENTER).justify(START).tag("breadcrumbs")
    var parts: List[View] = []
    for k in range(len(items)):
        if k > 0:
            parts.append(Icon("chevron-right", 14).tag("crumb-sep"))
        if k == len(items) - 1:
            parts.append(Text(items[k]).tag("crumb-here-mono") if mono_last else Text(items[k]).tag("crumb-here"))
        else:
            parts.append(Button(items[k], on_tap + k, style=SUBTLE).tag("crumb"))
    return HStack(parts, spacing=4).align(CENTER).justify(START).tag("breadcrumbs")
