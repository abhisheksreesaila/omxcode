#!/usr/bin/env bash
# Build a mojoui example for Linux, Mac and/or iPhone from ONE app file.
#   scripts/build.sh <example> linux|mac|ios|all      e.g. scripts/build.sh hello all
# Input:  examples/<example>/app.mojo (defines Main)
# Output: build/<example>/linux/<example>            native GTK app (runs here)
#         build/<example>/mac/<Name>Mojo.app (+ .zip)  native AppKit app (Apple Silicon)
#         build/<example>/ios/<Name>Mojo.ipa           native UIKit app (install with apple/install_iphone.sh)
#         build/<example>/web/mojoui_app.so            the app as a Python module, served by mojoui/hosts/web.py
# Env: BUNDLE_PREFIX (default com.mojoui) → bundle ID <prefix>.<example>
set -euo pipefail
cd "$(dirname "$0")/.."
EX="${1:?usage: scripts/build.sh <example> linux|web|mac|ios|android|all}"
WHAT="${2:-all}"
SRC="examples/$EX/app.mojo"
test -f "$SRC" || { echo "no $SRC" >&2; exit 2; }
NAME="$(tr '[:lower:]' '[:upper:]' <<< "${EX:0:1}")${EX:1}Mojo"   # hello → HelloMojo
BUNDLE_ID="${BUNDLE_PREFIX:-com.mojoui}.$EX"
MOJO=(pixi run mojo build -I "examples/$EX" -I . -I vendor)
# An example that uses the MX frame package (vendor/mxframe.mojoc, vendor/MXFRAME_COMMIT) links its Parquet codecs.
LINK=()
if grep -qx mxframe "examples/$EX/needs" 2>/dev/null && [ "$(uname)" != Darwin ]; then source scripts/mxlink.sh; fi  # (Linux's codecs)

mojo_build() {  # mojo_build <args...>: fails if Mojo fails, hides the telemetry warning
  local log; log=$(mktemp)
  if ! "${MOJO[@]}" "$@" >"$log" 2>&1; then grep -v telemetry "$log" >&2; rm -f "$log"; return 1; fi
  grep -v telemetry "$log" || true; rm -f "$log"
}

stamp() { sha256sum "$SRC" | cut -d' ' -f1 > "$1/app.sha256"; }  # which app file this build used

sign() {  # ad-hoc signature: codesign on a Mac, rcodesign on Linux
  if command -v codesign >/dev/null; then codesign --force --sign - "$1"; else rcodesign sign "$1" >/dev/null 2>&1; fi
}

plist() {  # plist <template> <out>
  sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/HelloMojo/$NAME/g" "$1" > "$2"
}

