#!/bin/bash
# Builds Murmur.app (universal: Apple Silicon + Intel) and Murmur.dmg into ./build
#
# Without env vars the app is signed ad-hoc (Gatekeeper asks to allow it on first launch).
# Release build, signed with Developer ID and notarized:
#   DEVELOPER_ID="Developer ID Application: Maksim Berezkin (TEAMID)" \
#   NOTARY_PROFILE=murmur-notary ./build.sh
# NOTARY_PROFILE is a keychain profile created once with `xcrun notarytool store-credentials`.
#
# Self-update (Sparkle 2, see HANDOFF.md §6): Sparkle.framework is always embedded; updates are switched on
# when the EdDSA public key is known — SPARKLE_PUBLIC_KEY or the file Resources/sparkle-public-key.txt.
# SPARKLE_FEED_URL overrides the appcast address (default: appcast.xml on the main branch on GitHub).
# MURMUR_APPSTORE=1 (used by build-appstore.sh) compiles Sparkle out and stops before notarization and the DMG.
set -euo pipefail
cd "$(dirname "$0")"

DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ] && [ -z "$DEVELOPER_ID" ]; then
  echo "✗ NOTARY_PROFILE задан без DEVELOPER_ID: нотаризовать можно только подписанное Developer ID" >&2
  exit 1
fi

APPSTORE="${MURMUR_APPSTORE:-}"
if [ -n "$APPSTORE" ] && [ -n "$DEVELOPER_ID$NOTARY_PROFILE" ]; then
  echo "✗ MURMUR_APPSTORE собирается только с ad-hoc подписью (App Store-подпись ставит build-appstore.sh)" >&2
  exit 1
fi
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/docomoz/Murmur/main/appcast.xml}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-$(cat Resources/sparkle-public-key.txt 2>/dev/null || true)}"
SPARKLE_PUBLIC_KEY="$(printf '%s' "$SPARKLE_PUBLIC_KEY" | tr -d '[:space:]')"

VERSION="1.10"
BUILD_NUMBER="11"   # CFBundleVersion — Sparkle compares it, so raise it with every release
APP="build/Murmur.app"

SWIFT_FLAGS=()
if [ -n "$APPSTORE" ]; then
  # No Sparkle in the App Store build: its code is compiled out and the unused framework isn't linked.
  SWIFT_FLAGS=(-Xswiftc -DAPPSTORE -Xlinker -dead_strip_dylibs)
fi

echo "▸ Compiling (arm64 + x86_64)…"
rm -rf build && mkdir -p build/bin "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swift build -c release --triple "$arch-apple-macosx14.0" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
  cp "$(swift build -c release --triple "$arch-apple-macosx14.0" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path)/Murmur" "build/bin/Murmur-$arch"
done

echo "▸ Assembling bundle…"
lipo -create build/bin/Murmur-arm64 build/bin/Murmur-x86_64 -output "$APP/Contents/MacOS/Murmur"
rm -rf build/bin
cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"
cp CREDITS.md "$APP/Contents/Resources/"

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -z "$APPSTORE" ]; then
  # Universal framework from the SwiftPM artifact. The binary links @rpath/Sparkle.framework and has
  # the rpath @executable_path/../Frameworks (Package.swift). ditto keeps the framework's symlinks.
  mkdir -p "$APP/Contents/Frameworks"
  ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$SPARKLE"
  # Murmur isn't sandboxed, so Sparkle's XPC services are never used (Sparkle docs, "Sandboxing");
  # headers are only for compiling against the framework.
  for dir in XPCServices Headers PrivateHeaders Modules; do
    rm -rf "${SPARKLE:?}/$dir" "${SPARKLE:?}/Versions/B/$dir"
  done
  cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt"   # MIT: ship the notice
fi

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
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Maksim Berezkin</string>
</dict>
</plist>
PLIST

if [ -z "$APPSTORE" ] && [ -n "$SPARKLE_PUBLIC_KEY" ]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" \
    -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" \
    -c "Add :SUEnableAutomaticChecks bool true" "$APP/Contents/Info.plist"
elif [ -z "$APPSTORE" ]; then
  echo "  (автообновление выключено: нет Resources/sparkle-public-key.txt или SPARKLE_PUBLIC_KEY)"
fi

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

# Nested code is signed inside-out without --deep, as Sparkle's docs prescribe for builds outside Xcode
# (its helpers Autoupdate and Updater.app, then the framework), and the app last.
sign_app() {
  if [ -d "$SPARKLE" ]; then
    codesign "$@" "$SPARKLE/Versions/B/Autoupdate"
    codesign "$@" "$SPARKLE/Versions/B/Updater.app"
    codesign "$@" "$SPARKLE"
  fi
  codesign "$@" "$APP"
}

if [ -n "$DEVELOPER_ID" ]; then
  echo "▸ Signing (Developer ID, hardened runtime)…"
  sign_app --force --options runtime --timestamp --sign "$DEVELOPER_ID"
else
  # No hardened runtime here: its library validation rejects an ad-hoc Sparkle.framework (no Team ID).
  echo "▸ Signing (ad-hoc)…"
  sign_app --force --sign -
fi
codesign --verify --deep --strict "$APP"
if [ -n "$DEVELOPER_ID" ] && ! "$APP/Contents/MacOS/Murmur" --selftest >/dev/null 2>&1; then
  # Catches a framework that dyld refuses under the hardened runtime before it reaches notarization.
  echo "✗ Подписанное приложение не запускается (--selftest); проверь подпись Sparkle.framework" >&2
  exit 1
fi

if [ -n "$APPSTORE" ]; then
  echo "✓ Основа для App Store (без Sparkle): $(pwd)/$APP"
  exit 0
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
