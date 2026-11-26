# mojoui.sight: a picture with labelled boxes round the things in it (goal 77 M6, D-7770). Every box is a named part of the
# card, named by its label, so the pointer can land on "banana" (mojoui.pointer.area_part: the card lists its boxes as parts).
# The same drawing serves the camera card (mojoui.looker) and genui's "Sight" component (an agent shows a held picture with
# boxes it names).
#
#   draw_sight(surface, pixels, w, h, boxes, font, palette, focus=-1)   # the picture fitted, the boxes over it; `focus` is drawn bolder
#
# Boxes are in the picture's own pixels (mojoui.grounding.Box); the picture is drawn aspect-fitted, so the boxes are scaled and
# offset the same way (mojoui.picture.fitted_box). Labels sit on a chip at the box's top-left (below the edge when the box
# touches the top); the box colours follow the theme's series.

from mojoui.canvas import Surface
from mojoui.draw import rect
from mojoui.grounding import Box
from mojoui.picture import draw_fitted, fitted_box
from mojoui.text import Font, MEDIUM
from mojoui.theme import Palette, rgba


def box_colour(p: Palette, k: Int) -> UInt32:
    return p.series[k % len(p.series)]


def draw_sight(mut s: Surface, pixels: List[UInt32], pw: Int, ph: Int, boxes: List[Box], font: Font, p: Palette, focus: Int = -1):
    """The picture as large as fits, the boxes over it with their labels."""
    draw_fitted(s, pixels, pw, ph, p.card, 14.0)
    if pw <= 0 or ph <= 0 or len(pixels) != pw * ph:
        return
    var at = fitted_box(s, pw, ph)
    var left = at[0]
    var top = at[1]
    var k = at[2]
    var u = s.scale  # a point in pixels
    for i in range(len(boxes)):
        ref b = boxes[i]
        var line = (3.0 if i == focus else 2.0) * u
        var x0 = left + b.x0 * k
        var y0 = top + b.y0 * k
        var x1 = left + b.x1 * k
        var y1 = top + b.y1 * k
        var colour = box_colour(p, i)
        rect(s, x0, y0, x1 - x0, line, colour)  # (four edges; a box over a photo has no fill)
        rect(s, x0, y1 - line, x1 - x0, line, colour)
        rect(s, x0, y0, line, y1 - y0, colour)
        rect(s, x1 - line, y0, line, y1 - y0, colour)
        var size = 12.0 * u
        var w = font.measure(b.label, size, MEDIUM) + 12.0 * u
        var h = 20.0 * u
        var cy = y0 if y0 - h < top else y0 - h  # (the chip sits above the box unless the picture's edge is there)
        rect(s, x0, cy, w, h, colour, 6.0 * u)
        font.draw(s, b.label, x0 + 6.0 * u, cy + h / 2.0 + size * 0.35, size, rgba(255, 255, 255), MEDIUM)
