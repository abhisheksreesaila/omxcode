/* Goal 38 M5: the external screen observer (docs/goals/38/README.md "The observer").

   observe mode (default):  screen_observer [--output NAME] X Y W H
       Captures the region X,Y,W,H (output logical coordinates) of the compositor's output with wlr-screencopy v3
       (capture_output_region + copy_with_damage: one small shm copy per composited frame that has damage, no polling
       timer). For every frame it prints one line to stdout:
           F <seq> <t_present_ns> <t_recv_ns> <hash> <damage>
       t_present_ns: the compositor's timestamp in the `ready` event ("the time at which the presentation took
       place"); t_recv_ns: CLOCK_MONOTONIC when this client received `ready`; hash: FNV-1a 64 of the region's pixels
       (alpha ignored); damage: 1 when the compositor sent damage events for the copy. First line:
           R <width_px> <height_px> <stride> <format> <clock_ok>
       stdin commands: "dump PATH" writes the next frame as a PPM (rows in screen order); "quit".

   probe mode:  screen_observer probe
       A test window (title "observer-probe", 320x200 logical) for the observer's self-test. stdin "flip" paints the
       whole window a new solid colour and commits it with a wp_presentation feedback request, printing
           C <t_commit_ns> <hash_of_rgb>          right before wl_surface.commit (CLOCK_MONOTONIC)
           P <t_presented_ns> <refresh_ns> <flags>  when the compositor reports the commit presented (its clock_id)
       First line: "K <clock_id>" (1 = CLOCK_MONOTONIC), then "S <w> <h>" when the window is configured and shown.

   Build: scripts/screen_observer.py builds it into build/observer/ (wayland-scanner + cc, libwayland-client). */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "wlr-screencopy-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include "presentation-time-client-protocol.h"

static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static int shm_fd(size_t size) {
    int fd = memfd_create("screen-observer", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)size) < 0) {
        perror("memfd");
        exit(2);
    }
    return fd;
}

/* ------------------------------------------------------------------------------------------------------------------ */
/* globals                                                                                                             */
/* ------------------------------------------------------------------------------------------------------------------ */

static struct wl_display *display;
static struct wl_shm *shm;
static struct zwlr_screencopy_manager_v1 *screencopy;
static struct wl_compositor *compositor;
static struct xdg_wm_base *wm_base;
static struct wp_presentation *presentation;
static uint32_t pres_clock = 0xffffffff;
#define MAX_OUTPUTS 8
static struct wl_output *outputs[MAX_OUTPUTS];
static char output_names[MAX_OUTPUTS][64];
static int n_outputs;

static void out_geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sp,
                         const char *make, const char *model, int32_t tr) {}
static void out_mode(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t r) {}
static void out_done(void *d, struct wl_output *o) {}
static void out_scale(void *d, struct wl_output *o, int32_t s) {}
static void out_name(void *d, struct wl_output *o, const char *name) {
    int i = (int)(intptr_t)d;
    snprintf(output_names[i], sizeof output_names[i], "%s", name);
}
static void out_desc(void *d, struct wl_output *o, const char *desc) {}
static const struct wl_output_listener output_listener = {out_geometry, out_mode, out_done, out_scale, out_name, out_desc};

static void wm_ping(void *d, struct xdg_wm_base *b, uint32_t serial) { xdg_wm_base_pong(b, serial); }
static const struct xdg_wm_base_listener wm_listener = {wm_ping};

static void pres_clock_id(void *d, struct wp_presentation *p, uint32_t clk) { pres_clock = clk; }
static const struct wp_presentation_listener pres_listener = {pres_clock_id};

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
    if (!strcmp(iface, wl_shm_interface.name)) {
        shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    } else if (!strcmp(iface, zwlr_screencopy_manager_v1_interface.name) && ver >= 2) {
        screencopy = wl_registry_bind(r, name, &zwlr_screencopy_manager_v1_interface, ver >= 3 ? 3 : 2);
    } else if (!strcmp(iface, wl_output_interface.name) && n_outputs < MAX_OUTPUTS) {
        int i = n_outputs++;
        outputs[i] = wl_registry_bind(r, name, &wl_output_interface, ver >= 4 ? 4 : ver);
        wl_output_add_listener(outputs[i], &output_listener, (void *)(intptr_t)i);
    } else if (!strcmp(iface, wl_compositor_interface.name)) {
        compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    } else if (!strcmp(iface, xdg_wm_base_interface.name)) {
        wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    } else if (!strcmp(iface, wp_presentation_interface.name)) {
        presentation = wl_registry_bind(r, name, &wp_presentation_interface, 1);
        wp_presentation_add_listener(presentation, &pres_listener, NULL);
    }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t name) {}
