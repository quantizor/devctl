import DevCtlKit
import Darwin
import Foundation

/** Absolute path of this running `devctl` binary. Prefer over
    CommandLine.arguments[0], which is often a bare PATH name and would resolve
    relative to cwd (breaking `hook install` when invoked as `devctl` from a
    project directory). */
enum CLISelf {
    static var path: String {
        if let raw = dyldExecutablePath() {
            return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        }
        return fallbackPath()
    }

    /** The devctld that shipped alongside this devctl; the preferred install
        source because it is version-matched to this binary. */
    static var daemonSibling: URL {
        URL(fileURLWithPath: path).deletingLastPathComponent().appending(path: "devctld")
    }

    /** Standard 2-call `_NSGetExecutablePath`: query size, then fill. */
    private static func dyldExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        let end = buf.firstIndex(of: 0) ?? buf.endIndex
        let bytes = buf[..<end].map { UInt8(bitPattern: $0) }
        let raw = String(decoding: bytes, as: UTF8.self)
        return raw.isEmpty ? nil : raw
    }

    /** Last resort when dyld refuses: absolute arg0, else first PATH hit. */
    private static func fallbackPath() -> String {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") {
            return URL(fileURLWithPath: arg0).resolvingSymlinksInPath().path
        }
        let name = URL(fileURLWithPath: arg0).lastPathComponent
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: String(dir)).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.resolvingSymlinksInPath().path
            }
        }
        return URL(fileURLWithPath: arg0).resolvingSymlinksInPath().path
    }
}

/** The harness-agnostic context primitive: a fenced plain-text block any agent
    harness can inject into a session. Prints nothing for unregistered or
    untrusted projects and never bootstraps the daemon (a session start must stay
    fast and side-effect free). Raw log lines and command strings never appear
    here: child output and committed configs are attacker-influenceable. */
enum AgentContext {
    static let maxLength = 2400

    static func render(project: String) async -> String? {
        let client = DaemonClient(socketPath: DevCtlPaths().socketPath)
        guard
            let list = try? await client.request(
                .serverStatus, params: ProjectParams(project: project), expecting: ServerListResult.self),
            list.trusted == true,
            !list.servers.isEmpty
        else { return nil }
        var lines: [String] = []
        lines.append("<devctl-servers>")
        lines.append(
            "This project's dev servers are managed by devctl (daemon-supervised; they and their logs survive session compaction and restarts). Prefer devctl over launching servers directly.")
        for server in list.servers {
            var parts = ["- \(server.server): \(server.phase.rawValue)"]
            if let url = server.url { parts.append(url) }
            if let heads = server.heads, !heads.isEmpty {
                let list = heads.sorted { $0.key < $1.key }
                    .map { "\($0.key) \($0.value)" }
                    .joined(separator: ", ")
                parts.append("heads: \(list)")
            }
            if let port = server.observedPort ?? server.declaredPort { parts.append("port \(port)") }
            if let exit = server.lastExit, server.phase == .crashed {
                let cause = exit.code.map { "exit \($0)" } ?? exit.signal.map { "signal \($0)" } ?? "unknown"
                parts.append("last exit \(cause) at \(JSONCoding.formatISO8601(exit.at))")
            }
            parts.append("log \(server.logPath)")
            lines.append(parts.joined(separator: " · "))
        }
        lines.append(
            "Useful: devctl ensure <name> (idempotent start) · devctl wait <name> --healthy · devctl why <name> (root cause) · devctl logs <name> --since-mark <id> --json · devctl mark <name> \"text\" · devctl events --since 10m. All support --json.")
        lines.append(
            "While you work, monitor devctl itself: if it misbehaves, surprises you, or a missing capability slows you down, flag it (a line in ~/code/devctl/BACKLOG.md, or tell the user) rather than silently working around it.")
        lines.append("</devctl-servers>")
        let text = lines.joined(separator: "\n")
        return text.count > maxLength ? String(text.prefix(maxLength)) + "\n</devctl-servers>" : text
    }
}

/** A harness adapter owns one agent harness's settings format and injection
    mechanism. Adding a harness = one new conformer + a registry entry (see
    CONTRIBUTING.md). The context payload itself is harness-agnostic. */
protocol HarnessAdapter: Sendable {
    /** Idempotently wires the session hook into the harness's settings. Returns
        a human summary of what changed. */
    func install(devctlPath: String) throws -> String
    var name: String { get }
}

let harnessAdapters: [any HarnessAdapter] = [ClaudeCodeAdapter(), CursorAdapter()]

