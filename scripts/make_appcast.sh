#!/bin/bash
# Adds the release in build/Murmur.dmg to appcast.xml — the Sparkle update feed — signed with the EdDSA key.
#
#   scripts/make_appcast.sh [notes.md|notes.html|notes.txt [notes.ru.md]]
#
# Run it after ./build.sh (with DEVELOPER_ID/NOTARY_PROFILE for a real release): the signature covers the exact
# DMG bytes, so upload that very file to the GitHub release vX.Y, then commit and push appcast.xml.
# Release notes are optional; Markdown, HTML and plain text are shown by Sparkle's update window.
# Notes are written in English; the optional second file is their Russian translation. With both, the item gets
# <description xml:lang="en"> and <description xml:lang="ru">, and Sparkle shows the one matching the user's languages.
#
# Environment:
#   SPARKLE_KEY_FILE  private key file (generate_keys -x); by default the key is taken from the login keychain
#   DMG               default build/Murmur.dmg
#   APPCAST           default appcast.xml
#   DOWNLOAD_URL      default https://github.com/docomoz/Murmur/releases/download/v<version>/Murmur.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${DMG:-build/Murmur.dmg}"
APPCAST="${APPCAST:-appcast.xml}"
NOTES="${1:-}"
NOTES_RU="${2:-}"
BIN=".build/artifacts/sparkle/Sparkle/bin"

fail() { echo "✗ $*" >&2; exit 1; }
[ -f "$DMG" ] || fail "no $DMG — run ./build.sh first"
[ -f "$APPCAST" ] || fail "no $APPCAST"
[ -z "$NOTES" ] || [ -f "$NOTES" ] || fail "no file $NOTES"
[ -z "$NOTES_RU" ] || [ -n "$NOTES" ] || fail "Russian notes need the English ones first"
[ -z "$NOTES_RU" ] || [ -f "$NOTES_RU" ] || fail "no file $NOTES_RU"
[ -x "$BIN/sign_update" ] || swift package resolve >/dev/null
[ -x "$BIN/sign_update" ] || fail "no $BIN/sign_update (did swift package resolve fail to fetch Sparkle?)"

TMP="$(mktemp -d)"
MOUNT="$TMP/mnt"
cleanup() {
  hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Read the version and the public key from the app inside the DMG itself, not from build/.
mkdir "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG"
PLIST="$MOUNT/Murmur.app/Contents/Info.plist"
[ -f "$PLIST" ] || fail "no Murmur.app in $DMG"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
MIN_OS="$(plist LSMinimumSystemVersion)"
PUBLIC_KEY="$(plist SUPublicEDKey)"
hdiutil detach -quiet "$MOUNT"
[ -n "$PUBLIC_KEY" ] || fail "the app has no SUPublicEDKey: put the public key into Resources/sparkle-public-key.txt and rebuild"

DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/docomoz/Murmur/releases/download/v$VERSION/Murmur.dmg}"
RELEASE_PAGE="https://github.com/docomoz/Murmur/releases/tag/v$VERSION"

echo "▸ Signing $DMG ($VERSION, build $BUILD)…"
KEY_ARGS=()
[ -n "${SPARKLE_KEY_FILE:-}" ] && KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
SIGNATURE="$("$BIN/sign_update" -p ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$DMG")"
LENGTH="$(stat -f %z "$DMG")"

# The most common release mistake is signing with a key that doesn't match the app's SUPublicEDKey —
# then every installed copy rejects the update. Check the signature against the key inside the app.
cat > "$TMP/verify.swift" <<'SWIFT'
import CryptoKit
import Foundation
let a = CommandLine.arguments
guard let key = Data(base64Encoded: a[1]), let sig = Data(base64Encoded: a[2]),
      let data = FileManager.default.contents(atPath: a[3]),
      let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { exit(2) }
exit(pub.isValidSignature(sig, for: data) ? 0 : 1)
SWIFT
swift "$TMP/verify.swift" "$PUBLIC_KEY" "$SIGNATURE" "$DMG" \
  || fail "the signature does not match the app's SUPublicEDKey — wrong private key"

# description <file> [language]
description() {
  local lang=""
  [ -z "${2:-}" ] || lang=" xml:lang=\"$2\""
  case "$1" in
    *.md) echo "<description$lang sparkle:format=\"markdown\"><![CDATA[$(cat "$1")]]></description>" ;;
    *.htm|*.html) echo "<description$lang><![CDATA[$(cat "$1")]]></description>" ;;
    *) echo "<description$lang sparkle:format=\"plain-text\"><![CDATA[$(cat "$1")]]></description>" ;;
  esac
}
if [ -z "$NOTES" ]; then
  DESCRIPTION="<!-- no release notes -->"
elif [ -z "$NOTES_RU" ]; then
  DESCRIPTION="$(description "$NOTES")"
else
  # English first: it's also what Sparkle falls back to.
  DESCRIPTION="$(description "$NOTES" en)
      $(description "$NOTES_RU" ru)"
fi

cat > "$TMP/item.xml" <<ITEM
    <item>
      <title>Murmur $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <link>$RELEASE_PAGE</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      $DESCRIPTION
      <enclosure url="$DOWNLOAD_URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
ITEM

# Newest item first; an existing item with the same build number is replaced, so the script can be rerun.
awk -v build="$BUILD" -v itemfile="$TMP/item.xml" '
  function flush_new() { while ((getline line < itemfile) > 0) print line; close(itemfile); inserted = 1 }
  /<item>/ && !inserted { flush_new() }
  /<\/channel>/ && !inserted { flush_new() }
  /<item>/ { buffering = 1; block = ""; drop = 0 }
  buffering {
    block = block $0 "\n"
    if (index($0, "<sparkle:version>" build "</sparkle:version>")) drop = 1
    if ($0 ~ /<\/item>/) { buffering = 0; if (!drop) printf "%s", block }
    next
  }
  { print }
' "$APPCAST" > "$TMP/appcast.xml"
xmllint --noout "$TMP/appcast.xml" || fail "the result is not valid XML"
cp "$TMP/appcast.xml" "$APPCAST"

echo "✓ $APPCAST: Murmur $VERSION (build $BUILD) → $DOWNLOAD_URL"
echo "  Next: gh release create v$VERSION $DMG, then commit and push $APPCAST."
