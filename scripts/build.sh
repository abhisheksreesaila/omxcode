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
# An example that uses the omxcore engine package (vendor/omxcore.mojoc, vendor/OMXCORE_COMMIT; its needs file says omxcore) links its Parquet codecs.
LINK=()
if grep -qx omxcore "examples/$EX/needs" 2>/dev/null && [ "$(uname)" != Darwin ]; then source scripts/mxlink.sh; fi  # (Linux's codecs)

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
  local debug=(); [ "${MOJOUI_DEBUG:-}" = 1 ] && debug=(-D MOJOUI_DEBUG) && echo "   (debug build: WebKit's inspector for widget views, source maps)"
  mojo_build hosts/linux_main.mojo "${debug[@]}" -o "$out/$EX" \
    -Xlinker -lgtk-4 -Xlinker -ladwaita-1 -Xlinker -lgobject-2.0 -Xlinker -lglib-2.0 -Xlinker -lgio-2.0 -Xlinker -lfontconfig -Xlinker -lpango-1.0 "${LINK[@]}"
  mkdir -p "$out/fonts"; cp mojoui/hosts/static/fonts/*.ttf "$out/fonts/"  # the app's own fonts, beside the binary (D-155)
  # Its JavaScript (docs/js.md, goal 34 M3): each WebComponent runs in a WebKitGTK view loading the web's own bundles,
  # built into $out/webview by the same esbuild step. Where WebKitGTK 6.0 isn't installed, scripts/webkitgtk.sh fetches
  # the pinned package and $out/$EX becomes a launcher that lays it over /usr/lib (bubblewrap, no root: D-608)
  rm -f "$out/$EX.bin"
  pixi run python scripts/web_assets.py --webview "$out/webview" "$EX"
  if [ -f "$out/webview/assets/manifest.json" ]; then
    # (a system WebKitGTK 6.0: webkitgtk.sh prints nothing, no launcher; it can't be fetched (offline, not x86_64): a
    # warning, no launcher, and the app's WebComponents show their `instead` views, D-619)
    local wk=""
    if ! wk="$(scripts/webkitgtk.sh)"; then
      echo "   warning: no WebKitGTK 6.0 (install webkitgtk-6.0, or run scripts/webkitgtk.sh online): WebComponents show their stand-ins" >&2
      wk=""
    fi
    if [ -n "$wk" ]; then
      mv "$out/$EX" "$out/$EX.bin"
      scripts/webkit_launcher.sh "$out" "$EX" "$wk"
    fi
  fi
  stamp "$out"; echo "   $out/$EX"
}

build_web() {
  local out="build/$EX/web"; mkdir -p "$out"; rm -f "$out/mojoui_app.so"
  echo "== Web ($EX): Mojo Python module for FastHTML"
  mojo_build hosts/web_main.mojo --emit shared-lib "${LINK[@]}" -o "$out/mojoui_app.so"
  # Its JavaScript and CSS (docs/js.md), for every app: examples/$EX/web/widgets/* bundled by esbuild into $out/assets
  # by content hash (a web/package.json is installed first with npm ci from its lockfile, into build/$EX/npm), then
  # the lint: every asset App.web_assets() lists was bundled, and nothing else is there
  pixi run python scripts/web_assets.py "$EX"
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

apple_objects() {  # apple_objects <dir> <triple> <host-main> [Mojo flags, e.g. -D MOJOUI_DEBUG]
  rm -f "$1"/*.o
  mojo_build "$3" ${4+"${@:4}"} --target-triple "$2" --emit object -o "$1/app.o"  # (${4+…}: macOS's bash 3.2 under set -u)
  mojo_build mojoui/hosts/mojo_rt.mojo --target-triple "$2" --emit object -o "$1/mojo_rt.o"
}

bundle_runtime() {  # bundle_runtime <app>: Modular's runtime libraries the native build links (and theirs), byte for byte
  # (Modular's own signatures; the executable's rpath finds them all), into the app with Modular's licence and our
  # notice (apple/licenses), so it runs without the pixi env (D-309)
  local exe="$1/Contents/MacOS/$NAME" fw="$1/Contents/Frameworks" dirs f dep d new=1
  dirs=$(otool -l "$exe" | awk '$1=="cmd" && $2=="LC_RPATH" {getline; getline; print $2}' | sort -u)
  mkdir -p "$fw" "$1/Contents/Resources/Licenses"
  while [ $new = 1 ]; do new=0  # (until no library needs one we haven't copied)
    for f in "$exe" "$fw"/*.dylib; do [ -e "$f" ] || continue
      for dep in $(otool -L "$f" | awk 'NR>1 && $1 ~ /^@rpath\// {sub("@rpath/", "", $1); print $1}'); do
        [ -e "$fw/$dep" ] && continue
        for d in $dirs; do [ -e "$d/$dep" ] && { cp "$d/$dep" "$fw/$dep"; chmod u+w "$fw/$dep"; new=1; break; }; done
        [ -e "$fw/$dep" ] || { echo "bundle_runtime: $dep not found in $dirs" >&2; return 1; }
      done
    done
  done
  for d in $dirs; do install_name_tool -delete_rpath "$d" "$exe"; done
  install_name_tool -add_rpath @executable_path/../Frameworks "$exe"
  cp apple/licenses/*.txt "$1/Contents/Resources/Licenses/"
  echo "   bundled: $(ls "$fw")"
}

build_mac() {
  local out="build/$EX/mac"; mkdir -p "$out"
  local app="$out/$NAME.app"
  # MOJOUI_DEBUG=1: a debug build, as on Linux (D-679): each widget's WKWebView inspectable from Safari's Develop menu,
  # bundles with source maps; release builds (the default) have neither
  local debug="${MOJOUI_DEBUG:-}"; [ "$debug" = 1 ] && echo "   (debug build: WebKit's inspector for widget views, source maps)"
  # Background jobs get threads of their own, as on Linux (D-792): the engine's Apple build otherwise runs a job inside
  # its start call, on the main thread, and a long one freezes the window. MOJOUI_SERIAL_JOBS=1 builds the old way, to compare
  local jobs=MXFRAME_JOB_THREADS; [ "${MOJOUI_SERIAL_JOBS:-}" = 1 ] && jobs=MOJOUI_SERIAL_JOBS && echo "   (jobs on the main thread)"
  if [ "$(uname)" = Darwin ] && [ -n "${MAC_GPU:-}" ]; then
    # On a Mac, with its GPU (omxcode#3): a native build, Metal kernels compiled by Apple's toolchain, Mojo's runtime
    # libraries bundled in the app (bundle_runtime, D-309). MAC_GPU: an accelerator
    # (metal:1 on GitHub's virtual GPU) or "native" (MAX names this Mac's own GPU)
    echo "== Mac ($EX): AppKit, arm64, native, GPU ($MAC_GPU)"
    rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
    local frameworks=(-Xlinker -framework -Xlinker AppKit -Xlinker -lobjc)
    if [ "$MAC_GPU" = native ]; then  # (two calls: an empty array is "unbound" under set -u in macOS's bash 3.2)
      if [ "$debug" = 1 ]; then mojo_build hosts/mac_gpu_main.mojo -D MOJOUI_DEBUG -D "$jobs" -o "$app/Contents/MacOS/$NAME" "${frameworks[@]}"
      else mojo_build hosts/mac_gpu_main.mojo -D "$jobs" -o "$app/Contents/MacOS/$NAME" "${frameworks[@]}"; fi
    elif [ "$debug" = 1 ]; then
      mojo_build hosts/mac_gpu_main.mojo -D MOJOUI_DEBUG -D "$jobs" --target-accelerator "$MAC_GPU" -o "$app/Contents/MacOS/$NAME" "${frameworks[@]}"
    else
      mojo_build hosts/mac_gpu_main.mojo -D "$jobs" --target-accelerator "$MAC_GPU" -o "$app/Contents/MacOS/$NAME" "${frameworks[@]}"
    fi
    bundle_runtime "$app"
  else
    echo "== Mac ($EX): AppKit, arm64 macOS 14+"
    if [ "$debug" = 1 ]; then apple_objects "$out" arm64-apple-macosx14.0 hosts/mac_main.mojo -D MOJOUI_DEBUG -D "$jobs"
    else apple_objects "$out" arm64-apple-macosx14.0 hosts/mac_main.mojo -D "$jobs"; fi
    rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
    pixi run ld64.lld -arch arm64 -e _mojo_entry -dead_strip -no_adhoc_codesign \
      -platform_version macos 14.0 26.0 -o "$app/Contents/MacOS/$NAME" "$out"/*.o apple/sdk/macos/*.tbd
  fi
  plist apple/mac/Info.plist "$app/Contents/Info.plist"
  mkdir -p "$app/Contents/Resources/fonts"; cp mojoui/hosts/static/fonts/*.ttf "$app/Contents/Resources/fonts/"
  # Its JavaScript (docs/js.md, goal 34b M2): each WebComponent runs in a WKWebView loading the web's own bundles, built
  # into Resources/webview by the same esbuild step (nothing for an app without web/widgets/)
  pixi run python scripts/web_assets.py --webview "$app/Contents/Resources/webview" "$EX"
  printf 'APPL????' > "$app/Contents/PkgInfo"
  sign "$app"
  rm -f "$out/$NAME-mac.zip"; (cd "$out" && zip -qry "$NAME-mac.zip" "$NAME.app")
  if [ -d "$app/Contents/Frameworks" ]; then (cd apple/licenses && zip -qj "../../$out/$NAME-mac.zip" NOTICE.txt); fi  # (beside the app)
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
