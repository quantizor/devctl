import DirectaKit
import Foundation
import Testing

@testable import DirectaDaemonCore

/** Two sessions calling `ensure` on the same server at the same moment is the
    ordinary case for this tool, not an edge one: agents run concurrently, and
    the session-start hook plus a hand-typed command can land together. The
    invariant is that the second caller joins the first spawn rather than racing
    it, so exactly one process exists and both callers are told the same pid.

    `docs/design.md` promised this as an end-to-end test in a target that only
    ever held `#expect(Bool(true))`, so the promise outlived the coverage. */
@Suite(.serialized) struct ConcurrentEnsureTests {
    private func env(port: Int) throws -> (paths: DirectaPaths, project: String) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "directa-concurrent-\(UUID().uuidString)")
        let project = base.appending(path: "proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fixture = try #require(fixtureServerExecutable())
        let body = """
            {
              "servers": {
                "web": {
                  "command": ["\(fixture)", "--listen-tcp", "\(port)"],
                  "healthcheck": { "type": "tcp", "port": \(port) },
                  "port": \(port)
                }
              },
              "version": 1
            }
            """
        try Data(body.utf8).write(to: project.appending(path: "devservers.json"))
        return (
            paths: DirectaPaths(
                dataDir: base.appending(path: "data"), logsDir: base.appending(path: "logs")),
            project: project.path
        )
    }

    private func ensure(_ router: Router, project: String) async throws -> EnsureResult {
        let line = try NDJSON.encodeLine(
            WireRequest(
                id: "e", method: WireMethod.serverEnsure.rawValue,
                params: EnsureParams(name: "web", project: project, timeoutSeconds: 15)))
        let response = try JSONCoding.decoder().decode(
            WireResponse<EnsureResult>.self, from: await router.handle(line: line))
        if response.ok, let result = response.result { return result }
        throw response.error ?? WireError(code: .internalError, message: "ensure returned nothing")
    }

    private func stop(_ router: Router, project: String) async {
        guard
            let line = try? NDJSON.encodeLine(
                WireRequest(
                    id: "s", method: WireMethod.serverStop.rawValue,
                    params: ServerTargetParams(name: "web", project: project)))
        else { return }
        _ = await router.handle(line: line)
    }

    @Test func simultaneousEnsuresProduceOneProcess() async throws {
        let env = try env(port: 45471)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        /** Eight at once rather than two: a single pair can pass by luck if the
            first happens to finish before the second is dispatched. */
        let results = try await withThrowingTaskGroup(of: EnsureResult.self) { group in
            for _ in 0..<8 {
                group.addTask { try await self.ensure(router, project: env.project) }
            }
            var collected: [EnsureResult] = []
            for try await result in group { collected.append(result) }
            return collected
        }

        #expect(results.count == 8)
        let pids = Set(results.compactMap(\.server.pid))
        #expect(pids.count == 1, "each caller should see the same process, saw pids \(pids)")
        for result in results {
            #expect(result.server.phase == .running)
        }

        /** The claim that matters is about the machine, not the replies: a
            second spawn that the supervisor forgot about would still be holding
            the port and would not show up in any of the answers above. */
        let pid = try #require(pids.first)
        let live: [pid_t] = ProcessTree.descendants(of: pid_t(pid)).identities.map(\.pid)
        #expect(live.isEmpty, "the one server spawned unexpected children: \(live)")

        /** Awaited, never a detached Task in a defer: that returns immediately
            and the test process can exit before the stop lands, leaking a server
            that squats this port for the next run. */
        await stop(router, project: env.project)
    }

    /** The same burst with no `stop` mixed in, which is the half that is known
        to hold. Interleaving a stop kills the test process outright; that is
        written up in BACKLOG.md with its reproduction rather than committed as
        a test that takes the suite down with it. */
    @Test func repeatedEnsuresNeverLeaveASecondListener() async throws {
        let env = try env(port: 45472)
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.project)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)

        _ = try await ensure(router, project: env.project)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { _ = try? await self.ensure(router, project: env.project) }
            }
        }
        await stop(router, project: env.project)

        /** Asks the port itself rather than the daemon, because the daemon's own
            view is exactly what a leaked process would be missing from. */
        var free = false
        for _ in 0..<50 where !free {
            free = !LoopbackProbe.isListening(port: 45472)
            if !free { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(free, "port 45472 is still held after every server was stopped")
    }
}
