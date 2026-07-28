import ArgumentParser
import DevCtlKit
import Foundation

/** devctl: the CLI. Agents are the primary consumer: every command supports
    --json with schemas documented in docs/cli-contract.md, and failures emit the
    error envelope on stdout so agents never scrape stderr prose. */
@main
struct DevCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devctl",
        abstract: "Command center for local dev servers.",
        version: DevCtlVersion.version,
        subcommands: [
            ConfigCommand.self, Context.self, Doctor.self, Down.self, Ensure.self, Events.self,
            HookCommand.self, Link.self, Logs.self, Mark.self, Open.self, Register.self, Start.self,
            Lock.self, Statusline.self, Status.self, Stop.self, Switch.self, Trust.self, Unregister.self, Up.self,
            Wait.self, Why.self, XURL.self, DaemonCommand.self,
        ]
    )
}

struct GlobalOptions: ParsableArguments {
    @Flag(help: "Emit machine-readable JSON (schemas: docs/cli-contract.md).")
    var json = false

    @Flag(help: "Never auto-install or auto-start the daemon on connection failure.")
    var noBootstrap = false

    @Option(help: "Project root; defaults to the nearest devservers.json ancestor, then git root, then cwd.")
    var project: String?

    /** Resolution order: nearest ancestor with devservers.json → git root → cwd,
        then canonicalized (symlinks and on-disk case). A git worktree is a real
        distinct path and keeps its own project identity; canonicalization does
        not collapse sibling checkouts into one. */
    func resolvedProject() -> String {
        if let project { return canonicalProjectPath(project) }
        return Self.resolveProject(from: FileManager.default.currentDirectoryPath)
    }

    static func resolveProject(from cwd: String) -> String {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: cwd)
        while true {
            if fm.fileExists(atPath: probe.appending(path: "devservers.json").path) {
                return canonicalProjectPath(probe.path)
            }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        var gitProbe = URL(fileURLWithPath: cwd)
        while true {
            if fm.fileExists(atPath: gitProbe.appending(path: ".git").path) {
                return canonicalProjectPath(gitProbe.path)
            }
            let parent = gitProbe.deletingLastPathComponent()
            if parent.path == gitProbe.path { break }
            gitProbe = parent
        }
        return canonicalProjectPath(cwd)
    }
}

/** Shared client construction + error rendering. Exit codes: 0 ok, 1 operation
    failed, 2 usage, 3 daemon unreachable, 4 named server not found. */
enum CLIRunner {
    static func client() -> DaemonClient {
        DaemonClient(socketPath: DevCtlPaths().socketPath)
    }

    static func emit<T: Codable>(_ value: T, json: Bool, human: (T) -> String) {
        if json {
            let payload = (try? JSONCoding.encoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
            print(payload ?? "{}")
        } else {
            print(human(value))
        }
    }

    static func fail(_ error: WireError, json: Bool) -> Never {
        if json {
            struct Envelope: Codable {
                var error: WireError
                var ok: Bool
            }
            let payload = (try? JSONCoding.encoder().encode(Envelope(error: error, ok: false)))
                .flatMap { String(data: $0, encoding: .utf8) }
            print(payload ?? #"{"ok":false}"#)
        } else {
            var text = "devctl: \(error.message)"
            if let hint = error.hint { text += "\n  \(hint)" }
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }
        switch error.code {
        case .daemonUnreachable, .versionMismatch:
            Foundation.exit(3)
        case .notFound:
            Foundation.exit(4)
        case .usage:
            Foundation.exit(2)
        case .configInvalid, .internalError, .notTrusted, .portDrift, .portHeld, .resourceLocked,
            .spawnFailed:
            Foundation.exit(1)
        }
    }

    static func run<R: Codable & Sendable>(
        json: Bool,
        bootstrap: Bool = true,
        _ body: (DaemonClient) async throws -> R
    ) async -> R {
        do {
            return try await body(client())
        } catch let error as WireError where error.code == .daemonUnreachable && bootstrap {
            if await attemptBootstrap() {
                do {
                    return try await body(client())
                } catch let retryError as WireError {
                    fail(retryError, json: json)
                } catch {
                    fail(WireError(code: .internalError, message: String(describing: error)), json: json)
                }
            }
            if FileManager.default.fileExists(atPath: DevCtlPaths().stoppedIntentFile.path) {
                fail(
                    WireError(
                        code: .daemonUnreachable,
                        hint: "run: devctl daemon start",
                        message: "devctld was deliberately stopped"),
                    json: json)
            }
            fail(error, json: json)
        } catch let error as WireError {
            fail(error, json: json)
        } catch {
            fail(WireError(code: .internalError, message: String(describing: error)), json: json)
        }
    }

    /** Auto-bootstrap: only against the default socket (never a test override),
        never past a deliberate-stop marker, install-if-missing when the devctld
        binary ships alongside this CLI. */
    static func attemptBootstrap() async -> Bool {
        await LaunchdAdmin.attemptBootstrap(extraDaemonCandidates: [CLISelf.daemonSibling])
    }

    static func describe(_ status: ServerStatus) -> String {
        var parts = ["\(status.server): \(status.phase.rawValue)"]
        if let pid = status.pid { parts.append("pid \(pid)") }
        if let port = status.declaredPort { parts.append("port \(port)") }
        if let exit = status.lastExit {
            let cause = exit.code.map { "exit \($0)" } ?? exit.signal.map { "signal \($0)" } ?? "unknown"
            parts.append("last exit \(cause) at \(JSONCoding.formatISO8601(exit.at))")
        }
        if let spawn = status.spawnError {
            parts.append("spawn failed: \(spawn.message)")
        }
        parts.append("log \(status.logPath)")
        return parts.joined(separator: "  ·  ")
    }
}

struct Ensure: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Idempotently start a server: healthy is a no-op, otherwise start and wait for health.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name.")
    var name: String

    @Option(help: "Override the declared port for this run.")
    var port: Int?

    @Option(help: "Seconds to wait for health before giving up.")
    var timeout: Double = 60

    func run() async throws {
        let params = EnsureParams(
            name: name, port: port, project: global.resolvedProject(), timeoutSeconds: timeout)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverEnsure, params: params, expecting: EnsureResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            var text = CLIRunner.describe(r.server)
            if let reason = r.reason { text = "ensure fell short (\(reason.rawValue))\n" + text }
            return text
        }
        if result.reason != nil {
            Foundation.exit(1)
        }
    }
}

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Block until a server is healthy (or stopped); fails fast on crash.")

    @Flag(help: "Wait for the server to be healthy (the default).")
    var healthy = false

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name.")
    var name: String

    @Flag(help: "Wait for the server to be fully stopped instead.")
    var stopped = false

    @Option(help: "Seconds to wait before giving up.")
    var timeout: Double = 60

    func run() async throws {
        let condition: WaitCondition = stopped ? .stopped : .healthy
        let params = WaitParams(
            condition: condition, name: name, project: global.resolvedProject(), timeoutSeconds: timeout)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverWait, params: params, expecting: EnsureResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            if let reason = r.reason {
                return "wait fell short (\(reason.rawValue))\n" + CLIRunner.describe(r.server)
            }
            return CLIRunner.describe(r.server)
        }
        if result.reason != nil {
            Foundation.exit(1)
        }
    }
}