static const struct wl_registry_listener reg_listener = {reg_global, reg_remove};

/* ------------------------------------------------------------------------------------------------------------------ */
/* observe                                                                                                             */
/* ------------------------------------------------------------------------------------------------------------------ */

static struct wl_output *target;
static int rx, ry, rw, rh;
static struct {
    uint32_t format, width, height, stride;
    int have_shm, done;
} binfo;
static struct wl_buffer *buffer;
static void *pixels;
static size_t pixels_size;
static uint32_t frame_flags;
static int frame_damage, frame_state; /* 0 pending, 1 ready, 2 failed */
static uint64_t t_present, t_recv;
static uint64_t seq;
static char dump_path[1024];

static void fr_buffer(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t format, uint32_t w, uint32_t h, uint32_t stride) {
    binfo.format = format, binfo.width = w, binfo.height = h, binfo.stride = stride, binfo.have_shm = 1;
}
static void fr_flags(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t flags) { frame_flags = flags; }
static void fr_ready(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t hi, uint32_t lo, uint32_t nsec) {
    t_recv = now_ns();
    t_present = (((uint64_t)hi << 32) | lo) * 1000000000ull + nsec;
    frame_state = 1;
}
static void fr_failed(void *d, struct zwlr_screencopy_frame_v1 *f) { frame_state = 2; }
static void fr_damage(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    frame_damage = 1;
}
static void fr_dmabuf(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t fmt, uint32_t w, uint32_t h) {}
static void fr_buffer_done(void *d, struct zwlr_screencopy_frame_v1 *f) { binfo.done = 1; }
static const struct zwlr_screencopy_frame_v1_listener frame_listener = {fr_buffer, fr_flags, fr_ready, fr_failed,
                                                                        fr_damage, fr_dmabuf, fr_buffer_done};

static void make_buffer(void) {
    size_t size = (size_t)binfo.stride * binfo.height;
    if (buffer && size == pixels_size) return;
    if (buffer) {
        wl_buffer_destroy(buffer);
        munmap(pixels, pixels_size);
    }
    int fd = shm_fd(size);
    pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    buffer = wl_shm_pool_create_buffer(pool, 0, (int32_t)binfo.width, (int32_t)binfo.height, (int32_t)binfo.stride,
                                       binfo.format);
    wl_shm_pool_destroy(pool);
    close(fd);
    pixels_size = size;
}

static uint64_t hash_region(void) {
    uint64_t h = 1469598103934665603ull;
    for (uint32_t y = 0; y < binfo.height; y++) {
        const uint8_t *row = (const uint8_t *)pixels + (size_t)y * binfo.stride;
        for (uint32_t x = 0; x < binfo.width; x++) {
            /* 4 bytes per pixel in every 32-bit wl_shm format the compositor offers; skip the X/alpha byte's influence
               by masking the pixel to 24 bits in little-endian XRGB/ARGB order */
            uint32_t p;
            memcpy(&p, row + 4 * x, 4);
            p &= 0x00ffffff;
            h = (h ^ p) * 1099511628211ull;
        }
    }
    return h;
}

static void write_ppm(const char *path) {
    FILE *f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "dump: cannot write %s\n", path);
        return;
    }
    fprintf(f, "P6\n%u %u\n255\n", binfo.width, binfo.height);
    int abgr = binfo.format == WL_SHM_FORMAT_ABGR8888 || binfo.format == WL_SHM_FORMAT_XBGR8888;
    for (uint32_t yy = 0; yy < binfo.height; yy++) {
        uint32_t y = (frame_flags & ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) ? binfo.height - 1 - yy : yy;
        const uint8_t *row = (const uint8_t *)pixels + (size_t)y * binfo.stride;
        for (uint32_t x = 0; x < binfo.width; x++) {
            const uint8_t *p = row + 4 * x; /* little endian: XRGB8888 is B,G,R,X in memory */
            uint8_t rgb[3] = {abgr ? p[0] : p[2], p[1], abgr ? p[2] : p[0]};
            fwrite(rgb, 1, 3, f);
        }
    }
    fclose(f);
}

static void read_stdin_commands(int *quit) {
    static char buf[4096];
    static size_t len;
    ssize_t n = read(0, buf + len, sizeof buf - 1 - len);
    if (n <= 0) {
        *quit = 1; /* the harness went away */
        return;
    }
    len += (size_t)n;
    buf[len] = 0;
    char *line, *rest = buf;
    while ((line = strchr(rest, '\n'))) {
        *line = 0;
        if (!strncmp(rest, "dump ", 5)) snprintf(dump_path, sizeof dump_path, "%s", rest + 5);
        else if (!strcmp(rest, "quit")) *quit = 1;
        rest = line + 1;
    }
    len = strlen(rest);
    memmove(buf, rest, len + 1);
}