/** Resolve the project directory a session-start hook should introspect. Cursor
    hooks carry workspace_roots (and CURSOR_PROJECT_DIR); Claude Code carries cwd.
    Fall back to the process cwd when the payload is empty or malformed. */
enum HookSessionCwd {
    static func resolve(stdin: Data) -> String {
        if let payload = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any] {
            if let roots = payload["workspace_roots"] as? [String], let first = roots.first,
                !first.isEmpty
            {
                return first
            }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { return cwd }
        }
        if let env = ProcessInfo.processInfo.environment["CURSOR_PROJECT_DIR"], !env.isEmpty {
            return env
        }
        return FileManager.default.currentDirectoryPath
    }
}

/** Claude Code: SessionStart hook with the compact matcher (fires right after
    compaction, exactly when agents forget), merged into user settings without
    clobbering existing hooks. */
struct ClaudeCodeAdapter: HarnessAdapter {
    let name = "claude"

    var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
    }

    func install(devctlPath: String) throws -> String {
        let command = "\(devctlPath) hook claude-session-start"
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var sessionStart = hooks["SessionStart"] as? [[String: Any]] ?? []
        if let repaired = repairClaudeSessionStart(sessionStart: &sessionStart, command: command) {
            hooks["SessionStart"] = sessionStart
            settings["hooks"] = hooks
            try writeSettings(settings)
            return repaired
        }
        let alreadyInstalled = sessionStart.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains { hook in
                (hook["command"] as? String) == command
            }
        }
        if alreadyInstalled {
            return "Claude Code SessionStart hook already installed (\(settingsURL.path))"
        }
        sessionStart.append([
            "hooks": [["command": command, "type": "command"]],
            "matcher": "startup|resume|clear|compact",
        ])
        hooks["SessionStart"] = sessionStart
        settings["hooks"] = hooks
        try writeSettings(settings)
        return "Claude Code SessionStart hook installed (matcher startup|resume|clear|compact) in \(settingsURL.path)"
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsURL)
    }

    /** Rewrite a prior install whose command path no longer resolves (e.g. a
        bare `devctl` that was resolved relative to cwd at install time). */
    private func repairClaudeSessionStart(sessionStart: inout [[String: Any]], command: String)
        -> String?
    {
        var changed = false
        for i in sessionStart.indices {
            guard var entryHooks = sessionStart[i]["hooks"] as? [[String: Any]] else { continue }
            for j in entryHooks.indices {
                guard let existing = entryHooks[j]["command"] as? String,
                    existing.contains("devctl hook claude-session-start"),
                    existing != command
                else { continue }
                entryHooks[j]["command"] = command
                changed = true
            }
            if changed { sessionStart[i]["hooks"] = entryHooks }
        }
        return changed
            ? "Claude Code SessionStart hook path repaired in \(settingsURL.path)" : nil
    }
}

/** Cursor: sessionStart hook merged into ~/.cursor/hooks.json without clobbering
    existing entries. Emits {additional_context} (snake_case; Cursor's schema). */
struct CursorAdapter: HarnessAdapter {
    let name = "cursor"

    var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cursor/hooks.json")
    }

    func install(devctlPath: String) throws -> String {
        let command = "\(devctlPath) hook cursor-session-start"
        var settings: [String: Any] = ["version": 1]
        if let data = try? Data(contentsOf: settingsURL),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            settings = parsed
            if settings["version"] == nil { settings["version"] = 1 }
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var sessionStart = hooks["sessionStart"] as? [[String: Any]] ?? []
        if let repaired = repairCursorSessionStart(sessionStart: &sessionStart, command: command) {
            hooks["sessionStart"] = sessionStart
            settings["hooks"] = hooks
            try writeSettings(settings)
            return repaired
        }
        let alreadyInstalled = sessionStart.contains { entry in
            (entry["command"] as? String) == command
        }
        if alreadyInstalled {
            return "Cursor sessionStart hook already installed (\(settingsURL.path))"
        }
        sessionStart.append(["command": command])
        hooks["sessionStart"] = sessionStart
        settings["hooks"] = hooks
        try writeSettings(settings)
        return "Cursor sessionStart hook installed in \(settingsURL.path)"
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsURL)
    }

    private func repairCursorSessionStart(sessionStart: inout [[String: Any]], command: String)
        -> String?
    {
        var changed = false
        for i in sessionStart.indices {
            guard let existing = sessionStart[i]["command"] as? String,
                existing.contains("devctl hook cursor-session-start"),
                existing != command
            else { continue }
            sessionStart[i]["command"] = command
            changed = true
        }
        return changed ? "Cursor sessionStart hook path repaired in \(settingsURL.path)" : nil
    }
}