struct Register: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Register a server ad hoc into the machine registry.")

    /** unconditionalSingleValue lets argv words that start with dashes through
        (`--cmd --spawn-grandchild`), which agent-composed commands need. */
    @Option(
        parsing: .unconditionalSingleValue,
        help: "Command argv, repeated per word; values may start with dashes.")
    var cmd: [String] = []

    @Option(help: "Working directory relative to the project root.")
    var cwd: String?

    @OptionGroup var global: GlobalOptions

    @Option(help: "Server name.")
    var name: String

    @Option(help: "Declared port.")
    var port: Int?

    func run() async throws {
        guard !cmd.isEmpty else {
            CLIRunner.fail(
                WireError(code: .usage, message: "--cmd is required (repeat it per argv word)"),
                json: global.json)
        }
        let spec = ServerSpec(command: cmd, cwd: cwd, name: name, port: port)
        let params = RegisterParams(project: global.resolvedProject(), spec: spec)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverRegister, params: params, expecting: ServerResult.self)
        }
        CLIRunner.emit(result, json: global.json) { "registered \(CLIRunner.describe($0.server))" }
    }
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a registered server.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name.")
    var name: String

    @Option(help: "Override the declared port for this run.")
    var port: Int?

    func run() async throws {
        let params = ServerTargetParams(name: name, port: port, project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverStart, params: params, expecting: ServerResult.self)
        }
        if result.server.phase == .failed {
            CLIRunner.fail(
                WireError(
                    code: .spawnFailed,
                    hint: "run: devctl status \(name) --json",
                    message: result.server.spawnError?.message ?? "spawn failed"),
                json: global.json)
        }
        CLIRunner.emit(result, json: global.json) { CLIRunner.describe($0.server) }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show server status for the project.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name (omit for all).")
    var name: String?

    func run() async throws {
        let params = ProjectParams(name: name, project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverStatus, params: params, expecting: ServerListResult.self)
        }
        if let name, result.servers.isEmpty {
            CLIRunner.fail(
                WireError(
                    code: .notFound,
                    hint: "run: devctl status --json",
                    message: "no server named '\(name)' is registered for this project"),
                json: global.json)
        }
        CLIRunner.emit(result, json: global.json) { list in
            if list.servers.isEmpty {
                return "no servers registered for this project (hint: devctl register --name myproj --cmd …)"
            }
            return list.servers.map(CLIRunner.describe).joined(separator: "\n")
        }
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop a running server (whole process group).")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name.")
    var name: String

    func run() async throws {
        let params = ServerTargetParams(name: name, project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverStop, params: params, expecting: ServerResult.self)
        }
        CLIRunner.emit(result, json: global.json) { CLIRunner.describe($0.server) }
    }
}

