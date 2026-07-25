import Foundation

/** First-run / upgrade planning for the menu bar app installer. Pure decisions
    only: the app performs copies and shells out to the installed CLI. Layout
    matches `make install` (`~/.local/bin`) so DMG and source installs converge. */
public enum SetupPlanner {
    public static let applicationsAppPath = "/Applications/devctl.app"
    public static let cliBinaryName = "devctl"
    public static let daemonBinaryName = "devctld"
    public static let resourceCLIName = "devctl"
    public static let resourceDaemonName = "devctld"
    public static let stampFileName = "setup.stamp"

    /** Canonical CLI directory shared with `make install` (`PREFIX/bin`). */
    public static func defaultCLIDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> URL
    {
        home.appending(path: ".local/bin")
    }

    public static func stampURL(paths: DevCtlPaths) -> URL {
        paths.dataDir.appending(path: stampFileName)
    }

    public static func installedCLIURL(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> URL
    {
        defaultCLIDirectory(home: home).appending(path: cliBinaryName)
    }

    public static func installedDaemonSiblingURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        defaultCLIDirectory(home: home).appending(path: daemonBinaryName)
    }

    /** Semver-ish compare: `"1.2.0"`, optionally with a trailing build label.
        Missing/unparseable sides sort as older than a concrete version. */
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = parseVersion(lhs)
        let right = parseVersion(rhs)
        if left.isEmpty && right.isEmpty { return .orderedSame }
        if left.isEmpty { return .orderedAscending }
        if right.isEmpty { return .orderedDescending }
        let count = max(left.count, right.count)
        for i in 0..<count {
            let a = i < left.count ? left[i] : 0
            let b = i < right.count ? right[i] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }

    /** Whether the setup / upgrade panel should appear. */
    public static func shouldPresent(
        bundledVersion: String,
        installedCLIVersion: String?,
        stampVersion: String?,
        resourcesPresent: Bool,
        runningOutsideApplications: Bool = false
    ) -> Bool {
        guard resourcesPresent else { return false }
        /** Opening from a DMG or Downloads always offers install: the app must
            land in /Applications so login items and deep links keep working. */
        if runningOutsideApplications { return true }
        if stampVersion == nil { return true }
        if installedCLIVersion == nil { return true }
        if let installed = installedCLIVersion,
            compareVersions(bundledVersion, installed) == .orderedDescending
        {
            return true
        }
        if let stamped = stampVersion,
            compareVersions(bundledVersion, stamped) == .orderedDescending
        {
            return true
        }
        return false
    }

    /** True when this process is not already `/Applications/devctl.app`. */
    public static func isRunningOutsideApplications(bundlePath: String) -> Bool {
        let running = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath()
            .standardizedFileURL.path
        let apps = URL(fileURLWithPath: applicationsAppPath).resolvingSymlinksInPath()
            .standardizedFileURL.path
        return running != apps
    }

    /** True when an on-disk CLI or LaunchAgent-era install already exists. */
    public static func isMigration(
        installedCLIExists: Bool,
        stampExists: Bool,
        launchAgentExists: Bool
    ) -> Bool {
        installedCLIExists || stampExists || launchAgentExists
    }

