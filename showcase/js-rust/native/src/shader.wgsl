// The particle field (showcase/SPEC.md): compute step, additive point draw, a tiny text readout.

struct Params {
    c: vec2<f32>,
    dt: f32,
    n: u32,
    groups_x: u32,   // workgroups per row of a 2D dispatch (20M particles exceed 65535 groups in one dimension)
    _pad0: u32,
    _pad1: u32,
    _pad2: u32,
};

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read_write> pos: array<vec2<f32>>;
@group(0) @binding(2) var<storage, read_write> vel: array<vec2<f32>>;

const WG: u32 = 256u;

@compute @workgroup_size(256)
fn step(@builtin(workgroup_id) wg: vec3<u32>, @builtin(local_invocation_index) li: u32) {
    let i = (wg.y * params.groups_x + wg.x) * WG + li;
    if (i >= params.n) { return; }
    let p = pos[i];
    let d = params.c - p;
    let r2 = d.x * d.x + d.y * d.y + 0.01;
    let a = d * (0.5 / r2);
    let v = vel[i] * 0.985 + a * params.dt;
    vel[i] = v;
    pos[i] = p + v * params.dt;
}

// ---- draw: one pixel per particle, colour by speed, additive ----
struct VOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) colour: vec3<f32>,
};

const SLOW: vec3<f32> = vec3<f32>(0.231, 0.169, 0.839); // #3b2bd6
const INTENSITY: f32 = 0.35;                             // per-particle weight before additive blending

@vertex
fn vs_point(@location(0) p: vec2<f32>, @location(1) v: vec2<f32>) -> VOut {
    var o: VOut;
    o.clip = vec4<f32>(p.x / 1.6, p.y / 0.9, 0.0, 1.0);
    let t = clamp(length(v) / 1.5, 0.0, 1.0);
    o.colour = mix(SLOW, vec3<f32>(1.0), t) * INTENSITY;
    return o;
}

@fragment
fn fs_point(i: VOut) -> @location(0) vec4<f32> {
    return vec4<f32>(i.colour, 1.0);
}

// ---- readout: a 3x5 bitmap font, text in a uniform ----
struct Text {
    chars: array<vec4<u32>, 12>, // 48 glyph indices
    len: u32,
};
@group(0) @binding(0) var<uniform> text: Text;

// glyphs "0123456789. NFPSTEMWGUCA"; 15 bits, rows top to bottom, 3 bits each (generated, see main.rs GLYPHS)
const FONT = array<u32, 24>(
    0x7B6Fu, 0x2C97u, 0x73E7u, 0x73CFu, 0x5BC9u, 0x79CFu, 0x79EFu, 0x7249u, 0x7BEFu, 0x7BCFu,
    0x0002u, 0x0000u, 0x6B6Du, 0x79A4u, 0x7BE4u, 0x79CFu, 0x7492u, 0x79A7u, 0x5FEDu, 0x5BFDu,
    0x796Fu, 0x5B6Fu, 0x7927u, 0x7BEDu,
);
const SCALE: f32 = 3.0;
const ORIGIN: vec2<f32> = vec2<f32>(12.0, 12.0);

@vertex
fn vs_text(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    let xy = vec2<f32>(f32((vi << 1u) & 2u), f32(vi & 2u)) * 2.0 - 1.0; // full-screen triangle
    return vec4<f32>(xy, 0.0, 1.0);
}

@fragment
fn fs_text(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let q = (frag.xy - ORIGIN) / SCALE;
    if (q.x < 0.0 || q.y < 0.0 || q.y >= 5.0) { discard; }
    let cell = u32(q.x) / 4u;
    if (cell >= text.len) { discard; }
    let col = u32(q.x) % 4u;
    if (col == 3u) { discard; }
    let g = text.chars[cell / 4u][cell % 4u];
    let row = u32(q.y);
    let bit = 14u - (row * 3u + col);
    if (((FONT[g] >> bit) & 1u) == 0u) { discard; }
    return vec4<f32>(0.9, 0.9, 0.95, 1.0);
}
