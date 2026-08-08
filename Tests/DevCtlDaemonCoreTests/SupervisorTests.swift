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
        /** The descendant sweep runs after the phase turns, so poll for the
            outcome rather than sleeping a fixed slice: under load that fixed
            wait expires before the sweep lands and fails a working teardown. */
        var reaped = false
        for _ in 0..<100 where !reaped {
            if kill(child, 0) != 0 {
                reaped = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        /** A bare verdict here cost several sessions: "Expectation failed:
            reaped" says a descendant survived but not which one, whose child it
            was, or what group it was in, which are the three facts that separate
            a missed snapshot from a group-kill that could never have reached
            it. */
        #expect(
            reaped,
            """
            grandchild \(child) survived the crash teardown
              pgid: \(getpgid(child)) (root pid was \(started.pid.map(String.init) ?? "nil"))
              ppid: \(ProcessTree.identity(of: child) == nil ? "gone" : String(describing: parentPid(of: child)))
              state: \(processState(of: child))
            """)
        if !reaped { kill(child, SIGKILL) }
    }

    /** Reads a live process's parent from ps, for failure evidence only. */
    private func parentPid(of pid: pid_t) -> String {
        shell(["/bin/ps", "-o", "ppid=", "-p", String(pid)])
    }

    private func processState(of pid: pid_t) -> String {
        let state = shell(["/bin/ps", "-o", "state=", "-p", String(pid)])
        return state.isEmpty ? "not in the process table" : state
    }

    private func shell(_ argv: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /** The same teardown guarantee, with the timing that used to decide it made
        explicit instead of left to machine load.

        Foundation's `Process` puts its child in a NEW process group, so the
        crash path's group-directed kill provably cannot reach a grandchild and
        the descendant snapshot is the only thing that can. That snapshot was
        taken once at spawn and once 100ms later, and for a server with no
        healthcheck the first health probe (which also refreshes it) waits out a
        two second stabilization window. A grandchild appearing in between was
        therefore in no snapshot at all, and a crash orphaned it permanently.

        `crashKillsSessionGrandchild` above spawns its grandchild immediately and
        so usually wins that race, which is exactly why it failed only under
        load. This one spawns at 400ms and loses it every time. */
    @Test func crashKillsAGrandchildSpawnedAfterTheEarlySnapshot() async throws {
        let fixture = try #require(fixtureServerExecutable())
        let env = try makeEnv()
        let paths = env.paths
        let registry = Registry(paths: paths)
        let spec = ServerSpec(
            command: [
                fixture, "--spawn-grandchild", "--grandchild-after", "0.4",
                "--exit-after", "1.0", "--code", "1",
            ],
            name: "late")
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: paths, projectPath: env.projectPath,
            registry: registry, spec: spec)
        #expect(await supervisor.start().pid != nil)

        var grandchild: pid_t?
        for _ in 0..<60 where grandchild == nil {
            let log =
                (try? String(
                    contentsOf: paths.structuredLogFile(project: env.projectPath, server: "late"),
                    encoding: .utf8)) ?? ""
            if let match = log.range(of: #"grandchild pid (\d+)"#, options: .regularExpression) {
                grandchild = String(log[match]).split(separator: " ").last.flatMap { pid_t($0) }
            }
            if grandchild == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let child = try #require(grandchild, "fixture never reported a grandchild pid")
        /** The premise, asserted rather than assumed: if this ever spawned into
            the root's group, the group kill would cover it and this test would
            be proving nothing. */
        #expect(getpgid(child) == child)

        let crashed = try await waitForPhase(supervisor, .crashed, tries: 80)
        #expect(crashed.phase == .crashed)

        var reaped = false
        for _ in 0..<100 where !reaped {
            if kill(child, 0) != 0 { reaped = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if !reaped {
            /** Names the survivor and its parent, so a failure carries the
                evidence rather than only the verdict. */
            kill(child, SIGKILL)
        }
        #expect(reaped, "grandchild \(child) survived the crash teardown (pgid \(getpgid(child)))")
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

/** Shared with the port-ownership suite, which needs the same test double. */
func fixtureServerExecutable() -> String? {
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
