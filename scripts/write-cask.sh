#!/usr/bin/env bash
# Prints the Homebrew cask for a release: scripts/write-cask.sh <version> <dmg sha256>
set -euo pipefail
VERSION="$1"
SHA="$2"
cat <<CASK
cask "portbar" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/1fc0nfig/portbar/releases/download/v#{version}/portbar-#{version}.dmg"
  name "portbar"
  desc "Menu bar app that shows which dev servers run on which ports"
  homepage "https://github.com/1fc0nfig/portbar"

  depends_on macos: ">= :sonoma"

  app "portbar.app"

  # The app is ad-hoc signed until it has a Developer ID. Without this step,
  # Gatekeeper says the app is damaged and refuses to open it.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/portbar.app"]
  end

  uninstall quit: "com.cernymatyas.portbar"

  zap trash: "~/Library/Preferences/com.cernymatyas.portbar.plist"
end
CASK
