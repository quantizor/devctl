# Canonical Homebrew cask for devctl. This is the single home for the cask's
# structure; the release workflow (.github/workflows/bump-homebrew-cask.yml)
# reads this file, substitutes `version` and `sha256` for the published release,
# and writes the result to the quantizor/homebrew-tap repo. scripts/smoke-cask.sh
# copies it into a throwaway local tap, rewriting the URL to a local file:// DMG
# with the real checksum, so the whole thing is testable before any release.
#
# The version and sha256 below are whatever the last release set; treat them as
# illustrative, since both are always overwritten on publish.
cask "devctl" do
  version "1.3.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/quantizor/devctl/releases/download/v#{version}/devctl-#{version}.dmg"
  name "devctl"
  desc "Agent-friendly coordinator for many devservers and their configurations"
  homepage "https://github.com/quantizor/devctl"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "devctl.app"
  binary "#{appdir}/devctl.app/Contents/Resources/devctl"

  # This runs on every `brew upgrade`, not only on uninstall, so it is limited to
  # unregistering the background agent, which the app re-registers when brew
  # relaunches it. It must never touch agent hooks or user data: nothing restores
  # those automatically, by design. Full removal is `devctl uninstall`.
  #
  # early_script rather than script, because a plain `script` runs after `quit:`,
  # and the CLI needs a live app to drive SMAppService.unregister over the deep
  # link. There is no launchctl: stanza (it would boot out the SMAppService job on
  # every upgrade) and no login_item: stanza (it cannot see a BTM registration);
  # the agent teardown is delegated to devctl's own CLI, the only lever that
  # reaches BTM.
  #
  # Footgun worth naming: trashing the app and THEN running `brew uninstall`
  # leaves this executable missing, so uninstall raises rather than skipping.
  # Recovery is `brew uninstall --cask --force devctl`. This is inherent to any
  # cask whose uninstall script ships inside the bundle it removes.
  uninstall early_script: {
              executable: "#{appdir}/devctl.app/Contents/Resources/devctl",
              args:       ["uninstall", "--agent-only", "--json"],
            },
            quit:         "dev.quantizor.devctl.app"

  # trash:, not delete:, so removal is recoverable and needs no sudo. The bundle
  # is already gone by the time zap runs (uninstall_artifacts runs first), so
  # nothing here can shell out to the CLI; these are the files devctl leaves in
  # the user's Library.
  zap trash: [
    "~/Library/Application Support/devctl",
    "~/Library/Caches/dev.quantizor.devctl.app",
    "~/Library/LaunchAgents/dev.quantizor.devctl.plist",
    "~/Library/Logs/devctl",
    "~/Library/Preferences/dev.quantizor.devctl.app.plist",
    "~/Library/Saved Application State/dev.quantizor.devctl.app.savedState",
  ]

  caveats <<~EOS
    To remove devctl's agent hooks and CLI state as well, run `devctl uninstall`
    before uninstalling this cask.
  EOS
end
