import DevCtlKit
import Foundation

/** launchd administration: install renders the LaunchAgent and bootstraps it;
    upgrades stage-and-rename the binary (overwriting a running signed Mach-O
    gets it SIGKILLed); restart drains, kickstarts, and re-ensures what ran. */
enum LaunchdAdmin {
    static let label = "dev.quantizor.devctl"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /** The devctld binary that ships alongside this devctl binary. */
    static func bundledDaemonBinary() -> URL? {
        let selfPath = URL(fileURLWithPath: CLISelf.path)
        let sibling = selfPath.deletingLastPathComponent().appending(path: "devctld")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    static func install(daemonBinary: URL, paths: DevCtlPaths) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.daemonBinaryDir, withIntermediateDirectories: true)
        let destination = paths.daemonBinaryDir.appending(path: "devctld")
        /** Stage-and-rename: never cp over a running signed binary. */
        let staged = paths.daemonBinaryDir.appending(path: ".devctld.staged-\(getpid())")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: daemonBinary, to: staged)
        _ = try fm.replaceItemAt(destination, withItemAt: staged)
        let plist = renderPlist(daemonPath: destination.path, paths: paths)
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(plist.utf8).write(to: plistURL)
        try? fm.removeItem(at: paths.stoppedIntentFile)
        /** Drain through the daemon FIRST: bootout's own kill can outrun the
            SIGTERM drain and orphan server trees mid-escalation. */
        let client = DaemonClient(socketPath: paths.socketPath)
        _ = try? await client.request(.daemonShutdown, params: WireEmpty(), expecting: WireEmpty.self)
        for _ in 0..<50 where FileManager.default.fileExists(atPath: paths.socketPath) {
            if (try? await DaemonClient(socketPath: paths.socketPath)
                .request(.daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)) == nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? fm.removeItem(at: paths.stoppedIntentFile)
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        let bootstrap = shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        /** A concurrent session bootstrapping first reports already-bootstrapped;
            the socket poll below is the actual success signal. */
        if bootstrap.status != 0, !bootstrap.output.contains("already bootstrapped"),
            !bootstrap.output.contains("Bootstrap failed: 5: Input/output error") {
            throw WireError(
                code: .internalError,
                hint: "run: launchctl bootstrap gui/\(getuid()) \(plistURL.path)",
                message: "launchctl bootstrap failed (\(bootstrap.status)): \(bootstrap.output)")
        }
        try await pollHello(paths: paths)
    }

    static func uninstall(paths: DevCtlPaths, purge: Bool) async {
        let client = DaemonClient(socketPath: paths.socketPath)
        _ = try? await client.request(.daemonShutdown, params: WireEmpty(), expecting: WireEmpty.self)
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        if purge {
            try? FileManager.default.removeItem(at: paths.dataDir)
            try? FileManager.default.removeItem(at: paths.logsDir)
        }
    }

    static func start(paths: DevCtlPaths) async throws {
        try? FileManager.default.removeItem(at: paths.stoppedIntentFile)
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw WireError(
                code: .internalError,
                hint: "run: devctl daemon install",
                message: "no LaunchAgent installed at \(plistURL.path)")
        }
        let result = shell("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(label)"])
        if result.status != 0 {
            _ = shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        }
        try await pollHello(paths: paths)
    }

    /** Drain, kickstart -k, re-ensure what was running: "servers bounce, then
        come back" is the restart contract. */
    static func restart(paths: DevCtlPaths) async throws -> [(project: String, name: String)] {
        let client = DaemonClient(socketPath: paths.socketPath)
        var runningServers: [(project: String, name: String)] = []
        if let all = try? await client.request(
            .serverStatus, params: ProjectParams(project: ""), expecting: ServerListResult.self) {
            runningServers = all.servers
                .filter { $0.phase == .running || $0.phase == .starting || $0.phase == .unhealthy }
                .map { (project: $0.project, name: $0.server) }
        }
        try? FileManager.default.removeItem(at: paths.stoppedIntentFile)
        let result = shell("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
        if result.status != 0 {
            throw WireError(
                code: .internalError,
                hint: "run: devctl daemon install",
                message: "launchctl kickstart failed (\(result.status)): \(result.output)")
        }
        try await pollHello(paths: paths)
        let fresh = DaemonClient(socketPath: paths.socketPath)
        for server in runningServers {
            _ = try? await fresh.request(
                .serverEnsure,
                params: EnsureParams(name: server.name, project: server.project, timeoutSeconds: 60),
                expecting: EnsureResult.self)
        }
        return runningServers
    }

    static func launchdState() -> String {
        let result = shell("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
        if result.status != 0 { return "not bootstrapped" }
        for line in result.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("state =") || trimmed.hasPrefix("pid =") {
                return trimmed
            }
        }
        return "bootstrapped"
    }

    static func pollHello(paths: DevCtlPaths, timeoutSeconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: Error = WireError(code: .daemonUnreachable, message: "daemon never answered")
        while Date() < deadline {
            do {
                let client = DaemonClient(socketPath: paths.socketPath)
                _ = try await client.request(.daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)
                return
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        throw lastError
    }

    /** Captured login-shell PATH so launchd children can find Homebrew/asdf/mise
        tools; launchd agents otherwise get a minimal PATH. Goes stale after a
        Homebrew migration, which doctor surfaces via daemon.info. */
    static func capturedPath() -> String {
        let result = shell("/bin/zsh", ["-lc", "echo $PATH"])
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "/usr/bin:/bin:/usr/sbin:/sbin" : path
    }

    static func renderPlist(daemonPath: String, paths: DevCtlPaths) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>\(capturedPath())</string>
            </dict>
            <key>ExitTimeOut</key>
            <integer>120</integer>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(daemonPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>\(paths.daemonLog.path)</string>
            <key>StandardOutPath</key>
            <string>\(paths.daemonLog.path)</string>
        </dict>
        </plist>
        """
    }

    @discardableResult
    static func shell(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (status: -1, output: String(describing: error))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
