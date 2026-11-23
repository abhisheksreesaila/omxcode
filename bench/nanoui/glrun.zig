//! [omxcode benchmark addition] The same scenes as cpu.zig, but each frame drawn by nanoui's
//! OpenGL renderer (the one GtkGLArea windows use on Linux) in a headless EGL context
//! (Mesa's surfaceless platform, as nanoui's own tests_opengl.zig makes it). "encode" here is the
//! wall time of Renderer.draw (instance upload + draws) plus glFinish: the GPU frame, CPU-waited.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const scenes = @import("scenes.zig");
const main = @import("main.zig");
const Renderer = ui.opengl_renderer.Renderer;

pub const renderer = "opengl";

var finish_fn: ?*const fn () callconv(.c) void = null;

fn egl() !void {
    const lib = std.c.dlopen("libEGL.so.1", .{ .NOW = true }) orelse return error.NoEgl;
    const getDisplay: *const fn (u32, ?*anyopaque, ?[*]const isize) callconv(.c) ?*anyopaque = @ptrCast(@alignCast(std.c.dlsym(lib, "eglGetPlatformDisplay") orelse return error.NoEgl));
    const initialize: *const fn (*anyopaque, ?*i32, ?*i32) callconv(.c) u32 = @ptrCast(@alignCast(std.c.dlsym(lib, "eglInitialize") orelse return error.NoEgl));
    const bindApi: *const fn (u32) callconv(.c) u32 = @ptrCast(@alignCast(std.c.dlsym(lib, "eglBindAPI") orelse return error.NoEgl));
    const chooseConfig: *const fn (*anyopaque, [*]const i32, *?*anyopaque, i32, *i32) callconv(.c) u32 = @ptrCast(@alignCast(std.c.dlsym(lib, "eglChooseConfig") orelse return error.NoEgl));
    const createContext: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, [*]const i32) callconv(.c) ?*anyopaque = @ptrCast(@alignCast(std.c.dlsym(lib, "eglCreateContext") orelse return error.NoEgl));
    const makeCurrent: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u32 = @ptrCast(@alignCast(std.c.dlsym(lib, "eglMakeCurrent") orelse return error.NoEgl));
    const getProc: *const fn ([*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(@alignCast(std.c.dlsym(lib, "eglGetProcAddress") orelse return error.NoEgl));
    const display = getDisplay(0x31DD, null, null) orelse return error.NoDisplay;
    if (initialize(display, null, null) == 0) return error.NoInit;
    if (bindApi(0x30A2) == 0) return error.NoApi;
    const config_attribs = [_]i32{ 0x3033, 0x0001, 0x3040, 0x0008, 0x3038 };
    var config: ?*anyopaque = null;
    var n: i32 = 0;
    if (chooseConfig(display, &config_attribs, &config, 1, &n) == 0 or n == 0) return error.NoConfig;
    const gl_attribs = [_]i32{ 0x3098, 3, 0x30FB, 3, 0x30FD, 0x1, 0x3038 };
    const context = createContext(display, config, null, &gl_attribs) orelse return error.NoContext;
    if (makeCurrent(display, null, null, context) == 0) return error.NoCurrent;
    finish_fn = @ptrCast(@alignCast(getProc("glFinish") orelse return error.NoFinish));
}

var ready = false;

pub fn run(gpa: std.mem.Allocator, scene: scenes.Scene, frames: usize) !main.Result {
    if (!ready) {
        try egl();
        if (!ui.gl_loader.load()) return error.NoGl;
        ready = true;
    }
    var state: scenes.State = .{ .scene = scene };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, scenes.State.view), .{ .width = main.width, .height = main.height, .scale = main.scale });
    defer t.deinit();
    t.dt = 1.0 / 120.0;
    var r = try Renderer.init();
    defer r.deinit();

    const frame_ms = try gpa.alloc(f64, frames);
    defer gpa.free(frame_ms);
    const encode_ms = try gpa.alloc(f64, frames);
    defer gpa.free(encode_ms);
    var phases: [3][]f64 = undefined;
    for (&phases) |*ph| ph.* = try gpa.alloc(f64, frames);
    defer for (phases) |ph| gpa.free(ph);
    var cpu0: f64 = 0;
    for (0..main.warmup + frames) |i| {
        if (i == main.warmup) cpu0 = main.cpuSeconds();
        state.frame = i;
        state.time = @as(f32, @floatFromInt(i)) / 120;
        t.time = state.time;
        const t0 = ui.clock.now();
        t.frame();
        const ft = (ui.clock.now() - t0) * 1000;
        const t1 = ui.clock.now();
        r.sync(t.text.atlas.mask(), t.text.atlas.generation, t.text.images.pictures(), t.text.images.generation);
        r.draw(t.instances.items, t.size, t.scale, t.theme.background, 0, t.ctx.time);
        finish_fn.?();
        const enc = (ui.clock.now() - t1) * 1000;
        if (i >= main.warmup) {
            frame_ms[i - main.warmup] = ft;
            encode_ms[i - main.warmup] = enc;
            phases[0][i - main.warmup] = t.ctx.stats.build_ms;
            phases[1][i - main.warmup] = t.ctx.stats.layout_ms;
            phases[2][i - main.warmup] = t.ctx.stats.paint_ms;
        }
        if (i == main.warmup + frames - 1) {
            if (std.c.getenv("HC_SHOT")) |dir| {
                const px = try r.read(gpa);
                defer px.deinit(gpa);
                var name_buf: [512]u8 = undefined;
                const name0 = try std.fmt.bufPrint(&name_buf, "{s}/nanoui-{s}.bgra\x00", .{ std.mem.span(dir), @tagName(scene) });
                const name: [*:0]const u8 = @ptrCast(name0.ptr);
                const f = std.c.fopen(name, "wb") orelse return error.Open;
                _ = std.c.fwrite(px.bytes.ptr, 1, px.bytes.len, f);
                _ = std.c.fclose(f);
                std.debug.print("shot {s}: {d}x{d}\n", .{ name, px.width, px.height });
            }
        }
    }
    const cpu = (main.cpuSeconds() - cpu0) * 1000 / @as(f64, @floatFromInt(frames));
    std.debug.print("RESULT {{\"scene\": \"{s}\", \"frame_med\": {d:.4}, \"frame_p95\": {d:.4}, \"gpu_med\": {d:.4}, \"gpu_p95\": {d:.4}, \"instances\": {d}}}\n", .{ @tagName(scene), main.medianOf(frame_ms), main.p95Of(frame_ms), main.medianOf(encode_ms), main.p95Of(encode_ms), t.instances.items.len });
    return .{
        .fw = "nanoui",
        .scene = @tagName(scene),
        .frames = frames,
        .frame_ms = main.medianOf(frame_ms),
        .frame_p95 = main.p95Of(frame_ms),
        .frame_p99 = main.p99Of(frame_ms),
        .encode_ms = main.medianOf(encode_ms),
        .gpu_ms = 0,
        .cpu_ms = cpu,
        .ops = t.instances.items.len,
        .build_ms = main.medianOf(phases[0]),
        .layout_ms = main.medianOf(phases[1]),
        .paint_ms = main.medianOf(phases[2]),
        .renderer = renderer,
    };
}