struct Unregister: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove a server from the machine registry.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name.")
    var name: String

    func run() async throws {
        let params = ServerTargetParams(name: name, project: global.resolvedProject())
        _ = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverUnregister, params: params, expecting: WireEmpty.self)
        }
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in "unregistered \(name)" }
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Query a server's structured logs (out/err/sys/mark streams).")

    @Flag(help: "Keep polling for new lines (Ctrl-C to stop).")
    var follow = false

    @OptionGroup var global: GlobalOptions

    @Option(help: "Regex filter (Swift Regex dialect) applied to line text.")
    var grep: String?

    @Argument(help: "Server name.")
    var name: String

    @Option(help: "Only lines at or after this time: 5m/2h style or ISO-8601.")
    var since: String?

    @Option(help: "Only lines after the mark with this id (from devctl mark).")
    var sinceMark: String?

    @Option(help: "Filter to one stream: out, err, sys, or mark.")
    var stream: [String] = []

    @Option(help: "Only the last N lines.")
    var tail: Int?

    func run() async throws {
        var sinceDate: Date?
        if let since {
            sinceDate = Self.parseSince(since)
            if sinceDate == nil {
                CLIRunner.fail(
                    WireError(code: .usage, message: "--since takes 5m/2h/1d style or ISO-8601, got '\(since)'"),
                    json: global.json)
            }
        }
        let streams: [LogStream]? = stream.isEmpty ? nil : stream.compactMap { LogStream(rawValue: $0) }
        if let streams, streams.count != stream.count {
            CLIRunner.fail(
                WireError(code: .usage, message: "--stream takes out, err, sys, or mark"), json: global.json)
        }
        var params = LogsQueryParams(
            grep: grep, name: name, project: global.resolvedProject(), since: sinceDate,
            sinceMark: sinceMark, streams: streams, tail: follow ? (tail ?? 50) : tail)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.logsQuery, params: params, expecting: LogsQueryResult.self)
        }
        emit(result.lines)
        guard follow else { return }
        /** Follow = incremental polling since the last seen line: restart-safe
            and no push machinery. Duplicate timestamps are deduped by count. */
        var lastAt = result.lines.last?.at
        var seenAtLast = result.lines.filter { $0.at == lastAt }.count
        params.sinceMark = nil
        params.tail = nil
        while true {
            try await Task.sleep(for: .milliseconds(300))
            params.since = lastAt
            let more = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
                try await client.request(.logsQuery, params: params, expecting: LogsQueryResult.self)
            }
            var fresh = more.lines
            if let lastAt {
                var skip = seenAtLast
                fresh = fresh.drop { record in
                    if record.at == lastAt, skip > 0 {
                        skip -= 1
                        return true
                    }
                    return false
                }.filter { $0.at >= lastAt }
            }
            if !fresh.isEmpty {
                emit(fresh)
                lastAt = fresh.last?.at
                seenAtLast = more.lines.filter { $0.at == lastAt }.count
            }
        }
    }

    private func emit(_ lines: [LogRecord]) {
        if global.json {
            for line in lines {
                if let data = try? JSONCoding.encoder().encode(line) {
                    print(String(decoding: data, as: UTF8.self))
                }
            }
        } else {
            for line in lines {
                print("\(JSONCoding.formatISO8601(line.at)) [\(line.stream.rawValue)] \(line.text)")
            }
        }
    }

    /** 5m / 2h / 1d / 30s relative forms, else ISO-8601. */
    static func parseSince(_ text: String) -> Date? {
        if let match = text.wholeMatch(of: /(\d+)([smhd])/) {
            let value = Double(match.1) ?? 0
            let unit: Double =
                switch match.2 {
                case "s": 1
                case "m": 60
                case "h": 3600
                default: 86400
                }
            return Date().addingTimeInterval(-value * unit)
        }
        return JSONCoding.parseISO8601(text)
    }
}

struct Mark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drop a correlation marker into a server's log stream.")

    @Flag(help: "Mark every server in the project.")
    var all = false

    @OptionGroup var global: GlobalOptions

    @Option(help: "Requester label recorded with the mark (defaults to the client pid).")
    var label: String?

    /** With --all the only argument is the text; otherwise name then text. */
    @Argument(help: "Server name (omitted with --all), then marker text.")
    var words: [String]

    func run() async throws {
        var name: String?
        var text: String
        if all {
            guard !words.isEmpty else {
                CLIRunner.fail(WireError(code: .usage, message: "mark --all needs marker text"), json: global.json)
            }
            text = words.joined(separator: " ")
        } else {
            guard words.count >= 2 else {
                CLIRunner.fail(
                    WireError(code: .usage, message: "usage: devctl mark <name> <text> (or --all <text>)"),
                    json: global.json)
            }
            name = words[0]
            text = words.dropFirst().joined(separator: " ")
        }
        let params = MarkParams(
            all: all ? true : nil,
            label: label ?? "pid-\(getpid())",
            name: name,
            project: global.resolvedProject(),
            text: text)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.logsMark, params: params, expecting: MarkResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            r.marks.map { "marked \($0.server): \($0.id) at \(JSONCoding.formatISO8601($0.at))" }
                .joined(separator: "\n")
        }
    }
}

struct Events: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The unified event feed: starts, stops, crashes, health changes, marks.")

    @Flag(help: "Events for every project, not just the current one.")
    var all = false

    @OptionGroup var global: GlobalOptions

    @Option(help: "Only events at or after this time: 5m/2h style or ISO-8601.")
    var since: String?

    @Option(help: "Only events after the mark with this id.")
    var sinceMark: String?

    @Option(help: "Only the last N events.")
    var tail: Int?

    func run() async throws {
        var sinceDate: Date?
        if let since {
            sinceDate = Logs.parseSince(since)
            if sinceDate == nil {
                CLIRunner.fail(
                    WireError(code: .usage, message: "--since takes 5m/2h/1d style or ISO-8601, got '\(since)'"),
                    json: global.json)
            }
        }
        let params = EventsQueryParams(
            project: all ? nil : global.resolvedProject(),
            since: sinceDate,
            sinceMark: sinceMark,
            tail: tail)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.eventsQuery, params: params, expecting: EventsQueryResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            if r.events.isEmpty { return "no events" }
            return r.events.map { event in
                var text = "\(JSONCoding.formatISO8601(event.at)) \(event.server): \(event.kind.rawValue)"
                if let detail = event.detail { text += " (\(detail))" }
                return text
            }.joined(separator: "\n")
        }
    }
}

