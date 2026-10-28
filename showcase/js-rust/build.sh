#!/usr/bin/env bash
# Builds both rows: the wasm step (threads + SIMD128) into build/web and the native wgpu binary.
# Run through pixi: `pixi run bash showcase/js-rust/build.sh` (Rust 1.99 stable from conda-forge; the
# threaded wasm std needs build-std, so RUSTC_BOOTSTRAP=1 unlocks -Z on this stable compiler, as nightly would).
set -euo pipefail
cd "$(dirname "$0")"
OUT=build/web
mkdir -p "$OUT"
RUSTC_BOOTSTRAP=1 \
CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_RUSTFLAGS='-C target-feature=+atomics,+bulk-memory,+mutable-globals,+simd128 -C link-arg=--shared-memory -C link-arg=--import-memory -C link-arg=--max-memory=4294967296 -C link-arg=--export=__wasm_init_tls -C link-arg=--export=__tls_size -C link-arg=--export=__tls_align -C link-arg=--export=__tls_base' \
  cargo build --release --target wasm32-unknown-unknown -p particles-wasm -Z build-std=panic_abort,std
wasm-bindgen --target web --out-dir "$OUT/pkg" target/wasm32-unknown-unknown/release/particles_wasm.wasm
# wasm-bindgen-rayon's worker imports the package directory ('../../..'), which only a bundler resolves;
# without one, point it at the generated module itself.
sed -i "s|import('../../..')|import('../../../particles_wasm.js')|" "$OUT"/pkg/snippets/wasm-bindgen-rayon-*/src/workerHelpers.js
wasm-opt -O3 --enable-threads --enable-bulk-memory --enable-simd --enable-mutable-globals --enable-nontrapping-float-to-int --enable-sign-ext \
  "$OUT/pkg/particles_wasm_bg.wasm" -o "$OUT/pkg/particles_wasm_bg.wasm"
cp web/index.html web/main.js web/worker.js "$OUT/"
cargo build --release -p particles-native
echo "built: $OUT and target/release/particles-native"
