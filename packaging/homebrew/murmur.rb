cask "murmur" do
  version "1.12"
  sha256 "fde6a24c38550cda681c25d3cf1c9c592f6a805e248b12669774e4d6df0c6be3"

  url "https://github.com/docomoz/Murmur/releases/download/v#{version}/Murmur.dmg"
  name "Murmur"
  desc "Menu bar ambient sound mixer for focus and sleep"
  homepage "https://github.com/docomoz/Murmur"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Murmur.app"

  uninstall quit: "app.murmur.mac"

  zap trash: [
    "~/Library/Caches/app.murmur.mac",
    "~/Library/HTTPStorages/app.murmur.mac",
    "~/Library/HTTPStorages/app.murmur.mac.binarycookies",
    "~/Library/Preferences/app.murmur.mac.plist",
    "~/Library/Saved Application State/app.murmur.mac.savedState",
  ]

  # Remove this block once releases are signed with Developer ID and notarized.
  caveats <<~EOS
    Murmur is not notarized yet, so macOS blocks the first launch.
    Open System Settings -> Privacy & Security and click "Open Anyway",
    or run:
      xattr -dr com.apple.quarantine #{appdir}/Murmur.app
  EOS
end
