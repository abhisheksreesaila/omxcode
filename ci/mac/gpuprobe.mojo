# Does this machine's GPU run a Mojo kernel through MAX? (goal 32 M6; docs/plans/speed.md.) One tiny kernel with
# explicit copies in and out (no zero-copy: modular/modular #6145 on Apple), no atomics. Prints DEVICE: <name> · <api>
# and RESULT: ok|wrong, or DEVICE: none. Run on the Mac runner (ci/mac/run.sh) and on the owner's Mac:
#   pixi run mojo run ci/mac/gpuprobe.mojo
from max.gpu import global_idx
from max.gpu.host import DeviceContext


def add_index(data: UnsafePointer[Float32, MutAnyOrigin], n: Int32):
    var i = Int(global_idx.x)
    if i < Int(n):
        data.unsafe_offset(i)[] = data.unsafe_offset(i)[] + Float32(i)


def main() raises:
    var count = DeviceContext.number_of_devices()
    print("DEVICES:", count)
    if count == 0:
        print("DEVICE: none")
        return
    var ctx = DeviceContext()
    print("DEVICE:", ctx.name(), "·", ctx.api())
    comptime N = 4096
    var host = List[Float32](length=N, fill=1.0)
    var buf = ctx.enqueue_create_buffer[DType.float32](N)
    ctx.enqueue_copy(dst_buf=buf, src_ptr=host.unsafe_ptr())
    ctx.enqueue_function[add_index](buf.unsafe_ptr(), Int32(N), grid_dim=N // 256, block_dim=256)
    var back = List[Float32](length=N, fill=0.0)
    ctx.enqueue_copy(dst_ptr=back.unsafe_ptr(), src_buf=buf)
    ctx.synchronize()
    var wrong = 0
    for i in range(N):
        if back[i] != Float32(1 + i):
            wrong += 1
    print("RESULT:", "ok" if wrong == 0 else "wrong (" + String(wrong) + " of " + String(N) + ")")
