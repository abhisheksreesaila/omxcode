# mojoui.mascot: a lightweight, pluggable 3D-fidelity Companion / Mascot component (hub-and-spoke state machine over
# pre-rendered transparent PNG sprite strips, layered with runtime spring physics and a local-vs-cloud ground aura).
#
#   Pack format (zero external codecs — pure Mojo via mojoui.pngread + mojoui.json):
#     <pack_dir>/manifest.json    frame size, anchor_y, states (rest, listen, think, speak, hype, nap), optional transitions
#     <pack_dir>/<state>.png      horizontal RGBA PNG sprite strip (N frames side-by-side)
#
#   Companion mirrors mojoui.orb's API so apps can swap between Orb and Companion via Presence:
#     self.mascot = Mascot.load("examples/stage/mascots/omx")
#     self.mascot.mode(MASCOT_LISTEN)   # hub-and-spoke state change (same 0..3 codes as ORB_*)
#     self.mascot.drive(mic_level)         # voice reactivity (0..1)
#     self.mascot.lane(is_cloud)           # local blue aura vs cloud warning/amber aura
#     self.mascot.look(gx, gy, amount)     # subtle gaze lean
#     self.mascot.poke()                   # tactile squash-and-hop + hype burst
#     MascotView(CANVAS_ID, self.mascot.version(), side=172, on_gesture=POKE)
#     self.mascot.draw(surface, palette)

from std.math import sin, cos, sqrt
from std.os import getenv
from std.os.path import exists
from mojoui import libc
from mojoui.canvas import Surface
from mojoui.clock import now_ns
from mojoui.draw import over
from mojoui.json import Json, J_OBJECT
from mojoui.orb import Orb, ORB_IDLE, ORB_LISTEN, ORB_THINK, ORB_SPEAK
from mojoui.pngread import decode_png
from mojoui.spring import Spring
from mojoui.theme import Palette, mix
from mojoui.view import View, Canvas, NO_MSG

comptime MASCOT_REST = 0    # Hub state (== ORB_IDLE)
comptime MASCOT_LISTEN = 1  # Attentive listening (== ORB_LISTEN)
comptime MASCOT_THINK = 2   # Reasoning / orbiting sparks (== ORB_THINK)
comptime MASCOT_SPEAK = 3   # Speaking rhythm (== ORB_SPEAK)
comptime MASCOT_HYPE = 4    # Celebration / timer done / tap-poke
comptime MASCOT_NAP = 5     # Calm sleep / long idle
comptime MASCOT_COUNT = 6

comptime PRESENCE_ORB = 0
comptime PRESENCE_MASCOT = 1

comptime MASCOT_SHADOW: UInt32 = 0xFF06070B


def mascot_pack_dir(override: String = "", name: String = "omx") -> String:
    """Where a mascot pack is, without assuming the working directory: the environment variable `override` names (OMX_MASCOT,
    STAGE_MASCOT) when it holds a folder; else `mascots/<name>` beside the program (a shipped app); else the repository's
    examples/stage/mascots/<name> found from the program (scripts/build.sh puts it in build/<app>/linux/, three folders down);
    else the same relative to the working directory. "" when none has a manifest.json."""
    if override != "":
        var own = getenv(override)
        if own != "" and own != "0" and own != "1" and own != name:
            if not exists(own + "/manifest.json"):  # (a typo in the variable: say so, then fall back to the shipped pack)
                print("MASCOT: " + override + "=" + own + " has no manifest.json; using the default pack")
            else:
                return own
    var d = libc.exe_dir()
    var tries: List[String] = [d + "/mascots/" + name, d + "/../../../examples/stage/mascots/" + name, "examples/stage/mascots/" + name]
    for t in tries:
        if exists(t + "/manifest.json"):
            return t
    return ""


def mascot_state_id(name: String) -> Int:
    """Map a manifest state name to its integer ID (-1 if unknown)."""
    var s = name.lower()
    if s == "rest" or s == "idle":
        return MASCOT_REST
    if s == "listen" or s == "listening":
        return MASCOT_LISTEN
    if s == "think" or s == "thinking":
        return MASCOT_THINK
    if s == "speak" or s == "speaking":
        return MASCOT_SPEAK
    if s == "hype" or s == "happy" or s == "celebrate" or s == "poke":
        return MASCOT_HYPE
    if s == "nap" or s == "sleep" or s == "sleeping":
        return MASCOT_NAP
    return -1


def mascot_state_name(state: Int) -> String:
    """Canonical lowercase name of a companion state."""
    if state == MASCOT_REST:
        return "rest"
    if state == MASCOT_LISTEN:
        return "listen"
    if state == MASCOT_THINK:
        return "think"
    if state == MASCOT_SPEAK:
        return "speak"
    if state == MASCOT_HYPE:
        return "hype"
    if state == MASCOT_NAP:
        return "nap"
    return "rest"