static int observe(const char *want_output) {
    if (!screencopy || !shm) {
        fprintf(stderr, "screen_observer: the compositor offers no zwlr_screencopy_manager_v1 v2+ or wl_shm\n");
        return 2;
    }
    wl_display_roundtrip(display); /* output names */
    target = outputs[0];
    for (int i = 0; i < n_outputs; i++)
        if (want_output && !strcmp(output_names[i], want_output)) target = outputs[i];
    if (!target) {
        fprintf(stderr, "screen_observer: no output\n");
        return 2;
    }
    int quit = 0, first = 1;
    uint64_t last_hash = 0;
    while (!quit) {
        struct zwlr_screencopy_frame_v1 *f = zwlr_screencopy_manager_v1_capture_output_region(screencopy, 0, target, rx, ry, rw, rh);
        memset(&binfo, 0, sizeof binfo);
        frame_state = 0, frame_damage = 0, frame_flags = 0;
        zwlr_screencopy_frame_v1_add_listener(f, &frame_listener, NULL);
        /* wait for the buffer description (buffer_done on v3; on v2 the buffer event is enough) */
        while (!(binfo.have_shm && (binfo.done || zwlr_screencopy_manager_v1_get_version(screencopy) < 3)) && frame_state != 2)
            if (wl_display_dispatch(display) < 0) return 3;
        if (frame_state == 2) {
            fprintf(stderr, "screen_observer: capture failed (region %d,%d %dx%d)\n", rx, ry, rw, rh);
            return 4;
        }
        make_buffer();
        if (first) {
            /* the compositor's ready timestamp's clock: if it is CLOCK_MONOTONIC it lies within a second of ours */
            printf("R %u %u %u %u\n", binfo.width, binfo.height, binfo.stride, binfo.format);
            fflush(stdout);
        }
        /* the first copy is immediate (a baseline); after that, wait for damage */
        if (first) zwlr_screencopy_frame_v1_copy(f, buffer);
        else zwlr_screencopy_frame_v1_copy_with_damage(f, buffer);
        first = 0;
        wl_display_flush(display);
        struct pollfd p[2] = {{wl_display_get_fd(display), POLLIN, 0}, {0, POLLIN, 0}};
        while (frame_state == 0 && !quit) {
            while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
            wl_display_flush(display);
            if (poll(p, 2, -1) < 0 && errno != EINTR) return 3;
            if (p[0].revents & POLLIN) wl_display_read_events(display);
            else wl_display_cancel_read(display);
            wl_display_dispatch_pending(display);
            if (p[1].revents & (POLLIN | POLLHUP)) read_stdin_commands(&quit);
        }
        if (frame_state == 1) {
            uint64_t h = hash_region();
            printf("F %llu %llu %llu %016llx %d\n", (unsigned long long)seq++, (unsigned long long)t_present,
                   (unsigned long long)t_recv, (unsigned long long)h, frame_damage);
            fflush(stdout);
            last_hash = h;
            if (dump_path[0]) {
                write_ppm(dump_path);
                printf("D %s\n", dump_path);
                fflush(stdout);
                dump_path[0] = 0;
            }
        } else if (frame_state == 2) {
            fprintf(stderr, "screen_observer: copy failed\n");
            zwlr_screencopy_frame_v1_destroy(f);
            return 4;
        }
        zwlr_screencopy_frame_v1_destroy(f);
    }
    (void)last_hash;
    return 0;
}

/* ------------------------------------------------------------------------------------------------------------------ */
/* probe                                                                                                               */
/* ------------------------------------------------------------------------------------------------------------------ */

static struct wl_surface *surface;
static struct xdg_surface *xsurface;
static struct xdg_toplevel *toplevel;
static int configured, pw = 320, ph = 200, flips;

static void xs_configure(void *d, struct xdg_surface *s, uint32_t serial) {
    xdg_surface_ack_configure(s, serial);
    configured = 1;
}
static const struct xdg_surface_listener xs_listener = {xs_configure};
static void tl_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *st) {
    if (w > 0 && h > 0) pw = w, ph = h;
}
static void tl_close(void *d, struct xdg_toplevel *t) { exit(0); }
static void tl_bounds(void *d, struct xdg_toplevel *t, int32_t w, int32_t h) {}
static void tl_caps(void *d, struct xdg_toplevel *t, struct wl_array *c) {}
static const struct xdg_toplevel_listener tl_listener = {tl_configure, tl_close, tl_bounds, tl_caps};

