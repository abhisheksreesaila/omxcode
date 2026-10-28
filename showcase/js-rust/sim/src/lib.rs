//! The particle field of showcase/SPEC.md: seed, attractor and the CPU step.
//! Positions and velocities are interleaved `[x0, y0, x1, y1, ...]` (the layout of positions.bin).

pub const DT: f32 = 1.0 / 60.0;

/// Initial positions from xorshift32 (seed 42), one call per number; velocities are zero.
pub fn initial_positions(n: usize) -> Vec<f32> {
    let mut s: u32 = 42;
    let mut out = Vec::with_capacity(2 * n);
    for _ in 0..2 * n {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        let u = (s >> 8) as f32 * (1.0 / 16777216.0);
        out.push(u * 2.0 - 1.0);
    }
    out
}

/// The scripted attractor c(t) = 0.5 (cos t, sin t), t = frame * dt (computed in f64, then rounded to f32).
pub fn attractor(frame: u32) -> (f32, f32) {
    let t = frame as f64 * DT as f64;
    ((0.5 * t.cos()) as f32, (0.5 * t.sin()) as f32)
}

/// One step over a slice of particles (scalar; the compiler vectorises it on native).
#[inline]
pub fn step_scalar(p: &mut [f32], v: &mut [f32], cx: f32, cy: f32) {
    for (p, v) in p.chunks_exact_mut(2).zip(v.chunks_exact_mut(2)) {
        let dx = cx - p[0];
        let dy = cy - p[1];
        let r2 = dx * dx + dy * dy + 0.01;
        let k = 0.5 / r2;
        let vx = v[0] * 0.985 + (dx * k) * DT;
        let vy = v[1] * 0.985 + (dy * k) * DT;
        v[0] = vx;
        v[1] = vy;
        p[0] += vx * DT;
        p[1] += vy * DT;
    }
}

/// One step with explicit wasm SIMD128: each v128 holds two particles (x0, y0, x1, y1).
#[cfg(all(target_arch = "wasm32", target_feature = "simd128"))]
#[inline]
pub fn step(p: &mut [f32], v: &mut [f32], cx: f32, cy: f32) {
    use core::arch::wasm32::*;
    let n4 = p.len() / 4 * 4;
    let c = f32x4(cx, cy, cx, cy);
    let eps = f32x4_splat(0.01);
    let half = f32x4_splat(0.5);
    let damp = f32x4_splat(0.985);
    let dt = f32x4_splat(DT);
    let pp = p.as_mut_ptr();
    let vp = v.as_mut_ptr();
    let mut i = 0;
    while i < n4 {
        unsafe {
            let pi = v128_load(pp.add(i) as *const v128);
            let vi = v128_load(vp.add(i) as *const v128);
            let d = f32x4_sub(c, pi);
            let sq = f32x4_mul(d, d);
            let sw = i32x4_shuffle::<1, 0, 3, 2>(sq, sq); // (dy², dx², ...)
            let r2 = f32x4_add(f32x4_add(sq, sw), eps);
            let a = f32x4_mul(d, f32x4_div(half, r2));
            let vn = f32x4_add(f32x4_mul(vi, damp), f32x4_mul(a, dt));
            v128_store(vp.add(i) as *mut v128, vn);
            v128_store(pp.add(i) as *mut v128, f32x4_add(pi, f32x4_mul(vn, dt)));
        }
        i += 4;
    }
    step_scalar(&mut p[n4..], &mut v[n4..], cx, cy);
}

#[cfg(not(all(target_arch = "wasm32", target_feature = "simd128")))]
#[inline]
pub fn step(p: &mut [f32], v: &mut [f32], cx: f32, cy: f32) {
    step_scalar(p, v, cx, cy);
}

/// Packs particles for drawing: one u32 each, `px | py << 11 | speed << 21` (pixel column 0..1280, row 0..720,
/// speed |v| / 1.5 as 0..255), or `OFFSCREEN` outside the view. A quarter of the bytes of positions + velocities,
/// which is what crosses into the GPU every frame.
pub const OFFSCREEN: u32 = 0x8000_0000;

#[inline]
pub fn pack(p: &[f32], v: &[f32], out: &mut [u32]) {
    for ((p, v), o) in p.chunks_exact(2).zip(v.chunks_exact(2)).zip(out.iter_mut()) {
        let fx = (p[0] + 1.6) * (1280.0 / 3.2);
        let fy = (0.9 - p[1]) * (720.0 / 1.8);
        *o = if fx >= 0.0 && fx < 1280.0 && fy >= 0.0 && fy < 720.0 {
            let s = ((v[0] * v[0] + v[1] * v[1]).sqrt() * (255.0 / 1.5)).min(255.0) as u32;
            fx as u32 | (fy as u32) << 11 | s << 21
        } else {
            OFFSCREEN
        };
    }
}
