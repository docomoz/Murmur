cask "murmur" do
  version "1.10"
  sha256 "71c31bd0934ebdba2fe51caa87cf54650569b966338632ef3fdae9757aa711cf"

  url "https://github.com/docomoz/Murmur/releases/download/v#{version}/Murmur.dmg"
  name "Murmur"
  desc "Menu bar ambient sound mixer for focus and sleep"
  homepage "https://github.com/docomoz/Murmur"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Murmur.app"

  uninstall quit: "app.murmur.mac"

  zap trash: [
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
