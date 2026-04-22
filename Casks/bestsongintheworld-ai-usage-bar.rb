cask "bestsongintheworld-ai-usage-bar" do
  version "0.1.0"
  sha256 "62cf45ec2f2dd0f0165b3aaf4112d0f4548c5097d31c84066180c70237217a8e"

  url "https://github.com/BestSonginTheWorld/ai-usage-bar/releases/download/v#{version}/AIUsageMenuBar-#{version}.zip",
      verified: "github.com/BestSonginTheWorld/ai-usage-bar/"
  name "AIUsageMenuBar"
  desc "Menu bar app for Claude and Codex usage tracking"
  homepage "https://github.com/BestSonginTheWorld/ai-usage-bar"

  depends_on macos: ">= :ventura"
  depends_on formula: "tmux"

  installer script: {
    executable: "install.sh",
    args:       ["--use-prebuilt"],
  }

  uninstall script: {
    executable: "uninstall.sh",
  }

  caveats do
    <<~EOS
      Claude and Codex CLIs must already be installed and available on PATH.

      Installed app:
        ~/Applications/AIUsageMenuBar.app

      First launch may show a macOS security warning because notarization is
      not configured yet. If needed, open the app once via Finder > right-click
      > Open, or remove quarantine manually:

        xattr -dr com.apple.quarantine ~/Applications/AIUsageMenuBar.app
    EOS
  end
end
