# Sourced by scripts/build.sh and scripts/mxbuild.sh: LINK = what a program using the omxcore package links (its
# Parquet codecs). Only the two libraries, through a folder of their own: an rpath at the whole pixi env would also
# put its libcurl ahead of the system one for the GTK libraries (libappstream then fails to link).
if [ "$(uname)" = Darwin ]; then LINK=(); return 0 2>/dev/null || true; fi  # (the Mac: programs here don't load the codecs, D-5723)
LIB="$PWD/.pixi/envs/default/lib"
if [ "$(uname)" = Darwin ]; then  # (a native Mac build, goal 55: the env's dylibs, by name; build.sh's bundle_runtime copies them in)
  LINK=(-Xlinker -L"$LIB" -Xlinker -lzstd -Xlinker -lsnappy -Xlinker -rpath -Xlinker "$LIB")
  return 0 2>/dev/null || true
fi
CODECS="$PWD/build/codecs"
mkdir -p "$CODECS"
for l in libzstd.so.1 libsnappy.so.1; do ln -sf "$(readlink -f "$LIB/$l")" "$CODECS/$l"; done
LINK=(-Xlinker "$CODECS/libzstd.so.1" -Xlinker "$CODECS/libsnappy.so.1" -Xlinker "-rpath=$CODECS")
