#!/usr/bin/env bash
# Build bridge/llm_shim.cpp into build/llm/libmojoui_llm.so (goal 72 M1: mojoui.llm runs libllama in the app's process).
#   scripts/build_llm_shim.sh
# Needs a built llama.cpp (CUDA for a GPU): $MOJOUI_LLAMA_SRC (headers; default ~/Projects/omx-local/third_party/llama.cpp)
# and $MOJOUI_LLAMA_DIR (its libllama.so, libllama-common.so, libggml*.so; default $MOJOUI_LLAMA_SRC/build/bin).
# The shim's rpath is that folder, so it runs from here without LD_LIBRARY_PATH; a release ships those libraries beside
# libmojoui_llm.so and builds the shim with MOJOUI_LLAMA_DIR pointing there (rpath $ORIGIN is added too).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${MOJOUI_LLAMA_SRC:-$HOME/Projects/omx-local/third_party/llama.cpp}"
LIB="${MOJOUI_LLAMA_DIR:-$SRC/build/bin}"
test -f "$SRC/include/llama.h" || { echo "no llama.cpp headers at $SRC (set MOJOUI_LLAMA_SRC)" >&2; exit 2; }
test -f "$LIB/libllama.so" || { echo "no libllama.so in $LIB (set MOJOUI_LLAMA_DIR)" >&2; exit 2; }
mkdir -p build/llm
g++ -std=c++17 -O2 -fPIC -shared -Wall -Wno-deprecated-declarations \
  -DGGML_BACKEND_SHARED -DGGML_SHARED -DLLAMA_SHARED \
  -I"$SRC/common" -I"$SRC/vendor/nlohmann/.." -I"$SRC/vendor/sheredom/.." -I"$SRC/include" -I"$SRC/ggml/include" \
  bridge/llm_shim.cpp -o build/llm/libmojoui_llm.so \
  -L"$LIB" -lllama-common -lllama -lggml -lggml-base \
  -Wl,-rpath,"$LIB" -Wl,-rpath,'$ORIGIN' -Wl,--disable-new-dtags
echo "built build/llm/libmojoui_llm.so (llama libraries from $LIB)"
