cask "ai-usage-bar" do
  version "0.3.1"
  sha256 "da014c40f06e2eb19128f0d1c06091cfb9d67d0677e7c8eff8fc7e9eb14de886"

  url "https://github.com/Balanced02/ai-usage-bar/releases/download/v#{version}/AIUsageBar-v#{version}.zip"
  name "AI Usage Bar"
  desc "Menu-bar app showing Claude / Codex / Gemini usage"
  homepage "https://github.com/Balanced02/ai-usage-bar"

  # The Release workflow bumps `version` + `sha256` via an automated PR on each tag.
  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "AIUsageBar.app"

  zap trash: [
    "~/Library/Preferences/com.aiusagebar.AIUsageBar.plist",
    "~/Library/Application Support/AIUsageBar",
    "~/Library/Caches/com.aiusagebar.AIUsageBar",
  ]
end
