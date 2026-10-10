#!/bin/bash
# Builds Murmur.app (universal: Apple Silicon + Intel) and Murmur.dmg into ./build
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.3"
APP="build/Murmur.app"

echo "▸ Compiling (arm64 + x86_64)…"
rm -rf build && mkdir -p build/bin "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swift build -c release --triple "$arch-apple-macosx14.0"
  cp "$(swift build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)/Murmur" "build/bin/Murmur-$arch"
done

echo "▸ Assembling bundle…"
lipo -create build/bin/Murmur-arm64 build/bin/Murmur-x86_64 -output "$APP/Contents/MacOS/Murmur"
rm -rf build/bin
cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"
cp CREDITS.md "$APP/Contents/Resources/"

ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Murmur</string>
  <key>CFBundleDisplayName</key><string>Murmur</string>
  <key>CFBundleIdentifier</key><string>app.murmur.mac</string>
  <key>CFBundleExecutable</key><string>Murmur</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Maksim Berezkin</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "▸ Packing DMG…"
STAGE="build/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "README-друзьям.txt" "$STAGE/Как открыть.txt"
hdiutil create -volname "Murmur" -srcfolder "$STAGE" -ov -format UDZO "build/Murmur.dmg" >/dev/null
rm -rf "$STAGE"

echo "✓ Готово: $(pwd)/build/Murmur.app и build/Murmur.dmg ($(du -h build/Murmur.dmg | cut -f1))"
