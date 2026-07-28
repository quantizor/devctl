import DevCtlKit
import Foundation
import Testing

@testable import DevCtlDaemonCore

/** Two checkouts of one project declare the same committed port, so every
    start-shaped path must refuse the second binder loudly instead of letting two
    processes silently fight over the port. These share the same declared port
    numbers, so the suite is serialized. */
@Suite(.serialized) struct PortOwnershipTests {
    private struct Env {
        let paths: DevCtlPaths
        let projectA: String
        let projectB: String
    }

    private func makeEnv() throws -> Env {
        let base = FileManager.default.temporaryDirectory.appending(path: "devctl-port-\(UUID().uuidString)")
        let a = base.appending(path: "checkout-a")
        let b = base.appending(path: "checkout-b")
        for dir in [a, b] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return Env(
            paths: DevCtlPaths(dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
            projectA: a.path, projectB: b.path)
    }

    private func handle<P: Codable & Sendable, R: Codable & Sendable>(
        _ router: Router, _ method: WireMethod, _ params: P, _ expecting: R.Type
    ) async -> Result<R, WireError> {
        do {
            let line = try NDJSON.encodeLine(WireRequest(id: "t", method: method.rawValue, params: params))
            let data = await router.handle(line: line)
            let response = try JSONCoding.decoder().decode(WireResponse<R>.self, from: data)
            if response.ok, let result = response.result { return .success(result) }
            return .failure(response.error ?? WireError(code: .internalError, message: "no result"))
        } catch let error as WireError {
            return .failure(error)
        } catch {
            return .failure(WireError(code: .internalError, message: "\(error)"))
        }
    }

    /** A long-lived sleeper with a declared port. It never binds the port, so any
        refusal comes from devctl's own bookkeeping (managed holder or persisted
        row), never from the loopback listener probe. */
    private func sleeperSpec(name: String, port: Int) -> ServerSpec {
        ServerSpec(command: ["/bin/sh", "-c", "sleep 60"], name: name, port: port)
    }

    @Test func ensureRefusesAPortAnotherProjectHolds() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.projectA, spec: sleeperSpec(name: "web", port: 45001))
        try await registry.register(project: env.projectB, spec: sleeperSpec(name: "web", port: 45001))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = await handle(router, .serverStart, ServerTargetParams(name: "web", project: env.projectA), ServerResult.self)
        let refused = await handle(
            router, .serverEnsure, EnsureParams(name: "web", project: env.projectB, timeoutSeconds: 3),
            EnsureResult.self)
        guard case .failure(let error) = refused else {
            Issue.record("expected the second checkout to be refused")
            return
        }
        #expect(error.code == .portHeld)
        /** The message names the holding project, not a bare number. */
        #expect(error.message.contains("45001"))
        #expect(error.message.contains(env.projectA))
        await teardown(router, env.projectA, "web")
    }

    @Test func groupUpRefusesWhenTheDeclaredPortIsHeld() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.projectA, spec: sleeperSpec(name: "web", port: 45002))
        /** Checkout B brings its server up through devctl up, the path that used
            to skip the pre-check entirely. */
        try writeDevserversPort(project: env.projectB, name: "web", port: 45002)
        try await registry.setTrusted(project: env.projectB)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = await handle(router, .serverStart, ServerTargetParams(name: "web", project: env.projectA), ServerResult.self)
        let refused = await handle(
            router, .groupUp, GroupParams(project: env.projectB, timeoutSeconds: 3), GroupResult.self)
        guard case .failure(let error) = refused else {
            Issue.record("expected group up to refuse the held port")
            return
        }
        #expect(error.code == .portHeld)
        await teardown(router, env.projectA, "web")
    }

    @Test func aRunningTargetIsNotRefusedAgainstItself() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.projectA, spec: sleeperSpec(name: "web", port: 45003))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = await handle(router, .serverStart, ServerTargetParams(name: "web", project: env.projectA), ServerResult.self)
        /** Ensuring the same already-up server must not trip the port check on its
            own listener. */
        let again = await handle(
            router, .serverEnsure, EnsureParams(name: "web", project: env.projectA, timeoutSeconds: 3),
            EnsureResult.self)
        guard case .success = again else {
            Issue.record("re-ensuring a running server should not be refused")
            return
        }
        await teardown(router, env.projectA, "web")
    }

    @Test func aHolderWithNoResidentSupervisorStillRefuses() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        /** A holder from before this daemon started: it has a persisted running
            row and a spec, but no supervisor in the pool. Model that with a real
            sleeping process whose pid the row records. */
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        holder.arguments = ["60"]
        try holder.run()
        defer { holder.terminate() }
        try await registry.register(project: env.projectA, spec: sleeperSpec(name: "web", port: 45004))
        let idA = serverID(project: env.projectA, name: "web")
        try await registry.updateState(serverID: idA) { entry in
            entry.phase = .running
            entry.pid = Int(holder.processIdentifier)
        }
        try await registry.register(project: env.projectB, spec: sleeperSpec(name: "web", port: 45004))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        /** B is the first thing this router touches, so A never becomes resident. */
        let refused = await handle(
            router, .serverEnsure, EnsureParams(name: "web", project: env.projectB, timeoutSeconds: 3),
            EnsureResult.self)
        guard case .failure(let error) = refused else {
            Issue.record("expected refusal from the persisted holder")
            return
        }
        #expect(error.code == .portHeld)
        #expect(error.message.contains(env.projectA))
    }

    private func teardown(_ router: Router, _ project: String, _ name: String) async {
        _ = await handle(router, .serverStop, ServerTargetParams(name: name, project: project), ServerResult.self)
    }

    private func writeDevserversPort(project: String, name: String, port: Int) throws {
        let body = """
        {
          "servers": {
            "\(name)": { "command": ["/bin/sh", "-c", "sleep 60"], "port": \(port) }
          },
          "version": 1
        }
        """
        try Data(body.utf8).write(to: URL(fileURLWithPath: project).appending(path: "devservers.json"))
    }
}
