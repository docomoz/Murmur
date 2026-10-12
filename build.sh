#!/bin/bash
# Builds Murmur.app (universal: Apple Silicon + Intel) and Murmur.dmg into ./build
#
# Without env vars the app is signed ad-hoc (Gatekeeper asks to allow it on first launch).
# Release build, signed with Developer ID and notarized:
#   DEVELOPER_ID="Developer ID Application: Maksim Berezkin (TEAMID)" \
#   NOTARY_PROFILE=murmur-notary ./build.sh
# NOTARY_PROFILE is a keychain profile created once with `xcrun notarytool store-credentials`.
set -euo pipefail
cd "$(dirname "$0")"

DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ] && [ -z "$DEVELOPER_ID" ]; then
  echo "✗ NOTARY_PROFILE задан без DEVELOPER_ID: нотаризовать можно только подписанное Developer ID" >&2
  exit 1
fi

VERSION="1.10"
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
  <key>CFBundleVersion</key><string>11</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Maksim Berezkin</string>
</dict>
</plist>
PLIST

# Submits a file to Apple's notary service and fails the build unless it is accepted.
notarize() {
  local file="$1" result status id
  result=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  echo "$result" > build/notary.json
  status=$(plutil -extract status raw -o - build/notary.json)
  id=$(plutil -extract id raw -o - build/notary.json)
  rm build/notary.json
  if [ "$status" != "Accepted" ]; then
    echo "✗ Нотаризация $file: $status" >&2
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
  fi
}

if [ -n "$DEVELOPER_ID" ]; then
  echo "▸ Signing (Developer ID, hardened runtime)…"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "▸ Signing (ad-hoc)…"
  codesign --force --deep --sign - "$APP"
fi

if [ -n "$NOTARY_PROFILE" ]; then
  echo "▸ Notarizing app (обычно 1–5 мин)…"
  ditto -c -k --keepParent "$APP" build/Murmur.zip
  notarize build/Murmur.zip
  rm build/Murmur.zip
  xcrun stapler staple "$APP"
fi

echo "▸ Packing DMG…"
STAGE="build/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [ -n "$NOTARY_PROFILE" ]; then
  # Notarized: replace the Gatekeeper workaround in step 2 with a plain "launch it"
  awk '/^2\. Запусти/ { print "2. Запусти Murmur из «Программ»."; skip = 1; next }
       /^3\./ { skip = 0 } !skip' "README-друзьям.txt" > "$STAGE/Как открыть.txt"
else
  cp "README-друзьям.txt" "$STAGE/Как открыть.txt"
fi
hdiutil create -volname "Murmur" -srcfolder "$STAGE" -ov -format UDZO "build/Murmur.dmg" >/dev/null
rm -rf "$STAGE"

if [ -n "$DEVELOPER_ID" ]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" build/Murmur.dmg
fi
if [ -n "$NOTARY_PROFILE" ]; then
  echo "▸ Notarizing DMG…"
  notarize build/Murmur.dmg
  xcrun stapler staple build/Murmur.dmg
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 build/Murmur.dmg
fi

echo "✓ Готово: $(pwd)/build/Murmur.app и build/Murmur.dmg ($(du -h build/Murmur.dmg | cut -f1))"
