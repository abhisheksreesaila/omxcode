// Draw, compute-rasteriser variant (?render=atomic): every on-screen particle adds itself to its pixel with
// two atomics (a count and a fixed-point speed sum). Because the colour is a linear blend of two colours,
// the sum of colours is count * SLOW + sum(k) * (FAST - SLOW): two integers per pixel hold the exact additive image.
@group(0) @binding(0) var<storage, read> S: array<vec4f>;
@group(0) @binding(1) var<storage, read_write> A: array<atomic<u32>>;   // [W*H counts][W*H speed sums]
@group(0) @binding(2) var<uniform> P: Params;

struct Params { c: vec2f, dt: f32, n: u32, rowStride: u32, saturated: u32 }

override WG: u32 = 256;
const W = 1280u;
const H = 720u;
const KSCALE = 64.0;   // 20M * 64 fits in u32

@compute @workgroup_size(WG)
fn main(@builtin(global_invocation_id) g: vec3u) {
  let i = g.x + g.y * P.rowStride;
  if (i >= P.n) { return; }
  let s = S[i];
  let fx = (s.x * (1.0 / 1.6) + 1.0) * (0.5 * f32(W));
  let fy = (1.0 - s.y * (1.0 / 0.9)) * (0.5 * f32(H));
  if (fx < 0.0 || fy < 0.0 || fx >= f32(W) || fy >= f32(H)) { return; }
  let pix = u32(fy) * W + u32(fx);
  let k = min(length(s.zw) * (1.0 / 1.5), 1.0);
  // Once a pixel's count passes P.saturated it is white after the tone map in every channel (1 - exp(-8) or
  // more), so nothing more changes it: look first (counts only grow within a frame) and skip both atomics there,
  // as C's PointCloud.splat does; past the load, skip the speed sum once this add crosses the line.
  if (atomicLoad(&A[pix]) >= P.saturated) { return; }
  if (atomicAdd(&A[pix], 1u) >= P.saturated) { return; }
  atomicAdd(&A[W * H + pix], u32(k * KSCALE + 0.5));
}
