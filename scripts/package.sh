#!/usr/bin/env bash
# Packages a built example as an app someone else can run (the owner checks them by hand).
#   scripts/package.sh omxplorer linux   dist/omxplorer-linux-x86_64.tar.gz: the binary, its fonts, the Mojo runtime
#                                        libraries it loads (found by RUNPATH at $ORIGIN/lib), an icon and install.sh
#                                        (~/.local/share/omxplorer plus a launcher entry). Needs GTK 4 and, for the GPU
#                                        path, NVIDIA's driver on the machine.
#   scripts/package.sh omxplorer mac     dist/omxplorer-mac-arm64.zip: the AppKit app with its icon, ad-hoc signed again.
# Build first (scripts/build.sh <example> linux|mac); this only copies, patches and zips.
set -euo pipefail
cd "$(dirname "$0")/.."
EX="${1:?example}"; WHAT="${2:?linux or mac}"
NAME="$(tr '[:lower:]' '[:upper:]' <<< "${EX:0:1}")${EX:1}Mojo"
ICON_SVG="docs/design/brand/logo-1-icon.svg"  # (D-254: Lens · bars; green, D-4733)
mkdir -p dist

icon_png() {  # icon_png <size> <out.png>
  rsvg-convert -w "$1" -h "$1" "$ICON_SVG" -o "$2"
}

if [[ "$WHAT" == "linux" ]]; then
  bin="build/$EX/linux/$EX"; [[ -x "$bin" ]] || { echo "build it first: scripts/build.sh $EX linux"; exit 1; }
  out="dist/$EX-linux-x86_64"; rm -rf "$out"; mkdir -p "$out/lib"
  cp "$bin" "$out/"; cp -r "build/$EX/linux/fonts" "$out/"
  # every library the binary needs from outside the system (Mojo's runtime, the Parquet codecs): ldd resolves them
  ldd "$bin" | awk '/=> \// {print $3}' | grep -v -E '^/(usr/)?lib' | while read -r so; do cp -L "$so" "$out/lib/"; done
  patchelf --set-rpath '$ORIGIN/lib' "$out/$EX"
  for so in "$out"/lib/*.so*; do patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true; done
  icon_png 256 "$out/$EX.png"
  cat > "$out/install.sh" <<EOF
#!/usr/bin/env bash
# Installs $EX for this user: ~/.local/share/$EX, a launcher entry, and ~/.local/bin/$EX. Remove with: $EX-uninstall
set -euo pipefail
here="\$(cd "\$(dirname "\$0")" && pwd)"
dest="\$HOME/.local/share/$EX"
rm -rf "\$dest"; mkdir -p "\$dest" "\$HOME/.local/bin" "\$HOME/.local/share/applications" "\$HOME/.local/share/icons/hicolor/256x256/apps"
cp -r "\$here/$EX" "\$here/fonts" "\$here/lib" "\$dest/"
cp "\$here/$EX.png" "\$HOME/.local/share/icons/hicolor/256x256/apps/$EX.png"
ln -sf "\$dest/$EX" "\$HOME/.local/bin/$EX"
cat > "\$HOME/.local/share/applications/$EX.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=$EX
Comment=Tables, charts and 100 million rows, written once in Mojo
Exec=\$dest/$EX %f
Icon=$EX
Terminal=false
Categories=Office;Spreadsheet;
MimeType=text/csv;
DESK
cat > "\$HOME/.local/bin/$EX-uninstall" <<UN
#!/usr/bin/env bash
rm -rf "\$dest" "\$HOME/.local/bin/$EX" "\$HOME/.local/share/applications/$EX.desktop" "\$HOME/.local/share/icons/hicolor/256x256/apps/$EX.png" "\$HOME/.local/bin/$EX-uninstall"
echo "$EX removed"
UN
chmod +x "\$HOME/.local/bin/$EX-uninstall"
echo "Installed. Open it from your app launcher, or run: $EX [file.csv]"
EOF
  chmod +x "$out/install.sh"
  cat > "$out/README.txt" <<EOF
$EX for Linux (x86_64)
Run it here:   ./$EX            (or ./$EX path/to/file.csv)
Install it:    ./install.sh     (launcher entry + ~/.local/bin/$EX; remove with $EX-uninstall)
Needs GTK 4. Queries use an NVIDIA GPU when the driver is there, the CPU otherwise.
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
