# D-7876 crash hunt tools (D-7885, D-7887, D-7888)

Copies of the tools from build/g77/crashloop (build/ isn't kept). Build a shim with
`cc -shared -fPIC -O2 -o kgen_guard.so kgen_guard.c -ldl -lpthread`.

- `kgen_guard.c`: guard-page allocator for Mojo's heap only (KGEN_CompilerRT_AlignedAlloc/Free). Use it with `LD_PRELOAD`. A write into a freed Mojo block, or past a block's end, faults at the writer.
- `kgen_glibc.c`: moves Mojo's heap onto glibc's malloc (for MALLOC_CHECK_ or valgrind). `glibc_malloc.c` is the older shim, which never moved Mojo's heap.
- `loop.py`: M7E's stage sequence in a loop (`LOOP_BIN`, `LOOP_PRELOAD`, `LOOP_CPU`). `par.sh` runs P of them in parallel. `shots_loop.sh` loops omx's M7f picture runs with the real model (`SHOTS_TAG`).
- `vg.py`: the valgrind driver. It can't start on this machine, because Arch's ld.so is stripped.
