# mojoui.look: the rules GTK and the web write from a theme's Look (goal 32, owner 2026-10-24: "if I just drop those
# components in another app it should just work out of the box… one language plus custom CSS and people lose
# interest"). The Look itself (a type scale, the controls' sizes, a Surface per framework role) is theme vocabulary,
# in mojoui/theme.mojo; AppKit draws the same values with fonts, layers, corners and shadows. A theme's hand-written
# CSS keeps only what one host alone can do (keyframes, hover springs, a backdrop blur's fallback).

from mojoui.canvas import rgba
from mojoui.theme import Look, Surface, Shadow, TypeScale, Controls, Motion
from mojoui.view import View, VSTACK, HSTACK, GRID, TABLE, space_value


# ---- the rules GTK and the web write from a look ----

def css_color(c: UInt32) -> String:
    var a = Int((c >> 24) & 255)
    var rgb = String(Int(c & 255)) + "," + String(Int((c >> 8) & 255)) + "," + String(Int((c >> 16) & 255))
    if a == 255:
        return "rgb(" + rgb + ")"
    var hundredths = (a * 100 + 127) // 255
    return "rgba(" + rgb + "," + ("0." + ("0" if hundredths < 10 else "") + String(hundredths) if hundredths < 100 else String("1")) + ")"


def px(v: Int) -> String:
    return "0" if v == 0 else String(v) + "px"


def fpx(v: Float64) -> String:
    var i = Int(v)
    return (String(i) if Float64(i) == v else String(v)) + "px"


def text_only(s: Surface) -> Bool:
    """A role the look gives type only (words()): no box rule is written for it."""
    return (s.fill == 0 and s.radius_top < 0 and s.margin_top < 0 and s.pad_top < 0 and len(s.shadows) == 0 and s.line_top == 0
            and s.line_bottom == 0 and s.min_height <= 0 and s.outline == 0 and s.gap < 0 and s.height == 0 and s.width == 0 and not s.scrolls_x and not s.shares and not s.shrinks and not s.items_shrink and not s.whole_width and not s.block_flow and not s.joins_row and not s.ends_row and s.text_align != 2 and not s.one_line and not s.inline_flow and s.max_chars == 0)


