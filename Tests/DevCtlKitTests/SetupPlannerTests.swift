import Foundation
import Testing
@testable import DevCtlKit

@Suite("SetupPlanner")
struct SetupPlannerTests {
    @Test func compareVersionsOrdersSemver() {
        #expect(SetupPlanner.compareVersions("1.0.0", "1.0.1") == .orderedAscending)
        #expect(SetupPlanner.compareVersions("1.2.0", "1.1.9") == .orderedDescending)
        #expect(SetupPlanner.compareVersions("1.2.0", "1.2.0") == .orderedSame)
        #expect(SetupPlanner.compareVersions("", "1.0.0") == .orderedAscending)
        #expect(SetupPlanner.compareVersions("2.0", "2.0.0") == .orderedSame)
    }

    @Test func shouldPresentOnFreshInstall() {
        #expect(
            SetupPlanner.shouldPresent(
                bundledVersion: "1.2.0",
                installedCLIVersion: nil,
                stampVersion: nil,
                resourcesPresent: true))
    }

    @Test func shouldPresentWhenBundledNewerThanStamp() {
        #expect(
            SetupPlanner.shouldPresent(
                bundledVersion: "1.3.0",
                installedCLIVersion: "1.2.0",
                stampVersion: "1.2.0",
                resourcesPresent: true))
    }

    @Test func shouldSkipWhenVersionsMatch() {
        #expect(
            !SetupPlanner.shouldPresent(
                bundledVersion: "1.2.0",
                installedCLIVersion: "1.2.0",
                stampVersion: "1.2.0",
                resourcesPresent: true))
    }

    @Test func shouldPresentWhenRunningOutsideApplicationsEvenIfVersionsMatch() {
        #expect(
            SetupPlanner.shouldPresent(
                bundledVersion: "1.2.0",
                installedCLIVersion: "1.2.0",
                stampVersion: "1.2.0",
                resourcesPresent: true,
                runningOutsideApplications: true))
    }

    @Test func shouldSkipWithoutResources() {
        #expect(
            !SetupPlanner.shouldPresent(
                bundledVersion: "1.2.0",
                installedCLIVersion: nil,
                stampVersion: nil,
                resourcesPresent: false))
        #expect(
            !SetupPlanner.shouldPresent(
                bundledVersion: "1.2.0",
                installedCLIVersion: nil,
                stampVersion: nil,
                resourcesPresent: false,
                runningOutsideApplications: true))
    }

    @Test func isRunningOutsideApplicationsComparesCanonicalPaths() {
        #expect(
            SetupPlanner.isRunningOutsideApplications(
                bundlePath: "/Volumes/devctl/devctl.app"))
        #expect(
            !SetupPlanner.isRunningOutsideApplications(
                bundlePath: SetupPlanner.applicationsAppPath))
    }

    @Test func isMigrationDetectsPriorLayout() {
        #expect(SetupPlanner.isMigration(
            installedCLIExists: true, stampExists: false, launchAgentExists: false))
        #expect(SetupPlanner.isMigration(
            installedCLIExists: false, stampExists: false, launchAgentExists: true))
        #expect(
            !SetupPlanner.isMigration(
                installedCLIExists: false, stampExists: false, launchAgentExists: false))
    }

    @Test func cliDirectoryOnPATH() {
        let dir = SetupPlanner.defaultCLIDirectory(
            home: URL(fileURLWithPath: "/Users/test"))
        #expect(
            SetupPlanner.cliDirectoryOnPATH(
                pathEnv: "/usr/bin:\(dir.path):/bin", cliDirectory: dir))
        #expect(
            !SetupPlanner.cliDirectoryOnPATH(
                pathEnv: "/usr/bin:/bin", cliDirectory: dir))
    }

    /** The PATH a GUI app sees is launchd's, not the shell's, and on a stock
        machine it can never contain `~/.local/bin`. Feeding it to this check
        produced a warning telling the user to add a directory their shell
        already had. This pins the two apart: the launchd default answers false
        for a directory that a user PATH containing it answers true for, so a
        caller that reaches for the process environment again fails here rather
        than shipping a confident wrong warning. */
    @Test func theLaunchdDefaultPathNeverContainsTheCLIDirectory() {
        let dir = SetupPlanner.defaultCLIDirectory(home: URL(fileURLWithPath: "/Users/test"))
        let launchdDefault = "/usr/bin:/bin:/usr/sbin:/sbin"
        #expect(!SetupPlanner.cliDirectoryOnPATH(pathEnv: launchdDefault, cliDirectory: dir))
        #expect(
            SetupPlanner.cliDirectoryOnPATH(
                pathEnv: "\(dir.path):" + launchdDefault, cliDirectory: dir))
    }

    /** The capture has to see what the user's shell sees, and the trap is that
        it looks correct when measured wrong. A shell started from a shell
        inherits its parent's PATH, so the missing entries appear anyway; only an
        empty environment shows what launchd gets. This runs the real capture
        that way, which is the only shape that can fail when `.zshrc` is skipped.

        Asserted against the machine's own answer rather than a fixed list: what
        a developer puts in `.zshrc` is theirs, so the contract is "the capture
        agrees with the user's shell", not "the capture contains pnpm". */
    @Test func theCaptureSeesWhatTheUsersShellSees() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func pathFrom(_ arguments: [String]) throws -> Set<String> {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = arguments
            process.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Set(
                String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: ":").map(String.init))
        }
        let interactive = try pathFrom(["-ilc", "echo $PATH"])
        try withKnownIssue("no .zshrc on this machine, so there is nothing to miss", isIntermittent: true) {
            try #require(FileManager.default.fileExists(atPath: "\(home)/.zshrc"))
        }
        guard FileManager.default.fileExists(atPath: "\(home)/.zshrc") else { return }
        /** The control: login-only must MISS something an interactive shell has,
            or this machine cannot demonstrate the bug and the assertion below
            would pass against the old implementation too. */
        let loginOnly = try pathFrom(["-lc", "echo $PATH"])
        try withKnownIssue(".zshrc adds nothing to PATH here", isIntermittent: true) {
            try #require(!interactive.subtracting(loginOnly).isEmpty)
        }
        guard !interactive.subtracting(loginOnly).isEmpty else { return }
        let captured = Set(LaunchdAdmin.capturedPath().split(separator: ":").map(String.init))
        #expect(interactive.subtracting(captured).isEmpty)
    }

    /** A prefix match would call `/Users/test/.local/binaries` a hit, and a
        substring match would do the same for any path containing the directory's
        name. The check splits on `:` and compares whole components. */
    @Test func aPathComponentMustMatchWholeNotAsAPrefix() {
        let dir = SetupPlanner.defaultCLIDirectory(home: URL(fileURLWithPath: "/Users/test"))
        #expect(
            !SetupPlanner.cliDirectoryOnPATH(
                pathEnv: "\(dir.path)aries:/usr/bin", cliDirectory: dir))
        #expect(
            !SetupPlanner.cliDirectoryOnPATH(
                pathEnv: "/opt\(dir.path):/usr/bin", cliDirectory: dir))
    }

    /** The remedy is handed to someone about to edit a shell profile, so it has
        to name the directory and carry the command rather than describe it. */
    @Test func theRemedyNamesTheDirectoryAndTheCommand() {
        #expect(SetupPlanner.pathRemedy.contains(SetupPlanner.defaultCLIDirectory().path))
        #expect(SetupPlanner.pathRemedy.contains("export PATH="))
        #expect(SetupPlanner.pathRemedy.contains(">> ~/.zprofile"))
    }

    @Test func harnessOffersDefaultCheckedOnlyWhenNeeded() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "devctl-setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(
            at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appending(path: ".cursor"), withIntermediateDirectories: true)

        let cliPath = home.appending(path: ".local/bin/devctl").path
        let offersFresh = SetupPlanner.harnessOffers(home: home, installedCLIPath: cliPath)
        #expect(offersFresh.map(\.harness) == ["claude", "cursor"])
        #expect(offersFresh.allSatisfy { $0.defaultChecked && !$0.alreadyInstalled })

        let claudeSettings = """
            {"hooks":{"SessionStart":[{"hooks":[{"command":"\(cliPath) hook claude-session-start","type":"command"}],"matcher":"startup|resume|clear|compact"}]}}
            """
        try Data(claudeSettings.utf8).write(
            to: home.appending(path: ".claude/settings.json"))
        let cursorSettings = """
            {"hooks":{"sessionStart":[{"command":"\(cliPath) hook cursor-session-start"}]},"version":1}
            """
        try Data(cursorSettings.utf8).write(to: home.appending(path: ".cursor/hooks.json"))

        let offersInstalled = SetupPlanner.harnessOffers(home: home, installedCLIPath: cliPath)
        #expect(offersInstalled.count == 2)
        #expect(offersInstalled.allSatisfy { $0.alreadyInstalled && !$0.defaultChecked })
    }

    @Test func stampRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "devctl-stamp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = root.appending(path: "setup.stamp")
        try SetupPlanner.writeStamp(version: "1.2.0", to: stamp)
        #expect(SetupPlanner.readStamp(at: stamp) == "1.2.0")
    }

    @Test func installBinaryStageAndRename() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "devctl-bin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "src-bin")
        let dest = root.appending(path: "bin/devctl")
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: source)
        try SetupPlanner.installBinary(from: source, to: dest)
        #expect(FileManager.default.isExecutableFile(atPath: dest.path))
        let again = root.appending(path: "src-bin-2")
        try Data("#!/bin/sh\necho v2\n".utf8).write(to: again)
        try SetupPlanner.installBinary(from: again, to: dest)
        let body = try String(contentsOf: dest, encoding: .utf8)
        #expect(body.contains("v2"))
    }

    @Test func installAppBundleReplacesExisting() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "devctl-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appending(path: "Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let source = root.appending(path: "source.app")
        let dest = apps.appending(path: "devctl.app")
        try FileManager.default.createDirectory(
            at: source.appending(path: "Contents"), withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: source.appending(path: "Contents/marker"))
        try FileManager.default.createDirectory(
            at: dest.appending(path: "Contents"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dest.appending(path: "Contents/marker"))
        try SetupPlanner.installAppBundle(from: source, to: dest)
        let body = try String(contentsOf: dest.appending(path: "Contents/marker"), encoding: .utf8)
        #expect(body == "v1")
    }

    @Test func cliOwnerIsHomebrewWhenCaskBundleMatchesRunningBundle() {
        let running = "/Applications/devctl.app"
        let owner = SetupPlanner.resolveCLIOwner(
            runningBundleRealpath: running,
            caskStagedBundles: [
                (prefix: "/opt/homebrew", bundleRealpaths: [running]),
                (prefix: "/usr/local", bundleRealpaths: []),
            ])
        #expect(owner == .homebrew(shim: URL(fileURLWithPath: "/opt/homebrew/bin/devctl")))
        #expect(owner.isHomebrew)
        #expect(owner.cliPath == URL(fileURLWithPath: "/opt/homebrew/bin/devctl"))
        #expect(owner.cliDirectory == URL(fileURLWithPath: "/opt/homebrew/bin"))
    }

    @Test func cliOwnerIsHomebrewUnderIntelPrefix() {
        let running = "/Applications/devctl.app"
        let owner = SetupPlanner.resolveCLIOwner(
            runningBundleRealpath: running,
            caskStagedBundles: [
                (prefix: "/opt/homebrew", bundleRealpaths: []),
                (prefix: "/usr/local", bundleRealpaths: [running]),
            ])
        #expect(owner == .homebrew(shim: URL(fileURLWithPath: "/usr/local/bin/devctl")))
    }

    @Test func cliOwnerFallsBackToDevctlWhenNoCaskMatches() {
        let cliDir = URL(fileURLWithPath: "/Users/x/.local/bin")
        let owner = SetupPlanner.resolveCLIOwner(
            runningBundleRealpath: "/Applications/devctl.app",
            caskStagedBundles: [
                (prefix: "/opt/homebrew", bundleRealpaths: ["/opt/homebrew/Caskroom/other.app"]),
            ],
            cliDirectory: cliDir)
        #expect(owner == .devctl(directory: cliDir))
        #expect(!owner.isHomebrew)
        #expect(owner.cliPath == cliDir.appending(path: "devctl"))
        #expect(owner.cliDirectory == cliDir)
    }

    @Test func pathCheckIsSatisfiedForBrewOwnerOnDefaultPATH() {
        /** brew's bin is on the login PATH via `brew shellenv`, so a brew owner's
            directory is found and no warning fires. */
        let brew = CLIOwner.homebrew(shim: URL(fileURLWithPath: "/opt/homebrew/bin/devctl"))
        #expect(
            SetupPlanner.cliDirectoryOnPATH(
                pathEnv: "/opt/homebrew/bin:/usr/bin:/bin", cliDirectory: brew.cliDirectory))
        let local = CLIOwner.devctl(directory: URL(fileURLWithPath: "/Users/x/.local/bin"))
        #expect(
            !SetupPlanner.cliDirectoryOnPATH(
                pathEnv: "/opt/homebrew/bin:/usr/bin:/bin", cliDirectory: local.cliDirectory))
    }
}