struct Why: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnose a server: root cause across its dependency chain.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Server name.")
    var name: String

    func run() async throws {
        let params = ServerTargetParams(name: name, project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverWhy, params: params, expecting: WhyResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            var sections: [String] = []
            if let root = r.rootCause {
                sections.append("root cause: \(root)")
            }
            for finding in r.findings {
                var block = "\(finding.server) [\(finding.phase.rawValue)]: \(finding.summary)"
                for line in finding.evidence {
                    block += "\n    \(line)"
                }
                sections.append(block)
            }
            return sections.joined(separator: "\n")
        }
    }
}

struct Context: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fenced plain-text server context for any agent harness. Silent when there is nothing to say.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        if let text = await HookContext.render(project: global.resolvedProject()) {
            print(text)
        }
    }
}

struct HookCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Agent-harness session hooks.",
        subcommands: [HookInstall.self, HookClaudeSessionStart.self, HookCursorSessionStart.self]
    )
}

struct HookInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Wire the session-start context hook into an agent harness (idempotent).")

    @OptionGroup var global: GlobalOptions

    @Option(help: "Harness to install for: \(harnessAdapters.map(\.name).joined(separator: ", ")) (default: claude).")
    var harness: String = "claude"

    @Flag(help: "Also print the statusline wiring suggestion.")
    var statusline = false

    func run() async throws {
        guard let adapter = harnessAdapters.first(where: { $0.name == harness }) else {
            CLIRunner.fail(
                WireError(
                    code: .usage,
                    hint: "supported: \(harnessAdapters.map(\.name).joined(separator: ", ")) (adding one: CONTRIBUTING.md)",
                    message: "unknown harness '\(harness)'"),
                json: global.json)
        }
        let devctlPath = CLISelf.path
        do {
            let summary = try adapter.install(devctlPath: devctlPath)
            var output = summary
            if statusline {
                output += "\n\nStatusline: pipe your statusline script through `devctl statusline` to append server presence, e.g.\n  devctl statusline <<< \"$STDIN_JSON\"  ->  myproj:3000 ok · api crashed"
            }
            /** The discovery tip is printed, never appended to CLAUDE.md/AGENTS.md:
                devctl does not edit a project's files. Server names come from the
                nearest devservers.json (empty when there is none yet). */
            let serverNames: [String]
            if let view = try? ProjectConfigLoader.load(project: global.resolvedProject()) {
                serverNames = view.specs.map(\.name)
            } else {
                serverNames = []
            }
            output += "\n\nDiscovery tip: paste this bullet into the project's CLAUDE.md/AGENTS.md so agents find devctl on their own (devctl never edits those files):\n\(DiscoveryStanza.render(serverNames: serverNames))"
            CLIRunner.emit(WireEmpty(), json: global.json) { _ in output }
        } catch {
            CLIRunner.fail(
                WireError(code: .internalError, message: "hook install failed: \(error)"),
                json: global.json)
        }
    }
}

/** Invoked by Claude Code's SessionStart hook. Reads the hook's stdin JSON for
    the session cwd, emits hookSpecificOutput.additionalContext, and always exits
    0 quickly: a session start must never stall or fail on devctl's account. */
struct HookClaudeSessionStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude-session-start", shouldDisplay: false)

    func run() async throws {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let cwd = HookSessionCwd.resolve(stdin: stdin)
        /** Project resolution without --project: reuse the CLI's walk from the
            hook cwd by chdir-ing there first. */
        FileManager.default.changeCurrentDirectoryPath(cwd)
        let project = GlobalOptions.resolveProject(from: cwd)
        guard let text = await HookContext.render(project: project) else { return }
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "additionalContext": text,
                "hookEventName": "SessionStart",
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(data)
        }
    }
}

/** Invoked by Cursor's sessionStart hook. Emits {additional_context} (Cursor's
    snake_case schema). Same silence / exit-0 guarantees as the Claude hook. */
struct HookCursorSessionStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cursor-session-start", shouldDisplay: false)

    func run() async throws {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let cwd = HookSessionCwd.resolve(stdin: stdin)
        FileManager.default.changeCurrentDirectoryPath(cwd)
        let project = GlobalOptions.resolveProject(from: cwd)
        guard let text = await HookContext.render(project: project) else { return }
        let output: [String: Any] = ["additional_context": text]
        if let data = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(data)
        }
    }
}

/** Statusline helper: reads the harness's statusline stdin JSON, prints one
    compact presence line for the cwd's project (empty when nothing to show). */
struct Statusline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compact server presence for a statusline; reads harness stdin JSON.")

    func run() async throws {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        var cwd = FileManager.default.currentDirectoryPath
        if let payload = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any] {
            if let workspace = payload["workspace"] as? [String: Any],
                let dir = workspace["current_dir"] as? String {
                cwd = dir
            } else if let dir = payload["cwd"] as? String {
                cwd = dir
            }
        }
        let project = GlobalOptions.resolveProject(from: cwd)
        let client = DaemonClient(socketPath: DevCtlPaths().socketPath)
        guard
            let list = try? await client.request(
                .serverStatus, params: ProjectParams(project: project), expecting: ServerListResult.self),
            !list.servers.isEmpty
        else { return }
        let parts = list.servers.map { server in
            let port = (server.observedPort ?? server.declaredPort).map { ":\($0)" } ?? ""
            let state =
                switch server.phase {
                case .running: "ok"
                default: server.phase.rawValue
                }
            return "\(server.server)\(port) \(state)"
        }
        print(parts.joined(separator: " · "))
    }
}

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the whole project in dependency order, waiting per waitFor.")

    @OptionGroup var global: GlobalOptions

    @Option(help: "Comma-separated server names (their dependencies come along).")
    var only: String?

    @Option(help: "Override the declared port for each server this up starts.")
    var port: Int?

    @Option(help: "Per-server seconds to wait for health.")
    var timeout: Double = 60

    func run() async throws {
        let params = GroupParams(
            only: only.map { $0.split(separator: ",").map(String.init) },
            port: port,
            project: global.resolvedProject(),
            timeoutSeconds: timeout)
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.groupUp, params: params, expecting: GroupResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            r.results.map { entry in
                entry.reason.map { "\(CLIRunner.describe(entry.server))  ·  FELL SHORT (\($0.rawValue))" }
                    ?? CLIRunner.describe(entry.server)
            }.joined(separator: "\n")
        }
        if result.results.contains(where: { $0.reason != nil }) {
            Foundation.exit(1)
        }
    }
}

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the whole project in reverse dependency order.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let params = GroupParams(project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.groupDown, params: params, expecting: GroupResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            r.results.isEmpty
                ? "nothing to stop"
                : r.results.map { CLIRunner.describe($0.server) }.joined(separator: "\n")
        }
    }
}

