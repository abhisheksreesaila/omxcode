#!/usr/bin/env bash
# Build A: install the locked npm packages, bundle app.js with esbuild, copy DuckDB-WASM's workers and wasm to dist/.
set -euo pipefail
cd "$(dirname "$0")"
[ -d node_modules/@duckdb/duckdb-wasm ] || pixi run npm ci --ignore-scripts --no-audit --no-fund
mkdir -p dist
pixi run esbuild app.js --bundle --format=esm --minify --sourcemap --target=chrome120 --outfile=dist/app.js --log-level=warning
D=node_modules/@duckdb/duckdb-wasm/dist
for f in "$D"/duckdb-*.wasm "$D"/duckdb-browser-*worker.js; do
  cmp -s "$f" "dist/$(basename "$f")" || cp "$f" dist/
done
cmp -s node_modules/parquet-wasm/esm/parquet_wasm_bg.wasm dist/parquet_wasm_bg.wasm || cp node_modules/parquet-wasm/esm/parquet_wasm_bg.wasm dist/
# DuckDB-WASM autoloads its Parquet reader as an extension from extensions.duckdb.org; serve a pinned copy instead, so a
# run never depends on the network (app.js points custom_extension_repository at dist/ext).
EXT=dist/ext/v1.5.4/wasm_eh/parquet.duckdb_extension.wasm
SHA=4845705bbd69fc9ad52878d96a505c73cae4a6c509822079cc2413e5eb437f95
if ! echo "$SHA  $EXT" | sha256sum -c --status 2>/dev/null; then
  mkdir -p "$(dirname "$EXT")"
  curl -fsSL -o "$EXT.tmp" https://extensions.duckdb.org/v1.5.4/wasm_eh/parquet.duckdb_extension.wasm
  echo "$SHA  $EXT.tmp" | sha256sum -c --status || { echo "parquet extension: unexpected sha256" >&2; exit 1; }
  mv "$EXT.tmp" "$EXT"
fi
