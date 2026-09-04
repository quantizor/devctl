import Foundation

/** Detects a second directa install shadowing the intended one.

    Two shapes, both hit in practice when a `make install` and a Homebrew cask
    coexist. A bare `directa` runs the first match on PATH, and `~/.local/bin`
    sits ahead of brew's bin on a typical PATH, so a manual copy there keeps
    running after a `brew upgrade` changed only Homebrew's copy. Separately,
    Homebrew cannot overwrite a foreign `/Applications/directa.app` it did not
    place, so the menu bar app and its daemon can keep running an old version
    from there.

    `detect` is pure over injected disk facts so it is unit-testable; `scan`
    gathers those facts from disk for `directa doctor`. */
public enum InstallShadow {
    /** A remediable shadowing between two directa installs. */
    public struct Finding: Equatable, Sendable {
        /** What is wrong, in plain terms a non-engineer can read. */
        public let detail: String
        /** The literal command that resolves it. */
        public let remedy: String

        public init(detail: String, remedy: String) {
            self.detail = detail
            self.remedy = remedy
        }
    }

    /** `foreignApp` is set only when an `/Applications/directa.app` exists that
        Homebrew does not own while a Homebrew CLI is installed. `homebrewCLI` is
        the Homebrew cask's CLI path when its symlink is present, else nil.
        `localCLI` is the `make install` CLI in `~/.local/bin` when present, with
        `localDaemon` its sibling daemon. `pathWinner` is the directa a bare
        command resolves to on the user's PATH, when one does. */
    public static func detect(
        foreignApp: String?,
        homebrewCLI: String?,
        localCLI: String?,
        localDaemon: String?,
        pathWinner: String?
    ) -> [Finding] {
        var findings: [Finding] = []
        if let homebrewCLI, let localCLI {
            let runs =
                pathWinner.map { "a bare `directa` runs \($0)" }
                ?? "PATH order decides which one runs"
            let targets = [localCLI, localDaemon].compactMap { $0 }.joined(separator: " ")
            findings.append(
                Finding(
                    detail:
                        "two directa CLIs are installed: Homebrew's at \(homebrewCLI) and a manual copy at \(localCLI), so \(runs) and a `brew upgrade` can change one while the other keeps running",
                    remedy: "rm \(targets)"))
        }
        if let foreignApp {
            findings.append(
                Finding(
                    detail:
                        "\(foreignApp) is not the Homebrew-installed app, so the menu bar app and its background daemon can keep running an old version from it",
                    remedy: "brew reinstall --cask \(DirectaDistribution.homebrewCaskToken)"))
        }
        return findings
    }

    /** Gather the disk facts and run `detect`. Impure (fileExists, PATH, bundle
        ownership); the decision it feeds is the pure `detect` above. Only fires
        when a Homebrew install is present, so a pure `make install` user (whose
        `~/.local/bin` copy and `/Applications` app are both legitimate) is never
        warned. */
    public static func scan(
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        pathEnv: String? = LaunchdAdmin.capturedPath()
    ) -> [Finding] {
        let homebrewCLI =
            SetupPlanner.homebrewPrefixes
            .map { "\($0)/bin/\(SetupPlanner.cliBinaryName)" }
            .first { fileManager.fileExists(atPath: $0) }

        let localCLIURL = SetupPlanner.installedCLIURL(home: home)
        let localCLI = fileManager.fileExists(atPath: localCLIURL.path) ? localCLIURL.path : nil
        let localDaemonURL = SetupPlanner.installedDaemonSiblingURL(home: home)
        let localDaemon =
            fileManager.fileExists(atPath: localDaemonURL.path) ? localDaemonURL.path : nil

        let pathWinner = firstOnPath(
            binary: SetupPlanner.cliBinaryName, pathEnv: pathEnv ?? "", fileManager: fileManager)

        var foreignApp: String?
        let appPath = SetupPlanner.applicationsAppPath
        if homebrewCLI != nil, fileManager.fileExists(atPath: appPath),
            let bundle = Bundle(url: URL(fileURLWithPath: appPath)),
            !SetupPlanner.cliOwner(bundle: bundle, fileManager: fileManager).isHomebrew
        {
            foreignApp = appPath
        }

        return detect(
            foreignApp: foreignApp, homebrewCLI: homebrewCLI, localCLI: localCLI,
            localDaemon: localDaemon, pathWinner: pathWinner)
    }

    /** First `<dir>/<binary>` that exists across the PATH, in PATH order, which is
        what the shell resolves a bare command to. */
    static func firstOnPath(binary: String, pathEnv: String, fileManager: FileManager) -> String? {
        for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
            let candidate = "\(dir)/\(binary)"
            if fileManager.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }
}
