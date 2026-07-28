import DevCtlKit
import Foundation
import Testing

@testable import DevCtlDaemonCore

/** Sibling git worktrees of one repo share committed ports; ensure on the
    linked tree must auto-rebind and advertise a worktree-* host. */
@Suite(.serialized) struct WorktreeCoexistenceTests {
    private struct Env {
        let fixture: String
        let main: String
        let paths: DevCtlPaths
        let worktree: String
    }

    private func makeEnv() throws -> Env {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "devctl-wt-\(UUID().uuidString)")
        let main = base.appending(path: "main")
        let worktree = base.appending(path: "worktrees/review")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try run(in: main.path, "/usr/bin/git", "init", "-b", "main")
        try run(in: main.path, "/usr/bin/git", "config", "user.email", "devctl@test")
        try run(in: main.path, "/usr/bin/git", "config", "user.name", "devctl")
        try Data("ok\n".utf8).write(to: main.appending(path: "README"))
        try run(in: main.path, "/usr/bin/git", "add", "README")
        try run(in: main.path, "/usr/bin/git", "commit", "-m", "init")
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run(
            in: main.path, "/usr/bin/git", "worktree", "add", "-b", "review", worktree.path)
        let fixture = try #require(Self.fixtureServerPath())
        let body = """
            {
              "host": "app.localhost",
              "servers": {
                "web": {
                  "command": ["\(fixture)", "--listen-tcp", "{port}"],
                  "healthcheck": { "type": "tcp", "port": 45111 },
                  "port": 45111,
                  "url": "http://app.localhost:45111/"
                }
              },
              "version": 1
            }
            """
        for root in [main, worktree] {
            try Data(body.utf8).write(to: root.appending(path: "devservers.json"))
        }
        return Env(
            fixture: fixture,
            main: main.path,
            paths: DevCtlPaths(
                dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
            worktree: worktree.path)
    }

    private func handle<P: Codable & Sendable, R: Codable & Sendable>(
        _ router: Router, _ method: WireMethod, _ params: P, _ expecting: R.Type
    ) async throws -> R {
        let line = try NDJSON.encodeLine(WireRequest(id: "t", method: method.rawValue, params: params))
        let data = await router.handle(line: line)
        let response = try JSONCoding.decoder().decode(WireResponse<R>.self, from: data)
        if response.ok, let result = response.result { return result }
        throw response.error ?? WireError(code: .internalError, message: "no result")
    }

    @Test func siblingWorktreeEnsureRebindsAndGetsEphemeralHost() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.main)
        try await registry.setTrusted(project: env.worktree)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let mainResult = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.main, timeoutSeconds: 10), EnsureResult.self)
        #expect(mainResult.server.phase == .running)
        #expect(mainResult.server.effectivePort == 45111)
        #expect(mainResult.server.url == "http://app.localhost:45111/")
        #expect(mainResult.server.portConflict == nil)

        let wtResult = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.worktree, timeoutSeconds: 10), EnsureResult.self)
        #expect(wtResult.server.phase == .running)
        #expect(wtResult.server.effectivePort != 45111)
        #expect(wtResult.server.portConflict?.state == .rebound)
        let url = try #require(wtResult.server.url)
        #expect(url.contains("worktree-review.app.localhost"))
        #expect(url.contains(":\(wtResult.server.effectivePort ?? -1)"))

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: env.worktree),
            ServerResult.self)
        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: env.main),
            ServerResult.self)
    }

    /** Discarding a worktree path stops its children and forgets registry/state
        without touching the main checkout. */
    @Test func discardedWorktreeIsPrunedOnMachineWideStatus() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.main)
        try await registry.setTrusted(project: env.worktree)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let mainResult = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.main, timeoutSeconds: 10), EnsureResult.self)
        #expect(mainResult.server.phase == .running)
        let mainPid = try #require(mainResult.server.pid)
        let mainProject = mainResult.server.project

        let wtResult = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.worktree, timeoutSeconds: 10), EnsureResult.self)
        #expect(wtResult.server.phase == .running)
        let wtPid = try #require(wtResult.server.pid)
        let wtPort = try #require(wtResult.server.effectivePort)
        let wtProject = wtResult.server.project

        try FileManager.default.removeItem(atPath: env.worktree)
        #expect(!FileManager.default.fileExists(atPath: env.worktree))

        let after = try await handle(
            router, .serverStatus, ProjectParams(project: ""), ServerListResult.self)
        #expect(!after.servers.contains { $0.project == wtProject })
        #expect(after.servers.contains { $0.project == mainProject && $0.phase == .running })
        #expect(await registry.project(wtProject) == nil)
        #expect(await registry.persistedState(serverID: serverID(project: wtProject, name: "web")) == nil)
        #expect(kill(pid_t(wtPid), 0) != 0)
        #expect(kill(pid_t(mainPid), 0) == 0)
        #expect(!LoopbackProbe.isListening(port: wtPort))

        /** Second prune is a no-op: machine-wide status still lists main only. */
        let again = try await handle(
            router, .serverStatus, ProjectParams(project: ""), ServerListResult.self)
        #expect(again.servers.allSatisfy { $0.project == mainProject })
        #expect(await registry.project(mainProject) != nil)

        _ = try await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: mainProject),
            ServerResult.self)
    }

    @Test func discardedWorktreeIsPrunedOnRecoverAtStartup() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.main)
        try await registry.setTrusted(project: env.worktree)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        let wtResult = try await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.worktree, timeoutSeconds: 10), EnsureResult.self)
        #expect(wtResult.server.phase == .running)
        let wtPid = try #require(wtResult.server.pid)
        let wtProject = wtResult.server.project
        let mainProject = canonicalProjectPath(env.main)

        try FileManager.default.removeItem(atPath: env.worktree)
        await router.recoverAtStartup()
        #expect(await registry.project(wtProject) == nil)
        #expect(kill(pid_t(wtPid), 0) != 0)
        #expect(await registry.project(mainProject) != nil)
    }

    private func run(in cwd: String, _ exe: String, _ args: String...) throws {
        let proc = Process()
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw WireError(
                code: .internalError,
                message: "\(exe) \(args.joined(separator: " ")) failed (\(proc.terminationStatus))")
        }
    }

    private static func fixtureServerPath() -> String? {
        let candidates = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: ".build/debug/fixture-server"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: ".build/debug/fixture-server"),
        ]
        return candidates.map(\.path).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
