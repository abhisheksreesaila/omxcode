# mojoui.look: the rules GTK and the web write from a theme's Look (goal 32, owner 2026-10-24: "if I just drop those
# components in another app it should just work out of the box… one language plus custom CSS and people lose
# interest"). The Look itself (a type scale, the controls' sizes, a Surface per framework role) is theme vocabulary,
# in mojoui/theme.mojo; AppKit draws the same values with fonts, layers, corners and shadows. A theme's hand-written
# CSS keeps only what one host alone can do (keyframes, hover springs, a backdrop blur's fallback).

from mojoui.canvas import rgba
from mojoui.theme import Look, Surface, Shadow, TypeScale, Controls, Motion


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
            and s.line_bottom == 0 and s.min_height <= 0 and s.outline == 0)


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


def text_rule(s: Surface, web: Bool = False) -> String:
    var out = String("")
    if s.font != "":
        out += "font-family: '" + s.font + "', " + ("monospace" if "Mono" in s.font else "sans-serif") + "; "
    if s.font_size > 0:
        out += "font-size: " + fpx(s.font_size) + "; "
    if s.font_weight > 0:
        out += "font-weight: " + String(s.font_weight) + "; "
    if s.tracking != 0:
        out += "letter-spacing: " + fpx(s.tracking) + "; "
    if web and s.line_height > 0:  # (GTK labels take the font's)
        out += "line-height: " + fpx(s.line_height) + "; "
    if s.ink != 0:
        out += "color: " + css_color(s.ink) + "; "
    return out


def look_gtk_css(look: Look, scope: String) -> String:
    """GTK's rules for a look, every selector under `scope` ("window.liquid ")."""
    if look.is_none():
        return ""
    var out = String("")
    for s in look.surfaces:
        if not text_only(s):
            out += scope + ".mui-tag-" + s.role + " { " + surface_rule(s, False) + "}\n"
            if look.controls.control_h > 0 and (s.pad_top > 0 or s.pad_bottom > 0 or s.min_height > 0):
                # a button wearing the role is a control high overall, as on the web (border-box), padding included (D-441)
                out += scope + "button.mui-tag-" + s.role + " { min-height: " + px(gtk_content_h(s, max(look.controls.control_h, s.min_height))) + "; }\n"
        var t = text_rule(s)
        if t != "":  # (its labels, or the label that wears the role itself)
            out += scope + ".mui-tag-" + s.role + " label, " + scope + "label.mui-tag-" + s.role + " { " + t + "}\n"
    var c = look.controls.copy()
    if c.control_h > 0:  # push buttons, fields and dropdowns: one height, the look's corners
        out += scope + "button { min-height: " + px(c.control_h) + "; border-radius: " + px(c.button_radius) + "; }\n"
        out += scope + "entry, " + scope + "textview, " + scope + "dropdown > button { min-height: " + px(c.control_h) + "; border-radius: " + px(c.field_radius) + "; }\n"
    if c.tool_w > 0:
        out += scope + "button.mui-tool { min-width: " + px(c.tool_w) + "; min-height: " + px(c.tool_h) + "; border-radius: " + px(c.tool_radius) + "; font-size: " + fpx(c.tool_font) + "; }\n"
        out += scope + "label.mui-tool-label { font-size: " + fpx(c.tool_font) + "; }\n"
        out += scope + "button.mui-tool.mui-tool-inline { min-width: 0; min-height: " + px(c.inline_h) + "; padding: 0 " + px(c.inline_pad) + "; border-radius: " + px(c.inline_radius) + "; }\n"
        out += scope + "button.mui-tool-inline label.mui-tool-label { font-size: " + fpx(c.inline_font) + "; }\n"
        out += scope + ".mui-tag-toolbar button.image-button { min-width: " + px(c.icon) + "; min-height: " + px(c.icon) + "; padding: 0; border-radius: " + px(c.icon_radius) + "; }\n"
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
            out += scope + "[data-tag=" + s.role + "], " + scope + "[data-role~=" + s.role + "] { " + surface_rule(s, True) + "}\n"
            if s.pad_top >= 0:  # a Board object wears its content's role; the content fills its inside, no second card (as GTK)
                out += (scope + ".board > .object[data-tag=" + s.role + "] > [data-tag=" + s.role + "] { background: none; box-shadow: none; border: 0; "
                        + "border-radius: 0; padding: 0; margin: 0; backdrop-filter: none; width: 100% !important; height: 100% !important; }\n")
        var t = text_rule(s)
        if t != "":
            out += (scope + "[data-tag=" + s.role + "] .text, " + scope + ".text[data-tag=" + s.role + "], " + scope + "button[data-tag=" + s.role + "], "
                    + scope + "[data-role~=" + s.role + "] .text { " + text_rule(s, True) + "}\n")
        if s.ink != 0:  # (an Icon right inside the role's view takes its ink, as its words do)
            out += scope + "[data-tag=" + s.role + "] > .icon { color: " + css_color(s.ink) + "; }\n"
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
    out += press_rules(look.motion, scope, True)
    return out
