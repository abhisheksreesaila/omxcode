# mojoui.skeleton: a placeholder bar while data loads (omxqua's .skel: a rounded bar with a shimmer running across it;
# still when the system asks for less motion). It wears the framework role "skeleton" (tag="skeleton"); the theme gives
# its colour, corners and shimmer.
#
#   VStack(Skeleton(), Skeleton(width=180), spacing=8)

from mojoui.view import View, VStack


def Skeleton(width: Int = 0, height: Int = 12) -> View:
    """A bar `height` points high: `width` points wide, or the width of its stack (0)."""
    var v = VStack(spacing=0).height(height).tag("skeleton")
    return v^.width(width) if width > 0 else v^.fill()
