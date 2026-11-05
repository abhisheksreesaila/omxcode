# mojoui.maxrt: run a compiled model (a "pack") in the app's own process, on the GPU when there is one (goal 51 M0).
# A pack is a MAX graph compiled once on our side (scripts/packs/*.py: Python there, never in the app) to a .mef, with
# its weights in a .safetensors file; the app loads it through MAX's C library and calls it like a function.
#
#   var rt = MaxRuntime()                                         # finds MAX, loads libmax (once per process), a GPU if any
#   var model = rt.load("build/packs/minilm/minilm.mef", "build/packs/minilm/minilm.safetensors")
#   var ins = List[TensorIn]()
#   ins.append(TensorIn.i64(ids, [rows, cols]))
#   var outs = model.run(ins, 1)                                  # output0 … as host arrays
#   var v = outs[0].floats()
#
# How: libmax.so is dlopened from MAX's package root (OMX_MAX_ROOT, else the pixi environment's
# site-packages/modular), and its M_* functions are called by address, as mojoui.sqlite calls SQLite: no link flag, and
# an app that never loads a pack never loads MAX. MODULAR_MOJO_MAX_PACKAGE_ROOT is set to that root before the first
# call (MAX needs it to find its runtime libraries). A model's inputs are named input0…, its outputs output0…; inputs
# are host arrays (MAX stages them onto the GPU), outputs come back to host arrays. Everything the C library allocates
# per call is freed per call. The first GPU call is slow (75–130 ms): load() runs nothing, warm() does.

from std.ffi import external_call, c_int, c_char
from std.memory import Pointer
from std.os import getenv, setenv
from mojoui.shared import get_shared, put_shared

comptime M_FLOAT32 = 81  # MAX's M_Dtype codes (types.h)
comptime M_INT64 = 141
comptime M_INT32 = 139
comptime M_UINT8 = 134
comptime SLOT_MAX_LIB = 197  # mojoui.shared slot: libmax's handle

comptime _P = def(Int) thin abi("C") -> Int
comptime _V = def(Int) thin abi("C") -> NoneType
comptime _PP = def(Int, Int) thin abi("C") -> Int
comptime _VPP = def(Int, Int) thin abi("C") -> NoneType
comptime _PPP = def(Int, Int, Int) thin abi("C") -> Int
comptime _PPPP = def(Int, Int, Int, Int) thin abi("C") -> Int
comptime _VPPPP = def(Int, Int, Int, Int) thin abi("C") -> NoneType
comptime _N = def() thin abi("C") -> Int
comptime _DEV = def(c_int, c_int, Int) thin abi("C") -> Int
comptime _SPEC = def(Int, Int64, c_int, Int, Int) thin abi("C") -> Int
comptime _LOADST = def(Int, Int, Int, Int) thin abi("C") -> Int
comptime _I = def(Int) thin abi("C") -> c_int


def _dlsym(handle: Int, name: String) -> Int:
    var n = name
    return external_call["dlsym", Int](handle, n.as_c_string_span())


def _fn[T: ImplicitlyCopyable](addr: Int) -> T:
    var raw = Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=addr)
    return Pointer(to=raw).unsafe_bitcast[T]()[]


def _c_text(addr: Int) -> String:
    if addr == 0:
        return String("")
    return String(unsafe_from_utf8_ptr=Pointer[c_char, MutUntrackedOrigin](unsafe_from_address=addr))


def _exists(path: String) -> Bool:
    var p = path
    return external_call["access", c_int](p.as_c_string_span(), c_int(0)) == 0


def max_root() -> String:
    """MAX's package root (the folder whose lib/ holds libmax.so): OMX_MAX_ROOT, else the pixi environment's
    (CONDA_PREFIX's, then ./.pixi/envs/default's) site-packages/modular. "" when none is found."""
    var asked = getenv("OMX_MAX_ROOT", "")
    if asked != "":
        return asked
    var envs = List[String]()
    var prefix = getenv("CONDA_PREFIX", "")
    if prefix != "":
        envs.append(prefix)
    envs.append(".pixi/envs/default")
    for e in envs:
        for minor in range(16, 9, -1):
            var root = e + "/lib/python3." + String(minor) + "/site-packages/modular"
            if _exists(root + "/lib/libmax.so"):
                return root
    return ""


