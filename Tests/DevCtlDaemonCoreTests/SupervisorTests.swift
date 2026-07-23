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
