import AppKit
import DevCtlKit
import Foundation

/** Performs first-run / upgrade install from the app bundle Resources. Copies
    the app into /Applications when needed, installs CLI + daemon, then optional
    harness hooks. File I/O is nonisolated; quitting peers / relaunch is MainActor. */
enum SetupPerformer: Sendable {
    static let appBundleIdentifier = "dev.quantizor.devctl.app"

    struct Result: Sendable {
        var cliOnPATH: Bool
        var harnessSummaries: [String]
        var migration: Bool
        var notes: [String]
        var relocatedToApplications: Bool
    }

    struct Presentation: Sendable {
        var installAppToApplications: Bool
        var migration: Bool
        var offers: [HarnessOffer]
        var pathWarning: Bool
        var replacingApplicationsApp: Bool
        var shouldPresent: Bool
    }

    enum Failure: Error, LocalizedError, Sendable {
        case missingResources
        case commandFailed(command: String, status: Int32, output: String)
        case appInstallFailed(String)
        case agentRegisterFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingResources:
                return "This copy of devctl.app is missing its bundled CLI and daemon. Reinstall from the DMG or run make app."
            case .commandFailed(let command, let status, let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    return "\(command) failed (exit \(status))."
                }
                return "\(command) failed (exit \(status)): \(detail)"
            case .appInstallFailed(let message):
                return message
            case .agentRegisterFailed(let message):
                return message
            }
        }
    }

    nonisolated static func resourceURLs(bundle: Bundle = .main) -> (cli: URL, daemon: URL)? {
        guard let cli = bundle.url(forResource: SetupPlanner.resourceCLIName, withExtension: nil),
            let daemon = bundle.url(forResource: SetupPlanner.resourceDaemonName, withExtension: nil),
            FileManager.default.isExecutableFile(atPath: cli.path),
            FileManager.default.isExecutableFile(atPath: daemon.path)
        else { return nil }
        return (cli, daemon)
    }

    nonisolated static func bundledVersion(bundle: Bundle = .main) -> String {
        if let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            !short.isEmpty
        {
            return short
        }
        return DevCtlVersion.version
    }

    nonisolated static func evaluatePresentation(
        bundle: Bundle = .main, paths: DevCtlPaths = DevCtlPaths()
    ) -> Presentation {
        let resources = resourceURLs(bundle: bundle) != nil
        let bundled = bundledVersion(bundle: bundle)
        let cliURL = SetupPlanner.installedCLIURL()
        let installedVersion = readCLIVersion(at: cliURL)
        let stamp = SetupPlanner.readStamp(at: SetupPlanner.stampURL(paths: paths))
        let outside = SetupPlanner.isRunningOutsideApplications(
            bundlePath: bundle.bundleURL.path)
        let should = SetupPlanner.shouldPresent(
            bundledVersion: bundled,
            installedCLIVersion: installedVersion,
            stampVersion: stamp,
            resourcesPresent: resources,
            runningOutsideApplications: outside)
        let agentPlist = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/dev.quantizor.devctl.plist")
        let migration = SetupPlanner.isMigration(
            installedCLIExists: FileManager.default.isExecutableFile(atPath: cliURL.path),
            stampExists: stamp != nil,
            launchAgentExists: FileManager.default.fileExists(atPath: agentPlist.path))
        let offers = SetupPlanner.harnessOffers(installedCLIPath: cliURL.path)
        let pathWarning = !SetupPlanner.cliDirectoryOnPATH(
            pathEnv: ProcessInfo.processInfo.environment["PATH"])
        return Presentation(
            installAppToApplications: outside,
            migration: migration,
            offers: offers,
            pathWarning: pathWarning,
            replacingApplicationsApp: outside && SetupPlanner.applicationsAppExists(),
            shouldPresent: should)
    }

    /** Install app (when needed), CLI, register the SMAppService agent from
        this process when the bundle can host it, then checked hooks.
        Call `quitOtherInstances` on the MainActor before this when relocating. */
    nonisolated static func run(
        selectedHarnesses: Set<String>,
        installAppToApplications: Bool,
        bundle: Bundle = .main
    ) async throws -> Result {
        guard let resources = resourceURLs(bundle: bundle) else { throw Failure.missingResources }
        let paths = DevCtlPaths()
        let cliDest = SetupPlanner.installedCLIURL()
        let daemonSibling = SetupPlanner.installedDaemonSiblingURL()
        let fm = FileManager.default
        let migration = SetupPlanner.isMigration(
            installedCLIExists: fm.isExecutableFile(atPath: cliDest.path),
            stampExists: SetupPlanner.readStamp(at: SetupPlanner.stampURL(paths: paths)) != nil,
            launchAgentExists: fm.fileExists(
                atPath: fm.homeDirectoryForCurrentUser
                    .appending(path: "Library/LaunchAgents/dev.quantizor.devctl.plist").path))

        var notes: [String] = []
        var relocated = false

        /** Running setup is intent to run the daemon, so a leftover
            deliberate-stop marker from an earlier `daemon stop` / uninstall must
            not suppress registration (in the relocated case the Applications
            copy reads this marker at launch, long after this process is gone). */
        try? fm.removeItem(at: paths.stoppedIntentFile)

        if installAppToApplications {
            let destination = URL(fileURLWithPath: SetupPlanner.applicationsAppPath)
            let replacing = fm.fileExists(atPath: destination.path)
            do {
                try SetupPlanner.installAppBundle(from: bundle.bundleURL, to: destination)
            } catch {
                throw Failure.appInstallFailed(
                    "Could not place the app at \(destination.path): \(error.localizedDescription). Quit any open copy of devctl and try again.")
            }
            relocated = true
            notes.append(
                replacing
                    ? "Updated the menu bar app at \(destination.path)."
                    : "Installed the menu bar app at \(destination.path).")
        }

        if migration {
            notes.append("Migrating the existing CLI and daemon to this version.")
        }

        try SetupPlanner.installBinary(from: resources.cli, to: cliDest)
        try SetupPlanner.installBinary(from: resources.daemon, to: daemonSibling)
        notes.append("Installed CLI to \(cliDest.path)")

        /** SMAppService must run with Bundle.main as the hosting app. After a
            relocate, the Applications copy registers on launch; otherwise do it
            here (and reregister on upgrade so the helper/plist swap sticks). */
        if !relocated {
            do {
                try LaunchdAdmin.writeAgentPath(paths: paths)
                if migration {
                    try await AgentService.reregister()
                } else {
                    try AgentService.register()
                }
                try await LaunchdAdmin.pollHello(paths: paths, timeoutSeconds: 8)
                notes.append("Daemon registered via Login Items.")
            } catch AgentService.Failure.needsApproval {
                /** Not a failed install: the job is registered and one switch
                    away from running, and Login Items is already open. */
                notes.append(AgentService.Failure.needsApproval.localizedDescription)
            } catch {
                throw Failure.agentRegisterFailed(
                    "Could not register the background agent: \(error.localizedDescription). Check System Settings > General > Login Items & Extensions.")
            }
        } else {
            notes.append(
                "The copy in Applications registers the daemon when it launches. If macOS asks, allow quantizor/devctl in Login Items.")
        }

        var harnessSummaries: [String] = []
        for harness in selectedHarnesses.sorted() {
            let out = try runCLI(cliDest, arguments: ["hook", "install", "--harness", harness])
            harnessSummaries.append(out.isEmpty ? "Installed \(harness) hook" : out)
        }

        try SetupPlanner.writeStamp(
            version: bundledVersion(bundle: bundle), to: SetupPlanner.stampURL(paths: paths))

        let onPATH = SetupPlanner.cliDirectoryOnPATH(
            pathEnv: ProcessInfo.processInfo.environment["PATH"])
        if !onPATH {
            notes.append(
                "\(SetupPlanner.defaultCLIDirectory().path) is not on your PATH. Add it so shells and agents can find `devctl`.")
        }

        return Result(
            cliOnPATH: onPATH,
            harnessSummaries: harnessSummaries,
            migration: migration,
            notes: notes,
            relocatedToApplications: relocated)
    }

    /** Quit every other running copy so /Applications/devctl.app can be replaced. */
    @MainActor
    static func quitOtherInstances() async {
        let peers = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == appBundleIdentifier && $0 != .current
        }
        for app in peers {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let still = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == appBundleIdentifier && $0 != .current
            }
            if !still { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == appBundleIdentifier && app != .current {
            app.forceTerminate()
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    /** Open the Applications copy and quit this (DMG/Downloads) process. Quitting
        is conditional: Launch Services treats the DMG and Applications copies as
        the same app (shared bundle id), so `openApplication` can return *this*
        process as a "success". We only quit once a different pid is running from
        the Applications path. */
    @MainActor
    static func relaunchFromApplicationsAndQuit() {
        let url = URL(fileURLWithPath: SetupPlanner.applicationsAppPath)
        let appsPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        /** Force a new instance: without this, openApplication often "succeeds"
            by activating the already-running DMG copy (same bundle id). */
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            Task { @MainActor in
                if let error {
                    DevCtlLog.app.error(
                        "relaunch from \(SetupPlanner.applicationsAppPath) failed: \(error.localizedDescription)")
                    return
                }
                let launchedPath = app?.bundleURL?
                    .resolvingSymlinksInPath().standardizedFileURL.path
                let differentProcess = (app?.processIdentifier).map { $0 != selfPID } ?? false
                if differentProcess, launchedPath == appsPath {
                    NSApp.terminate(nil)
                    return
                }
                DevCtlLog.app.info(
                    "openApplication returned self or wrong path; waiting for Applications peer")
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    let peer = NSWorkspace.shared.runningApplications.first { running in
                        guard running.bundleIdentifier == appBundleIdentifier else { return false }
                        guard running.processIdentifier != selfPID else { return false }
                        let path = running.bundleURL?
                            .resolvingSymlinksInPath().standardizedFileURL.path
                        return path == appsPath
                    }
                    if peer != nil {
                        NSApp.terminate(nil)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                /** Last resort: `open(1)` bypasses some LS same-bundle shortcuts. */
                let open = LaunchdAdmin.shell("/usr/bin/open", [SetupPlanner.applicationsAppPath])
                if open.status == 0 {
                    let openDeadline = Date().addingTimeInterval(5)
                    while Date() < openDeadline {
                        let peer = NSWorkspace.shared.runningApplications.contains { running in
                            guard running.bundleIdentifier == appBundleIdentifier else {
                                return false
                            }
                            guard running.processIdentifier != selfPID else { return false }
                            let path = running.bundleURL?
                                .resolvingSymlinksInPath().standardizedFileURL.path
                            return path == appsPath
                        }
                        if peer {
                            NSApp.terminate(nil)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                DevCtlLog.app.error(
                    "could not hand off to \(SetupPlanner.applicationsAppPath); staying alive so setup is not lost")
            }
        }
    }

    nonisolated private static func readCLIVersion(at url: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    nonisolated private static func runCLI(_ cli: URL, arguments: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = cli
        proc.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw Failure.commandFailed(
                command: ([cli.path] + arguments).joined(separator: " "),
                status: -1,
                output: error.localizedDescription)
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""
        let combined = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard proc.terminationStatus == 0 else {
            throw Failure.commandFailed(
                command: ([cli.path] + arguments).joined(separator: " "),
                status: proc.terminationStatus,
                output: combined)
        }
        return combined
    }
}