struct Trust: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Approve this project's devservers.json so the session hook advertises it.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let params = ProjectOnlyParams(project: global.resolvedProject())
        _ = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.projectTrust, params: params, expecting: WireEmpty.self)
        }
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in "project trusted" }
    }
}

struct Open: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a server's URL (or one of a multi-headed server's named heads).")

    /** Positional order is load-bearing: the server name comes first, then the
        optional head, so declaration order deliberately breaks the alphabet. */
    @Argument(help: "Server name.")
    var name: String

    @Argument(help: "Head name for multi-headed servers (see devctl status --json).")
    var head: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let params = ProjectParams(name: name, project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.serverStatus, params: params, expecting: ServerListResult.self)
        }
        guard let server = result.servers.first else {
            CLIRunner.fail(
                WireError(
                    code: .notFound, hint: "run: devctl status --json",
                    message: "no server named '\(name)' is registered for this project"),
                json: global.json)
        }
        var target = server.url
        if let head {
            guard let headURL = server.heads?[head] else {
                let known = (server.heads ?? [:]).keys.sorted().joined(separator: ", ")
                CLIRunner.fail(
                    WireError(
                        code: .notFound,
                        hint: known.isEmpty ? "this server declares no heads" : "known heads: \(known)",
                        message: "no head named '\(head)' on \(name)"),
                    json: global.json)
            }
            target = headURL
        }
        guard let url = target else {
            CLIRunner.fail(
                WireError(
                    code: .usage,
                    hint: "add a port, url, or heads to \(name) in devservers.json",
                    message: "\(name) has no URL (no port declared and no url configured)"),
                json: global.json)
        }
        LaunchdAdmin.shell("/usr/bin/open", [url])
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in "opened \(url)" }
    }
}

/** Print a `devctl://` URL for the cwd project (Raycast snippets, docs, smoke). */
struct Link: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print a devctl:// URL for a verb and server in this project.")

    @Argument(help: "Verb: open, ensure, stop, or why.")
    var verb: String

    @Argument(help: "Server name.")
    var name: String

    @Argument(help: "Head name (open only).")
    var head: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        guard let deepVerb = DeepLinkVerb(rawValue: verb.lowercased()) else {
            CLIRunner.fail(
                WireError(
                    code: .usage,
                    hint: "verbs: \(DeepLinkVerb.allCases.map(\.rawValue).sorted().joined(separator: ", "))",
                    message: "unknown verb '\(verb)'"),
                json: global.json)
        }
        if head != nil, deepVerb != .open {
            CLIRunner.fail(
                WireError(
                    code: .usage, message: "a head is only valid with verb open"),
                json: global.json)
        }
        let project = global.resolvedProject()
        let slug = (project as NSString).lastPathComponent
        let link = DeepLink(verb: deepVerb, projectSlug: slug, server: name, head: head)
        struct LinkResult: Codable {
            var url: String
        }
        let url = link.urlString()
        CLIRunner.emit(LinkResult(url: url), json: global.json) { $0.url }
    }
}

/** Smoke/CI entry: run a `devctl://` URL through DeepLinkRunner without Launch
    Services or the menu bar app. Hidden from `--help`. */
struct XURL: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "x-url",
        abstract: "Dispatch a devctl:// URL via the daemon (smoke / agents).",
        shouldDisplay: false)

    @Argument(help: "A devctl:// URL.")
    var url: String

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let link: DeepLink
        switch DeepLink.parse(url) {
        case .failure(let error):
            CLIRunner.fail(error, json: global.json)
        case .success(let parsed):
            link = parsed
        }
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await DeepLinkRunner(client: client, effects: CLIDeepLinkEffects()).run(link)
        }
        CLIRunner.emit(result, json: global.json) { r in
            var line = "\(r.verb.rawValue) \(r.projectPath)"
            if let detail = r.detail { line += ": \(detail)" }
            return line
        }
    }
}

/** CLI-side effects for x-url: open(1), pbcopy, stderr notify (no AppKit). */
struct CLIDeepLinkEffects: DeepLinkEffects {
    func copyToPasteboard(_ text: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        try? process.run()
        pipe.fileHandleForWriting.write(Data(text.utf8))
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    func notify(title: String, body: String) async {
        FileHandle.standardError.write(Data("devctl: \(title): \(body)\n".utf8))
    }

    func openBrowser(_ url: URL) async {
        _ = LaunchdAdmin.shell("/usr/bin/open", [url.absoluteString])
    }
}

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Project configuration helpers.",
        subcommands: [ConfigCheck.self]
    )
}

