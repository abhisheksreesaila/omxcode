# mojoui.signal: small, generic signal steps for recorded channels (goal 47): what a telemetry chart needs to show a
# robot's, a drone's or a sensor's numbers honestly and readably. No app, no file format, no engine: lists in, lists out.
#
#   var a = unwrap(angles)                       # radians without 2π jumps (each step the short way round)
#   var s = smooth(values, 5)                    # a centred moving average over 5 samples (the ends use what they have)
#   var e = steps(gripper, 0.25, 0.12)           # [Step]: rising past 0.25 (on), falling below 0.12 (off): hysteresis
#   var p = peaks(speed, 1.5)                    # the samples where a run above 1.5 is highest (one per run)
#   var r = span_of(values)                      # (low, high), widened when flat, for a chart's y axis

from std.math import pi


@fieldwise_init
struct Step(Copyable, Movable, ImplicitlyCopyable):
    """A channel crossing its threshold: the sample, and on (rising) or off (falling)."""

    var at: Int
    var on: Bool


def unwrap(values: List[Float64]) -> List[Float64]:
    """Angles in radians with every jump larger than π taken the short way round (as numpy.unwrap)."""
    var out = List[Float64](capacity=len(values))
    if len(values) == 0:
        return out^
    var shift = 0.0
    out.append(values[0])
    for i in range(1, len(values)):
        var d = values[i] - values[i - 1]
        if d > pi:
            shift -= 2.0 * pi * Float64(Int((d + pi) / (2.0 * pi)))
        elif d < -pi:
            shift += 2.0 * pi * Float64(Int((-d + pi) / (2.0 * pi)))
        out.append(values[i] + shift)
    return out^


def smooth(values: List[Float64], window: Int) -> List[Float64]:
    """A centred moving average over `window` samples (odd; an even one grows by one). Near the ends the window shrinks
    to what's there, so the first and last values stay close to the data. A window of 1 or less returns a copy."""
    var n = len(values)
    if window <= 1 or n == 0:
        return values.copy()
    var half = window // 2
    var prefix = List[Float64](capacity=n + 1)
    prefix.append(0.0)
    for v in values:
        prefix.append(prefix[len(prefix) - 1] + v)
    var out = List[Float64](capacity=n)
    for i in range(n):
        var a = max(i - half, 0)
        var b = min(i + half + 1, n)
        out.append((prefix[b] - prefix[a]) / Float64(b - a))
    return out^


def steps(values: List[Float64], on_above: Float64, off_below: Float64) -> List[Step]:
    """Where the channel turns on (rises past on_above) and off again (falls below off_below): a gripper closing and
    opening, a brake pressed and let go. Hysteresis: between the two thresholds nothing changes."""
    var out = List[Step]()
    var on = False
    for i in range(len(values)):
        if not on and values[i] > on_above:
            on = True
            out.append(Step(i, True))
        elif on and values[i] < off_below:
            on = False
            out.append(Step(i, False))
    return out^


def peaks(values: List[Float64], above: Float64) -> List[Int]:
    """For each run of samples above `above`, the sample where it is highest (the first of equals)."""
    var out = List[Int]()
    var best = -1
    for i in range(len(values)):
        if values[i] > above:
            if best < 0 or values[i] > values[best]:
                best = i
        elif best >= 0:
            out.append(best)
            best = -1
    if best >= 0:
        out.append(best)
    return out^


def span_of(values: List[Float64]) -> Tuple[Float64, Float64]:
    """The lowest and highest value; a flat (or empty) channel gets a span of 1 around its value so a chart can draw it."""
    if len(values) == 0:
        return (0.0, 1.0)
    var lo = values[0]
    var hi = values[0]
    for v in values:
        lo = min(lo, v)
        hi = max(hi, v)
    if hi - lo < 1e-9:
        return (lo - 0.5, hi + 0.5)
    return (lo, hi)
