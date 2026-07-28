import DevCtlKit
import Foundation
import Testing

@testable import DevCtlDaemonCore

private struct TestEnv {
    let paths: DevCtlPaths
    /** A real directory: the child chdirs into it, so it must exist. */
    let projectPath: String
}

private func makeEnv() throws -> TestEnv {
    let base = FileManager.default.temporaryDirectory.appending(path: "devctl-sup-\(UUID().uuidString)")
    let project = base.appending(path: "proj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    return TestEnv(
        paths: DevCtlPaths(dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
        projectPath: project.path)
}

@Suite struct SupervisorTests {
    @Test func startCapturesOutputAndStopKillsGroup() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(
            command: ["/bin/sh", "-c", "echo started; sleep 30"], name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        /** start() settles at spawn; health promotion to `running` follows. */
        #expect(started.phase == .starting)
        #expect(started.pid != nil)
        try await Task.sleep(for: .milliseconds(300))
        let spool = paths.structuredLogFile(project: env.projectPath, server: "web")
        let contents = try String(contentsOf: spool, encoding: .utf8)
        #expect(contents.contains("started"))
        let stopped = await supervisor.stop(graceSeconds: 2)
        #expect(stopped.phase == .stopped)
        #expect(stopped.pid == nil)
        if let pid = started.pid {
            #expect(kill(pid_t(pid), 0) != 0)
        }
    }

    @Test func spawnFailureIsFailedNotCrashed() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/nonexistent/binary-xyz"], name: "bad")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let status = await supervisor.start()
        #expect(status.phase == .failed)
        #expect(status.spawnError != nil)
        #expect(status.pid == nil)
    }

    @Test func deliberateStopRetiresBootIntent() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web")
        let id = serverID(project: env.projectPath, name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        /** Start records the intent to come back after a reboot. */
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == true)
        _ = await supervisor.stop(graceSeconds: 2, deliberate: true)
        /** A deliberate stop retires it: the user asked for down. */
        #expect(await registry.persistedState(serverID: id)?.resumeOnBoot == nil)
    }

    @Test func drainStopPreservesBootIntent() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web")
        let id = serverID(project: env.projectPath, name: "web")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        _ = await supervisor.stop(graceSeconds: 2, deliberate: false)
        /** A launchd drain keeps the intent so the next boot restores the server,
            while the drained phase reads stopped. */
        let persisted = await registry.persistedState(serverID: id)
        #expect(persisted?.phase == .stopped)
        #expect(persisted?.resumeOnBoot == true)
    }

    @Test func crashRecordsExitForensics() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "exit 3"], name: "flaky")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        /** The exit lands asynchronously; poll briefly for the phase transition. */
        var status = await supervisor.status()
        for _ in 0..<50 where status.phase != .crashed {
            try await Task.sleep(for: .milliseconds(100))
            status = await supervisor.status()
        }
        #expect(status.phase == .crashed)
        #expect(status.lastExit?.code == 3)
        /** Forensics survive into the persisted state file. */
        let persisted = await registry.persistedState(serverID: serverID(project: env.projectPath, name: "flaky"))
        #expect(persisted?.lastExit?.code == 3)
    }

    @Test func crashKillsSessionGrandchild() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(
            command: [fixture, "--spawn-grandchild", "--exit-after", "0.6", "--code", "1"],
            name: "composite")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        let started = await supervisor.start()
        #expect(started.pid != nil)
        var grandchild: pid_t?
        for _ in 0..<40 {
            let spool =
                (try? String(
                    contentsOf: paths.structuredLogFile(
                        project: env.projectPath, server: "composite"),
                    encoding: .utf8)) ?? ""
            if let match = spool.range(of: #"grandchild pid (\d+)"#, options: .regularExpression) {
                let line = String(spool[match])
                grandchild = line.split(separator: " ").last.flatMap { pid_t($0) }
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let child = try #require(grandchild)
        #expect(kill(child, 0) == 0)
        let crashed = try await waitForPhase(supervisor, .crashed, tries: 80)
        #expect(crashed.phase == .crashed)
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(child, 0) != 0)
    }

    /** Poll the supervisor until it reaches `phase` or the budget runs out. */
    private func waitForPhase(
        _ supervisor: ServerSupervisor, _ phase: ServerPhase, tries: Int = 50
    ) async throws -> ServerStatus {
        var status = await supervisor.status()
        for _ in 0..<tries where status.phase != phase {
            try await Task.sleep(for: .milliseconds(100))
            status = await supervisor.status()
        }
        return status
    }

    @Test func crashCapturesErrorLineTally() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(
            command: ["/bin/sh", "-c", "echo boom >&2; echo bang >&2; exit 1"], name: "noisy")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let status = try await waitForPhase(supervisor, .crashed)
        #expect(status.phase == .crashed)
        /** Two stderr lines this run: devctl's own count, not the lines. */
        #expect(status.errorSummary?.count == 2)
        #expect(status.errorSummary.map { $0.lastAt >= $0.firstAt } == true)
        /** And it survives into the state file for a post-restart read. */
        let persisted = await registry.persistedState(
            serverID: serverID(project: env.projectPath, name: "noisy"))
        #expect(persisted?.errorSummary?.count == 2)
    }

    @Test func respawnClearsThePreviousRunsTally() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        /** First run writes one stderr line and crashes; the second is quiet and
            sleeps, so its live tally must not inherit the first run's count. */
        let spec = ServerSpec(
            command: ["/bin/sh", "-c", "echo once >&2; exit 1"], name: "cycle")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let crashed = try await waitForPhase(supervisor, .crashed)
        #expect(crashed.errorSummary?.count == 1)
        await supervisor.updateSpec(ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "cycle"))
        _ = await supervisor.start()
        /** A fresh run starts with no tally; it fills only on the next failure. */
        #expect(await supervisor.status().errorSummary == nil)
        _ = await supervisor.stop(graceSeconds: 1)
    }

    @Test func errorSummaryRehydratesFromStateFile() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let id = serverID(project: env.projectPath, name: "web")
        /** A prior daemon left a crashed row with a tally; a fresh supervisor for
            the same server surfaces it without re-running anything. */
        let seed = Registry(paths: paths)
        try await seed.updateState(serverID: id) { entry in
            entry.errorSummary = ErrorSummary(
                count: 4,
                firstAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastAt: Date(timeIntervalSince1970: 1_700_000_009))
            entry.phase = .crashed
        }
        let registry = Registry(paths: paths)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web"))
        let status = await supervisor.status()
        #expect(status.phase == .crashed)
        #expect(status.errorSummary?.count == 4)
    }

    @Test func concurrentStartsSingleFlight() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "solo")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        async let a = supervisor.start()
        async let b = supervisor.start()
        let (first, second) = await (a, b)
        #expect(first.pid == second.pid)
        _ = await supervisor.stop(graceSeconds: 1)
    }
}

@Suite struct RegistryTests {
    @Test func registerPersistsAcrossReload() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(command: ["echo"], name: "web", port: 3000)
        try await registry.register(project: "/p", spec: spec)
        let reloaded = Registry(paths: paths)
        #expect(await reloaded.spec(project: "/p", name: "web") == spec)
    }

    @Test func unregisterRemovesEmptyProject() async throws {
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        try await registry.register(project: "/p", spec: ServerSpec(command: ["echo"], name: "web"))
        try await registry.unregister(project: "/p", name: "web")
        #expect(await registry.project("/p") == nil)
    }
}

private func fixtureServerExecutable() -> String? {
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