    /** True when /Applications already has a copy (replace vs first place). */
    public static func applicationsAppExists(
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: applicationsAppPath)
    }

    /** Detect agent harnesses and whether their hooks still need installing. */
    public static func harnessOffers(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        installedCLIPath: String
    ) -> [HarnessOffer] {
        var offers: [HarnessOffer] = []
        let claudeDir = home.appending(path: ".claude")
        if FileManager.default.fileExists(atPath: claudeDir.path) {
            let installed = HookPresence.claudeHookInstalled(
                settingsURL: claudeDir.appending(path: "settings.json"),
                expectedCLIPath: installedCLIPath)
            offers.append(
                HarnessOffer(
                    alreadyInstalled: installed,
                    defaultChecked: !installed,
                    displayName: "Claude Code",
                    harness: "claude"))
        }
        let cursorDir = home.appending(path: ".cursor")
        if FileManager.default.fileExists(atPath: cursorDir.path) {
            let installed = HookPresence.cursorHookInstalled(
                settingsURL: cursorDir.appending(path: "hooks.json"),
                expectedCLIPath: installedCLIPath)
            offers.append(
                HarnessOffer(
                    alreadyInstalled: installed,
                    defaultChecked: !installed,
                    displayName: "Cursor",
                    harness: "cursor"))
        }
        return offers.sorted { $0.harness < $1.harness }
    }

    /** Whether `~/.local/bin` appears on PATH (split on `:`). */
    public static func cliDirectoryOnPATH(
        pathEnv: String?,
        cliDirectory: URL = defaultCLIDirectory()
    ) -> Bool {
        let needle = cliDirectory.path
        let path = pathEnv ?? ""
        return path.split(separator: ":").contains { String($0) == needle }
    }

    /** Read a prior setup stamp (plain version string). */
    public static func readStamp(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /** Persist the installed bundled version after a successful setup. */
    public static func writeStamp(version: String, to url: URL) throws {
        try AtomicFile.write(Data("\(version)\n".utf8), to: url)
    }

    /** Stage-and-rename a Mach-O into place (never overwrite a running signed binary). */
    public static func installBinary(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).staged-\(getpid())")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: staged.path)
        _ = try fm.replaceItemAt(destination, withItemAt: staged)
    }

    /** Stage-and-replace an .app bundle into /Applications (or `destination`).
        Caller must quit any process still holding the destination first. */
    public static func installAppBundle(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).staged-\(getpid())")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        clearQuarantine(at: staged)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
        clearQuarantine(at: destination)
    }

    /** Drop the DMG/Downloads quarantine so Gatekeeper trusts the Applications copy. */
    private static func clearQuarantine(at url: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        proc.arguments = ["-dr", "com.apple.quarantine", url.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func parseVersion(_ raw: String) -> [Int] {
        let head = raw.split(separator: " ", maxSplits: 1).first.map(String.init) ?? raw
        let numeric = head.split(separator: "-").first.map(String.init) ?? head
        return numeric.split(separator: ".").compactMap { Int($0) }
    }
}

/** One harness row on the first-run panel. */
public struct HarnessOffer: Equatable, Sendable {
    public var alreadyInstalled: Bool
    public var defaultChecked: Bool
    public var displayName: String
    public var harness: String

    public init(
        alreadyInstalled: Bool,
        defaultChecked: Bool,
        displayName: String,
        harness: String
    ) {
        self.alreadyInstalled = alreadyInstalled
        self.defaultChecked = defaultChecked
        self.displayName = displayName
        self.harness = harness
    }
}

/** Lightweight read of harness settings to decide checkbox defaults. Mirrors the
    CLI adapters' "already installed" checks without writing. */
enum HookPresence {
    static func claudeHookInstalled(settingsURL: URL, expectedCLIPath: String) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = settings["hooks"] as? [String: Any],
            let sessionStart = hooks["SessionStart"] as? [[String: Any]]
        else { return false }
        let expected = "\(expectedCLIPath) hook claude-session-start"
        return sessionStart.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains { hook in
                let command = hook["command"] as? String ?? ""
                return command == expected || command.contains("devctl hook claude-session-start")
            }
        }
    }

    static func cursorHookInstalled(settingsURL: URL, expectedCLIPath: String) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = settings["hooks"] as? [String: Any],
            let sessionStart = hooks["sessionStart"] as? [[String: Any]]
        else { return false }
        let expected = "\(expectedCLIPath) hook cursor-session-start"
        return sessionStart.contains { entry in
            let command = entry["command"] as? String ?? ""
            return command == expected || command.contains("devctl hook cursor-session-start")
        }
    }
}
