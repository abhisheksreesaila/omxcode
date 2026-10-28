// One simulation step (showcase/SPEC.md "Step"). State is one vec4f per particle: xy = position, zw = velocity,
// so each thread does one coalesced 16-byte load and one 16-byte store.
struct Params {
  c: vec2f,        // attractor, world units
  dt: f32,
  n: u32,          // particle count
  rowStride: u32,  // threads per dispatch row (2D dispatch: more than 65535 workgroups)
}

override WG: u32 = 256;

@group(0) @binding(0) var<uniform> P: Params;
@group(0) @binding(1) var<storage, read_write> S: array<vec4f>;

@compute @workgroup_size(WG)
fn main(@builtin(global_invocation_id) g: vec3u) {
  let i = g.x + g.y * P.rowStride;
  if (i >= P.n) { return; }
  let s = S[i];
  let d = P.c - s.xy;
  let r2 = d.x * d.x + d.y * d.y + 0.01;
  let a = d * (0.5 / r2);
  let v = s.zw * 0.985 + a * P.dt;
  let p = s.xy + v * P.dt;
  S[i] = vec4f(p, v);
}
