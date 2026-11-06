#!/usr/bin/env bash
# Packages a built example as an app someone else can run (the owner checks them by hand).
#   scripts/package.sh omxplorer linux   dist/omxplorer-linux-x86_64.tar.gz: the binary, its fonts, the Mojo runtime
#                                        libraries it loads (found by RUNPATH at $ORIGIN/lib), an icon and install.sh
#                                        (~/.local/share/omxplorer plus a launcher entry). Needs GTK 4 and, for the GPU
#                                        path, NVIDIA's driver on the machine.
#   scripts/package.sh omxplorer mac     dist/omxplorer-mac-arm64.zip: the AppKit app with its icon, ad-hoc signed again.
# Any gallery app packages the same way (goal 53: every gallery card links its downloads): scripts/package.sh sketch linux.
# Build first (scripts/build.sh <example> linux|mac); this only copies, patches and zips.
set -euo pipefail
cd "$(dirname "$0")/.."
EX="${1:?example}"; WHAT="${2:?linux or mac}"
NAME="$(tr '[:lower:]' '[:upper:]' <<< "${EX:0:1}")${EX:1}Mojo"
ICON_SVG="docs/design/brand/logo-1-icon.svg"  # (D-254: Lens · bars; green, D-4733)
mkdir -p dist
# what the launcher entry and README say, per app: comment|categories|mime types|how to run it
case "$EX" in
  omxplorer) META="Tables, charts and 100 million rows, written once in Mojo|Office;Spreadsheet;|text/csv;|./$EX            (or ./$EX path/to/file.csv)
Queries use an NVIDIA GPU when the driver is there, the CPU otherwise." ;;
  sketch) META="Pressure ink with pan and zoom, written once in Mojo|Graphics;||./$EX" ;;
  jot) META="Notes in a SQLite file, searched as you type, written once in Mojo|Office;Utility;||./$EX
Notes are kept in ~/.config/jot/jot.db." ;;
  keeper) META="Keeps a folder searchable with its window closed, written once in Mojo|Utility;||./$EX" ;;
  widgets) META="CodeMirror and ECharts inside a native Mojo app|Development;||./$EX" ;;
  lens) META="20 million points painted on the GPU, written once in Mojo|Science;Graphics;||./$EX
Drawn on an NVIDIA GPU when the driver is there, the CPU otherwise." ;;
  todo) META="A to-do list in the platform's own controls, written once in Mojo|Utility;||./$EX" ;;
  *) META="Written once in Mojo|Utility;||./$EX" ;;
esac
IFS='|' read -r COMMENT CATS MIME RUN <<< "$(head -1 <<< "$META")"
NOTE="$(tail -n +2 <<< "$META")"

icon_png() {  # icon_png <size> <out.png>
  rsvg-convert -w "$1" -h "$1" "$ICON_SVG" -o "$2"
}

