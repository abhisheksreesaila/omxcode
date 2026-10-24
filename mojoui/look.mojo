# mojoui.look: the rules GTK and the web write from a theme's Look (goal 32, owner 2026-10-24: "if I just drop those
# components in another app it should just work out of the box… one language plus custom CSS and people lose
# interest"). The Look itself (a type scale, the controls' sizes, a Surface per framework role) is theme vocabulary,
# in mojoui/theme.mojo; AppKit draws the same values with fonts, layers, corners and shadows. A theme's hand-written
# CSS keeps only what one host alone can do (keyframes, hover springs, a backdrop blur's fallback).

from mojoui.canvas import rgba
from mojoui.theme import Look, Surface, Shadow, TypeScale, Controls


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
    if s.min_height > 0:
        out += "min-height: " + px(s.min_height) + "; "
    return out


def text_rule(s: Surface) -> String:
    var out = String("")
    if s.font != "":
        out += "font-family: '" + s.font + "', " + ("monospace" if "Mono" in s.font else "sans-serif") + "; "
    if s.font_size > 0:
        out += "font-size: " + fpx(s.font_size) + "; "
    if s.ink != 0:
        out += "color: " + css_color(s.ink) + "; "
    return out


def look_gtk_css(look: Look, scope: String) -> String:
    """GTK's rules for a look, every selector under `scope` ("window.liquid ")."""
    if look.is_none():
        return ""
    var out = String("")
    for s in look.surfaces:
        out += scope + ".mui-tag-" + s.role + " { " + surface_rule(s, False) + "}\n"
        var t = text_rule(s)
        if t != "":
            out += scope + ".mui-tag-" + s.role + " label { " + t + "}\n"
    var c = look.controls.copy()
    if c.tool_w > 0:
        out += scope + "button.mui-tool { min-width: " + px(c.tool_w) + "; min-height: " + px(c.tool_h) + "; border-radius: " + px(c.tool_radius) + "; font-size: " + fpx(c.tool_font) + "; }\n"
        out += scope + "label.mui-tool-label { font-size: " + fpx(c.tool_font) + "; }\n"
        out += scope + "button.mui-tool.mui-tool-inline { min-width: 0; min-height: " + px(c.inline_h) + "; padding: 0 " + px(c.inline_pad) + "; border-radius: " + px(c.inline_radius) + "; }\n"
        out += scope + "button.mui-tool-inline label.mui-tool-label { font-size: " + fpx(c.inline_font) + "; }\n"
        out += scope + ".mui-tag-toolbar button.image-button { min-width: " + px(c.icon) + "; min-height: " + px(c.icon) + "; padding: 0; border-radius: " + px(c.icon_radius) + "; }\n"
    return out


def look_web_css(look: Look, scope: String) -> String:
    """The web's rules for a look, every selector under `scope` ("body.liquid ")."""
    if look.is_none():
        return ""
    var out = String("")
    for s in look.surfaces:
        out += scope + "[data-tag=" + s.role + "] { " + surface_rule(s, True) + "}\n"
        var t = text_rule(s)
        if t != "":
            out += scope + "[data-tag=" + s.role + "] .text { " + t + "}\n"
    var c = look.controls.copy()
    if c.tool_w > 0:
        out += scope + "button.tool, " + scope + "label.picker.tool { min-width: " + px(c.tool_w) + "; min-height: " + px(c.tool_h) + "; border-radius: " + px(c.tool_radius) + "; font-size: " + fpx(c.tool_font) + "; }\n"
        out += scope + "button.tool.inline, " + scope + "label.picker.tool.inline { min-width: 0; min-height: " + px(c.inline_h) + "; padding: 0 " + px(c.inline_pad) + "; border-radius: " + px(c.inline_radius) + "; font-size: " + fpx(c.inline_font) + "; }\n"
        out += scope + "[data-tag=toolbar] button.icon-only { border-radius: " + px(c.icon_radius) + "; }\n"
    return out
