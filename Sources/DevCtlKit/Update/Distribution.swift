import Foundation

/** One home for the strings that identify where devctl is published and how it
    updates, shared by the app, the CLI, and the update check so a rename touches
    a single place. */
public enum DevCtlDistribution: Sendable {
    /** The Homebrew tap cask, fully qualified so `brew` trusts this one cask
        rather than the whole tap. */
    public static let homebrewCaskToken = "quantizor/tap/devctl"

    /** Human-facing releases page, offered to non-Homebrew installs. */
    public static let releasesLatestURL = "https://github.com/quantizor/devctl/releases/latest"

    /** GitHub API for the newest non-prerelease, used by the update check. */
    public static let latestReleaseAPIURL =
        "https://api.github.com/repos/quantizor/devctl/releases/latest"

    /** The command an in-app control runs in Terminal to upgrade a cask install. */
    public static var brewUpgradeCommand: String {
        "brew upgrade --cask \(homebrewCaskToken)"
    }

    /** The command an in-app control runs in Terminal to fully remove a cask
        install, including devctl's own data via `zap`. */
    public static var brewUninstallCommand: String {
        "brew uninstall --cask --zap \(homebrewCaskToken)"
    }
}
