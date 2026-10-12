cask "murmur" do
  version "1.11"
  sha256 "0b5c314f8f84179473a19b302add9b714e8f6684082bf2d7a144227a2e3bbb62"

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
