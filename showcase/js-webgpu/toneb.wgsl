// Tone map for the compute-rasteriser variant: the two per-pixel sums -> additive colour -> the canvas.
override EXPOSURE: f32 = 1.0;
const W = 1280u;
const H = 720u;
const SLOW = vec3f(0.2314, 0.1686, 0.8392);   // #3b2bd6
const FAST = vec3f(1.0, 1.0, 1.0);

@group(0) @binding(0) var<storage, read> A: array<u32>;
@group(0) @binding(1) var<uniform> D: vec4f;   // x = light per particle

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  let x = f32((i << 1u) & 2u);
  let y = f32(i & 2u);
  return vec4f(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) p: vec4f) -> @location(0) vec4f {
  let pix = u32(p.y) * W + u32(p.x);
  let n = f32(A[pix]);
  let k = f32(A[W * H + pix]) * (1.0 / 64.0);
  let x = (SLOW * n + (FAST - SLOW) * k) * D.x;
  return vec4f(vec3f(1.0) - exp(-x * EXPOSURE), 1.0);
}
