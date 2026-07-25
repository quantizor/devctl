import Foundation

/** launchd administration: install renders the LaunchAgent and bootstraps it;
    upgrades stage-and-rename the binary (overwriting a running signed Mach-O
    gets it SIGKILLed); restart drains, kickstarts, and re-ensures what ran.
    Shared by the CLI and the menu bar app so both can bring the daemon back. */
public enum LaunchdAdmin {
    public static let label = "dev.quantizor.devctl"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /** Menu bar app at the standard install location. When present, agent
        registration must go through SMAppService inside that process. */
    public static var applicationsAppURL: URL {
        URL(fileURLWithPath: SetupPlanner.applicationsAppPath)
    }

    public static func applicationsAppPresent() -> Bool {
        FileManager.default.fileExists(atPath: applicationsAppURL.path)
    }

    /** Ask the menu bar app to register/ensure the SMAppService agent.
        CLI processes cannot call `SMAppService.agent` (wrong `Bundle.main`).
        Prefer `-a /Applications/devctl.app` so a DMG/Downloads copy with the
        same bundle id does not steal the URL. */
    @discardableResult
    public static func requestAppAgentEnsure() -> (status: Int32, output: String) {
        if applicationsAppPresent() {
            return shell(
                "/usr/bin/open", ["-a", applicationsAppURL.path, "devctl://daemon/ensure"])
        }
        return shell("/usr/bin/open", ["devctl://daemon/ensure"])
    }

    /** Ask the menu bar app to unregister the SMAppService agent. */
    @discardableResult
    public static func requestAppAgentUnregister() -> (status: Int32, output: String) {
        if applicationsAppPresent() {
            return shell(
                "/usr/bin/open", ["-a", applicationsAppURL.path, "devctl://daemon/unregister"])
        }
        return shell("/usr/bin/open", ["devctl://daemon/unregister"])
    }

