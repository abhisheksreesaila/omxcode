/* D-7885: Mojo's heap (KGEN_CompilerRT_AlignedAlloc/Free, tcmalloc in libAsyncRTRuntimeGlobals) routed to glibc's allocator,
   so valgrind (which replaces glibc's malloc) or MALLOC_CHECK_ sees Mojo's blocks too. LD_PRELOAD=kgen_glibc.so.
   Signatures as spike/kgen_shim.c infers them. */
#include <stdlib.h>
void *KGEN_CompilerRT_AlignedAlloc(size_t align, size_t size) {
    if (align < sizeof(void *)) align = sizeof(void *);
    void *p = NULL;
    if (posix_memalign(&p, align, size ? size : 1) != 0) return NULL;
    return p;
}
void KGEN_CompilerRT_AlignedFree(void *p) { free(p); }
