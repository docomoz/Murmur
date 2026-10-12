#!/bin/bash
# Builds the Mac App Store version of Murmur from the regular build:
# sandboxed, with its own bundle ID, privacy manifest and the App Store signature, packed into a .pkg.
#
# Local test (no Apple account needed): sandboxed app signed ad-hoc → build/appstore/Murmur.app
#   ./build-appstore.sh
#
# Upload build (after enrolling, see AppStore/README.md):
#   MAS_APP_IDENTITY="Apple Distribution: Maksim Berezkin (TEAMID)" \
#   MAS_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Maksim Berezkin (TEAMID)" \
#   MAS_PROFILE=~/Downloads/Murmur_Mac_App_Store.provisionprofile \
#   ./build-appstore.sh
#   → build/appstore/Murmur.pkg, ready for Transporter.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="${MAS_BUNDLE_ID:-com.docomoz.murmur}"
APP_IDENTITY="${MAS_APP_IDENTITY:-}"
INSTALLER_IDENTITY="${MAS_INSTALLER_IDENTITY:-}"
PROFILE="${MAS_PROFILE:-}"

if [ -n "$APP_IDENTITY" ] && { [ -z "$INSTALLER_IDENTITY" ] || [ -z "$PROFILE" ]; }; then
  echo "✗ Для сборки на загрузку нужны все три: MAS_APP_IDENTITY, MAS_INSTALLER_IDENTITY и MAS_PROFILE" >&2
  exit 1
fi

echo "▸ Regular build without Sparkle…"
# The App Store updates the app itself: self-update (Sparkle) is compiled out and not embedded.
# Note: this replaces build/Murmur.app with that variant and leaves no DMG — run ./build.sh again for the DMG.
MURMUR_APPSTORE=1 DEVELOPER_ID= NOTARY_PROFILE= ./build.sh >/dev/null

OUT="build/appstore"
APP="$OUT/Murmur.app"
rm -rf "$OUT" && mkdir -p "$OUT"
cp -R build/Murmur.app "$APP"
rm -f "$APP/Contents/_CodeSignature/CodeResources"
if [ -e "$APP/Contents/Frameworks/Sparkle.framework" ] || otool -L "$APP/Contents/MacOS/Murmur" | grep -q Sparkle \
   || /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "✗ В App Store-сборку попал Sparkle" >&2
  exit 1
fi

echo "▸ App Store bundle ($BUNDLE_ID)…"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ITSAppUsesNonExemptEncryption bool false" "$PLIST"
cp AppStore/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

ENTITLEMENTS="$OUT/Murmur.entitlements"
cp AppStore/Murmur.entitlements "$ENTITLEMENTS"

if [ -z "$APP_IDENTITY" ]; then
  echo "▸ Signing ad-hoc with the sandbox (local test only)…"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
  codesign -d --entitlements - "$APP" 2>/dev/null | grep -q app-sandbox
  echo "✓ Тестовая версия в песочнице: $(pwd)/$APP"
  echo "  Загрузить в App Store её нельзя — для этого нужны сертификаты (см. AppStore/README.md)."
  exit 0
fi

echo "▸ Provisioning profile…"
PROFILE_PLIST="$OUT/profile.plist"
security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
APP_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$PROFILE_PLIST")
TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$PROFILE_PLIST")
if [ "$APP_ID" != "$TEAM_ID.$BUNDLE_ID" ]; then
  echo "✗ Профиль выписан на $APP_ID, а приложение — $TEAM_ID.$BUNDLE_ID" >&2
  exit 1
fi
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_ID" "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENTITLEMENTS"

echo "▸ Signing for the App Store…"
codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ Packing installer…"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$OUT/Murmur.pkg"
pkgutil --check-signature "$OUT/Murmur.pkg" | head -3

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
echo "✓ Готово к загрузке: $(pwd)/$OUT/Murmur.pkg (версия $VERSION, сборка $BUILD)"
echo "  Открой Transporter и перетащи туда Murmur.pkg."
