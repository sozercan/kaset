cask "kaset" do
  version "0.2.0"
  sha256 "1997ece8ecf7ed565b120efdd978558729f5265190868711bd8b14505aed78af"

  url "https://github.com/sozercan/kaset/releases/download/v0.2.0/kaset-v0.2.0.dmg"
  name "Kaset"
  desc "Native macOS YouTube Music client"
  homepage "https://github.com/sozercan/kaset"

  auto_updates true
  depends_on macos: ">= :tahoe"

  app "Kaset.app"

  zap trash: [
    "~/Library/Application Support/Kaset",
    "~/Library/Caches/com.sertacozercan.Kaset",
    "~/Library/Preferences/com.sertacozercan.Kaset.plist",
    "~/Library/Saved Application State/com.sertacozercan.Kaset.savedState",
    "~/Library/WebKit/com.sertacozercan.Kaset",
  ]
end