struct ConfigCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check", abstract: "Validate devservers.json with the daemon's own validator.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let params = ProjectOnlyParams(project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.projectCheck, params: params, expecting: CheckResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            var lines: [String] = []
            if let host = r.host { lines.append("host: \(host)") }
            if !r.servers.isEmpty { lines.append("servers: \(r.servers.joined(separator: ", "))") }
            lines.append(contentsOf: r.errors.map { "error: \($0)" })
            lines.append(contentsOf: r.warnings.map { "warning: \($0)" })
            if r.errors.isEmpty && r.warnings.isEmpty { lines.append("config ok") }
            return lines.joined(separator: "\n")
        }
        if !result.errors.isEmpty {
            Foundation.exit(1)
        }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Health report: daemon, launchd, PATH staleness, signatures, stale registrations.")

    @Flag(help: "Prune registry entries whose project directories no longer exist.")
    var fix = false

    @OptionGroup var global: GlobalOptions

    struct Finding: Codable {
        var detail: String
        var kind: String
        var severity: String
    }

    func run() async throws {
        var findings: [Finding] = []
        let client = CLIRunner.client()
        let info = try? await client.request(.daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)
        if let info {
            findings.append(
                Finding(detail: "v\(info.daemonVersion) pid \(info.pid) on \(info.socketPath)", kind: "daemon", severity: "ok"))
            let livePath = LaunchdAdmin.capturedPath()
            let storedPath = LaunchdAdmin.readAgentPath()
            if let daemonPath = info.searchPath, daemonPath != livePath {
                findings.append(
                    Finding(
                        detail: "daemon PATH differs from the current login shell (captured at install; run: devctl daemon install)",
                        kind: "path-staleness", severity: "warning"))
            }
            if let storedPath, storedPath != livePath {
                findings.append(
                    Finding(
                        detail: "agent.path differs from the current login shell (run: devctl daemon install)",
                        kind: "path-staleness", severity: "warning"))
            }
        } else {
            findings.append(
                Finding(detail: "daemon not responding (run: devctl daemon status)", kind: "daemon", severity: "error"))
        }
        findings.append(
            Finding(detail: LaunchdAdmin.launchdState(), kind: "launchd", severity: "info"))
        if let all = try? await client.request(
            .serverStatus, params: ProjectParams(project: ""), expecting: ServerListResult.self) {
            var signatureHolders: [String: String] = [:]
            var staleProjects: Set<String> = []
            for server in all.servers {
                if !FileManager.default.fileExists(atPath: server.project) {
                    staleProjects.insert(server.project)
                    continue
                }
                if let port = server.declaredPort {
                    let host = server.url.flatMap { URL(string: $0)?.host } ?? "localhost"
                    let signature = "\(host):\(port)"
                    let holder = "\(server.server) (\(server.project))"
                    if let existing = signatureHolders[signature] {
                        findings.append(
                            Finding(
                                detail: "signature \(signature) claimed by both \(existing) and \(holder)",
                                kind: "signature-conflict", severity: "warning"))
                    } else {
                        signatureHolders[signature] = holder
                        findings.append(
                            Finding(
                                detail: "\(signature) -> \(holder) [\(server.phase.rawValue)]",
                                kind: "signature", severity: "info"))
                    }
                    if server.phase == .stopped || server.phase == .crashed,
                        LoopbackProbe.isListening(port: port) {
                        findings.append(
                            Finding(
                                detail: "port \(port) has an unmanaged listener while \(server.server) is down",
                                kind: "port-squatter", severity: "warning"))
                    }
                }
            }
            for project in staleProjects.sorted() {
                if fix {
                    let names = all.servers.filter { $0.project == project }.map(\.server)
                    for name in names {
                        _ = try? await client.request(
                            .serverUnregister,
                            params: ServerTargetParams(name: name, project: project),
                            expecting: WireEmpty.self)
                    }
                    findings.append(
                        Finding(detail: "pruned \(project) (\(names.count) servers)", kind: "stale-project", severity: "fixed"))
                } else {
                    findings.append(
                        Finding(
                            detail: "\(project) no longer exists on disk (devctl doctor --fix prunes it)",
                            kind: "stale-project", severity: "warning"))
                }
            }
        }
        if global.json {
            struct Report: Codable {
                var findings: [Finding]
            }
            CLIRunner.emit(Report(findings: findings), json: true) { _ in "" }
        } else {
            for finding in findings {
                print("[\(finding.severity)] \(finding.kind): \(finding.detail)")
            }
        }
        if findings.contains(where: { $0.severity == "error" }) {
            Foundation.exit(1)
        }
    }
}

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Daemon management.",
        subcommands: [
            DaemonInfoCommand.self, DaemonInstall.self, DaemonRestart.self, DaemonStart.self,
            DaemonStatusCommand.self, DaemonStop.self, DaemonUninstall.self,
        ]
    )
}