    /** True when launchd currently has our agent in the gui domain. */
    public static func isAgentLoaded() -> Bool {
        shell("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    /** Wait until launchd drops the agent after an unregister, then idle so BTM
        can drop the prior launch constraint. Returns false if the job is still
        loaded after the timeout (and a last-resort bootout); callers must not
        replace the helper in that case. */
    @discardableResult
    public static func waitUntilAgentUnloaded(
        timeoutSeconds: Double = 10,
        settleSeconds: Double = AgentRebindPolicy.settleSeconds
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline, isAgentLoaded() {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if isAgentLoaded() {
            _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            let bootoutDeadline = Date().addingTimeInterval(3)
            while Date() < bootoutDeadline, isAgentLoaded() {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        guard !isAgentLoaded() else { return false }
        if settleSeconds > 0 {
            try? await Task.sleep(for: .seconds(settleSeconds))
        }
        return !isAgentLoaded()
    }

    /** Marker for the Applications copy: settle, then register, after a DMG
        replace that unregistered first. */
    public static func markAgentRebindNeeded(paths: DevCtlPaths = DevCtlPaths()) throws {
        try FileManager.default.createDirectory(
            at: paths.dataDir, withIntermediateDirectories: true)
        try AtomicFile.write(Data(), to: paths.agentRebindFile)
    }

    public static func agentRebindNeeded(paths: DevCtlPaths = DevCtlPaths()) -> Bool {
        FileManager.default.fileExists(atPath: paths.agentRebindFile.path)
    }

    public static func clearAgentRebindMarker(paths: DevCtlPaths = DevCtlPaths()) {
        try? FileManager.default.removeItem(at: paths.agentRebindFile)
    }

    /** True when launchd has the job but is waiting out ThrottleInterval
        (`minimum runtime` defaults to 10s) after a failed spawn. */
    public static func agentSpawnScheduled() -> Bool {
        launchdState().contains("spawn scheduled")
    }

    public static func pollHello(paths: DevCtlPaths, timeoutSeconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: Error = WireError(code: .daemonUnreachable, message: "daemon never answered")
        while Date() < deadline {
            do {
                let client = DaemonClient(socketPath: paths.socketPath)
                _ = try await client.request(
                    .daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)
                return
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        throw lastError
    }

    /** True when `devctl daemon stop` left the deliberate-stop marker. Auto
        bootstrap honors it; an explicit Start clears it. */
    public static func deliberatelyStopped(paths: DevCtlPaths = DevCtlPaths()) -> Bool {
        FileManager.default.fileExists(atPath: paths.stoppedIntentFile.path)
    }

    /** First executable `devctld` among `extraCandidates`, then argv0 sibling,
        `~/.local/bin/devctld`, and the Application Support install path. */
    public static func resolveDaemonBinary(extraCandidates: [URL] = []) -> URL? {
        var candidates = extraCandidates
        let arg0 = URL(fileURLWithPath: CommandLine.arguments[0])
        candidates.append(arg0.deletingLastPathComponent().appending(path: "devctld"))
        candidates.append(SetupPlanner.installedDaemonSiblingURL())
        candidates.append(DevCtlPaths().daemonBinaryDir.appending(path: "devctld"))
        let fm = FileManager.default
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    /** Auto-bootstrap: only against the default socket (never a test override),
        never past a deliberate-stop marker. Prefers the Applications app's
        SMAppService path when present; otherwise kickstarts/installs the
        legacy home LaunchAgent. */
    @discardableResult
    public static func attemptBootstrap(
        paths: DevCtlPaths = DevCtlPaths(),
        extraDaemonCandidates: [URL] = [],
        forceLegacy: Bool = false
    ) async -> Bool {
        guard ProcessInfo.processInfo.environment["DEVCTL_SOCKET"] == nil else { return false }
        guard !deliberatelyStopped(paths: paths) else { return false }
        /** With the app installed it owns registration, so a silent socket is
            answered by waiting, never by installing a second job. Falling through
            to the legacy path here wrote `~/Library/LaunchAgents` back whenever a
            command landed inside launchd's respawn throttle, leaving two jobs
            competing for one label and socket. The wait clears that throttle. */
        if !forceLegacy, applicationsAppPresent() {
            try? writeAgentPath(paths: paths)
            _ = requestAppAgentEnsure()
            return (try? await pollHello(paths: paths, timeoutSeconds: 12)) != nil
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            return (try? await start(paths: paths)) != nil
        }
        guard let binary = resolveDaemonBinary(extraCandidates: extraDaemonCandidates) else {
            return false
        }
        return (try? await install(daemonBinary: binary, paths: paths, forceLegacy: true)) != nil
    }

    /** Explicit user start: clears the stop marker, then kickstarts or installs. */
    public static func startOrInstall(
        paths: DevCtlPaths = DevCtlPaths(),
        extraDaemonCandidates: [URL] = [],
        forceLegacy: Bool = false
    ) async throws {
        try? FileManager.default.removeItem(at: paths.stoppedIntentFile)
        if !forceLegacy, applicationsAppPresent() {
            try writeAgentPath(paths: paths)
            _ = requestAppAgentEnsure()
            try await pollHello(paths: paths, timeoutSeconds: 12)
            return
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try await start(paths: paths)
            return
        }
        guard let binary = resolveDaemonBinary(extraCandidates: extraDaemonCandidates) else {
            throw WireError(
                code: .internalError,
                hint: "run: make install  (or open the setup panel from the DMG)",
                message: "no LaunchAgent and no devctld binary found to install")
        }
        _ = try await install(daemonBinary: binary, paths: paths, forceLegacy: true)
    }

    /** Install (or upgrade) the LaunchAgent. Same bounce contract as restart:
        capture what is running, drain, swap binary + bootstrap, re-ensure. The
        daemon's recoverAtStartup is the reboot path; install cannot rely on it
        alone because a pre-feature state.json may lack resumeOnBoot, and the
        CLI already knows the live names from status. */
    /** Install (or upgrade) the agent. When `/Applications/devctl.app` exists
        and `forceLegacy` is false, asks the app to register via SMAppService
        (correct Bundle.main). Otherwise writes the home LaunchAgent. */
    @discardableResult
    public static func install(
        daemonBinary: URL, paths: DevCtlPaths, forceLegacy: Bool = false
    ) async throws -> [(
        project: String, name: String
    )] {
        let client = DaemonClient(socketPath: paths.socketPath)
        let runningServers = await captureActiveServers(client: client)
        /** Drain through the daemon FIRST: bootout's own kill can outrun the
            SIGTERM drain and orphan server trees mid-escalation. */
        _ = try? await client.request(.daemonShutdown, params: WireEmpty(), expecting: WireEmpty.self)
        for _ in 0..<50 where FileManager.default.fileExists(atPath: paths.socketPath) {
            if (try? await DaemonClient(socketPath: paths.socketPath)
                .request(.daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)) == nil
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? FileManager.default.removeItem(at: paths.stoppedIntentFile)

        if !forceLegacy, applicationsAppPresent() {
            try writeAgentPath(paths: paths)
            /** Leave any legacy home plist for the app to migrate on ensure. */
            _ = requestAppAgentEnsure()
            do {
                try await pollHello(paths: paths, timeoutSeconds: 10)
            } catch {
                /** The app owns registration, so the usual reason for silence is
                    an unapproved background item. Say that instead of a timeout. */
                throw WireError(
                    code: .daemonUnreachable,
                    hint: "open \"x-apple.systempreferences:com.apple.LoginItems-Settings.extension\"",
                    message:
                        "asked \(SetupPlanner.applicationsAppPath) to start devctld, but it never answered. If macOS is waiting for permission, turn on quantizor/devctl in System Settings > General > Login Items & Extensions, or run: devctl daemon install --legacy")
            }
            await reensure(runningServers, paths: paths)
            return runningServers
        }

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
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        let bootstrap = shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        /** A concurrent session bootstrapping first reports already-bootstrapped;
            the socket poll below is the actual success signal. */
        if bootstrap.status != 0, !bootstrap.output.contains("already bootstrapped"),
            !bootstrap.output.contains("Bootstrap failed: 5: Input/output error")
        {
            throw WireError(
                code: .internalError,
                hint: "run: launchctl bootstrap gui/\(getuid()) \(plistURL.path)",
                message: "launchctl bootstrap failed (\(bootstrap.status)): \(bootstrap.output)")
        }
        try await pollHello(paths: paths)
        await reensure(runningServers, paths: paths)
        return runningServers
    }

    public static func uninstall(paths: DevCtlPaths, purge: Bool) async {
        let client = DaemonClient(socketPath: paths.socketPath)
        _ = try? await client.request(.daemonShutdown, params: WireEmpty(), expecting: WireEmpty.self)
        if applicationsAppPresent() {
            _ = requestAppAgentUnregister()
            /** Brief wait so the app can finish SMAppService.unregister. */
            try? await Task.sleep(for: .milliseconds(800))
        }
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        if purge {
            try? FileManager.default.removeItem(at: paths.dataDir)
            try? FileManager.default.removeItem(at: paths.logsDir)
        }
    }

    public static func start(paths: DevCtlPaths) async throws {
        try? FileManager.default.removeItem(at: paths.stoppedIntentFile)
        try? writeAgentPath(paths: paths)
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
    @discardableResult
    public static func restart(paths: DevCtlPaths) async throws -> [(project: String, name: String)] {
        let client = DaemonClient(socketPath: paths.socketPath)
        let runningServers = await captureActiveServers(client: client)
        try? FileManager.default.removeItem(at: paths.stoppedIntentFile)
        let result = shell("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
        if result.status != 0 {
            throw WireError(
                code: .internalError,
                hint: "run: devctl daemon install",
                message: "launchctl kickstart failed (\(result.status)): \(result.output)")
        }
        try await pollHello(paths: paths)
        await reensure(runningServers, paths: paths)
        return runningServers
    }

    public static func captureActiveServers(client: DaemonClient) async -> [(
        project: String, name: String
    )] {
        guard
            let all = try? await client.request(
                .serverStatus, params: ProjectParams(project: ""), expecting: ServerListResult.self)
        else { return [] }
        return all.servers
            .filter { $0.phase == .running || $0.phase == .starting || $0.phase == .unhealthy }
            .map { (project: $0.project, name: $0.server) }
    }

    public static func reensure(
        _ servers: [(project: String, name: String)], paths: DevCtlPaths
    ) async {
        let fresh = DaemonClient(socketPath: paths.socketPath)
        for server in servers {
            _ = try? await fresh.request(
                .serverEnsure,
                params: EnsureParams(name: server.name, project: server.project, timeoutSeconds: 60),
                expecting: EnsureResult.self)
        }
    }

    public static func launchdState() -> String {
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

    /** Floor PATH for sealed in-bundle LaunchAgent plists. Dynamic user PATH
        lives in `agent.path` and is applied by the daemon at start. */
    public static let pathFloor =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /** Captured login-shell PATH so launchd children can find Homebrew/asdf/mise
        tools; launchd agents otherwise get a minimal PATH. Goes stale after a
        Homebrew migration, which doctor surfaces via daemon.info. */
    public static func capturedPath() -> String {
        let result = shell("/bin/zsh", ["-lc", "echo $PATH"])
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? pathFloor : path
    }

    /** Persist the login-shell PATH for the daemon to merge at start. */
    public static func writeAgentPath(
        _ path: String = capturedPath(), paths: DevCtlPaths = DevCtlPaths()
    ) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = trimmed.isEmpty ? pathFloor : trimmed
        try AtomicFile.write(Data(payload.utf8), to: paths.agentPathFile)
    }

    public static func readAgentPath(paths: DevCtlPaths = DevCtlPaths()) -> String? {
        guard let data = try? Data(contentsOf: paths.agentPathFile),
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return text
    }

    /** Apply the persisted PATH into this process before spawning children. */
    public static func applyAgentPathToProcess(paths: DevCtlPaths = DevCtlPaths()) {
        guard let path = readAgentPath(paths: paths) else { return }
        setenv("PATH", path, 1)
    }

    /** LaunchAgent plist for CLI-only installs. AssociatedBundleIdentifiers is
        a best-effort BTM hint; Login Items naming for the app path comes from
        SMAppService + the responsible app's CFBundleDisplayName. Legacy plists
        still bake PATH; the daemon also reads agent.path so both stay in sync. */
    public static func renderPlist(daemonPath: String, paths: DevCtlPaths) -> String {
        let resolvedPath: String
        do {
            try writeAgentPath(paths: paths)
            resolvedPath = readAgentPath(paths: paths) ?? capturedPath()
        } catch {
            resolvedPath = capturedPath()
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AssociatedBundleIdentifiers</key>
            <array>
                <string>dev.quantizor.devctl.app</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>\(resolvedPath)</string>
            </dict>
            <key>ExitTimeOut</key>
            <integer>60</integer>
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
    public static func shell(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
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
