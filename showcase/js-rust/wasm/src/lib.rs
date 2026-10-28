//! The particle step for the browser: state lives in wasm memory, JS reads it through views.
use rayon::prelude::*;
use wasm_bindgen::prelude::*;

pub use wasm_bindgen_rayon::init_thread_pool;

/// Particles per rayon task (a multiple of 2 so a chunk keeps whole SIMD pairs).
const CHUNK: usize = 1 << 15;

#[wasm_bindgen]
pub struct Field {
    pos: Vec<f32>,
    vel: Vec<f32>,
    packed: Vec<u32>, // what the draw uploads: see sim::pack
}

#[wasm_bindgen]
impl Field {
    #[wasm_bindgen(constructor)]
    pub fn new(n: usize) -> Field {
        let pos = sim::initial_positions(n);
        let vel = vec![0.0; 2 * n];
        let mut packed = vec![0; n];
        sim::pack(&pos, &vel, &mut packed);
        Field { pos, vel, packed }
    }

    pub fn len(&self) -> usize {
        self.pos.len() / 2
    }

    /// One step towards the attractor (cx, cy), split across the thread pool; each chunk is packed for
    /// drawing while it is still in cache.
    pub fn step(&mut self, cx: f32, cy: f32) {
        self.pos
            .par_chunks_mut(2 * CHUNK)
            .zip(self.vel.par_chunks_mut(2 * CHUNK))
            .zip(self.packed.par_chunks_mut(CHUNK))
            .for_each(|((p, v), o)| {
                sim::step(p, v, cx, cy);
                sim::pack(p, v, o);
            });
    }

    /// Byte offsets into wasm memory; JS builds Float32Array views over them.
    pub fn pos_ptr(&self) -> *const f32 {
        self.pos.as_ptr()
    }
    pub fn packed_ptr(&self) -> *const u32 {
        self.packed.as_ptr()
    }
}

/// The scripted attractor for a frame (the same f64 maths the reference uses).
#[wasm_bindgen]
pub fn attractor(frame: u32) -> Vec<f32> {
    let (x, y) = sim::attractor(frame);
    vec![x, y]
}
