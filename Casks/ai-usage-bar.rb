cask "ai-usage-bar" do
  version "0.3.2"
  sha256 "f3e29838b2bbc9b8fe437540147bd9405366267faa75e6bbe8283c59f71dd3c8"

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
