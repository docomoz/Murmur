#!/bin/bash
# Updates the Homebrew cask (packaging/homebrew/murmur.rb) to a released version:
# rewrites `version` and `sha256`, checks the result with `brew style` and,
# optionally, copies it into a local checkout of the tap repo.
#
#   scripts/update_cask.sh                      # version from build.sh, sha256 of the published GitHub asset
#   scripts/update_cask.sh 1.11                 # explicit version
#   scripts/update_cask.sh --local              # sha256 of build/Murmur.dmg (upload exactly this file!)
#   scripts/update_cask.sh --tap ~/Projects/homebrew-tap   # also copy to <tap>/Casks/murmur.rb
#
# Nothing is committed or pushed: the script prints the git commands for the tap.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="docomoz/Murmur"
CASK="packaging/homebrew/murmur.rb"
ASSET="Murmur.dmg"

version="" local_dmg=0 tap_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --local) local_dmg=1 ;;
    --tap) tap_dir="${2:?--tap needs a path}"; shift ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "✗ Unknown option: $1" >&2; exit 1 ;;
    *) version="$1" ;;
  esac
  shift
done

if [ -z "$version" ]; then
  version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' build.sh)
  [ -n "$version" ] || { echo "✗ VERSION not found in build.sh" >&2; exit 1; }
fi
url="https://github.com/$REPO/releases/download/v$version/$ASSET"

if [ "$local_dmg" = 1 ]; then
  [ -f "build/$ASSET" ] || { echo "✗ build/$ASSET not found, run ./build.sh first" >&2; exit 1; }
  sha=$(shasum -a 256 "build/$ASSET" | cut -d' ' -f1)
  echo "▸ sha256 of local build/$ASSET (upload this exact file as v$version)"
else
  sha=""
  if command -v gh >/dev/null; then
    # GitHub stores a sha256 digest for every release asset, no download needed.
    digest=$(gh release view "v$version" -R "$REPO" --json assets \
      -q ".assets[] | select(.name == \"$ASSET\") | .digest" 2>/dev/null || true)
    sha="${digest#sha256:}"
  fi
  if [ -z "$sha" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    echo "▸ Downloading $url"
    curl -fL --progress-bar -o "$tmp/$ASSET" "$url"
    sha=$(shasum -a 256 "$tmp/$ASSET" | cut -d' ' -f1)
  fi
  echo "▸ sha256 of published $url"
fi
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "✗ Bad sha256: '$sha'" >&2; exit 1; }

sed -i '' -E \
  -e "s/^  version \".*\"$/  version \"$version\"/" \
  -e "s/^  sha256 \".*\"$/  sha256 \"$sha\"/" \
  "$CASK"
grep -q "^  version \"$version\"$" "$CASK" && grep -q "^  sha256 \"$sha\"$" "$CASK" \
  || { echo "✗ Failed to rewrite $CASK" >&2; exit 1; }
echo "✓ $CASK → $version ($sha)"

if [ -n "$tap_dir" ]; then
  [ -d "$tap_dir" ] || { echo "✗ Tap checkout not found: $tap_dir" >&2; exit 1; }
  mkdir -p "$tap_dir/Casks"
  cp "$CASK" "$tap_dir/Casks/murmur.rb"
  echo "✓ Copied to $tap_dir/Casks/murmur.rb"
  # Inside a tap the file is checked as a cask (outside it, as a plain Ruby file).
  if command -v brew >/dev/null; then
    brew style "$tap_dir/Casks/murmur.rb" || echo "⚠ brew style reported problems (see above)" >&2
  fi
  echo "  Next: cd \"$tap_dir\" && git add Casks/murmur.rb && git commit -m \"murmur $version\" && git push"
fi
