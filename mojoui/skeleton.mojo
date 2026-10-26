# mojoui.skeleton: a placeholder bar while data loads (omxqua's .skel: a rounded bar with a shimmer running across it;
# still when the system asks for less motion). It wears the framework role "skeleton" (tag="skeleton"); the theme gives
# its colour, corners and shimmer.
#
#   VStack(Skeleton(), Skeleton(width=180), spacing=8)

from mojoui.view import View, VStack, SPACE_M


def Skeleton(width: Int = 0, height: Int = 12) -> View:
    """A bar `height` points high: `width` points wide, or the width of its stack (0)."""
    var v = VStack(spacing=0).height(height).tag("skeleton")
    return v^.width(width) if width > 0 else v^.fill()


def SkeletonList(count: Int) -> View:
    """`count` row-high bars, a list still loading (roles skeleton-list: its insets and spacing, skeleton)."""
    var bars: List[View] = []
    for _ in range(count):
        bars.append(Skeleton(0, 34))
    return VStack(bars^, spacing=SPACE_M).fill().tag("skeleton-list")