def surface_rule(s: Surface, web: Bool) -> String:
    """The declarations for one surface (no selector)."""
    var out = String("")
    if s.fill != 0:
        out += "background: " + css_color(s.fill) + "; "
    else:
        out += "background: transparent; "
    if s.radius_top >= 0:
        out += "border-radius: " + (px(s.radius_top) if s.radius_top == s.radius_bottom else px(s.radius_top) + " " + px(s.radius_top) + " " + px(s.radius_bottom) + " " + px(s.radius_bottom)) + "; "
    if s.margin_top >= 0:
        out += "margin: " + px(s.margin_top) + " " + px(s.margin_x) + " " + px(s.margin_bottom) + "; "
    if s.pad_top >= 0:
        if s.pad_left >= 0 or s.pad_right >= 0:  # (leading and trailing apart: top right bottom left)
            out += ("padding: " + px(s.pad_top) + " " + px(s.pad_right if s.pad_right >= 0 else s.pad_x) + " " + px(s.pad_bottom) + " "
                    + px(s.pad_left if s.pad_left >= 0 else s.pad_x) + "; ")
        else:
            out += "padding: " + px(s.pad_top) + (" " + px(s.pad_x) if s.pad_x != s.pad_top or s.pad_bottom != s.pad_top else "") + (" " + px(s.pad_bottom) if s.pad_bottom != s.pad_top else "") + "; "
        if web:
            out += "box-sizing: border-box; "
    var shadow = String("")
    for sh in s.shadows:
        shadow += (", " if shadow != "" else "") + ("inset " if sh.inset else "") + "0 " + px(sh.y) + " " + px(sh.blur) + (" " + px(sh.spread) if sh.spread != 0 else "") + " " + css_color(sh.color)
    out += "box-shadow: " + (shadow if shadow != "" else "none") + "; "
    out += "border: 0; " if web else "border-bottom: none; border-top: none; "
    if s.line_top != 0:
        out += "border-top: 1px solid " + css_color(s.line_top) + "; "
    if s.line_bottom != 0:
        out += "border-bottom: 1px solid " + css_color(s.line_bottom) + "; "
    if web and s.blur > 0:
        out += "-webkit-backdrop-filter: blur(" + String(s.blur) + "px) saturate(1.6); backdrop-filter: blur(" + String(s.blur) + "px) saturate(1.6); "
    if s.outline != 0:
        out += "border: " + px(s.outline_w) + (" dashed " if s.dashed else " solid ") + css_color(s.outline) + "; "
    if s.min_height > 0:  # (the web's boxes are border-box; GTK's min-height is the content's: padding and lines come off)
        out += "min-height: " + px(s.min_height if web else gtk_content_h(s, s.min_height)) + "; "
    if s.height > 0:
        out += ("height: " + px(s.height) + "; min-height: " + px(s.height) + "; ") if web else ("min-height: " + px(gtk_content_h(s, s.height)) + "; ")
    elif s.height == -2:  # (HEIGHT_AUTO)
        out += "height: auto; min-height: 0; " if web else "min-height: 0; "
    if s.width == 0 and s.shrinks and web:  # (no set width: it gives way below its content when its row is short, what overflows cut)
        out += "min-width: 0 !important; flex-shrink: 1 !important; overflow: hidden; "
    if s.width > 0:
        if web and s.shrinks:
            out += "width: " + px(s.width) + "; min-width: 0 !important; flex-shrink: 1 !important; "  # (over the inline size every host gets)
        else:
            out += ("width: " + px(s.width) + "; min-width: " + px(s.width) + "; flex-shrink: 0; ") if web else ("min-width: " + px(gtk_content_w(s, s.width)) + "; ")
    if s.gap >= 0 and web:  # (over the stack's own inline gap; GTK and the Mac take it as the stack's spacing from
        # resolve_layout: GTK adds a box's CSS border-spacing to its spacing, so writing both doubled the gap)
        out += "gap: " + px(s.gap) + " !important; "
    if s.text_align == 2 and web:  # (centred: a button's icon and word in its middle too)
        out += "justify-content: center; "
    if s.one_line and web:
        out += "flex-wrap: nowrap; "
    if s.inline_flow and web:
        out += "display: block; "
    if s.joins_row and web:
        out += "display: contents !important; "  # (over a host's own display for the view)
    if s.ends_row and web:
        out += "margin-left: auto; "
    if s.block_flow and web:  # (block flow: margins collapse as CSS's; its children are blocks that fill its width)
        out += "display: block; "
    if s.whole_width and web:  # (the web host's script reads the marker and sets the width to the content's whole pixels)
        out += "--mojoui-whole-width: 1; "
    if s.max_chars > 0 and web:  # (its measure; GTK's labels take it as max-width-chars, the Mac's as a width of "0"s)
        out += "max-width: " + String(s.max_chars) + "ch; "
    if s.shares and web:
        out += "flex: 1 1 0% !important; min-width: auto !important; "
    if s.scrolls_x and web:
        out += "flex-wrap: nowrap; overflow-x: auto; scrollbar-width: none; "
    if s.column_gap >= 0 and web:
        out += "column-gap: " + px(s.column_gap) + " !important; "
    return out


def gtk_content_h(s: Surface, outer: Int) -> Int:
    """The content height GTK must be given for a box `outer` high overall (the web's border-box), the surface's
    padding and lines taken off (D-441)."""
    var inner = outer - max(s.pad_top, 0) - max(s.pad_bottom, 0)
    if s.line_top != 0:
        inner -= 1
    if s.line_bottom != 0:
        inner -= 1
    if s.outline != 0:
        inner -= 2 * s.outline_w
    return max(inner, 0)


def gtk_content_w(s: Surface, outer: Int) -> Int:
    """The content width GTK must be given for a box `outer` wide overall (the web's border-box), its side padding and
    outline taken off (as gtk_content_h)."""
    var left = s.pad_left if s.pad_left >= 0 else max(s.pad_x, 0)
    var right = s.pad_right if s.pad_right >= 0 else max(s.pad_x, 0)
    var inner = outer - left - right
    if s.outline != 0:
        inner -= 2 * s.outline_w
    return max(inner, 0)


