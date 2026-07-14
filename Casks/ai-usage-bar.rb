cask "ai-usage-bar" do
  version "0.1.6"
  sha256 "ab8eb02829772d3ae4d7f3dc9d5cee23c2b914ac80d36599cf8e4ab1b4941f0c"

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
