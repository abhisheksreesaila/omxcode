// Tone map: the float16 accumulation target -> the canvas (fullscreen triangle).
// Per-channel exponential: one particle reads as a faint dot, a crowd saturates towards white.
override EXPOSURE: f32 = 1.0;

@group(0) @binding(0) var acc: texture_2d<f32>;

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  let x = f32((i << 1u) & 2u);
  let y = f32(i & 2u);
  return vec4f(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) p: vec4f) -> @location(0) vec4f {
  let x = textureLoad(acc, vec2i(p.xy), 0).rgb;
  return vec4f(vec3f(1.0) - exp(-x * EXPOSURE), 1.0);
}