static void fb_sync(void *d, struct wp_presentation_feedback *f, struct wl_output *o) {}
static void fb_presented(void *d, struct wp_presentation_feedback *f, uint32_t hi, uint32_t lo, uint32_t nsec,
                         uint32_t refresh, uint32_t shi, uint32_t slo, uint32_t flags) {
    uint64_t t = (((uint64_t)hi << 32) | lo) * 1000000000ull + nsec;
    printf("P %llu %u %u\n", (unsigned long long)t, refresh, flags);
    fflush(stdout);
    wp_presentation_feedback_destroy(f);
}
static void fb_discarded(void *d, struct wp_presentation_feedback *f) {
    printf("P 0 0 discarded\n");
    fflush(stdout);
    wp_presentation_feedback_destroy(f);
}
static const struct wp_presentation_feedback_listener fb_listener = {fb_sync, fb_presented, fb_discarded};

static void paint(uint32_t rgb, int feedback) {
    size_t stride = (size_t)pw * 4, size = stride * (size_t)ph;
    int fd = shm_fd(size);
    uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    for (size_t i = 0; i < (size_t)pw * (size_t)ph; i++) px[i] = 0xff000000u | rgb;
    munmap(px, size);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, pw, ph, (int32_t)stride, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    wl_surface_attach(surface, b, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, pw, ph);
    if (feedback && presentation) {
        struct wp_presentation_feedback *f = wp_presentation_feedback(presentation, surface);
        wp_presentation_feedback_add_listener(f, &fb_listener, NULL);
    }
    if (feedback) {
        printf("C %llu %06x\n", (unsigned long long)now_ns(), rgb);
        fflush(stdout);
    }
    wl_surface_commit(surface);
    wl_display_flush(display);
    /* the buffer is released by the compositor later; a probe leaks one small buffer per flip (bounded by the test) */
}

static int probe(void) {
    if (!compositor || !wm_base || !shm) {
        fprintf(stderr, "probe: no wl_compositor/xdg_wm_base/wl_shm\n");
        return 2;
    }
    wl_display_roundtrip(display);
    printf("K %u\n", pres_clock);
    fflush(stdout);
    surface = wl_compositor_create_surface(compositor);
    xsurface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xsurface, &xs_listener, NULL);
    toplevel = xdg_surface_get_toplevel(xsurface);
    xdg_toplevel_add_listener(toplevel, &tl_listener, NULL);
    xdg_toplevel_set_title(toplevel, "observer-probe");
    xdg_toplevel_set_app_id(toplevel, "observer-probe");
    wl_surface_commit(surface);
    while (!configured) wl_display_dispatch(display);
    paint(0x202020, 0);
    printf("S %d %d\n", pw, ph);
    fflush(stdout);
    struct pollfd p[2] = {{wl_display_get_fd(display), POLLIN, 0}, {0, POLLIN, 0}};
    char buf[256];
    size_t len = 0;
    for (;;) {
        while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
        wl_display_flush(display);
        if (poll(p, 2, -1) < 0 && errno != EINTR) return 3;
        if (p[0].revents & POLLIN) wl_display_read_events(display);
        else wl_display_cancel_read(display);
        wl_display_dispatch_pending(display);
        if (p[1].revents & (POLLIN | POLLHUP)) {
            ssize_t n = read(0, buf + len, sizeof buf - 1 - len);
            if (n <= 0) return 0;
            len += (size_t)n;
            buf[len] = 0;
            char *nl;
            while ((nl = strchr(buf, '\n'))) {
                *nl = 0;
                if (!strcmp(buf, "flip")) {
                    flips++;
                    /* a different, deterministic colour per flip */
                    uint32_t rgb = (uint32_t)(flips * 2654435761u) & 0x00ffffffu;
                    paint(rgb, 1);
                } else if (!strcmp(buf, "quit")) {
                    return 0;
                }
                len -= (size_t)(nl + 1 - buf);
                memmove(buf, nl + 1, len + 1);
            }
        }
    }
}

int main(int argc, char **argv) {
    display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "screen_observer: no Wayland display (WAYLAND_DISPLAY)\n");
        return 2;
    }
    struct wl_registry *reg = wl_display_get_registry(display);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(display);
    if (argc >= 2 && !strcmp(argv[1], "probe")) return probe();
    const char *want = NULL;
    int a = 1;
    if (argc > 2 && !strcmp(argv[1], "--output")) want = argv[2], a = 3;
    if (argc - a != 4) {
        fprintf(stderr, "usage: screen_observer [--output NAME] X Y W H | screen_observer probe\n");
        return 1;
    }
    rx = atoi(argv[a]), ry = atoi(argv[a + 1]), rw = atoi(argv[a + 2]), rh = atoi(argv[a + 3]);
    return observe(want);
}
