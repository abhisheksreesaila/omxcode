# The pixels a Canvas is painted into. Hosts own the memory; the app's draw() fills it.

from std.memory import Pointer
from std.sys import CompilationTarget, is_defined


# A native Mac build with the GPU (scripts/build.sh with MAC_GPU on a Mac: Mojo's runtime and MAX's Metal path linked,
# D-309): GPU pictures may go straight into an IOSurface the host shows (D-5311). The cross build has neither.
comptime MAC_GPU = CompilationTarget.is_macos() and is_defined["MOJOUI_MAC_GPU"]()


struct Surface(Movable):
    """RGBA pixels, row by row with no gaps (each UInt32 holds R, G, B, A from the low byte up).
    `width` × `height` are pixels; `scale` is pixels per point (2 on a Retina screen)."""

    var address: Int
    var width: Int
    var height: Int
    var scale: Float64
    var again: Bool  # set by drawing code that is mid-animation (a gliding selection ring): the host draws again next frame
    var still: Bool  # set by the host: the person asked for less motion (or a still picture is wanted): animations jump to their end
    # A picture drawn on the GPU can stay there (goal 36b): the host sets gpu_ok when it can take one (mojoui.present);
    # GPU drawing code (PointCloud.splat/shade) then leaves the RGBA picture in GPU memory instead of copying it into
    # `address`, and says where: gpu_address (a device pointer, rows of `width` pixels, no gaps) on CUDA device
    # gpu_device. gpu_drawn: the picture was made on the GPU (handed over or copied back), so the host can report its path.
    var gpu_ok: Bool
    var gpu_address: Int
    var gpu_device: Int
    var gpu_drawn: Bool
    # gpu_painter: the host's mojoui.present.Presenter (its address; 0: none), current while draw() runs: GPU drawing
    # code may blend straight into one of its textures with the GPU's fixed-function blending and say which (gpu_slot).
    var gpu_painter: Int
    var gpu_slot: Int
    # The Mac with its GPU (D-5311): shared_address is an IOSurface's memory, locked for this draw (page-aligned,
    # shared_bytes long, rows of shared_row pixels, bytes B, G, R, A; shared_id names it). The GPU and the CPU share one
    # memory there, so GPU drawing code may write the picture straight into it and say so (gpu_address =
    # shared_address); the host then shows the IOSurface itself: the picture is never copied. 0: not offered.
    var shared_address: Int
    var shared_bytes: Int
    var shared_row: Int
    var shared_id: Int

    def __init__(out self, address: Int, width: Int, height: Int, scale: Float64):
        self.address = address
        self.width = width
        self.height = height
        self.scale = scale
        self.again = False
        self.still = False
        self.gpu_ok = False
        self.gpu_address = 0
        self.gpu_device = -1
        self.gpu_drawn = False
        self.gpu_painter = 0
        self.gpu_slot = -1
        self.shared_address = 0
        self.shared_bytes = 0
        self.shared_row = 0
        self.shared_id = 0

    def pixels(self) -> Pointer[UInt32, MutUntrackedOrigin]:
        return Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=self.address)

    def set(self, x: Int, y: Int, rgba: UInt32):
        if 0 <= x < self.width and 0 <= y < self.height:
            self.pixels().unsafe_offset(y * self.width + x)[] = rgba

    def get(self, x: Int, y: Int) -> UInt32:
        if 0 <= x < self.width and 0 <= y < self.height:
            return self.pixels().unsafe_offset(y * self.width + x)[]
        return 0

    def fill(self, rgba: UInt32):
        var p = self.pixels()
        for i in range(self.width * self.height):
            p.unsafe_offset(i)[] = rgba

    def points_width(self) -> Float64:
        return Float64(self.width) / self.scale

    def points_height(self) -> Float64:
        return Float64(self.height) / self.scale


def rgba(r: Int, g: Int, b: Int, a: Int = 255) -> UInt32:
    """A colour for Surface.set/fill from 0–255 channels."""
    return UInt32(r & 255) | (UInt32(g & 255) << 8) | (UInt32(b & 255) << 16) | (UInt32(a & 255) << 24)
