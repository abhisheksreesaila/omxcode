# mojoui.spring: a value that moves toward its target like a spring (Liquid's motion: it arrives quickly and settles,
# no bounce; lower the damping for one), stepped by a canvas's display frames (Canvas(on_frame=…): event.number = µs).
#
#   var s = Spring(0.0)              # at rest at 0
#   s.to(1.0)                        # aim at 1
#   on each frame: if s.step(event.number): keep asking for frames   (False once it has settled)
#   draw with s.value                # 0 … 1

comptime SPRING_STIFFNESS = 220.0  # (Liquid's feel: a quick arrival, ~300 ms, that settles without a bounce)
comptime SPRING_DAMPING = 30.0  # (critical: 2·√stiffness; less than that overshoots)


struct Spring(Copyable, Movable):
    var value: Float64
    var velocity: Float64
    var target: Float64
    var stiffness: Float64
    var damping: Float64

    def __init__(out self, value: Float64 = 0.0, stiffness: Float64 = SPRING_STIFFNESS, damping: Float64 = SPRING_DAMPING):
        self.value = value
        self.velocity = 0.0
        self.target = value
        self.stiffness = stiffness
        self.damping = damping

    def to(mut self, target: Float64):
        self.target = target

    def snap(mut self, value: Float64):
        """At rest at `value` at once (reduced motion, a test)."""
        self.value = value
        self.target = value
        self.velocity = 0.0

    def moving(self) -> Bool:
        return abs(self.value - self.target) > 0.002 or abs(self.velocity) > 0.01

    def step(mut self, microseconds: Int) -> Bool:
        """One frame of `microseconds` (a long gap is taken in small steps); True while it still moves."""
        var left = min(Float64(max(microseconds, 0)) / 1e6, 0.1)
        while left > 0:
            var dt = min(left, 1.0 / 240.0)
            var force = -self.stiffness * (self.value - self.target) - self.damping * self.velocity
            self.velocity += force * dt
            self.value += self.velocity * dt
            left -= dt
        if not self.moving():
            self.value = self.target
            self.velocity = 0.0
            return False
        return True
