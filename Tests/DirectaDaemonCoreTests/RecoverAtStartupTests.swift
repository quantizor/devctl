import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

private struct RecoverEnv {
    let paths: DirectaPaths
    let projectPath: String
}

private func makeRecoverEnv() throws -> RecoverEnv {
    let base = FileManager.default.temporaryDirectory.appending(path: "directa-recover-\(UUID().uuidString)")
    let project = base.appending(path: "proj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    return RecoverEnv(
        paths: DirectaPaths(dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
        projectPath: project.path)
}

private func writeDevservers(project: String, serversJSON: String) throws {
    let body = """
    {
      "servers": \(serversJSON),
      "version": 1
    }
    """
    try Data(body.utf8).write(
        to: URL(fileURLWithPath: project).appending(path: "devservers.json"))
}

private func statusList(router: Router, project: String) async throws -> [ServerStatus] {
    let line = try NDJSON.encodeLine(
        WireRequest(
            id: "status", method: WireMethod.serverStatus.rawValue,
            params: ProjectParams(project: project)))
    let data = await router.handle(line: line)
    let response = try JSONCoding.decoder().decode(WireResponse<ServerListResult>.self, from: data)
    guard response.ok, let result = response.result else {
        throw WireError(code: .internalError, message: response.error?.message ?? "status failed")
    }
    return result.servers
}

private func stopServer(router: Router, project: String, name: String) async {
    let line = try? NDJSON.encodeLine(
        WireRequest(
            id: "stop", method: WireMethod.serverStop.rawValue,
            params: ServerTargetParams(name: name, project: project)))
    guard let line else { return }
    _ = await router.handle(line: line)
}

@Suite struct RecoverAtStartupTests {
    /** Config-defined servers live only in devservers.json (registry.servers is
        empty for them). Boot restore must still find the spec and bring them up. */
    @Test func restoresConfigDefinedServerWithResumeIntent() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.updateState(serverID: id) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = true
            entry.pid = nil
        }
        #expect(await registry.spec(project: env.projectPath, name: "web") == nil)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        let web = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "web" }
        #expect(web != nil)
        #expect(web?.phase == .starting || web?.phase == .running)
        #expect(web?.pid != nil)
        await stopServer(router: router, project: env.projectPath, name: "web")
    }

    /** The trust gate. A malicious repo's devservers.json must never be
        auto-started: boot restore resolves the committed spec but `prepareSpawn`
        refuses it while the project's config has never been approved (no trust
        flag), so the server stays down. The mirror of
        `restoresConfigDefinedServerWithResumeIntent`, which sets trust and does
        spawn; the only difference here is the missing approval. */
    @Test func untrustedConfigDefinedServerIsNotRestored() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        /** Deliberately not trusted: no start-shaped command ever approved it. */
        let id = serverID(project: env.projectPath, name: "web")
        try await registry.updateState(serverID: id) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = true
            entry.pid = nil
        }
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        let web = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "web" }
        #expect(web?.pid == nil)
        #expect(web?.phase != .running)
        #expect(web?.phase != .starting)
        /** Recover is autonomous, so it must not silently grant trust either. */
        #expect(await registry.isTrusted(project: env.projectPath) == false)
    }

    /** A rename leaves resume intent under the old name. Recover must drop the
        orphan row, not resurrect a ghost. */
    @Test func dropsOrphanStateWhenSpecMissing() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "myproj": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let staleID = serverID(project: env.projectPath, name: "dev")
        try await registry.updateState(serverID: staleID) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = true
        }
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        #expect(await registry.persistedState(serverID: staleID) == nil)
        let statuses = try await statusList(router: router, project: env.projectPath)
        #expect(statuses.contains { $0.server == "dev" } == false)
        #expect(statuses.allSatisfy { $0.phase == .stopped })
    }

    /** A stopped row under a deleted name (no resume intent) is still pruned. */
    @Test func prunesStoppedOrphanWithoutResumeIntent() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let staleID = serverID(project: env.projectPath, name: "old")
        try await registry.updateState(serverID: staleID) { entry in
            entry.phase = .stopped
            entry.resumeOnBoot = nil
        }
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        #expect(await registry.persistedState(serverID: staleID) == nil)
    }

    /** Pre-feature state.json may lack resumeOnBoot. A phase left running still
        restores (daemon-crash case), using the config spec. */
    @Test func restoresLeftActivePhaseWithoutResumeFlag() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "api": {
                "command": ["/bin/sh", "-c", "sleep 30"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        let id = serverID(project: env.projectPath, name: "api")
        try await registry.updateState(serverID: id) { entry in
            entry.phase = .running
            entry.resumeOnBoot = nil
            entry.pid = nil
        }
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        await router.recoverAtStartup()
        let api = try await statusList(router: router, project: env.projectPath)
            .first { $0.server == "api" }
        #expect(api?.phase == .starting || api?.phase == .running)
        #expect(api?.pid != nil)
        await stopServer(router: router, project: env.projectPath, name: "api")
    }

    @Test func whyDiagnosesConfigDefinedServer() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "web": {
                "command": ["/bin/sh", "-c", "exit 7"]
              }
            }
            """)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectPath)
        #expect(await registry.spec(project: env.projectPath, name: "web") == nil)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        let startLine = try NDJSON.encodeLine(
            WireRequest(
                id: "start", method: WireMethod.serverStart.rawValue,
                params: ServerTargetParams(name: "web", project: env.projectPath)))
        _ = await router.handle(line: startLine)
        var phase: ServerPhase = .starting
        for _ in 0..<50 {
            let web = try await statusList(router: router, project: env.projectPath)
                .first { $0.server == "web" }
            phase = web?.phase ?? .starting
            if phase == .crashed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(phase == .crashed)
        let whyLine = try NDJSON.encodeLine(
            WireRequest(
                id: "why", method: WireMethod.serverWhy.rawValue,
                params: ServerTargetParams(name: "web", project: env.projectPath)))
        let whyData = await router.handle(line: whyLine)
        let whyResponse = try JSONCoding.decoder().decode(
            WireResponse<WhyResult>.self, from: whyData)
        #expect(whyResponse.ok == true)
        #expect(whyResponse.result?.findings.isEmpty == false)
        #expect(whyResponse.result?.findings.first?.server == "web")
        #expect(whyResponse.result?.rootCause?.contains("crashed") == true)
    }
}
