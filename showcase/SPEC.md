# The particle field: one spec, three builds

Every build implements exactly this, so the numbers compare. Float32 everywhere.

## State
- `N` particles (default 1,000,000; the app's slider: 1M, 2M, 5M, 10M, 20M).
- Each has position `p = (x, y)` and velocity `v = (vx, vy)`, float32.
- Initial state from xorshift32, seed 42 (`s ^= s << 13; s ^= s >> 17; s ^= s << 5`, unsigned 32-bit), one call per number:
  for i in 0..N: `x = u() * 2 - 1`, `y = u() * 2 - 1` where `u() = (next() >> 8) * (1 / 16777216)`; `v = (0, 0)`.

## Step (dt = 1/60, one per frame)
- The attractor `c`: the cursor; in scripted runs `c(t) = (0.5 * cos(t), 0.5 * sin(t))` with `t = frame * dt`.
- For each particle: `d = c - p`; `r2 = d.x*d.x + d.y*d.y + 0.01`; `a = d * (0.5 / r2)`;
  `v = v * 0.985 + a * dt`; `p = p + v * dt`.

## Draw
- Window/canvas 1280 × 720, black background; world [-1.6, 1.6] × [-0.9, 0.9] maps to it.
- Each particle one pixel, additive blending, colour by speed `|v|`: from deep indigo (#3b2bd6, slow) to white (fast,
  |v| ≥ 1.5), linear.
- An on-screen readout: N, fps, step ms.

## Scripted mode (for measurement)
`--scripted --n <N> --frames <F>`: no input, the attractor follows `c(t)`, run F frames, then write
`positions.bin` (N × 2 float32, little-endian, after F steps) and `timings.json` (per-frame ms: total, step) and exit.

## Correctness
After 120 steps from the seed, each build's positions match a NumPy float32 reference (showcase/reference.py) within
1e-3 absolute for at least 99.9 % of particles (GPU math may differ in the last bits).