def ratio(v: Float64) -> String:
    """A number to four places, trailing zeros dropped (1.6, 1.45, 1.3)."""
    var n = Int(v * 10000 + 0.5)
    var out = String(n // 10000)
    var frac = n % 10000
    if frac != 0:
        var digits = String(frac + 10000)  # ("1" + four digits)
        var end = 5
        while end > 2 and digits.as_bytes()[end - 1] == 48:  # (trailing zeros dropped)
            end -= 1
        out += "." + String(digits[byte = 1 : end])
    return out^


def line_px(v: Float64) -> String:
    """A line height in px to a tenth."""
    return fpx(Float64(Int(v * 10 + 0.5)) / 10)


def text_rule(s: Surface, web: Bool = False, line: Float64 = 0) -> String:
    var out = String("")
    if s.font != "":
        out += "font-family: '" + s.font + "', " + ("monospace" if "Mono" in s.font else "sans-serif") + "; "
    if s.font_size > 0:
        out += "font-size: " + fpx(s.font_size) + "; "
    if s.font_weight > 0:
        out += "font-weight: " + String(s.font_weight) + "; "
    if s.tracking != 0:
        out += "letter-spacing: " + fpx(s.tracking) + "; "
    if web and s.line_height > 0 and s.font_size > 0:  # (a line set against its own size is written as CSS's number, 1.6, which
        # the browser resolves as the original's unitless line-heights do: 11.5 × 1.6 rounds down to 18.39 px, while 18.4px
        # rounds up to 18.41 and a log's lines drifted a pixel in fifteen, D-482)
        out += "line-height: " + ratio(s.line_height / s.font_size) + "; "
    elif web and s.line_height > 0:
        out += "line-height: " + fpx(s.line_height) + "; "
    elif web and s.line_height < 0:  # (the font's own line: CSS's normal)
        out += "line-height: normal; "
    elif not web and line > 0 and (s.line_height != 0 or s.font_size > 0):
        # (GTK: in px, as the web's lines measure, D-444; only for a look that declares its line: TypeScale.line 0 keeps
        # GTK's labels at the font's own lines, as before: D-460; below 0: the font's own, over the look's label line: GTK
        # reads a bare number as a factor of the font's own line, so 1 (it drops "normal": the look's label line won, D-496)
        out += "line-height: " + ("1" if s.line_height < 0 else line_px(s.line_height if s.line_height > 0 else s.font_size * line)) + "; "
    if web and s.breaks_words:  # (GTK: its labels wrap at any character, PANGO_WRAP_WORD_CHAR; the Mac: character wrapping)
        out += "overflow-wrap: anywhere; "
    if web and s.one_line:  # (its words on one line too; GTK and the Mac cut them with an ellipsis: the hosts read one_line)
        out += "white-space: nowrap; "
    if web and s.text_align > 0:
        out += "text-align: " + ("left" if s.text_align == 1 else ("center" if s.text_align == 2 else "right")) + "; "
    if s.ink != 0:
        out += "color: " + css_color(s.ink) + "; "
    return out


def look_gtk_css(look: Look, scope: String) -> String:
    """GTK's rules for a look, every selector under `scope` ("window.liquid ")."""
    if look.is_none():
        return ""
    var out = String("")
    if look.type.line > 0 and look.type.body > 0:  # every label a line as high as the web's (body 14px/1.45: 20.3)
        out += scope + "label { line-height: " + line_px(look.type.body * look.type.line) + "; }\n"
    var own = String("")
    for s in look.surfaces:
        if not text_only(s):
            out += scope + ".mui-tag-" + s.role + " { " + surface_rule(s, False) + "}\n"
            if look.controls.control_h > 0 and (s.pad_top > 0 or s.pad_bottom > 0 or s.min_height > 0) and s.height != -2:  # (HEIGHT_AUTO: its words' height, the web's height: auto; min-height: 0, D-498)
                # a button wearing the role is a control high overall, as on the web (border-box), padding included (D-441)
                out += scope + "button.mui-tag-" + s.role + " { min-height: " + px(gtk_content_h(s, max(look.controls.control_h, s.min_height))) + "; }\n"
        if s.gap >= 0:  # (a button's icon and words the role's gap apart, as the web's button gap; a stack's gap is its
            # spacing from resolve_layout, not CSS: GtkBox would add the two)
            out += scope + "button.mui-tag-" + s.role + " > buttoncontent > box { border-spacing: " + px(s.gap) + "; }\n"
        if s.icon_size > 0:  # (its icons at the role's size, as the web's svg: a button's own and an Icon inside it, D-497)
            out += scope + ".mui-tag-" + s.role + " image, " + scope + "image.mui-tag-" + s.role + " { -gtk-icon-size: " + px(s.icon_size) + "; }\n"
        var t = text_rule(s, False, look.type.line)
        if t != "":  # (its labels; the label that wears the role itself comes after every role's: below)
            out += scope + ".mui-tag-" + s.role + " label:not(.mui-in-button) { " + t + "}\n"  # (not a button's title: D-511)
            own += scope + "label.mui-tag-" + s.role + ":not(.mui-in-button), " + scope + "button.mui-tag-" + s.role + " > label, " + scope + "button.mui-tag-" + s.role + " > buttoncontent label { " + t + "}\n"
    # a label's own role (or its button's) has the last word over any role around it (a mono line in a table's cell, a
    # text action in a mono head: the web's words take
    # an ancestor's type at the lowest weight, :where; GTK has no :where, so the same weight written later, D-491)
    out += own
    var c = look.controls.copy()
    if c.control_h > 0:  # push buttons, fields and dropdowns: one height, the look's corners
        out += (scope + "button { min-height: " + px(c.control_h) + "; border-radius: " + px(c.button_radius) + "; "
                + ("font-size: " + line_px(c.button_font) + "; " if c.button_font > 0 else String(""))
                + ("font-weight: " + String(c.button_weight) + "; " if c.button_weight > 0 else String("")) + "}\n")
        out += scope + "entry, " + scope + "textview, " + scope + "dropdown > button { min-height: " + px(c.control_h) + "; border-radius: " + px(c.field_radius) + "; }\n"
    if c.tool_w > 0:
        out += scope + "button.mui-tool { min-width: " + px(c.tool_w) + "; min-height: " + px(c.tool_h) + "; border-radius: " + px(c.tool_radius) + "; font-size: " + fpx(c.tool_font) + "; }\n"
        out += scope + "label.mui-tool-label { font-size: " + fpx(c.tool_font) + "; }\n"
        out += scope + "button.mui-tool.mui-tool-inline { min-width: 0; min-height: " + px(c.inline_h) + "; padding: 0 " + px(c.inline_pad) + "; border-radius: " + px(c.inline_radius) + "; }\n"
        out += scope + "button.mui-tool-inline label.mui-tool-label { font-size: " + fpx(c.inline_font) + "; }\n"
        out += scope + ".mui-tag-toolbar button.image-button { min-width: " + px(c.icon) + "; min-height: " + px(c.icon) + "; padding: 0; border-radius: " + px(c.icon_radius) + "; }\n"
    if c.divider_gap > 0:  # a Divider's room (GTK's own is none; the host marks a Divider mui-divider, a row's mui-divider-up)
        out += scope + "separator.mui-divider { margin: " + px(c.divider_gap) + " 0; }\n"
    if c.divider_side > 0:
        out += scope + "separator.mui-divider-up { margin: 0 " + px(c.divider_side) + "; }\n"
    # a button the app gave a height (.height(26)) is that high, as on the web: no control minimum, no padding to add
    out += scope + "button.mui-fixed-h { min-height: 0; padding-top: 0; padding-bottom: 0; }\n"
    out += press_rules(look.motion, scope, False)
    return out


def press_rules(m: Motion, scope: String, web: Bool) -> String:
    """A press as the look says: the control shrinks while held and springs back (omxqua's .oq-pressable). The web takes
    the spring itself (linear()); GTK its cubic-bezier stand-in. Colours change quickly beside it (150 ms)."""
    if m.press_scale <= 0:
        return ""
    var curve = m.spring if web and m.spring != "" else m.ease
    var quick = String("150ms ease-out")
    var sel = scope + "button" + (", " + scope + "label.picker" if web else String(""))
    var held = scope + "button:active" + (", " + scope + "label.picker:active" if web else String(""))
    return (sel + " { transition: transform " + String(m.press_ms) + "ms " + curve + ", background-color " + quick + ", color " + quick
            + ", box-shadow " + quick + ", border-color " + quick + "; }\n"
            + held + " { transform: scale(" + String(m.press_scale) + "); }\n")


def look_web_css(look: Look, scope: String) -> String:
    """The web's rules for a look, every selector under `scope` ("body.liquid ")."""
    if look.is_none():
        return ""
    var out = String("")
    if look.type.tabular:  # (GTK's sheet doesn't say it yet: D-301)
        out += String(scope.strip()) + " { font-feature-settings: \"tnum\" 1; }\n"
    for s in look.surfaces:
        # a role is worn by a tagged view (data-tag) or by a part of one that isn't a view of its own (data-role: a
        # table's cells, which may wear two: "table-cell table-num")
        if not text_only(s):
            out += scope + "[data-tag=" + s.role + "], " + scope + "button[data-tag=" + s.role + "], " + scope + "[data-role~=" + s.role + "] { " + surface_rule(s, True) + "}\n"  # (a button wearing it: over the theme's button.subtle)
            if s.pad_top >= 0:  # a Board object wears its content's role; the content fills its inside, no second card (as GTK)
                out += (scope + ".board > .object[data-tag=" + s.role + "] > [data-tag=" + s.role + "] { background: none; box-shadow: none; border: 0; "
                        + "border-radius: 0; padding: 0; margin: 0; backdrop-filter: none; width: 100% !important; height: 100% !important; }\n")
        if s.inline_flow:  # (its children as words in a line: text inline, a button inline beside it, a space and `gap` apart; its own type sets the line)
            out += scope + "[data-tag=" + s.role + "] { " + text_rule(s, True) + "}\n"
            out += (scope + "[data-tag=" + s.role + "] > .text { display: inline; } " + scope + "[data-tag=" + s.role + "] > button { display: inline-flex; vertical-align: middle; } "
                    + scope + "[data-tag=" + s.role + "] > * + * { margin-left: " + px(max(s.gap, 0)) + "; }\n")
        if s.items_shrink:  # (what it holds gives way with it: a chip keeps its border, its words cut, as .kchip)
            out += scope + "[data-tag=" + s.role + "] > * { min-width: 0; flex-shrink: 1; overflow: hidden; }\n"
        if s.one_line:  # (its words cut with an ellipsis when squeezed, as GTK and the Mac cut them; a button wearing it keeps its width)
            out += scope + "[data-tag=" + s.role + "] .text, " + scope + ".text[data-tag=" + s.role + "] { overflow: hidden; text-overflow: ellipsis; min-width: 0; }\n"
        if s.scrolls_x:  # (a row that scrolls sideways: its items keep their own width)
            out += scope + ":where([data-tag=" + s.role + "]) > * { flex-shrink: 0; }\n"  # (weakly: an item that shrinks says so)
        var t = text_rule(s, True)
        if t != "":
            out += (scope + "[data-tag=" + s.role + "] .text, " + scope + ".text[data-tag=" + s.role + "], " + scope + "button[data-tag=" + s.role + "], "
                    + scope + ":where([data-role~=" + s.role + "]) .text, " + scope + "[data-role~=" + s.role + "] { " + text_rule(s, True) + "}\n")
            # (a part, a table's cell: its own type too, for what's in it to inherit; its words take it at the lowest
            # weight, so a role of their own (a mono line in a cell) has the last word)
        if s.ink != 0:  # (an Icon right inside the role's view takes its ink, as its words do)
            out += scope + "[data-tag=" + s.role + "] > .icon { color: " + css_color(s.ink) + "; }\n"
        if s.icon_size != 0 or s.icon_stroke > 0 or s.icon_ink != 0:  # (its icons: a button's own, or an Icon inside it)
            var ic = String("")
            if s.icon_size < 0:  # (none: a compact tab shows its word alone)
                ic += "display: none; "
            elif s.icon_size > 0:
                ic += "width: " + px(s.icon_size) + "; height: " + px(s.icon_size) + "; "
            if s.icon_stroke > 0:
                ic += "stroke-width: " + fpx(s.icon_stroke) + "; "
            if s.icon_ink != 0:
                ic += "color: " + css_color(s.icon_ink) + "; "
            out += scope + "[data-tag=" + s.role + "] svg, " + scope + "[data-role~=" + s.role + "] svg { " + ic + "}\n"
    var c = look.controls.copy()
    if c.control_h > 0:
        out += scope + "button { min-height: " + px(c.control_h) + "; border-radius: " + px(c.button_radius) + "; }\n"
        out += scope + "label.toggle { min-height: " + px(c.control_h) + "; }\n"  # (the base sheet's 48 px touch row made an inspector's toggle row 18 px taller than GTK's and the Mac's)
        out += (scope + "select, " + scope + "input[type=text], " + scope + "input[type=date], " + scope + "textarea { min-height: " + px(c.control_h)
                + "; border-radius: " + px(c.field_radius) + "; }\n")
    if c.tool_w > 0:
        out += scope + "button.tool, " + scope + "label.picker.tool { min-width: " + px(c.tool_w) + "; min-height: " + px(c.tool_h) + "; border-radius: " + px(c.tool_radius) + "; font-size: " + fpx(c.tool_font) + "; }\n"
        out += scope + "button.tool.inline, " + scope + "label.picker.tool.inline { min-width: 0; min-height: " + px(c.inline_h) + "; padding: 0 " + px(c.inline_pad) + "; border-radius: " + px(c.inline_radius) + "; font-size: " + fpx(c.inline_font) + "; }\n"
        out += scope + "[data-tag=toolbar] button.icon-only { border-radius: " + px(c.icon_radius) + "; }\n"
    # a Divider's room, as weak as the base sheet's hr (:where): a role's own margins on a Divider still win (D-460; scoped
    # plainly, the look's hr rule beat every role's rule-margin 0 and moved the console's pages 4 px a rule)
    var weak = ":where(" + scope.strip() + ") "
    if c.divider_gap != 0:  # (below 0: none, D-490)
        out += weak + "hr { margin: " + px(max(c.divider_gap, 0)) + " 0; }\n"
    if c.divider_side != 0:
        out += ":where(" + scope.strip() + " .hstack) > hr { margin: 0 " + px(max(c.divider_side, 0)) + "; }\n"
    out += press_rules(look.motion, scope, True)
    return out


# ---- the layout a look gives views (D-412, D-416): every host gets plain points ----

def resolve_layout(mut view: View, look: Look):
    """In place, before any host sees the screen: spacing and padding tokens (SPACE_…) become the look's points, and a
    view wearing a role whose surface sets a gap, a width or a height takes them (so GTK, the Mac and the web lay it
    out alike; the look's CSS paints the rest)."""
    var roles = Dict[String, Int]()
    for k in range(len(look.surfaces)):
        roles[look.surfaces[k].role] = k
    for i in range(len(view.nodes)):
        ref n = view.nodes[i]
        var stack = n.kind == VSTACK or n.kind == HSTACK or n.kind == GRID
        if n.spacing < 0 and stack:
            n.spacing = space_value(n.spacing, look.space)
        if n.pad_v < 0:
            n.pad_v = space_value(n.pad_v, look.space)
        if n.pad_h < 0:
            n.pad_h = space_value(n.pad_h, look.space)
        if n.kind == TABLE and len(n.options) > 0:  # (a dense table's cut columns: the theme's widths, table-cut and table-cut-name)
            var cut = look.surface("table-cut-compact" if n.style == 2 else "table-cut")
            var name = look.surface("table-cut-name-compact" if n.style == 2 else "table-cut-name")
            var tick = look.surface("table-tick-compact" if n.style == 2 else "table-tick")
            for j in range(len(n.options)):
                if n.options[j] == "T" and tick >= 0:  # (the tick column: the theme's width, at least its box)
                    n.options[j] = "T" + String(look.surfaces[tick].width)
                elif n.options[j] == "C":
                    n.options[j] = String(look.surfaces[cut].width) if cut >= 0 else String("")
                elif n.options[j] == "N":
                    n.options[j] = (String(look.surfaces[name].width) if name >= 0 else String("")) + "S"
        if n.name != "" and n.name in roles:
            var k = roles.get(n.name, -1)
            if k < 0:
                continue
            ref sf = look.surfaces[k]
            if sf.gap >= 0 and stack:
                n.spacing = sf.gap
            if sf.width > 0 and n.w == 0:
                n.w = sf.width
            if sf.height > 0 and n.h == 0:
                n.h = sf.height
            if sf.max_width > 0 and n.max_w == 0:
                n.max_w = sf.max_width
