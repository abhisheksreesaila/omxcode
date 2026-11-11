#!/usr/bin/env bash
# The image for a mojoui.serve SaaS server (goal 66 M8; examples/finance_min by default): one process, host.db and the
# tenants' files on a volume (/data), a health check, nothing from pixi at run time.
#   scripts/saas_image.sh bundle   # build/saas_image/rootfs/app: the server, its libraries (RUNPATH $ORIGIN/lib), static, migrations
#   scripts/saas_image.sh build    # bundle, then `docker build` → omxcode-saas:g66 (needs a docker the user can reach)
#   docker run -v $PWD/data:/data -p 8000:8000 -e SAAS_BASE=… -e SAAS_SECRET=… -e GOOGLE_CLIENT_ID=… omxcode-saas:g66
# Nothing here deploys or pushes.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${SAAS_IMAGE_APP:-examples/finance_min}
TAG=${SAAS_IMAGE_TAG:-omxcode-saas:g66}
OUT=build/saas_image
cmd=${1:-build}

bundle() {
  scripts/mojo_flare.sh build "$APP/server.mojo" -o build/saas_image_server >/dev/null
  rm -rf "$OUT/rootfs"
  mkdir -p "$OUT/rootfs/app/lib" "$OUT/rootfs/app/$APP"
  cp build/saas_image_server "$OUT/rootfs/app/server"
  cp build/flare/lib/*.so "$OUT/rootfs/app/lib/"
  # every library the server and Flare's shims load from pixi or build/ (the system's libc, libm, libsqlite3 come from the image)
  for f in "$OUT/rootfs/app/server" "$OUT"/rootfs/app/lib/*.so; do
    ldd "$f" | awk '/=> \// {print $3}' | grep -E '/\.pixi/|/build/' || true
  done | sort -u | while read -r lib; do cp -L "$lib" "$OUT/rootfs/app/lib/"; done
  # their own dependencies, once more (libssl → libcrypto and the like)
  for f in "$OUT"/rootfs/app/lib/*.so*; do
    ldd "$f" 2>/dev/null | awk '/=> \// {print $3}' | grep -E '/\.pixi/|/build/' || true
  done | sort -u | while read -r lib; do cp -nL "$lib" "$OUT/rootfs/app/lib/" || true; done
  patchelf --set-rpath '$ORIGIN/lib' "$OUT/rootfs/app/server"
  # only libraries whose search path points into pixi or build/ (Flare's shims, conda's): patchelf on Mojo's own runtime
  # libraries (RPATH $ORIGIN already) leaves a server that hangs at start (goal 66 M8, D-6628)
  for f in "$OUT"/rootfs/app/lib/*.so*; do
    if readelf -d "$f" 2>/dev/null | grep -E 'R(UN)?PATH' | grep -qE '/\.pixi/|/build/'; then patchelf --set-rpath '$ORIGIN' "$f"; fi
  done
  cp -r "$APP/static" "$APP/migrations" "$OUT/rootfs/app/$APP/"
  cp Dockerfile "$OUT/Dockerfile"
  echo "bundle: $OUT/rootfs/app ($(du -sh "$OUT/rootfs/app" | cut -f1))"
}

case "$cmd" in
  bundle) bundle ;;
  build) bundle; docker build -t "$TAG" --build-arg APP="$APP" "$OUT" ;;
  *) echo "usage: $0 bundle|build" >&2; exit 2 ;;
esac
