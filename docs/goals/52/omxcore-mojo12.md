# For omxcore's next stable commit (draft, not filed): Mojo 1.2, and declaring no disputed libc function

Supersedes docs/goals/50/omxcore-issue.md. The patch, against stable 834ef9a, is
vendor/patches/omxcore-834ef9a-mojo12.patch (10 files, about 115 added lines); the app vendors 834ef9a + it (D-5202).

1. **Mojo 1.2** removed `has_apple_gpu_accelerator()`. `default_accelerator().is_apple_gpu()` gives the same answer on
   every target (Linux, a Mac with and without `--target-accelerator metal:N`, iOS, probed on 1.1 and 1.2):
   mojo/omxcore/gpu.mojo, kernels_aot/kernels_aot_gpu.mojo, kernels_aot/pipeline_gpu.mojo.
2. **One signature per C symbol per binary.** 1.2's stdlib declares `read` and `write` itself; Flare and its json
   declare `pthread_create`, `pthread_join`, `pthread_detach`, `strtod`, `mmap`, `munmap` and `unlink` with other types.
   A new mojo/omxcore/_libc.mojo looks each up with dlsym and calls it through a typed pointer, so the engine declares
   none of them and links beside all of them (the app's tests/test_engine_flare.mojo: engine jobs answering HTTP
   requests through Flare). The cost is a dlsym per call, none on a per-row path.
3. **Running the tests with PyPI's Mojo:** scripts/mojo_test.sh's `ldd | grep -i python` matches every binary when Mojo
   comes from PyPI (its libraries live under python3.13/site-packages). `grep -i libpython` keeps the intent; the
   symbol checks after it already catch the interop.

All 40 engine Mojo tests pass on Mojo 1.2.0 with the patch (Linux, NVIDIA). Not checked: the Metal path on a real Mac
beyond the app's Mac run (goal 52 M6).

One more for apps that serve: code an app runs on Mojo's runtime pool (`parallelize`, as the engine's kernels do) can
wait forever behind Flare 0.13 serving loops that hold pool workers; mojoui.serve now keeps Flare's loops off the pool
(D-5207). Nothing for omxcore to change, but worth knowing for an engine used inside a server.
