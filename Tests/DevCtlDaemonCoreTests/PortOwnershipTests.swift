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

    /** `why` is the command a reader reaches for after a refusal, so it has to
        name the holder itself rather than answering only "not running
        (stopped)". That requires it to annotate latent conflicts the way the
        status handler does. */
    @Test func whyNamesTheHolderOfAStoppedServersPort() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.projectA, spec: sleeperSpec(name: "web", port: 45005))
        try await registry.register(project: env.projectB, spec: sleeperSpec(name: "web", port: 45005))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = await handle(router, .serverStart, ServerTargetParams(name: "web", project: env.projectA), ServerResult.self)

        let answer = await handle(
            router, .serverWhy, ServerTargetParams(name: "web", project: env.projectB), WhyResult.self)
        guard case .success(let why) = answer else {
            Issue.record("why should answer for a stopped server")
            await teardown(router, env.projectA, "web")
            return
        }
        let rootCause = try #require(why.rootCause)
        #expect(rootCause.contains("45005"))
        #expect(rootCause.contains(env.projectA))
        /** The holder belongs in the root cause, not only buried in evidence. */
        #expect(!rootCause.hasSuffix("not running (stopped)"))
        await teardown(router, env.projectA, "web")
    }

    /** The machine-wide sweep feeds `doctor` and the menu bar app, and skipped
        the annotation entirely. */
    @Test func statusAcrossAllProjectsAnnotatesTheHeldPort() async throws {
        let env = try makeEnv()
        let registry = Registry(paths: env.paths)
        try await registry.register(project: env.projectA, spec: sleeperSpec(name: "web", port: 45006))
        try await registry.register(project: env.projectB, spec: sleeperSpec(name: "web", port: 45006))
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = await handle(router, .serverStart, ServerTargetParams(name: "web", project: env.projectA), ServerResult.self)

        let listed = await handle(
            router, .serverStatus, ProjectParams(project: ""), ServerListResult.self)
        guard case .success(let all) = listed else {
            Issue.record("machine-wide status should answer")
            await teardown(router, env.projectA, "web")
            return
        }
        /** The registry canonicalizes project paths, so compare in that form. */
        let stopped = try #require(
            all.servers.first { $0.project == canonicalProjectPath(env.projectB) })
        let conflict = try #require(stopped.portConflict)
        #expect(conflict.state == .held)
        #expect(conflict.message.contains(env.projectA))
        await teardown(router, env.projectA, "web")
    }

    /** Waits for a phase, polling rather than sleeping a fixed span. */
    private func settle(
        _ supervisor: ServerSupervisor, until predicate: @Sendable (ServerStatus) -> Bool
    ) async -> ServerStatus {
        var status = await supervisor.status()
        for _ in 0..<60 where !predicate(status) {
            try? await Task.sleep(for: .milliseconds(100))
            status = await supervisor.status()
        }
        return status
    }

    /** The failure that motivated this check: another project's server holds the
        port, answers the healthcheck, and every liveness signal reads green while
        this server is not serving at all. */
    @Test func aHealthcheckAnsweredByAForeignProcessFailsTheServer() async throws {
        guard let fixture = fixtureServerExecutable() else {
            Issue.record("fixture-server is not built; run swift build")
            return
        }
        let env = try makeEnv()
        let port = 45007
        let registry = Registry(paths: env.paths)
        /** The thief is another server this daemon supervises, which is what the
            real incident looked like: two projects, one port, whichever bound
            first answers for both. */
        let thiefSpec = ServerSpec(
            command: [fixture, "--listen-tcp", String(port)], name: "web", port: port)
        try await registry.register(project: env.projectB, spec: thiefSpec)
        let thief = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectB,
            registry: registry, spec: thiefSpec)
        _ = await thief.start()
        _ = await settle(thief) { $0.phase == .running }

        /** The victim never binds anything, so the only listener on the port
            belongs to the thief, yet its TCP healthcheck still passes. */
        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web", port: port)
        try await registry.register(project: env.projectA, spec: spec)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectA,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let settled = await settle(supervisor) { $0.phase == .failed }
        #expect(settled.phase == .failed)
        let conflict = try #require(settled.portConflict)
        #expect(conflict.state == .foreign)
        #expect(conflict.message.contains("\(port)"))
        /** Names the managed server, not just a pid, so the reader can act. */
        #expect(conflict.holder?.contains(env.projectB) == true)
        #expect(settled.spawnError?.message.contains("\(port)") == true)
        _ = await supervisor.stop(graceSeconds: 2)
        _ = await thief.stop(graceSeconds: 2)
    }

    /** The control. Same shape, except the supervised process owns the port, so
        the check must stay silent. Without this a probe that always reported a
        foreign owner would pass the test above and look like a working feature. */
    @Test func aServerThatOwnsItsPortStaysHealthy() async throws {
        guard let fixture = fixtureServerExecutable() else {
            Issue.record("fixture-server is not built; run swift build")
            return
        }
        let env = try makeEnv()
        let port = 45008
        let registry = Registry(paths: env.paths)
        let spec = ServerSpec(
            command: [fixture, "--listen-tcp", String(port)], name: "web", port: port)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectA,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        /** The listen scan runs in its own task after health promotion, so wait
            for the scan's result rather than for `running` alone. */
        let settled = await settle(supervisor) {
            ($0.phase == .running && $0.observedPort != nil) || $0.phase == .failed
        }
        #expect(settled.phase == .running)
        #expect(settled.portConflict == nil)
        #expect(settled.observedPort == port)
        _ = await supervisor.stop(graceSeconds: 2)
    }

    @Test func extrasAreKeptAndAreNotDrift() async throws {
        guard let fixture = fixtureServerExecutable() else {
            Issue.record("fixture-server is not built; run swift build")
            return
        }
        let env = try makeEnv()
        let primary = 45020
        let extra = 45021
        let registry = Registry(paths: env.paths)
        let spec = ServerSpec(
            command: [fixture, "--listen-tcp", String(primary), "--listen-tcp", String(extra)],
            name: "web", port: primary)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectA,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let settled = await settle(supervisor) {
            ($0.phase == .running && ($0.observedPorts?.contains(extra) ?? false))
                || $0.phase == .failed
        }
        #expect(settled.phase == .running)
        #expect(settled.portConflict == nil)
        #expect(settled.observedPort == primary)
        #expect(settled.observedPorts == [primary, extra])
        #expect(settled.extraPorts == [extra])
        #expect(settled.holds(extra))
        _ = await supervisor.stop(graceSeconds: 2)
        let stopped = await supervisor.status()
        #expect(stopped.observedPort == nil)
        #expect(stopped.observedPorts == [primary, extra])
        let id = serverID(project: env.projectA, name: "web")
        #expect(await registry.persistedState(serverID: id)?.observedPorts == [primary, extra])
    }

    @Test func anExtraPortIsAManagedHold() async throws {
        guard let fixture = fixtureServerExecutable() else {
            Issue.record("fixture-server is not built; run swift build")
            return
        }
        let env = try makeEnv()
        let primary = 45022
        let extra = 45023
        let registry = Registry(paths: env.paths)
        try await registry.register(
            project: env.projectA,
            spec: ServerSpec(
                command: [fixture, "--listen-tcp", String(primary), "--listen-tcp", String(extra)],
                name: "web", port: primary))
        try await registry.register(
            project: env.projectB, spec: sleeperSpec(name: "web", port: extra))
        try await registry.setTrusted(project: env.projectB)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = await handle(
            router, .serverStart, ServerTargetParams(name: "web", project: env.projectA),
            ServerResult.self)
        var status = ServerStatus(logPath: "", phase: .stopped, project: env.projectA, server: "web")
        for _ in 0..<60 {
            if case .success(let list) = await handle(
                router, .serverStatus, ProjectParams(project: env.projectA), ServerListResult.self),
                let server = list.servers.first,
                server.observedPorts?.contains(extra) == true
            {
                status = server
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(status.observedPorts?.contains(extra) == true)
        let refused = await handle(
            router, .serverEnsure,
            EnsureParams(name: "web", project: env.projectB, timeoutSeconds: 3),
            EnsureResult.self)
        guard case .failure(let error) = refused else {
            Issue.record("expected the extra port to be held")
            await teardown(router, env.projectA, "web")
            return
        }
        #expect(error.code == .portHeld)
        #expect(error.message.contains(String(extra)))
        #expect(error.message.contains("managed server"))
        #expect(error.message.contains(env.projectA))
        await teardown(router, env.projectA, "web")
    }

    @Test func lockResumeRefusesWhileAnExtraPortStaysBusy() async throws {
        guard let fixture = fixtureServerExecutable() else {
            Issue.record("fixture-server is not built; run swift build")
            return
        }
        let env = try makeEnv()
        let primary = 45024
        let extra = 45025
        try Data(
            """
            {
              "servers": {
                "web": {
                  "command": ["\(fixture)", "--listen-tcp", "\(primary)", "--listen-tcp", "\(extra)"],
                  "locks": ["data"],
                  "port": \(primary)
                }
              },
              "version": 1
            }
            """.utf8
        ).write(to: URL(fileURLWithPath: env.projectA).appending(path: "devservers.json"))
        let registry = Registry(paths: env.paths)
        try await registry.setTrusted(project: env.projectA)
        let router = Router(launcher: SubprocessLauncher(), paths: env.paths, registry: registry)
        _ = await handle(
            router, .serverStart, ServerTargetParams(name: "web", project: env.projectA),
            ServerResult.self)
        for _ in 0..<60 {
            if case .success(let list) = await handle(
                router, .serverStatus, ProjectParams(project: env.projectA), ServerListResult.self),
                list.servers.first?.observedPorts?.contains(extra) == true
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let acquired = await handle(
            router, .lockAcquire,
            LockParams(
                holderPid: Int(getpid()), project: env.projectA, resource: "data",
                resumeTimeoutSeconds: 8),
            LockResult.self)
        guard case .success = acquired else {
            Issue.record("expected lock acquire to pause the server")
            await teardown(router, env.projectA, "web")
            return
        }
        for _ in 0..<40 where LoopbackProbe.isListening(port: extra) {
            try await Task.sleep(for: .milliseconds(50))
        }
        /** After pause, occupy the extra port so resume must wait on last listen. */
        let leftover = Process()
        leftover.executableURL = URL(fileURLWithPath: fixture)
        leftover.arguments = ["--listen-tcp", String(extra)]
        leftover.standardOutput = FileHandle.nullDevice
        leftover.standardError = FileHandle.nullDevice
        try leftover.run()
        defer { leftover.terminate() }
        var bound = false
        for _ in 0..<40 {
            if LoopbackProbe.isListening(port: extra) {
                bound = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(bound)
        _ = await handle(
            router, .lockRelease,
            LockParams(
                holderPid: Int(getpid()), project: env.projectA, resource: "data",
                resumeTimeoutSeconds: 8),
            LockResult.self)
        if case .success(let list) = await handle(
            router, .serverStatus, ProjectParams(project: env.projectA), ServerListResult.self),
            let server = list.servers.first
        {
            #expect(server.phase == .stopped)
        } else {
            Issue.record("expected status after a refused resume")
        }
        _ = await handle(
            router, .serverStop, ServerTargetParams(name: "web", project: env.projectA),
            ServerResult.self)
    }

    @Test func anOlderStateFileWithoutObservedPortsStillLoads() throws {
        let data = Data(#"{"phase":"stopped"}"#.utf8)
        let state = try JSONCoding.decoder().decode(PersistedServerState.self, from: data)
        #expect(state.observedPorts == nil)
        #expect(state.phase == .stopped)
    }

    /** ATTACK: the server's own listener lives outside its process tree. A
        container-backed server (docker compose) is the common shape: the
        listening socket belongs to the runtime, never to our children. Modelled
        here by a middle process that exits, reparenting the listener to launchd
        and out of the ppid chain the descendant sweep walks. Nothing was stolen,
        so failing this server would be wrong. */
    @Test func aServerWhoseListenerLeftTheProcessTreeIsNotTheft() async throws {
        guard let fixture = fixtureServerExecutable() else {
            Issue.record("fixture-server is not built; run swift build")
            return
        }
        let env = try makeEnv()
        let port = 45009
        let registry = Registry(paths: env.paths)
        /** The inner shell exits at once, so the listener reparents away. The
            outer shell stays alive as the supervised root. */
        let spec = ServerSpec(
            command: [
                "/bin/sh", "-c",
                "/bin/sh -c '\(fixture) --listen-tcp \(port) >/dev/null 2>&1 &' ; sleep 30",
            ],
            name: "web", port: port)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectA,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let settled = await settle(supervisor) {
            $0.phase == .failed || ($0.phase == .running && $0.portConflict != nil)
        }
        _ = await supervisor.stop(graceSeconds: 2)
        /** The reparented listener outlives the supervised tree by construction. */
        for stray in PortGuard.listenerPids(port: port) { kill(pid_t(stray), SIGKILL) }
        #expect(settled.phase != .failed)
    }

    /** ATTACK: a stale state row names a pid that macOS later handed to an
        unrelated process. Matching on the number alone would accuse an innocent
        managed server and fail this one for it. The row here claims a start time
        an hour before the listener actually started, which is what a recycled
        pid looks like. */
    @Test func aRecycledPidIsNotMistakenForAManagedThief() async throws {
        guard let fixture = fixtureServerExecutable() else {
            Issue.record("fixture-server is not built; run swift build")
            return
        }
        let env = try makeEnv()
        let port = 45010
        let registry = Registry(paths: env.paths)
        /** An unmanaged listener, started now. */
        let stranger = Process()
        stranger.executableURL = URL(fileURLWithPath: fixture)
        stranger.arguments = ["--listen-tcp", String(port)]
        stranger.standardOutput = FileHandle.nullDevice
        stranger.standardError = FileHandle.nullDevice
        try stranger.run()
        defer { stranger.terminate() }
        try await Task.sleep(for: .milliseconds(400))

        /** A stale row for another project claiming that very pid, recorded an
            hour ago: the pid matches, the identity cannot. */
        try await registry.register(project: env.projectB, spec: sleeperSpec(name: "web", port: port))
        try await registry.updateState(serverID: serverID(project: env.projectB, name: "web")) {
            entry in
            entry.phase = .running
            entry.pid = Int(stranger.processIdentifier)
            entry.startedAt = Date().addingTimeInterval(-3600)
        }

        let spec = ServerSpec(command: ["/bin/sh", "-c", "sleep 30"], name: "web", port: port)
        try await registry.register(project: env.projectA, spec: spec)
        let supervisor = ServerSupervisor(
            launcher: SubprocessLauncher(), paths: env.paths, projectPath: env.projectA,
            registry: registry, spec: spec)
        _ = await supervisor.start()
        let settled = await settle(supervisor) {
            $0.phase == .failed || ($0.phase == .running && $0.portConflict != nil)
        }
        _ = await supervisor.stop(graceSeconds: 2)
        /** Annotated, never failed: the accusation could not be substantiated. */
        #expect(settled.phase != .failed)
        #expect(settled.portConflict?.state == .foreign)
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