def _library() raises -> Int:
    var have = get_shared(SLOT_MAX_LIB)
    if have != 0:
        return have
    var root = max_root()
    if root == "":
        raise Error("No MAX here: set OMX_MAX_ROOT to MAX's package root (the folder whose lib/ has libmax.so), or run inside the pixi environment")
    if getenv("MODULAR_MOJO_MAX_PACKAGE_ROOT", "") == "":
        _ = setenv("MODULAR_MOJO_MAX_PACKAGE_ROOT", root, True)
    var dlopen = _dlsym(0, "dlopen")
    if dlopen == 0:
        raise Error("maxrt: no dlopen in this process")
    var path = root + "/lib/libmax.so"
    var h = _fn[def(Int, c_int) thin abi("C") -> Int](dlopen)(Int(path.as_c_string_span().unsafe_ptr()), c_int(2 | 256))  # RTLD_NOW | RTLD_GLOBAL
    if h == 0:
        var err = _dlsym(0, "dlerror")
        raise Error("maxrt: couldn't load " + path + ": " + (_c_text(_fn[_N](err)()) if err != 0 else String("")))
    put_shared(SLOT_MAX_LIB, h)
    return h


@fieldwise_init
struct _MaxLib(ImplicitlyCopyable, Movable):
    var new_status: Int
    var is_error: Int
    var get_error: Int
    var free_status: Int
    var new_runtime_config: Int
    var new_device: Int
    var config_add_device: Int
    var new_runtime_context: Int
    var new_compile_config: Int
    var set_model_path: Int
    var compile_model_sync: Int
    var load_safetensors: Int
    var registry_from_safetensors: Int
    var init_model: Int
    var wait_for_model: Int
    var new_tensor_spec: Int
    var free_tensor_spec: Int
    var new_tensor_map: Int
    var free_tensor_map: Int
    var borrow_tensor_into: Int
    var tensor_by_name: Int
    var copy_tensor_to_device: Int
    var tensor_data: Int
    var tensor_elements: Int
    var tensor_device: Int
    var is_host_device: Int
    var free_tensor: Int
    var execute_model_sync: Int
    var accelerator_count: Int

    @staticmethod
    def load() raises -> _MaxLib:
        var h = _library()
        var lib = _MaxLib(
            _dlsym(h, "M_newStatus"), _dlsym(h, "M_isError"), _dlsym(h, "M_getError"), _dlsym(h, "M_freeStatus"),
            _dlsym(h, "M_newRuntimeConfig"), _dlsym(h, "M_newDevice"), _dlsym(h, "M_runtimeConfigAddDevice"),
            _dlsym(h, "M_newRuntimeContext"), _dlsym(h, "M_newCompileConfig"), _dlsym(h, "M_setModelPath"),
            _dlsym(h, "M_compileModelSync"), _dlsym(h, "M_loadSafetensors"), _dlsym(h, "M_newWeightsRegistryFromSafetensors"),
            _dlsym(h, "M_initModel"), _dlsym(h, "M_waitForModel"), _dlsym(h, "M_newTensorSpec"), _dlsym(h, "M_freeTensorSpec"),
            _dlsym(h, "M_newAsyncTensorMap"), _dlsym(h, "M_freeAsyncTensorMap"), _dlsym(h, "M_borrowTensorInto"),
            _dlsym(h, "M_getTensorByNameFrom"), _dlsym(h, "M_copyTensorToDevice"), _dlsym(h, "M_getTensorData"),
            _dlsym(h, "M_getTensorNumElements"), _dlsym(h, "M_getTensorDevice"), _dlsym(h, "M_isHostDevice"),
            _dlsym(h, "M_freeTensor"), _dlsym(h, "M_executeModelSync"), _dlsym(h, "M_getAcceleratorCount"),
        )
        if lib.new_status == 0 or lib.execute_model_sync == 0 or lib.tensor_by_name == 0 or lib.accelerator_count == 0:
            raise Error("maxrt: this libmax is missing functions (a MAX version this code wasn't written for?)")
        return lib

    def check(self, status: Int, what: String) raises:
        if _fn[_I](self.is_error)(status) != 0:
            raise Error("maxrt: " + what + ": " + _c_text(_fn[_P](self.get_error)(status)))


def _width(dtype: Int) -> Int:
    if dtype == M_INT64:
        return 8
    if dtype == M_FLOAT32 or dtype == M_INT32:
        return 4
    if dtype == M_UINT8:
        return 1
    return 0