struct DaemonInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Install (or upgrade) the launchd agent and start the daemon.")

    @Option(help: "Path to the devctld binary; defaults to the one alongside this devctl.")
    var devctld: String?

    @Flag(
        help:
            "Force the home LaunchAgent path even when /Applications/devctl.app is present (CLI-only / smoke)."
    )
    var legacy = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let binary = devctld.map { URL(fileURLWithPath: $0) }
            ?? LaunchdAdmin.resolveDaemonBinary(extraCandidates: [CLISelf.daemonSibling])
        guard let binary else {
            CLIRunner.fail(
                WireError(
                    code: .usage,
                    hint: "run: devctl daemon install --devctld /path/to/devctld",
                    message: "cannot find a devctld binary next to devctl"),
                json: global.json)
        }
        let restored: [(project: String, name: String)]
        do {
            restored = try await LaunchdAdmin.install(
                daemonBinary: binary, paths: DevCtlPaths(), forceLegacy: legacy)
        } catch let error as WireError {
            CLIRunner.fail(error, json: global.json)
        }
        let viaApp = !legacy && LaunchdAdmin.applicationsAppPresent()
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in
            if restored.isEmpty {
                viaApp
                    ? "devctld ensured via \(SetupPlanner.applicationsAppPath) (Login Items)"
                    : "devctld installed and running (\(LaunchdAdmin.label))"
            } else {
                "devctld installed; re-ensured \(restored.map(\.name).joined(separator: ", "))"
            }
        }
    }
}

struct DaemonUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "Stop the daemon and remove the launchd agent.")

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Also delete all devctl data and logs.")
    var purge = false

    func run() async throws {
        await LaunchdAdmin.uninstall(paths: DevCtlPaths(), purge: purge)
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in
            purge ? "devctld uninstalled; data and logs removed" : "devctld uninstalled"
        }
    }
}

struct DaemonStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start", abstract: "Start a stopped daemon (clears the deliberate-stop marker).")

    @Flag(
        help:
            "Force the home LaunchAgent path even when /Applications/devctl.app is present."
    )
    var legacy = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        do {
            try await LaunchdAdmin.startOrInstall(
                paths: DevCtlPaths(),
                extraDaemonCandidates: [CLISelf.daemonSibling],
                forceLegacy: legacy)
        } catch let error as WireError {
            CLIRunner.fail(error, json: global.json)
        }
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in "devctld running" }
    }
}

struct DaemonStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Drain all servers and stop the daemon until asked to start.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let client = CLIRunner.client()
        _ = try? await client.request(.daemonShutdown, params: WireEmpty(), expecting: WireEmpty.self)
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in
            "devctld stopping (servers drained; devctl daemon start to bring it back)"
        }
    }
}

struct DaemonRestart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Drain, relaunch the daemon, and re-ensure the servers that were running.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let bounced: [(project: String, name: String)]
        do {
            bounced = try await LaunchdAdmin.restart(paths: DevCtlPaths())
        } catch let error as WireError {
            CLIRunner.fail(error, json: global.json)
        }
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in
            bounced.isEmpty
                ? "devctld restarted (no servers were running)"
                : "devctld restarted; re-ensured \(bounced.map(\.name).joined(separator: ", "))"
        }
    }
}

struct DaemonStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "launchd state plus live daemon identity.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let launchdLine = LaunchdAdmin.launchdState()
        let client = CLIRunner.client()
        let info = try? await client.request(.daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)
        if global.json {
            struct StatusPayload: Codable {
                var daemon: DaemonInfo?
                var launchd: String
            }
            CLIRunner.emit(StatusPayload(daemon: info, launchd: launchdLine), json: true) { _ in "" }
        } else if let info {
            print("launchd: \(launchdLine)\ndaemon: v\(info.daemonVersion) pid \(info.pid) on \(info.socketPath)")
        } else {
            print("launchd: \(launchdLine)\ndaemon: not responding")
        }
    }
}

struct DaemonInfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info", abstract: "Daemon identity and paths.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(.daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)
        }
        CLIRunner.emit(result, json: global.json) { info in
            "devctld v\(info.daemonVersion) (proto \(info.proto)) pid \(info.pid)\nsocket \(info.socketPath)\ndata \(info.dataDir)\nlogs \(info.logsDir)"
        }
    }
}

/** Branch switching with the project's own lifecycle playbook: stop the
    servers, move the checkout, run the configured commands (install, seed,
    codegen), bring everything back healthy. The tree must be clean: devctl
    never stashes or discards work. */