def _read_bytes(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def _read_text(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _join(base: String, leaf: String) -> String:
    if base == "":
        return leaf
    if base.endswith("/"):
        return base + leaf
    return base + "/" + leaf


def _tone(color: UInt32, alpha: Float64) -> UInt32:
    return (color & 0x00FFFFFF) | (UInt32(Int(min(max(alpha, 0.0), 1.0) * 255.0 + 0.5)) << 24)


def _soft_ellipse(mut s: Surface, cx: Float64, cy: Float64, rx: Float64, ry: Float64, color: UInt32):
    """Smooth radial-falloff ellipse composited with straight-alpha over() for ground shadow & aura."""
    if rx <= 1.0 or ry <= 1.0:
        return
    var base_a = Float64(Int((color >> 24) & 0xFF)) / 255.0
    if base_a <= 0.002:
        return
    var rgb = color & 0x00FFFFFF
    var x0 = max(Int(cx - rx - 1.0), 0)
    var x1 = min(Int(cx + rx + 2.0), s.width)
    var y0 = max(Int(cy - ry - 1.0), 0)
    var y1 = min(Int(cy + ry + 2.0), s.height)
    var inv_rx = 1.0 / rx
    var inv_ry = 1.0 / ry
    for py in range(y0, y1):
        var dy = (Float64(py) + 0.5 - cy) * inv_ry
        var dy2 = dy * dy
        if dy2 >= 1.0:
            continue
        var row = py * s.width
        for px in range(x0, x1):
            var dx = (Float64(px) + 0.5 - cx) * inv_rx
            var d2 = dx * dx + dy2
            if d2 >= 1.0:
                continue
            var f = 1.0 - sqrt(d2)
            # Smooth cubic-like falloff for a natural Pixar-style soft floor glow
            var fall = f * f * (3.0 - 2.0 * f)
            var a = base_a * fall
            if a > 0.003:
                var dst = s.pixels().unsafe_offset(row + px)
                dst[] = over(dst[], rgb | (UInt32(Int(a * 255.0 + 0.5)) << 24), 1.0)


@fieldwise_init
struct MascotClip(Copyable, Movable):
    """One horizontal PNG sprite strip (either a looping/one-shot state or a hub-and-spoke transition)."""

    var path: String
    var width: Int
    var height: Int
    var frame_w: Int
    var frames: Int
    var fps: Float64
    var loop: Bool
    var next_state: Int  # -1 if none; e.g. MASCOT_REST when one-shot hype finishes
    var loaded: Bool
    var pixels: List[UInt32]

    @staticmethod
    def empty() -> MascotClip:
        return MascotClip("", 0, 0, 0, 0, 12.0, True, -1, False, List[UInt32]())

    def configured(self) -> Bool:
        return self.path != "" or self.loaded

    def duration(self) -> Float64:
        if self.frames <= 0 or self.fps <= 0.0:
            return 0.0
        return Float64(self.frames) / self.fps

    def ensure_loaded(mut self) -> Bool:
        """Decode the strip PNG into RGBA memory on first use (pure Mojo via mojoui.pngread)."""
        if self.loaded:
            return len(self.pixels) > 0
        if self.path == "":
            return False
        try:
            var img = decode_png(_read_bytes(self.path))
            self.width = img.width
            self.height = img.height
            if self.frames <= 0:
                self.frames = 1
            if self.frame_w <= 0:
                self.frame_w = max(1, self.width // self.frames)
            if self.frame_w > 0 and self.width >= self.frame_w:
                self.frames = min(self.frames, self.width // self.frame_w)
            self.pixels = img.pixels.copy()
            self.loaded = True
            return len(self.pixels) > 0
        except:
            self.loaded = True
            return False

    def frame_at(self, t: Float64) -> Int:
        if self.frames <= 1:
            return 0
        var idx = Int(t * self.fps)
        if self.loop:
            return idx % self.frames
        return min(max(idx, 0), self.frames - 1)


@fieldwise_init
struct MascotTransition(Copyable, Movable):
    """An optional hub-and-spoke transition strip between two states (e.g. rest->hype, listen->rest)."""

    var from_state: Int
    var to_state: Int
    var clip: MascotClip


def _sample_premul(clip: MascotClip, frame: Int, u: Float64, v: Float64) -> UInt32:
    """Premultiplied bilinear sample from `clip` at frame-local coordinates `(u, v)`."""
    if not clip.loaded or len(clip.pixels) == 0 or clip.frame_w <= 0 or clip.height <= 0:
        return 0
    if u < 0.0 or v < 0.0 or u >= Float64(clip.frame_w) or v >= Float64(clip.height):
        return 0
    var fx = u - 0.5
    var fy = v - 0.5
    var x0 = Int(fx) if fx >= 0.0 else Int(fx) - 1
    var y0 = Int(fy) if fy >= 0.0 else Int(fy) - 1
    var wx = fx - Float64(x0)
    var wy = fy - Float64(y0)
    var x1 = x0 + 1
    var y1 = y0 + 1
    var base_x = min(max(frame, 0), max(clip.frames - 1, 0)) * clip.frame_w

    var pr: Float64 = 0.0
    var pg: Float64 = 0.0
    var pb: Float64 = 0.0
    var pa: Float64 = 0.0

    for j in range(2):
        var sy = y0 if j == 0 else y1
        if sy < 0 or sy >= clip.height:
            continue
        var wy_j = (1.0 - wy) if j == 0 else wy
        var row = sy * clip.width + base_x
        for i in range(2):
            var sx = x0 if i == 0 else x1
            if sx < 0 or sx >= clip.frame_w:
                continue
            var w = ((1.0 - wx) if i == 0 else wx) * wy_j
            var px = clip.pixels[row + sx]
            var a = Float64(Int((px >> 24) & 0xFF)) / 255.0
            if a <= 0.0:
                continue
            var wa = w * a
            pr += Float64(Int(px & 0xFF)) * wa
            pg += Float64(Int((px >> 8) & 0xFF)) * wa
            pb += Float64(Int((px >> 16) & 0xFF)) * wa
            pa += wa

    if pa <= 0.002:
        return 0
    var inv_a = 1.0 / pa
    var r = min(max(Int(pr * inv_a + 0.5), 0), 255)
    var g = min(max(Int(pg * inv_a + 0.5), 0), 255)
    var b = min(max(Int(pb * inv_a + 0.5), 0), 255)
    var a_out = min(max(Int(pa * 255.0 + 0.5), 0), 255)
    return UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(a_out) << 24)


def _blit_frame(mut s: Surface, clip: MascotClip, frame: Int,
                dx: Float64, dy: Float64, dw: Float64, dh: Float64, opacity: Float64):
    """Composite one scaled sprite frame onto `s` with bilinear filtering and straight-alpha over()."""
    if opacity <= 0.004 or dw <= 1.0 or dh <= 1.0 or not clip.loaded or len(clip.pixels) == 0:
        return
    var x0 = max(Int(dx), 0)
    var y0 = max(Int(dy), 0)
    var x1 = min(Int(dx + dw) + 1, s.width)
    var y1 = min(Int(dy + dh) + 1, s.height)
    if x0 >= x1 or y0 >= y1:
        return
    var su = Float64(clip.frame_w) / dw
    var sv = Float64(clip.height) / dh
    for py in range(y0, y1):
        var v = (Float64(py) + 0.5 - dy) * sv
        if v < 0.0 or v >= Float64(clip.height):
            continue
        var row = py * s.width
        for px in range(x0, x1):
            var u = (Float64(px) + 0.5 - dx) * su
            if u < 0.0 or u >= Float64(clip.frame_w):
                continue
            var sample = _sample_premul(clip, frame, u, v)
            if (sample >> 24) == 0:
                continue
            var dst = s.pixels().unsafe_offset(row + px)
            dst[] = over(dst[], sample, opacity)


struct Mascot(Movable):
    """Hub-and-spoke animated 3D mascot player with runtime springs and local/cloud aura."""

    var name: String
    var pack_dir: String
    var anchor_y: Float64
    var ready: Bool
    var clips: List[MascotClip]
    var transitions: List[MascotTransition]
    var _state: Int          # active state (0..MASCOT_COUNT-1)
    var _target: Int         # requested state
    var _prev_state: Int     # outgoing state during crossfade
    var _prev_frame: Int
    var _in_transition: Int  # index into self.transitions, or -1
    var _queued_target: Int  # target waiting after hub transition completes, or -1
    var _clip_time: Float64
    var _fade: Spring        # 0 -> 1 crossfade weight on current clip
    var loud: Spring         # voice loudness 0..1
    var cloud: Spring        # 0 = local blue aura, 1 = cloud amber/orange aura
    var gaze_x: Spring       # subtle horizontal lean (-1..1)
    var gaze_y: Spring       # subtle vertical lean (-1..1)
    var gaze_on: Spring
    var squash: Spring       # vertical squash/stretch offset (0 at rest)
    var hop: Spring          # vertical bounce offset in fraction of height (0 at rest)
    var phase: Float64
    var last_ns: Int
    var stamp: Int
    var aura_on: Bool

    def __init__(out self):
        self.name = ""
        self.pack_dir = ""
        self.anchor_y = 0.92
        self.ready = False
        self.clips = List[MascotClip]()
        for _ in range(MASCOT_COUNT):
            self.clips.append(MascotClip.empty())
        self.transitions = List[MascotTransition]()
        self._state = MASCOT_REST
        self._target = MASCOT_REST
        self._prev_state = MASCOT_REST
        self._prev_frame = 0
        self._in_transition = -1
        self._queued_target = -1
        self._clip_time = 0.0
        self._fade = Spring(1.0, 260.0, 32.0)
        self.loud = Spring(0.0, 140.0, 18.0)
        self.cloud = Spring(0.0, 90.0, 19.0)
        self.gaze_x = Spring(0.0, 160.0, 22.0)
        self.gaze_y = Spring(0.0, 160.0, 22.0)
        self.gaze_on = Spring(0.0, 130.0, 20.0)
        self.squash = Spring(0.0, 280.0, 15.0)  # underdamped for lively elastic bounce!
        self.hop = Spring(0.0, 240.0, 14.0)
        self.phase = 0.0
        self.last_ns = 0
        self.stamp = 0
        self.aura_on = True

    @staticmethod
    def load(pack_dir: String, eager: Bool = False) raises -> Mascot:
        """Load a companion pack from `<pack_dir>/manifest.json`."""
        var c = Mascot()
        c.pack_dir = pack_dir
        var manifest_path = _join(pack_dir, "manifest.json")
        var j = Json.parse(_read_text(manifest_path))
        c.name = j.text(j.get(0, "name"), "Mascot")
        var fw = j.number(j.get(0, "frame_width"), 192)
        var fh = j.number(j.get(0, "frame_height"), 192)
        c.anchor_y = j.real(j.get(0, "anchor_y"), 0.92)

        var states_node = j.get(0, "states")
        if j.kind(states_node) == J_OBJECT:
            for i in range(j.size(states_node)):
                var key = j.key(states_node, i)
                var sid = mascot_state_id(key)
                if sid < 0 or sid >= MASCOT_COUNT:
                    continue
                var entry = j.at(states_node, i)
                var fname = j.text(j.get(entry, "file"), "")
                if fname == "":
                    continue
                var frames = max(j.number(j.get(entry, "frames"), 1), 1)
                var fps = j.real(j.get(entry, "fps"), 12.0)
                var loop = j.flag(j.get(entry, "loop"), True)
                var next_name = j.text(j.get(entry, "next"), "")
                var next_id = mascot_state_id(next_name) if next_name != "" else -1
                c.clips[sid] = MascotClip(
                    _join(pack_dir, fname), fw * frames, fh, fw, frames,
                    max(fps, 1.0), loop, next_id, False, List[UInt32](),
                )

        var trans_node = j.get(0, "transitions")
        if j.kind(trans_node) == J_OBJECT:
            for i in range(j.size(trans_node)):
                var key = j.key(trans_node, i)
                var arrow = key.find("->")
                if arrow <= 0:
                    continue
                var a = mascot_state_id(String(key[byte = 0 : arrow]))
                var b = mascot_state_id(String(key[byte = arrow + 2 :]))
                if a < 0 or b < 0:
                    continue
                var entry = j.at(trans_node, i)
                var fname = j.text(j.get(entry, "file"), "")
                if fname == "":
                    continue
                var frames = max(j.number(j.get(entry, "frames"), 1), 1)
                var fps = j.real(j.get(entry, "fps"), 24.0)
                var clip = MascotClip(
                    _join(pack_dir, fname), fw * frames, fh, fw, frames,
                    max(fps, 1.0), False, b, False, List[UInt32](),
                )
                c.transitions.append(MascotTransition(a, b, clip^))

        # Always decode the hub state (`rest`) right away to validate the pack
        var ok = c.clips[MASCOT_REST].ensure_loaded()
        if not ok:
            # Fall back to first configured state if rest is absent
            for s in range(MASCOT_COUNT):
                if c.clips[s].configured() and c.clips[s].ensure_loaded():
                    c._state = s
                    c._target = s
                    ok = True
                    break
        if not ok:
            raise Error("mascot: no readable state PNG in " + pack_dir)

        if eager:
            for s in range(MASCOT_COUNT):
                if c.clips[s].configured():
                    _ = c.clips[s].ensure_loaded()
            for k in range(len(c.transitions)):
                _ = c.transitions[k].clip.ensure_loaded()

        c.ready = True
        c.stamp = 1
        return c^

    def _resolve_state(self, want: Int) -> Int:
        """Map a requested state to the best available clip in the pack (graceful fallback)."""
        if 0 <= want < MASCOT_COUNT and self.clips[want].configured():
            return want
        if want == MASCOT_SPEAK and self.clips[MASCOT_LISTEN].configured():
            return MASCOT_LISTEN
        if self.clips[MASCOT_REST].configured():
            return MASCOT_REST
        for s in range(MASCOT_COUNT):
            if self.clips[s].configured():
                return s
        return MASCOT_REST

    def _find_transition(self, from_s: Int, to_s: Int) -> Int:
        for i in range(len(self.transitions)):
            if self.transitions[i].from_state == from_s and self.transitions[i].to_state == to_s:
                return i
        return -1

    def _switch_direct(mut self, to_s: Int, soft_bounce: Bool = True):
        """Switch directly to state `to_s` with a smooth crossfade from the current frame."""
        var resolved = self._resolve_state(to_s)
        _ = self.clips[resolved].ensure_loaded()
        self._prev_state = self._state
        self._prev_frame = self.clips[self._state].frame_at(self._clip_time)
        self._state = resolved
        self._in_transition = -1
        self._clip_time = 0.0
        self._fade.snap(0.0)
        self._fade.to(1.0)
        if soft_bounce:
            self.squash.velocity += -0.65
        self.stamp += 1

    def mode(mut self, m: Int):
        """Request a new state using hub-and-spoke routing through REST when transition strips exist."""
        if not self.ready:
            return
        var resolved = self._resolve_state(m)
        if resolved == self._target and self._in_transition < 0:
            return
        self._target = resolved
        self._queued_target = -1

        # 1. Direct transition strip exists (e.g. rest->hype, listen->rest)
        var direct = self._find_transition(self._state, resolved)
        if direct >= 0 and self.transitions[direct].clip.ensure_loaded():
            self._prev_state = self._state
            self._prev_frame = self.clips[self._state].frame_at(self._clip_time)
            self._in_transition = direct
            self._clip_time = 0.0
            self._fade.snap(0.0)
            self._fade.to(1.0)
            self.stamp += 1
            return

        # 2. Hub-and-spoke routing: if moving between two spoke states and an exit strip to REST exists
        if self._state != MASCOT_REST and resolved != MASCOT_REST:
            var to_hub = self._find_transition(self._state, MASCOT_REST)
            if to_hub >= 0 and self.transitions[to_hub].clip.ensure_loaded():
                self._prev_state = self._state
                self._prev_frame = self.clips[self._state].frame_at(self._clip_time)
                self._in_transition = to_hub
                self._queued_target = resolved
                self._clip_time = 0.0
                self._fade.snap(0.0)
                self._fade.to(1.0)
                self.stamp += 1
                return

        # 3. No transition strip: smooth spring crossfade directly to target
        self._switch_direct(resolved)

    def current(self) -> Int:
        return self._state

    def target(self) -> Int:
        return self._target

    def drive(mut self, level: Float64):
        """Voice loudness 0..1 (matches Orb.drive)."""
        var active = self._state == MASCOT_LISTEN or self._state == MASCOT_SPEAK
        self.loud.to(min(max(level, 0.0), 1.0) if active else 0.0)

    def lane(mut self, cloud: Bool):
        """Local (False: family blue aura) vs cloud (True: warm warning/amber aura)."""
        self.cloud.to(1.0 if cloud else 0.0)

    def look(mut self, x: Float64, y: Float64, amount: Float64):
        """Subtle lean toward unit vector `(x, y)` with `amount` 0..1."""
        if amount > 0.02:
            self.gaze_x.to(min(max(x, -1.0), 1.0))
            self.gaze_y.to(min(max(y, -1.0), 1.0))
        self.gaze_on.to(min(max(amount, 0.0), 1.0) if amount > 0.02 else 0.0)

    def poke(mut self):
        """Playful tap reaction: springy squash + vertical hop + HYPE celebration burst."""
        self.squash.velocity = -2.2
        self.hop.velocity = -1.6
        if self.ready and self.clips[MASCOT_HYPE].configured():
            self._target = -1  # allow re-triggering HYPE on repeated taps
            self.mode(MASCOT_HYPE)
        else:
            self.stamp += 1

    def version(self) -> Int:
        return self.stamp

    def loaded_frames(self) -> Int:
        var n = 0
        for i in range(len(self.clips)):
            if self.clips[i].loaded and len(self.clips[i].pixels) > 0:
                n += self.clips[i].frames
        for i in range(len(self.transitions)):
            if self.transitions[i].clip.loaded and len(self.transitions[i].clip.pixels) > 0:
                n += self.transitions[i].clip.frames
        return n

    def step(mut self, dt_sec: Float64):
        """Advance playback, hub-and-spoke transitions, and all physics springs by `dt_sec` seconds."""
        var dt = min(max(dt_sec, 0.0), 0.1)
        var us = Int(dt * 1e6)
        _ = self._fade.step(us)
        _ = self.loud.step(us)
        _ = self.cloud.step(us)
        _ = self.gaze_x.step(us)
        _ = self.gaze_y.step(us)
        _ = self.gaze_on.step(us)
        _ = self.squash.step(us)
        _ = self.hop.step(us)

        var tempo = 0.55 if self._state == MASCOT_NAP else (1.35 if self._state == MASCOT_THINK else 1.0)
        self.phase += dt * tempo

        if not self.ready:
            return

        self._clip_time += dt

        # Check transition completion
        if self._in_transition >= 0:
            var dur = self.transitions[self._in_transition].clip.duration()
            if dur > 0.0 and self._clip_time >= dur:
                var arrived = self.transitions[self._in_transition].to_state
                self._state = arrived
                self._in_transition = -1
                self._clip_time = 0.0
                if self._queued_target >= 0:
                    var nxt = self._queued_target
                    self._queued_target = -1
                    var leg2 = self._find_transition(arrived, nxt)
                    if leg2 >= 0 and self.transitions[leg2].clip.ensure_loaded():
                        self._in_transition = leg2
                    else:
                        self._switch_direct(nxt, soft_bounce=False)
                else:
                    _ = self.clips[arrived].ensure_loaded()
                self.stamp += 1
            return

        # Check one-shot clip completion (e.g. hype -> rest)
        var cur = self._state
        if not self.clips[cur].loop:
            var dur = self.clips[cur].duration()
            if dur > 0.0 and self._clip_time >= dur:
                var nxt = self.clips[cur].next_state
                if nxt >= 0 and nxt != cur:
                    self._target = nxt
                    self._switch_direct(nxt, soft_bounce=False)

    def draw(mut self, mut s: Surface, p: Palette):
        """Render the companion (ground aura + spring-animated 3D sprite frame) onto a clear Surface."""
        s.fill(0)
        var now = now_ns()
        var dt = Float64(now - self.last_ns) / 1e9 if self.last_ns > 0 else 0.016
        self.last_ns = now
        self.step(dt)

        if not self.ready:
            return

        var w = Float64(s.width)
        var h = Float64(s.height)
        var side = min(w, h)
        var cx = w * 0.5
        var foot_y = h * self.anchor_y

        # 1. Soft floor aura (local family blue <-> cloud warm amber) + subtle contact shadow
        if self.aura_on:
            var aura_col = mix(p.accent, p.warn, self.cloud.value)
            var pulse = 0.5 + 0.5 * sin(self.phase * 1.6)
            var hype_boost = 0.16 if self._state == MASCOT_HYPE else 0.0
            var nap_dim = 0.55 if self._state == MASCOT_NAP else 1.0
            var aura_a = (0.28 + 0.07 * pulse + 0.18 * self.loud.value + hype_boost) * nap_dim
            var aura_rx = side * (0.34 + 0.04 * self.loud.value + 0.02 * pulse)
            var aura_ry = side * 0.105
            _soft_ellipse(s, cx, foot_y + side * 0.01, aura_rx, aura_ry, _tone(aura_col, aura_a))
            # Crisp soft contact shadow directly under feet (shrinks slightly during hop)
            var lift = max(-self.hop.value, 0.0)
            var sh_scale = max(0.55, 1.0 - lift * 1.8)
            _soft_ellipse(s, cx, foot_y + side * 0.005, side * 0.22 * sh_scale, side * 0.055 * sh_scale,
                          _tone(MASCOT_SHADOW, 0.34 * sh_scale))

        # 2. Compute spring-driven squash/stretch, breathing, voice bounce, and subtle gaze lean
        var breath_amp = 0.012 if self._state == MASCOT_NAP else 0.016
        var breath = breath_amp * sin(self.phase * 1.8)
        var voice_boost = 0.065 * self.loud.value
        var sq = min(max(self.squash.value, -0.18), 0.18)
        var scale_y = 1.0 + breath + voice_boost + sq
        var scale_x = 1.0 - (breath + voice_boost + sq) * 0.65

        var base_size = side * 0.92
        var dw = base_size * scale_x
        var dh = base_size * scale_y
        var lean_x = self.gaze_x.value * self.gaze_on.value * side * 0.045
        var lean_y = self.gaze_y.value * self.gaze_on.value * side * 0.025
        var hop_px = self.hop.value * side * 0.16
        var dx = cx - dw * 0.5 + lean_x
        var dy = foot_y - dh * self.anchor_y + hop_px + lean_y

        # 3. Blit outgoing crossfade frame (if transitioning smoothly) + active clip frame
        var alpha_cur = min(max(self._fade.value, 0.0), 1.0)
        if alpha_cur < 0.995 and 0 <= self._prev_state < len(self.clips):
            var prev_alpha = 1.0 - alpha_cur
            if self.clips[self._prev_state].loaded:
                _blit_frame(s, self.clips[self._prev_state], self._prev_frame, dx, dy, dw, dh, prev_alpha)

        if self._in_transition >= 0:
            var tclip_idx = self._in_transition
            var fr = self.transitions[tclip_idx].clip.frame_at(self._clip_time)
            _blit_frame(s, self.transitions[tclip_idx].clip, fr, dx, dy, dw, dh, alpha_cur)
        else:
            var fr = self.clips[self._state].frame_at(self._clip_time)
            _blit_frame(s, self.clips[self._state], fr, dx, dy, dw, dh, alpha_cur)

        s.again = True


def MascotView(canvas: Int, version: Int, side: Int = 172, on_gesture: Int = NO_MSG, hover: Bool = False) -> View:
    """The Companion's Canvas: square `side` points, transparent background. Pass `on_gesture` to enable tap-to-poke
    (and `hover=True` for subtle gaze lean toward the cursor); omit `on_gesture` for a passthrough display-only view."""
    if on_gesture == NO_MSG:
        return Canvas(canvas, version).passthrough().width(side).height(side).tag("mascot")
    return Canvas(canvas, version, on_gesture=on_gesture, hover=hover).width(side).height(side).tag("mascot").tooltip("Tap to say hi")


comptime PRESENCE_K = 260.0  # the crossfade's spring (omxqua's --oq-spring-slow, k260 c20 here: a slight settle past full size)
comptime PRESENCE_C = 20.0
comptime PRESENCE_FROM_SCALE = 0.86  # the newcomer grows from this while the one leaving swells a little and fades


def _sample(px: List[UInt32], w: Int, h: Int, x: Float64, y: Float64) -> UInt32:
    """A straight-alpha pixel of a w x h picture at (x, y) (nearest; outside: clear)."""
    var ix = Int(x)
    var iy = Int(y)
    if x < 0.0 or y < 0.0 or ix >= w or iy >= h:
        return 0
    return px[iy * w + ix]


def _layer(c: UInt32, a: Float64) -> Tuple[Float64, Float64, Float64, Float64]:
    """A straight-alpha pixel premultiplied and weighted by `a`."""
    var al = Float64(Int((c >> 24) & 255)) / 255.0 * a
    return (Float64(Int(c & 255)) * al, Float64(Int((c >> 8) & 255)) * al, Float64(Int((c >> 16) & 255)) * al, al)


struct Presence(Movable):
    """Pluggable presence switcher: lets an app toggle seamlessly between the Liquid Orb (PRESENCE_ORB) and any
    drop-in 3D Companion pack (PRESENCE_MASCOT) through a single unified API. A switch crossfades (mojoui.personalize's
    "use the mascot instead of the orb", owner 2026-11-25: no snap): the newcomer grows from PRESENCE_FROM_SCALE on a spring
    with a slight settle while the one leaving swells a little and fades, both still moving."""

    var kind: Int
    var orb: Orb
    var mascot: Mascot
    var from_kind: Int  # the one leaving while blend runs
    var blend: Spring  # 0 -> 1: the crossfade's progress (1: the current kind alone)
    var blend_ns: Int
    var stamp: Int
    var _old: List[UInt32]  # the crossfade's two pictures
    var _new: List[UInt32]

    def __init__(out self):
        self.kind = PRESENCE_ORB
        self.orb = Orb()
        self.mascot = Mascot()
        self.from_kind = PRESENCE_ORB
        self.blend = Spring(1.0, PRESENCE_K, PRESENCE_C)
        self.blend_ns = 0
        self.stamp = 0
        self._old = List[UInt32]()
        self._new = List[UInt32]()

    def show(mut self, kind: Int) -> Bool:
        """Switches to `kind` with the crossfade (the mascot only once a pack is loaded). True when `kind` now shows."""
        var want = kind
        if want == PRESENCE_MASCOT and not self.mascot.ready:
            want = PRESENCE_ORB
        if want != self.kind:
            self.from_kind = self.kind
            self.kind = want
            self.blend.snap(0.0)
            self.blend.to(1.0)
            self.blend_ns = 0
            self.stamp += 1
        return want == kind

    def crossfading(self) -> Bool:
        return self.blend.moving() or self.blend.value < 0.999

    def use_orb(mut self):
        _ = self.show(PRESENCE_ORB)

    def use_mascot(mut self, pack_dir: String, eager: Bool = False) raises:
        self.mascot = Mascot.load(pack_dir, eager=eager)
        _ = self.show(PRESENCE_MASCOT)

    def load_mascot(mut self, pack_dir: String, eager: Bool = False) raises:
        """The pack ready to show, without switching to it (show(PRESENCE_MASCOT) then crossfades to it)."""
        self.mascot = Mascot.load(pack_dir, eager=eager)

    def has_mascot(self) -> Bool:
        return self.mascot.ready

    def toggle(mut self) -> Bool:
        """Toggle between Orb and Mascot (no-op if no mascot pack is loaded). Returns True if Mascot is active."""
        if not self.mascot.ready:
            _ = self.show(PRESENCE_ORB)
            return False
        _ = self.show(PRESENCE_ORB if self.kind == PRESENCE_MASCOT else PRESENCE_MASCOT)
        return self.kind == PRESENCE_MASCOT

    def mode(mut self, m: Int):
        var orb_m = m if (0 <= m <= ORB_SPEAK) else ORB_IDLE
        self.orb.mode(orb_m)
        if self.mascot.ready:
            self.mascot.mode(m)

    def drive(mut self, level: Float64):
        self.orb.drive(level)
        if self.mascot.ready:
            self.mascot.drive(level)

    def lane(mut self, cloud: Bool):
        self.orb.lane(cloud)
        if self.mascot.ready:
            self.mascot.lane(cloud)

    def look(mut self, x: Float64, y: Float64, amount: Float64):
        self.orb.look(x, y, amount)
        if self.mascot.ready:
            self.mascot.look(x, y, amount)

    def poke(mut self):
        if self.mascot.ready:
            self.mascot.poke()

    def version(self) -> Int:
        var v = self.orb.version()
        if self.kind == PRESENCE_MASCOT and self.mascot.ready:
            v = self.mascot.version()
        return v * 64 + self.stamp % 64  # (a switch is a new picture even when both have drawn as often)

    def _draw_kind(mut self, kind: Int, mut s: Surface, p: Palette):
        if kind == PRESENCE_MASCOT and self.mascot.ready:
            self.mascot.draw(s, p)
        else:
            self.orb.draw(s, p)

    def draw(mut self, mut s: Surface, p: Palette):
        var now = now_ns()
        if self.blend_ns > 0:
            _ = self.blend.step((now - self.blend_ns) // 1000)
        self.blend_ns = now
        if s.still:
            self.blend.snap(1.0)
        if not self.crossfading():
            self._draw_kind(self.kind, s, p)
            return
        var w = s.width
        var h = s.height
        var n = w * h
        if len(self._old) != n:
            self._old = List[UInt32](length=n, fill=0)
            self._new = List[UInt32](length=n, fill=0)
        var old = Surface(Int(self._old.unsafe_ptr()), w, h, s.scale)
        old.fill(0)
        self._draw_kind(self.from_kind, old, p)
        var neu = Surface(Int(self._new.unsafe_ptr()), w, h, s.scale)
        neu.fill(0)
        self._draw_kind(self.kind, neu, p)
        var a = min(max(self.blend.value, 0.0), 1.0)
        var k_new = PRESENCE_FROM_SCALE + (1.0 - PRESENCE_FROM_SCALE) * self.blend.value  # (the spring's settle shows as a size)
        var k_old = 1.0 + 0.06 * a
        var cx = Float64(w) * 0.5
        var cy = Float64(h) * 0.5
        for y in range(h):
            for x in range(w):
                var fx = Float64(x) + 0.5 - cx
                var fy = Float64(y) + 0.5 - cy
                var o = _layer(_sample(self._old, w, h, cx + fx / k_old, cy + fy / k_old), 1.0 - a)
                var q = _layer(_sample(self._new, w, h, cx + fx / k_new, cy + fy / k_new), a)
                var al = min(o[3] + q[3], 1.0)  # (weights a and 1 - a: a straight sum of the two premultiplied layers)
                var out: UInt32 = 0
                if al > 0.002:
                    var r = (o[0] + q[0]) / al
                    var g = (o[1] + q[1]) / al
                    var b = (o[2] + q[2]) / al
                    out = UInt32(min(Int(r + 0.5), 255)) | (UInt32(min(Int(g + 0.5), 255)) << 8) | (UInt32(min(Int(b + 0.5), 255)) << 16) | (UInt32(Int(al * 255.0 + 0.5)) << 24)
                s.pixels().unsafe_offset(y * w + x)[] = out
        s.again = True