struct TensorIn(Movable):
    """An input: its bytes (owned, so they live through the call), its shape and its MAX dtype."""

    var data: List[UInt8]
    var shape: List[Int]
    var dtype: Int

    def __init__(out self, var data: List[UInt8], var shape: List[Int], dtype: Int):
        self.data = data^
        self.shape = shape^
        self.dtype = dtype

    @staticmethod
    def f32(values: List[Float32], var shape: List[Int]) -> TensorIn:
        var b = List[UInt8](length=len(values) * 4, fill=0)
        var src = values.unsafe_ptr().bitcast[UInt8]()
        for i in range(len(b)):
            b[i] = src[i]
        return TensorIn(b^, shape^, M_FLOAT32)

    @staticmethod
    def i64(values: List[Int64], var shape: List[Int]) -> TensorIn:
        var b = List[UInt8](length=len(values) * 8, fill=0)
        var src = values.unsafe_ptr().bitcast[UInt8]()
        for i in range(len(b)):
            b[i] = src[i]
        return TensorIn(b^, shape^, M_INT64)


struct TensorOut(Movable):
    """An output, back on the host: its bytes and its element count (its shape is the model's to know)."""

    var data: List[UInt8]
    var count: Int

    def __init__(out self, var data: List[UInt8], count: Int):
        self.data = data^
        self.count = count

    def floats(self) -> List[Float32]:
        var out = List[Float32](length=self.count, fill=0)
        var src = self.data.unsafe_ptr().bitcast[Float32]()
        for i in range(min(self.count, len(self.data) // 4)):
            out[i] = src[i]
        return out^


struct MaxModel(Movable):
    """A loaded pack: call run() as often as you like (one thread at a time)."""

    var lib: _MaxLib
    var ctx: Int
    var host: Int
    var device: Int  # where it runs (the GPU's device, or the host's)
    var model: Int
    var on_gpu: Bool
    var path: String

    def __init__(out self, lib: _MaxLib, ctx: Int, host: Int, device: Int, model: Int, on_gpu: Bool, path: String):
        self.lib = lib
        self.ctx = ctx
        self.host = host
        self.device = device
        self.model = model
        self.on_gpu = on_gpu
        self.path = path

    def run(mut self, inputs: List[TensorIn], outputs: Int = 1) raises -> List[TensorOut]:
        """The model on `inputs` (input0, input1 … in order): its first `outputs` outputs, as host arrays."""
        var lib = self.lib
        var st = _fn[_N](lib.new_status)()
        var ins = _fn[_P](lib.new_tensor_map)(self.ctx)
        var specs = List[Int]()
        var names = List[String]()
        var shapes = List[List[Int64]]()  # (MAX may read a spec's shape and name until the call: they live until then)
        for k in range(len(inputs)):
            var shape = List[Int64]()
            for d in inputs[k].shape:
                shape.append(Int64(d))
            shapes.append(shape^)
            names.append("input" + String(k) + "\0")
        try:
            for k in range(len(inputs)):
                ref t = inputs[k]
                var spec = _fn[_SPEC](lib.new_tensor_spec)(Int(shapes[k].unsafe_ptr()), Int64(len(shapes[k])), c_int(t.dtype),
                                                          Int(names[k].unsafe_ptr()), self.device)
                specs.append(spec)
                _fn[_VPPPP](lib.borrow_tensor_into)(ins, Int(t.data.unsafe_ptr()), spec, st)
                lib.check(st, "input" + String(k) + " of " + self.path)
            var outs = _fn[_PPPP](lib.execute_model_sync)(self.ctx, self.model, ins, st)
            _ = len(names)  # (the inputs' names and shapes live until the call)
            _ = len(shapes)
            lib.check(st, "running " + self.path)
            var got = List[TensorOut]()
            try:
                for k in range(outputs):
                    var name = "output" + String(k) + "\0"
                    var y = _fn[_PPP](lib.tensor_by_name)(outs, Int(name.unsafe_ptr()), st)
                    _ = name
                    lib.check(st, name + " of " + self.path)
                    var hy = y
                    if _fn[_I](lib.is_host_device)(_fn[_P](lib.tensor_device)(y)) == 0:
                        hy = _fn[_PPP](lib.copy_tensor_to_device)(y, self.host, st)
                        lib.check(st, "copying " + name + " back")
                    var n = _fn[_P](lib.tensor_elements)(hy)
                    var bytes = n * 4  # (packs answer in float32: maxrt's contract)
                    var b = List[UInt8](length=bytes, fill=0)
                    var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=_fn[_P](lib.tensor_data)(hy))
                    for i in range(bytes):
                        b[i] = src[i]
                    if hy != y:
                        _fn[_V](lib.free_tensor)(hy)
                    _fn[_V](lib.free_tensor)(y)
                    got.append(TensorOut(b^, n))
            finally:
                _fn[_V](lib.free_tensor_map)(outs)
            return got^
        finally:
            _fn[_V](lib.free_tensor_map)(ins)
            for s in specs:
                _fn[_V](lib.free_tensor_spec)(s)
            _fn[_V](lib.free_status)(st)


struct MaxRuntime(Movable):
    """MAX in this process: its library, a runtime context with the host and (when there is one) the first GPU."""

    var lib: _MaxLib
    var ctx: Int
    var host: Int
    var gpu: Int  # 0: none
    var status: Int

    def __init__(out self, use_gpu: Bool = True) raises:
        self.lib = _MaxLib.load()
        var lib = self.lib
        self.status = _fn[_N](lib.new_status)()
        var cfg = _fn[_N](lib.new_runtime_config)()
        self.host = _fn[_DEV](lib.new_device)(c_int(0), c_int(0), self.status)
        lib.check(self.status, "the host device")
        _fn[_VPP](lib.config_add_device)(cfg, self.host)
        self.gpu = 0
        if use_gpu and _fn[_N](lib.accelerator_count)() > 0:
            var g = _fn[_DEV](lib.new_device)(c_int(1), c_int(0), self.status)
            if _fn[_I](lib.is_error)(self.status) == 0 and g != 0:
                self.gpu = g
                _fn[_VPP](lib.config_add_device)(cfg, g)
            else:
                _fn[_V](lib.free_status)(self.status)  # (no GPU after all: the host only, with a clean status)
                self.status = _fn[_N](lib.new_status)()
        self.ctx = _fn[_PP](lib.new_runtime_context)(cfg, self.status)
        lib.check(self.status, "the runtime context")

    def has_gpu(self) -> Bool:
        return self.gpu != 0

    def load(mut self, mef: String, weights: String = "", gpu: Bool = True) raises -> MaxModel:
        """A pack: its compiled graph (.mef) and, when it reads external weights, its .safetensors. `gpu`: the pack was
        built for the GPU (needs one here)."""
        if not _exists(mef):
            raise Error("No pack at " + mef + ": its scripts/packs/*.py makes it")
        if gpu and self.gpu == 0:
            raise Error(mef + " is a GPU pack and there is no GPU here")
        var lib = self.lib
        var st = self.status
        var cc = List[Int](length=1, fill=0)
        cc[0] = _fn[_N](lib.new_compile_config)()
        var path = mef + "\0"
        _fn[_VPP](lib.set_model_path)(cc[0], Int(path.unsafe_ptr()))
        var compiled = _fn[_PPP](lib.compile_model_sync)(self.ctx, Int(cc.unsafe_ptr()), st)
        lib.check(st, "loading " + mef)
        var registry = 0
        if weights != "":
            if not _exists(weights):
                raise Error("No weights at " + weights)
            var w = weights + "\0"
            var paths = List[Int](length=1, fill=0)
            paths[0] = Int(w.unsafe_ptr())
            var sts = _fn[_LOADST](lib.load_safetensors)(Int(paths.unsafe_ptr()), 1, self.host, st)
            lib.check(st, "reading " + weights)
            registry = _fn[_PP](lib.registry_from_safetensors)(sts, st)
            _ = w  # (its text and the list of it live until the library has read the weights)
            _ = paths[0]
            lib.check(st, "the weights of " + mef)
        var model = _fn[_PPPP](lib.init_model)(self.ctx, compiled, registry, st)
        lib.check(st, "starting " + mef)
        _fn[_VPP](lib.wait_for_model)(model, st)
        lib.check(st, "starting " + mef)
        _ = cc[0]  # (MAX reads the compile config's cell and the path until the model has started: they live until here,
        _ = path   # else Mojo frees them right after the compile call and init reads freed memory)
        return MaxModel(lib, self.ctx, self.host, self.gpu if gpu else self.host, model, gpu, mef)
