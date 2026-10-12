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

VERSION="1.11"
BUILD_NUMBER="12"   # CFBundleVersion — Sparkle compares it, so raise it with every release
APP="build/Murmur.app"

SWIFT_FLAGS=()
if [ -n "$APPSTORE" ]; then
  # No Sparkle in the App Store build: its code is compiled out and the unused framework isn't linked.
  SWIFT_FLAGS=(-Xswiftc -DAPPSTORE -Xlinker -dead_strip_dylibs)
fi

echo "▸ Compiling (arm64 + x86_64)…"
rm -rf build && mkdir -p build/bin build/intents "$APP/Contents/MacOS" "$APP/Contents/Resources"
# App Intents (Shortcuts / Spotlight / Siri / Focus filter) need Metadata.appintents in the bundle.
# Xcode makes it in two steps, repeated here by hand: the compiler dumps compile-time values of
# everything conforming to these protocols (the list Xcode 27 passes), then
# appintentsmetadataprocessor turns that dump into the metadata (see "App Intents metadata" below).
echo '["AnyResolverProviding","AppEntity","AppEnum","AppExtension","AppIntent","AppIntentsPackage","AppShortcutProviding","AppShortcutsProvider","AppUnionValue","AppUnionValueCasesProviding","DynamicOptionsProvider","EntityQuery","ExtensionPointDefining","IntentValueQuery","Resolver","TransientEntity","_AssistantIntentsProvider","_GenerativeFunctionExtractable","_IntentValueRepresentable"]' \
  > build/intents/protocols.json
CONST_VALUES=(-Xswiftc -emit-const-values -Xswiftc -const-gather-protocols-list -Xswiftc "$PWD/build/intents/protocols.json")
for arch in arm64 x86_64; do
  swift build -c release --triple "$arch-apple-macosx14.0" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} "${CONST_VALUES[@]}"
  cp "$(swift build -c release --triple "$arch-apple-macosx14.0" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} "${CONST_VALUES[@]}" --show-bin-path)/Murmur" "build/bin/Murmur-$arch"
done

echo "▸ Assembling bundle…"
lipo -create build/bin/Murmur-arm64 build/bin/Murmur-x86_64 -output "$APP/Contents/MacOS/Murmur"
rm -rf build/bin
cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"
cp CREDITS.md "$APP/Contents/Resources/"
# en/ru localizations: English for the App Intents texts (the UI itself is translated in code)
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"

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
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
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
echo "▸ App Intents metadata…"
# Same tools and flags as Xcode's "Extract app intents metadata" and "App Intents SSU training"
# build steps. The metadata is architecture-neutral, so the arm64 compile-time values are enough.
if ! xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
  echo "✗ Нет appintentsmetadataprocessor: нужен полный Xcode (xcode-select -s /Applications/Xcode.app)" >&2
  exit 1
fi
ls "$PWD"/Sources/Murmur/*.swift > build/intents/sources.txt
# Release builds are whole-module: one file per module. Newest wins, in case an older build
# layout left a stale copy somewhere in .build.
find "$PWD/.build" -ipath '*release*' -path '*/arm64/*' -name '*.swiftconstvalues' -print0 \
  | xargs -0 ls -t 2>/dev/null | head -1 > build/intents/constvalues.txt || true
if [ ! -s build/intents/constvalues.txt ]; then
  echo "✗ Компилятор не выдал .swiftconstvalues — Metadata.appintents не из чего собрать" >&2
  exit 1
fi
XCODE_BUILD=$(xcodebuild -version | awk '/Build version/ { print $3 }')
TOOLCHAIN_DIR=$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")
xcrun appintentsmetadataprocessor \
  --output "$APP/Contents/Resources" \
  --toolchain-dir "$TOOLCHAIN_DIR" \
  --module-name Murmur \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --xcode-version "$XCODE_BUILD" \
  --platform-family macOS \
  --deployment-target 14.0 \
  --bundle-identifier app.murmur.mac \
  --target-triple arm64-apple-macosx14.0 \
  --source-file-list build/intents/sources.txt \
  --swift-const-vals-list build/intents/constvalues.txt \
  --compile-time-extraction \
  --deployment-aware-processing > build/intents/metadata.log 2>&1 \
  || { cat build/intents/metadata.log >&2; exit 1; }
# Siri / Spotlight phrase models for every .lproj (ru from the source literals, en from AppShortcuts.strings)
xcrun appintentsnltrainingprocessor \
  --infoplist-path "$APP/Contents/Info.plist" \
  --temp-dir-path build/intents/ssu \
  --bundle-id app.murmur.mac \
  --product-path "$APP/Contents/Resources" \
  --extracted-metadata-path "$APP/Contents/Resources/Metadata.appintents" \
  --source-file Resources/Localization/en.lproj/AppShortcuts.strings \
  --archive-ssu-assets > build/intents/training.log 2>&1 \
  || { cat build/intents/training.log >&2; exit 1; }
[ -s "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ] || { echo "✗ Нет Metadata.appintents" >&2; exit 1; }
rm -rf build/intents

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