struct Switch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Switch the project to a branch, run its lifecycle commands, and bring servers back up.")

    @Argument(help: "Branch name (created from the matching remote branch when needed).")
    var branch: String

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Skip the git fetch before switching.")
    var noFetch = false

    @Option(help: "Per-server seconds to wait for health when coming back up.")
    var timeout: Double = 120

    func run() async throws {
        let project = global.resolvedProject()
        let dirty = Self.git(["status", "--porcelain"], in: project)
        guard dirty.status == 0 else {
            CLIRunner.fail(
                WireError(code: .internalError, message: "git status failed: \(dirty.output)"),
                json: global.json)
        }
        guard dirty.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            CLIRunner.fail(
                WireError(
                    code: .usage,
                    hint: "commit your work first (devctl never stashes or discards changes)",
                    message: "the working tree has uncommitted changes"),
                json: global.json)
        }
        if !noFetch {
            print("fetching…")
            _ = Self.git(["fetch", "origin", "--prune"], in: project)
        }
        print("stopping servers…")
        _ = try? await CLIRunner.client().request(
            .groupDown, params: GroupParams(project: project), expecting: GroupResult.self)
        var switched = Self.git(["switch", branch], in: project)
        if switched.status != 0 {
            /** A remote-only branch needs a tracking checkout. */
            switched = Self.git(["switch", "--track", "origin/\(branch)"], in: project)
        }
        guard switched.status == 0 else {
            CLIRunner.fail(
                WireError(
                    code: .internalError,
                    hint: "run: git -C \(project) switch \(branch)",
                    message: "git switch failed: \(switched.output.trimmingCharacters(in: .whitespacesAndNewlines))"),
                json: global.json)
        }
        print("on \(branch)")
        let playbook = (try? ProjectConfigLoader.load(project: project))
            .flatMap { _ in try? JSONCoding.decoder().decode(
                ProjectFileConfig.self,
                from: Data(contentsOf: ProjectConfigLoader.configURL(project: project))) }?
            .lifecycle?["switch"] ?? []
        for argv in playbook {
            guard let executable = argv.first else { continue }
            print("lifecycle: \(argv.joined(separator: " "))")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            process.currentDirectoryURL = URL(fileURLWithPath: project)
            do {
                try process.run()
            } catch {
                CLIRunner.fail(
                    WireError(
                        code: .spawnFailed,
                        message: "cannot run lifecycle command '\(executable)': \(error)"),
                    json: global.json)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                CLIRunner.fail(
                    WireError(
                        code: .internalError,
                        hint: "fix the failure, then: devctl up",
                        message: "lifecycle command failed (\(process.terminationStatus)): \(argv.joined(separator: " "))"),
                    json: global.json)
            }
        }
        print("bringing servers up…")
        let result = await CLIRunner.run(json: global.json, bootstrap: !global.noBootstrap) { client in
            try await client.request(
                .groupUp,
                params: GroupParams(project: project, timeoutSeconds: timeout),
                expecting: GroupResult.self)
        }
        CLIRunner.emit(result, json: global.json) { r in
            r.results.isEmpty
                ? "switched to \(branch) (no servers registered)"
                : r.results.map { entry in
                    entry.reason.map { "\(CLIRunner.describe(entry.server))  ·  FELL SHORT (\($0.rawValue))" }
                        ?? CLIRunner.describe(entry.server)
                }.joined(separator: "\n")
        }
        if result.results.contains(where: { $0.reason != nil }) {
            Foundation.exit(1)
        }
    }

    static func git(_ arguments: [String], in project: String) -> (status: Int32, output: String) {
        LaunchdAdmin.shell("/usr/bin/git", ["-C", project] + arguments)
    }
}

/** Runs a command while holding a named resource exclusively. By default the
    daemon pauses managed servers that declare the resource; `--no-pause` takes
    the mutex without stopping them (for harnesses that reuse the live server). */
struct Lock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command holding a project resource; conflicting servers pause and return.")

    @OptionGroup var global: GlobalOptions

    /** Positional order is load-bearing: the resource comes first, everything
        after -- is the command, so declaration order deliberately breaks the
        alphabet. Options and flags must appear before the passthrough argv so
        `--no-pause` is not captured into the command. */
    @Argument(help: "Resource name (matches servers' `locks` in devservers.json).")
    var resource: String

    @Option(help: "Seconds to wait for the resource if another holder has it.")
    var acquireTimeout: Double = 300

    /** Explicit long name: `@Flag(inversion: .prefixedNo)` on a default-true
        `pause` was still pausing under `--no-pause` in the smoke gate (daemon
        unit tests with `pause: false` were fine), so the wire bit is driven by
        this opt-out flag instead. */
    @Flag(name: .customLong("no-pause"), help: "Hold the mutex without stopping servers that declare the resource.")
    var noPause = false

    @Option(help: "Per-server seconds to wait for health when servers return.")
    var timeout: Double = 120

    @Argument(parsing: .captureForPassthrough, help: "Command to run while holding the resource.")
    var command: [String]

    func run() async throws {
        var noPause = noPause
        var command = command
        if !noPause, let flagIndex = command.firstIndex(of: "--no-pause") {
            noPause = true
            command.remove(at: flagIndex)
        }
        guard !command.isEmpty else {
            CLIRunner.fail(
                WireError(code: .usage, message: "usage: devctl lock <resource> [--no-pause] -- <command…>"),
                json: global.json)
        }
        let project = global.resolvedProject()
        let holderPid = Int(getpid())
        let client = CLIRunner.client()
        /** Acquire with patience: another harness may hold it. The daemon owns
            pause/resume of declaring servers; this CLI just runs the command. */
        let deadline = Date().addingTimeInterval(acquireTimeout)
        var acquired: LockResult?
        var lastError: WireError?
        while Date() < deadline {
            do {
                acquired = try await client.request(
                    .lockAcquire,
                    params: LockParams(
                        holderPid: holderPid, pause: !noPause, project: project, resource: resource,
                        resumeTimeoutSeconds: timeout),
                    expecting: LockResult.self)
                break
            } catch let error as WireError where error.code == .resourceLocked {
                lastError = error
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard let acquired else {
            CLIRunner.fail(
                lastError ?? WireError(code: .resourceLocked, message: "could not acquire '\(resource)'"),
                json: global.json)
        }
        for name in acquired.paused {
            print("paused \(name) (holds \(resource))")
        }
        /** Run the guarded command with inherited stdio. */
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = URL(fileURLWithPath: project)
        var commandStatus: Int32 = 1
        do {
            try process.run()
            process.waitUntilExit()
            commandStatus = process.terminationStatus
        } catch {
            FileHandle.standardError.write(Data("devctl lock: cannot run command: \(error)\n".utf8))
        }
        /** Release resumes whoever was paused, even if the command failed. */
        let released = (try? await client.request(
            .lockRelease,
            params: LockParams(
                holderPid: holderPid, project: project, resource: resource,
                resumeTimeoutSeconds: timeout),
            expecting: LockResult.self)) ?? LockResult()
        for name in released.paused {
            print("resuming \(name)…")
        }
        Foundation.exit(commandStatus)
    }
}
