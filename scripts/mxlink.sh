# Sourced by scripts/build.sh and scripts/mxbuild.sh: LINK = what a program using the omxcore package links (its
# Parquet codecs). Only the two libraries, through a folder of their own: an rpath at the whole pixi env would also
# put its libcurl ahead of the system one for the GTK libraries (libappstream then fails to link).
LIB="$PWD/.pixi/envs/default/lib"
CODECS="$PWD/build/codecs"
mkdir -p "$CODECS"
for l in libzstd.so.1 libsnappy.so.1; do ln -sf "$(readlink -f "$LIB/$l")" "$CODECS/$l"; done
LINK=(-Xlinker "$CODECS/libzstd.so.1" -Xlinker "$CODECS/libsnappy.so.1" -Xlinker "-rpath=$CODECS")
