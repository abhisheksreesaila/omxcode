/* D-7885: a guard-page allocator for Mojo's heap only (KGEN_CompilerRT_AlignedAlloc/Free; GTK's malloc is untouched).
   A block ends where an unmapped guard page starts; its 32-byte header sits just before it (in an extra page only when the block
   starts within 32 bytes of a page). A free drops the pages (MADV_DONTNEED) and makes them PROT_NONE; addresses are never reused
   (a bump pointer through one big reservation). So a write past a block's end, or into a freed block, by Mojo or by C, faults at
   the writer. A free of a pointer this shim didn't make prints its stack (once per 1000) and goes to the real allocator.
   LD_PRELOAD=kgen_guard.so; KGEN_GUARD_GB: the reservation (default 6144). */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define PG 4096UL
#define MAGIC 0x6b67656e67756172ULL
static uint8_t *base, *next, *end;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static unsigned long blocks, frees, foreign;
typedef struct { uint64_t magic, first, pages, live; } Hdr;  /* first: the block's first page (header page or data page) */

static void init(void) {
    const char *g = getenv("KGEN_GUARD_GB");
    size_t gb = g ? strtoul(g, 0, 10) : 6144;
    size_t n = gb << 30;
    void *p = mmap(0, n, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED) { fprintf(stderr, "kgen_guard: no reservation\n"); abort(); }
    base = next = p; end = base + n;
    fprintf(stderr, "kgen_guard: %zu GB reserved for Mojo's heap\n", gb);
}

void *KGEN_CompilerRT_AlignedAlloc(size_t align, size_t size) {
    if (align < 1) align = 1;  /* exact: the block ends at the guard page whatever its size (D-7889) */
    size_t sz = (size ? size : 1);
    sz = (sz + align - 1) & ~(align - 1);
    size_t data = (sz + PG - 1) / PG;
    size_t off = data * PG - sz;  /* the block's start within its first data page */
    size_t lead = off < sizeof(Hdr) ? 1 : 0;
    size_t pages = lead + data + 1;
    pthread_mutex_lock(&mu);
    if (!base) init();
    if (next + pages * PG > end) {
        fprintf(stderr, "kgen_guard: reservation used up after %lu blocks (%lu freed): stopping\n", blocks, frees);
        abort();
    }
    uint8_t *f = next;
    next += pages * PG;
    blocks++;
    pthread_mutex_unlock(&mu);
    if (mprotect(f, (lead + data) * PG, PROT_READ | PROT_WRITE)) { fprintf(stderr, "kgen_guard: mprotect failed after %lu blocks (%lu freed)\n", blocks, frees); abort(); }
    uint8_t *p = f + (lead + data) * PG - sz;
    Hdr *hd = (Hdr *)(p - sizeof(Hdr));
    hd->magic = MAGIC; hd->first = (uint64_t)f; hd->pages = lead + data; hd->live = 1;
    return p;
}

void KGEN_CompilerRT_AlignedFree(void *p) {
    if (!p) return;
    uint8_t *q = p;
    if (!base || q < base || q >= end) {
        static void (*real)(void *);
        unsigned long n = __sync_fetch_and_add(&foreign, 1);
        if (n % 1000 == 0) {
            void *bt[32];
            int k = backtrace(bt, 32);
            fprintf(stderr, "kgen_guard: free of %p, which Mojo's heap didn't make (%lu so far): stack\n", p, n + 1);
            backtrace_symbols_fd(bt, k, 2);
        }
        if (!real) real = (void (*)(void *))dlsym(RTLD_NEXT, "KGEN_CompilerRT_AlignedFree");
        if (real) real(p); else free(p);
        return;
    }
    Hdr *hd = (Hdr *)(q - sizeof(Hdr));  /* (faults here on a second free: the block's pages are PROT_NONE) */
    if (hd->magic != MAGIC) { fprintf(stderr, "kgen_guard: free of %p: no header (not a block's start)\n", p); abort(); }
    uint8_t *f = (uint8_t *)hd->first;
    size_t pages = hd->pages;
    hd->live = 0;
    madvise(f, pages * PG, MADV_DONTNEED);
    if (mprotect(f, pages * PG, PROT_NONE)) { perror("kgen_guard mprotect (free)"); abort(); }
    __sync_fetch_and_add(&frees, 1);
}

__attribute__((destructor)) static void bye(void) {
    if (base) fprintf(stderr, "kgen_guard: %lu blocks, %lu freed, %lu foreign frees, %zu GB of address space used\n", blocks, frees, foreign, (size_t)(next - base) >> 30);
}
