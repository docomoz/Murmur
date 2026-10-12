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
# Finder window: just the app and Applications with an arrow between them, over a drawn background.
# Sizes are in points; the background is rendered for exactly this layout (WIN_H is the content below
# the title bar). The window is made TITLEBAR taller; the background has a bottom bleed in case
# another macOS draws a shorter title bar.
WIN_W=600 WIN_H=330 ICON_Y=200 APP_X=160 APPS_X=440 TITLEBAR=32
STAGE="build/dmg"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift scripts/make_dmg_background.swift Resources/icon-1024.png build/dmg-bg $WIN_W $WIN_H $APP_X $APPS_X $ICON_Y
tiffutil -cathidpicheck build/dmg-bg.png build/dmg-bg@2x.png -out "$STAGE/.background/background.tiff" 2>/dev/null
rm build/dmg-bg.png build/dmg-bg@2x.png

# Finder stores the window layout in .DS_Store, so it's set on a writable image and then compressed.
hdiutil create -volname "Murmur" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov build/Murmur-rw.dmg >/dev/null
rm -rf "$STAGE"
MOUNT=$(hdiutil attach build/Murmur-rw.dmg -readwrite -noverify -noautoopen | grep -o '/Volumes/.*$')
osascript - "$MOUNT" $WIN_W $((WIN_H + TITLEBAR)) $APP_X $APPS_X $ICON_Y <<'APPLESCRIPT'
on run {mountPath, winW, winH, appX, appsX, iconY}
  set {winW, winH, appX, appsX, iconY} to {winW as integer, winH as integer, appX as integer, appsX as integer, iconY as integer}
  tell application "Finder"
    set dmg to (POSIX file mountPath as alias)
    open dmg
    set w to container window of dmg
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set bounds of w to {200, 120, 200 + winW, 120 + winH}
    set opts to icon view options of w
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set shows item info of opts to false
    set shows icon preview of opts to false
    set background picture of opts to file ".background:background.tiff" of dmg
    set position of item "Murmur.app" of dmg to {appX, iconY}
    set position of item "Applications" of dmg to {appsX, iconY}
    close w
    open dmg
    update dmg without registering applications
    delay 1
    close container window of dmg
  end tell
end run
APPLESCRIPT
# Finder writes .DS_Store asynchronously; wait for it before detaching.
for _ in $(seq 20); do [ -f "$MOUNT/.DS_Store" ] && break; sleep 0.5; done
# Volume icon goes in last: -srcfolder skips it and Finder drops it while the window is being set up.
cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"
rm -rf "$MOUNT/.fseventsd"
hdiutil detach "$MOUNT" -quiet
hdiutil convert build/Murmur-rw.dmg -format UDZO -imagekey zlib-level=9 -ov -o build/Murmur.dmg >/dev/null
rm build/Murmur-rw.dmg

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
