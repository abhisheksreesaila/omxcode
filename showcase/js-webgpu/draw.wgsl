// Draw (showcase/SPEC.md "Draw"): every particle one pixel, additive, coloured by speed from indigo to white.
// Points are added into a float16 accumulation target; tone.wgsl maps it onto the canvas, so dense
// regions glow towards white instead of clipping flat.

@group(0) @binding(0) var<storage, read> S: array<vec4f>;
@group(0) @binding(1) var<uniform> D: DrawParams;

struct DrawParams {
  gain: f32,       // light per particle (scaled with N so 1M and 20M look alike)
  _pad: vec3f,
}

struct VOut {
  @builtin(position) pos: vec4f,
  @location(0) col: vec3f,
}

const SLOW = vec3f(0.2314, 0.1686, 0.8392);   // #3b2bd6
const FAST = vec3f(1.0, 1.0, 1.0);

@vertex
fn vs(@builtin(vertex_index) i: u32) -> VOut {
  let s = S[i];
  var o: VOut;
  // world [-1.6, 1.6] x [-0.9, 0.9] -> clip [-1, 1]^2
  o.pos = vec4f(s.x * (1.0 / 1.6), s.y * (1.0 / 0.9), 0.0, 1.0);
  let k = min(length(s.zw) * (1.0 / 1.5), 1.0);
  o.col = mix(SLOW, FAST, k) * D.gain;
  return o;
}

@fragment
fn fs(v: VOut) -> @location(0) vec4f {
  return vec4f(v.col, 1.0);
}