build_linux() {
  local out="build/$EX/linux"; mkdir -p "$out"; rm -f "$out/$EX"
  echo "== Linux ($EX): GTK4 + libadwaita"
  mojo_build hosts/linux_main.mojo -o "$out/$EX" \
    -Xlinker -lgtk-4 -Xlinker -ladwaita-1 -Xlinker -lgobject-2.0 -Xlinker -lglib-2.0 -Xlinker -lgio-2.0 -Xlinker -lfontconfig -Xlinker -lpango-1.0 "${LINK[@]}"
  mkdir -p "$out/fonts"; cp mojoui/hosts/static/fonts/*.ttf "$out/fonts/"  # the app's own fonts, beside the binary (D-155)
  stamp "$out"; echo "   $out/$EX"
}

build_web() {
  local out="build/$EX/web"; mkdir -p "$out"; rm -f "$out/mojoui_app.so"
  echo "== Web ($EX): Mojo Python module for FastHTML"
  mojo_build hosts/web_main.mojo --emit shared-lib "${LINK[@]}" -o "$out/mojoui_app.so"
  stamp "$out"; echo "   $out/mojoui_app.so  (serve: pixi run python mojoui/hosts/web.py $out)"
}

build_android() {  # a signed APK: the app + mojoui as libmojoui.so (arm64 phones, x86_64 emulators) + one Java file
  local out="build/$EX/android"; mkdir -p "$out"; rm -rf "$out"/lib "$out"/*.o "$out"/*.apk "$out"/classes "$out"/dex
  local sdk="${ANDROID_HOME:-$HOME/Android/Sdk}"
  local bt; bt="$(ls -d "$sdk"/build-tools/* 2>/dev/null | sort -V | tail -n1)"
  local jar; jar="$(ls -d "$sdk"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -n1)"
  [[ -n "$bt" && -n "$jar" ]] || { echo "no Android SDK at $sdk (run scripts/android_setup.sh)" >&2; return 1; }
  echo "== Android ($EX): Android views via JNI, $(basename "$(dirname "$jar")")"
  for abi in arm64-v8a:aarch64 x86_64:x86_64; do
    local dir="${abi%%:*}" cpu="${abi##*:}"
    mkdir -p "$out/lib/$dir" "$out/stubs-$dir"
    mojo_build hosts/android_main.mojo -D MOJOUI_ANDROID --target-triple "$cpu-linux-android29" --emit object -o "$out/app-$dir.o"
    mojo_build mojoui/hosts/mojo_rt.mojo --target-triple "$cpu-linux-android29" --emit object -o "$out/rt-$dir.o"
    mojo_build mojoui/hosts/no_gpu_rt.mojo --target-triple "$cpu-linux-android29" --emit object -o "$out/nogpu-$dir.o"
    # Empty stand-ins carrying only the system libraries' names (like apple/sdk/*.tbd).
    echo "" | llvm-mc -triple="$cpu-linux-android" -filetype=obj -o "$out/stubs-$dir/empty.o"
    for lib in libc liblog libm libdl; do
      pixi run ld.lld -shared -soname "$lib.so" -o "$out/stubs-$dir/$lib.so" "$out/stubs-$dir/empty.o"
    done
    pixi run ld.lld -shared -soname libmojoui.so -z noexecstack --gc-sections -o "$out/lib/$dir/libmojoui.so" \
      "$out/app-$dir.o" "$out/rt-$dir.o" "$out/nogpu-$dir.o" "$out"/stubs-"$dir"/*.so
  done
  # The framework's one Java file → dex
  mkdir -p "$out/classes" "$out/dex"
  javac -nowarn --release 11 -cp "$jar" -d "$out/classes" mojoui/hosts/android/MojoActivity.java
  "$bt/d8" --release --min-api 29 --lib "$jar" --output "$out/dex" $(find "$out/classes" -name '*.class')
  # Manifest → base APK, then the dex and the libraries, aligned and signed
  local pkg="dev.mojoui.$EX"
  sed -e "s/__PACKAGE__/$pkg/" -e "s/__LABEL__/$NAME/" mojoui/hosts/android/AndroidManifest.xml > "$out/AndroidManifest.xml"
  "$bt/aapt2" link --manifest "$out/AndroidManifest.xml" -I "$jar" --min-sdk-version 29 --target-sdk-version 36 \
    --version-code 1 --version-name 0.1 -o "$out/base.apk"
  (cd "$out/dex" && zip -q ../base.apk classes.dex)
  (cd "$out" && zip -q -r base.apk lib)
  "$bt/zipalign" -f -p 4 "$out/base.apk" "$out/aligned.apk"
  local ks="build/android-debug.keystore"  # a local debug key (never committed: build/ is ignored)
  [[ -f "$ks" ]] || keytool -genkeypair -keystore "$ks" -storepass android -keypass android -alias debug \
    -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=mojo-ui debug" >/dev/null 2>&1
  "$bt/apksigner" sign --ks "$ks" --ks-pass pass:android --out "$out/$NAME.apk" "$out/aligned.apk"
  rm -f "$out/base.apk" "$out/aligned.apk"
  stamp "$out"; echo "   $out/$NAME.apk ($pkg)"
}

apple_objects() {  # apple_objects <dir> <triple> <host-main>
  rm -f "$1"/*.o
  mojo_build "$3" --target-triple "$2" --emit object -o "$1/app.o"
  mojo_build mojoui/hosts/mojo_rt.mojo --target-triple "$2" --emit object -o "$1/mojo_rt.o"
}

build_mac() {
  local out="build/$EX/mac"; mkdir -p "$out"
  local app="$out/$NAME.app"
  if [ "$(uname)" = Darwin ] && [ -n "${MAC_GPU:-}" ]; then
    # On a Mac, with its GPU (omxcode#3): a native build, Metal kernels compiled by Apple's toolchain, Mojo's runtime
    # linked from the pixi env (CI only for now: the runtime libraries aren't in the bundle). MAC_GPU: an accelerator
    # (metal:1 on GitHub's virtual GPU) or "native" (MAX names this Mac's own GPU)
    echo "== Mac ($EX): AppKit, arm64, native, GPU ($MAC_GPU)"
    rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
    local frameworks=(-Xlinker -framework -Xlinker AppKit -Xlinker -lobjc)
    if [ "$MAC_GPU" = native ]; then  # (two calls: an empty array is "unbound" under set -u in macOS's bash 3.2)
      mojo_build hosts/mac_gpu_main.mojo -o "$app/Contents/MacOS/$NAME" "${frameworks[@]}"
    else
      mojo_build hosts/mac_gpu_main.mojo --target-accelerator "$MAC_GPU" -o "$app/Contents/MacOS/$NAME" "${frameworks[@]}"
    fi
  else
    echo "== Mac ($EX): AppKit, arm64 macOS 14+"
    apple_objects "$out" arm64-apple-macosx14.0 hosts/mac_main.mojo
    rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
    pixi run ld64.lld -arch arm64 -e _mojo_entry -dead_strip -no_adhoc_codesign \
      -platform_version macos 14.0 26.0 -o "$app/Contents/MacOS/$NAME" "$out"/*.o apple/sdk/macos/*.tbd
  fi
  plist apple/mac/Info.plist "$app/Contents/Info.plist"
  mkdir -p "$app/Contents/Resources/fonts"; cp mojoui/hosts/static/fonts/*.ttf "$app/Contents/Resources/fonts/"
  printf 'APPL????' > "$app/Contents/PkgInfo"
  sign "$app"
  rm -f "$out/$NAME-mac.zip"; (cd "$out" && zip -qry "$NAME-mac.zip" "$NAME.app")
  stamp "$out"; echo "   $app (+ $out/$NAME-mac.zip)"
}

build_ios() {
  local out="build/$EX/ios"; mkdir -p "$out"
  echo "== iPhone ($EX): UIKit, arm64 iOS 17+"
  apple_objects "$out" arm64-apple-ios17.0 hosts/ios_main.mojo
  local app="$out/Payload/$NAME.app"; rm -rf "$out/Payload" "$out/$NAME.ipa"; mkdir -p "$app"
  pixi run ld64.lld -arch arm64 -e _mojo_entry -dead_strip -no_adhoc_codesign \
    -platform_version ios 17.0 26.0 -o "$app/$NAME" "$out"/*.o apple/sdk/ios/*.tbd
  plist apple/ios/Info.plist "$app/Info.plist"
  mkdir -p "$app/fonts"; cp mojoui/hosts/static/fonts/*.ttf "$app/fonts/"  # the app's own fonts (D-155), registered at start
  printf 'APPL????' > "$app/PkgInfo"
  sign "$app"
  (cd "$out" && zip -qry "$NAME.ipa" Payload)
  stamp "$out"; echo "   $out/$NAME.ipa"
}

case "$WHAT" in
  linux) build_linux ;;
  web) build_web ;;
  mac) build_mac ;;
  ios) build_ios ;;
  android) build_android ;;
  all)  # every platform, or only those listed in examples/<example>/platforms
    for p in $(cat "examples/$EX/platforms" 2>/dev/null || echo linux web mac ios); do "build_$p"; done ;;
  *) echo "usage: scripts/build.sh <example> linux|web|mac|ios|android|all" >&2; exit 2 ;;
esac
