// What a program does to its files, in order, for tests/diskorder.py (LD_PRELOAD; Linux): opens, writes, syncs, renames, removals.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#define REAL(n) __typeof__(&n) r = (__typeof__(&n))dlsym(RTLD_NEXT, #n)
static int out = -1;
static void say(const char *k, const char *a, const char *b) {
  if (out < 0) { const char *p = getenv("DISKORDER"); int (*o)(const char *, int, ...) = dlsym(RTLD_NEXT, "open"); out = p ? o(p, O_WRONLY | O_CREAT | O_APPEND, 0600) : 2; }
  char s[1400]; int n = snprintf(s, sizeof s, "%s\t%s\t%s\n", k, a, b ? b : "");
  ssize_t (*w)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write"); w(out, s, n);
}
static const char *name(int fd, char *buf) { char p[64]; snprintf(p, sizeof p, "/proc/self/fd/%d", fd); ssize_t n = readlink(p, buf, 1200); buf[n > 0 ? n : 0] = 0; return buf; }
static void on(const char *k, int fd) { char b[1300]; name(fd, b); if (strstr(b, "unsaved") || strstr(b, "notes.db")) say(k, b, 0); }
ssize_t write(int fd, const void *p, size_t n) { REAL(write); if (fd > 2 && fd != out) on("write", fd); return r(fd, p, n); }
ssize_t pwrite(int fd, const void *p, size_t n, off_t o) { REAL(pwrite); on("write", fd); return r(fd, p, n, o); }
ssize_t pwrite64(int fd, const void *p, size_t n, off64_t o) { REAL(pwrite64); on("write", fd); return r(fd, p, n, o); }
int fsync(int fd) { REAL(fsync); on("sync", fd); return r(fd); }
int fdatasync(int fd) { REAL(fdatasync); on("sync", fd); return r(fd); }
int rename(const char *a, const char *b) { REAL(rename); int e = r(a, b); if (!e && strstr(b, "unsaved")) say("rename", a, b); return e; }
int unlink(const char *a) { REAL(unlink); int e = r(a); if (!e && strstr(a, "unsaved")) say("unlink", a, 0); return e; }
