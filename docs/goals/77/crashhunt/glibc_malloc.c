/* D-7876: route malloc and friends to glibc's allocator (Mojo's runtime library exports tcmalloc's), so MALLOC_CHECK_ /
   MALLOC_PERTURB_ can see the heap. LD_PRELOAD=glibc_malloc.so */
#include <stddef.h>
#include <errno.h>
extern void *__libc_malloc(size_t);
extern void __libc_free(void *);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void *__libc_memalign(size_t, size_t);
void *malloc(size_t n) { return __libc_malloc(n); }
void free(void *p) { __libc_free(p); }
void cfree(void *p) { __libc_free(p); }
void *calloc(size_t a, size_t b) { return __libc_calloc(a, b); }
void *realloc(void *p, size_t n) { return __libc_realloc(p, n); }
void *memalign(size_t a, size_t n) { return __libc_memalign(a, n); }
void *aligned_alloc(size_t a, size_t n) { return __libc_memalign(a, n); }
void *valloc(size_t n) { return __libc_memalign(4096, n); }
int posix_memalign(void **out, size_t a, size_t n) { void *p = __libc_memalign(a, n); if (!p) return ENOMEM; *out = p; return 0; }
