import DevCtlKit
import Foundation
import Testing

@testable import DevCtlDaemonCore

private struct RecoverEnv {
    let paths: DevCtlPaths
    let projectPath: String
}

private func makeRecoverEnv() throws -> RecoverEnv {
    let base = FileManager.default.temporaryDirectory.appending(path: "devctl-recover-\(UUID().uuidString)")
    let project = base.appending(path: "proj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    return RecoverEnv(
        paths: DevCtlPaths(dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
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

    /** A rename leaves resume intent under the old name. Recover must drop the
        orphan row, not resurrect a ghost. */
    @Test func dropsOrphanStateWhenSpecMissing() async throws {
        let env = try makeRecoverEnv()
        try writeDevservers(
            project: env.projectPath,
            serversJSON: """
            {
              "candor": {
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
}