if [[ "$WHAT" == "linux" ]]; then
  bin="build/$EX/linux/$EX"; [[ -x "$bin" ]] || { echo "build it first: scripts/build.sh $EX linux"; exit 1; }
  [[ -x "$bin.bin" ]] && bin="$bin.bin"  # (widgets: $EX is the launcher script, $EX.bin the app)
  out="dist/$EX-linux-x86_64"; rm -rf "$out"; mkdir -p "$out/lib"
  # the build folder as it runs (binary, fonts, a web view's assets), less the build's own notes; widgets.webkitgtk names
  # a folder on this machine only
  (cd "build/$EX/linux" && find . -mindepth 1 -maxdepth 1 ! -name app.sha256 ! -name '*.webkitgtk' -exec cp -r {} "$OLDPWD/$out/" \;)
  # every library the binary needs from outside the system (Mojo's runtime, the Parquet codecs): ldd resolves them
  ldd "$bin" | awk '/=> \// {print $3}' | grep -v -E '^/(usr/)?lib' | while read -r so; do cp -L "$so" "$out/lib/"; done
  patchelf --set-rpath '$ORIGIN/lib' "$out/$(basename "$bin")"  # (the libraries stay byte for byte: each already finds its neighbours at $ORIGIN)
  mkdir -p "$out/licenses"; cp apple/licenses/MODULAR-*.txt linux/licenses/*-*.txt mojoui/hosts/static/fonts/LICENSE-*.txt "$out/licenses/"; cp linux/licenses/NOTICE.txt "$out/"
  cp LICENSE "$out/LICENSE.txt"
  icon_png 256 "$out/$EX.png"
  cat > "$out/install.sh" <<EOF
#!/usr/bin/env bash
# Installs $EX for this user: ~/.local/share/$EX, a launcher entry, and ~/.local/bin/$EX. Remove with: $EX-uninstall
set -euo pipefail
here="\$(cd "\$(dirname "\$0")" && pwd)"
dest="\$HOME/.local/share/$EX"
rm -rf "\$dest"; mkdir -p "\$dest" "\$HOME/.local/bin" "\$HOME/.local/share/applications" "\$HOME/.local/share/icons/hicolor/256x256/apps"
cp -r "\$here"/. "\$dest/"; rm -f "\$dest/install.sh"  # (the licences travel with the libraries)
cp "\$here/$EX.png" "\$HOME/.local/share/icons/hicolor/256x256/apps/$EX.png"
ln -sf "\$dest/$EX" "\$HOME/.local/bin/$EX"
cat > "\$HOME/.local/share/applications/$EX.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=$EX
Comment=$COMMENT
Exec=\$dest/$EX %f
Icon=$EX
Terminal=false
Categories=$CATS
MimeType=$MIME
DESK
cat > "\$HOME/.local/bin/$EX-uninstall" <<UN
#!/usr/bin/env bash
rm -rf "\$dest" "\$HOME/.local/bin/$EX" "\$HOME/.local/share/applications/$EX.desktop" "\$HOME/.local/share/icons/hicolor/256x256/apps/$EX.png" "\$HOME/.local/bin/$EX-uninstall"
echo "$EX removed"
UN
chmod +x "\$HOME/.local/bin/$EX-uninstall"
echo "Installed. Open it from your app launcher, or run: $EX"
EOF
  chmod +x "$out/install.sh"
  cat > "$out/README.txt" <<EOF
$EX for Linux (x86_64)
Run it here:   $RUN
${NOTE:+$NOTE
}Install it:    ./install.sh     (launcher entry + ~/.local/bin/$EX; remove with $EX-uninstall)
Built for a recent Linux with GTK 4, libadwaita and WebKitGTK 6.0 (Ubuntu 24.04 or Fedora 40 should do; not yet tried on either).
Licences: LICENSE.txt (MIT, $EX's own code); NOTICE.txt (the bundled libraries).
EOF
  rm -f "$out.tar.gz"; tar -C dist -czf "$out.tar.gz" "$(basename "$out")"
  echo "$out.tar.gz ($(du -h "$out.tar.gz" | cut -f1))"
elif [[ "$WHAT" == "mac" ]]; then
  app="build/$EX/mac/$NAME.app"; [[ -d "$app" ]] || { echo "build it first: scripts/build.sh $EX mac"; exit 1; }
  stage="dist/mac-$EX"; rm -rf "$stage"; mkdir -p "$stage"
  cp -R "$app" "$stage/$EX.app"
  res="$stage/$EX.app/Contents/Resources"; mkdir -p "$res"
  icon_png 1024 "$stage/icon.png"
  pixi run python -c "from PIL import Image; Image.open('$stage/icon.png').save('$res/$EX.icns', sizes=[(16,16),(32,32),(64,64),(128,128),(256,256),(512,512),(1024,1024)])"
  plist="$stage/$EX.app/Contents/Info.plist"
  sed -i -e "s#<key>CFBundleName</key><string>[^<]*</string>#<key>CFBundleName</key><string>$EX</string>#" \
         -e "s#<key>CFBundleDisplayName</key><string>[^<]*</string>#<key>CFBundleDisplayName</key><string>$EX</string>#" \
         -e "s#<key>CFBundlePackageType</key>#<key>CFBundleIconFile</key><string>$EX</string>\n\t<key>CFBundlePackageType</key>#" "$plist"
  rm -rf "$stage/$EX.app/Contents/_CodeSignature"
  if command -v codesign >/dev/null; then codesign --force --sign - "$stage/$EX.app"; else rcodesign sign "$stage/$EX.app" >/dev/null; fi
  zip_out="dist/$EX-mac-arm64.zip"; rm -f "$zip_out"
  (cd "$stage" && zip -qry "../$(basename "$zip_out")" "$EX.app")
  echo "$zip_out ($(du -h "$zip_out" | cut -f1))"
else
  echo "linux or mac"; exit 1
fi
