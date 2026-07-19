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
            Register.self, Start.self, Status.self, Stop.self, Unregister.self, DaemonCommand.self,
        ]
    )
}

struct GlobalOptions: ParsableArguments {
    @Flag(help: "Emit machine-readable JSON (schemas: docs/cli-contract.md).")
    var json = false

    @Option(help: "Project root; defaults to the nearest devservers.json ancestor, then git root, then cwd.")
    var project: String?

    /** Resolution order: nearest ancestor with devservers.json → git root → cwd,
        canonicalized so worktrees/symlinks cannot mint duplicate identities. */
    func resolvedProject() -> String {
        if let project { return canonicalProjectPath(project) }
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
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
        case .configInvalid, .internalError, .notTrusted, .portHeld, .spawnFailed:
            Foundation.exit(1)
        }
    }

    static func run<R: Codable & Sendable>(
        json: Bool,
        _ body: (DaemonClient) async throws -> R
    ) async -> R {
        do {
            return try await body(client())
        } catch let error as WireError {
            fail(error, json: json)
        } catch {
            fail(WireError(code: .internalError, message: String(describing: error)), json: json)
        }
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
        let result = await CLIRunner.run(json: global.json) { client in
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

    func run() async throws {
        let params = ServerTargetParams(name: name, project: global.resolvedProject())
        let result = await CLIRunner.run(json: global.json) { client in
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
        let result = await CLIRunner.run(json: global.json) { client in
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
                return "no servers registered for this project (hint: devctl register --name web --cmd …)"
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
        let result = await CLIRunner.run(json: global.json) { client in
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
        _ = await CLIRunner.run(json: global.json) { client in
            try await client.request(.serverUnregister, params: params, expecting: WireEmpty.self)
        }
        CLIRunner.emit(WireEmpty(), json: global.json) { _ in "unregistered \(name)" }
    }
}

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Daemon management.",
        subcommands: [DaemonInfoCommand.self]
    )
}

struct DaemonInfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info", abstract: "Daemon identity and paths.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let result = await CLIRunner.run(json: global.json) { client in
            try await client.request(.daemonInfo, params: WireEmpty(), expecting: DaemonInfo.self)
        }
        CLIRunner.emit(result, json: global.json) { info in
            "devctld v\(info.daemonVersion) (proto \(info.proto)) pid \(info.pid)\nsocket \(info.socketPath)\ndata \(info.dataDir)\nlogs \(info.logsDir)"
        }
    }
}
