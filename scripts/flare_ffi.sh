#!/usr/bin/env bash
# Builds Flare's C shims (vendor/flare/{tls,http}/ffi, the same compile lines as Flare's own build.sh files) into
# build/flare/lib against the pixi env's OpenSSL, zlib and brotli, and installs them in $CONDA_PREFIX/lib, where Flare
# looks (flare/utils/dylib.mojo: $FLARE_LIB_DIR, then $CONDA_PREFIX/lib, then the library path). The rustls/QUIC shim
# isn't built (no HTTP/3 here). Idempotent: rebuilds when a source is newer.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${CONDA_PREFIX:-}" ]; then exec pixi run bash "$0" "$@"; fi
OUT=build/flare/lib
mkdir -p "$OUT"
P="$CONDA_PREFIX"
# (.so on the Mac too: Flare dlopens "libflare_<name>.so" everywhere, flare/utils/dylib.mojo; dlopen ignores the extension, goal 55)
if [[ "$(uname)" == "Darwin" ]]; then CC=clang CXX=clang++ EXT=so NODELETE=""; else CC=gcc CXX=g++ EXT=so NODELETE="-Wl,-z,nodelete"; fi
one() {  # name source compiler flags...
    local name=$1 src=$2 cc=$3; shift 3
    local lib="$OUT/libflare_$name.$EXT"
    if [ ! -f "$lib" ] || [ "$src" -nt "$lib" ] || [ "$0" -nt "$lib" ]; then
        $cc -O2 -fPIC -shared -o "$lib" "$src" "$@" $NODELETE
        echo "built $lib"
    fi
    cp -f "$lib" "$P/lib/"
}
one tls vendor/flare/tls/ffi/openssl_wrapper.cpp "$CXX" -std=c++17 -DNDEBUG -I"$P/include" -L"$P/lib" -lssl -lcrypto -ldl -Wl,-rpath,"$P/lib"
one zlib vendor/flare/http/ffi/zlib_wrapper.c "$CC" -I"$P/include" -L"$P/lib" -lz -ldeflate -pthread -Wl,-rpath,"$P/lib"  # (0.13: gzip encodes through libdeflate)
one brotli vendor/flare/http/ffi/brotli_wrapper.c "$CC" -L"$P/lib" -lbrotlienc -lbrotlidec -lbrotlicommon -Wl,-rpath,"$P/lib"
one fs vendor/flare/http/ffi/fs_wrapper.c "$CC"
# each shim must load with every symbol bound: Flare only says "cannot load" and then, for zlib, leaves gzip bodies
# compressed without a word (0.13's zlib shim needed libdeflate, goal 52)
for lib in "$OUT"/libflare_*."$EXT"; do
    python3 -c "import ctypes, os, sys; ctypes.CDLL(sys.argv[1], mode=os.RTLD_NOW)" "$lib" || { echo "flare shim doesn't load: $lib" >&2; exit 1; }
done
echo "flare shims: ok ($OUT)"
