import DevCtlKit
import Foundation

/** One actor per server: owns the child's lifecycle and serializes every mutation,
    which is what makes `ensure` single-flight (concurrent starts join the same
    in-flight attempt instead of double-spawning). */
public actor ServerSupervisor {
    public let projectPath: String

    private var lastExit: LastExit?
    private let launcher: any ProcessLauncher
    private let paths: DevCtlPaths
    private var phase: ServerPhase = .stopped
    private var pid: pid_t?
    private let registry: Registry
    private var runTask: Task<Void, Never>?
    private var spawnError: SpawnError?
    private var spawnWaiters: [CheckedContinuation<Void, Never>] = []
    private var spec: ServerSpec
    private var startedAt: Date?
    private var stopRequested = false

    public init(
        launcher: any ProcessLauncher,
        paths: DevCtlPaths,
        projectPath: String,
        registry: Registry,
        spec: ServerSpec
    ) {
        self.launcher = launcher
        self.paths = paths
        self.projectPath = projectPath
        self.registry = registry
        self.spec = spec
        if let persisted = AtomicFile.loadDefensively(StateFile.self, from: paths.stateFile)?
            .servers[serverID(project: projectPath, name: spec.name)] {
            self.lastExit = persisted.lastExit
            self.spawnError = persisted.spawnError
            if persisted.phase == .crashed || persisted.phase == .failed {
                self.phase = persisted.phase
            }
        }
    }

    public func updateSpec(_ newSpec: ServerSpec) {
        spec = newSpec
    }

    /** Starts the server if not already starting/running; otherwise joins the
        in-flight attempt. Returns once a pid exists or the spawn has failed. */
    public func start() async -> ServerStatus {
        switch phase {
        case .running, .unhealthy:
            return status()
        case .starting:
            await waitForSpawnSettled()
            return status()
        case .stopping:
            // A start during stop waits for the stop to land, then starts fresh.
            await waitForRunTaskCompletion()
            return await start()
        case .crashed, .failed, .stopped:
            break
        }
        phase = .starting
        stopRequested = false
        spawnError = nil
        let id = serverID(project: projectPath, name: spec.name)
        let argv = effectiveArgv()
        let cwd = effectiveCwd()
        let environment = spec.env ?? [:]
        let spoolURL = paths.spoolFile(project: projectPath, server: spec.name)
        do {
            try FileManager.default.createDirectory(
                at: spoolURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            await recordSpawnFailure(SpawnError(errno: nil, message: "cannot create log directory: \(error)"), id: id)
            return status()
        }
        let spoolFD = open(spoolURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard spoolFD >= 0 else {
            await recordSpawnFailure(
                SpawnError(errno: Int(errno), message: "cannot open spool: \(String(cString: strerror(errno)))"),
                id: id)
            return status()
        }
        runTask = Task { [launcher] in
            let outcome = await launcher.run(
                argv: argv,
                cwd: cwd,
                environment: environment,
                spoolFD: spoolFD,
                onSpawn: { [weak self] childPid in
                    await self?.recordSpawn(pid: childPid, id: id)
                }
            )
            close(spoolFD)
            await self.recordOutcome(outcome, id: id)
        }
        await waitForSpawnSettled()
        return status()
    }

    /** SIGTERM to the process group plus every stray descendant, grace period,
        then SIGKILL the same way. The session created at spawn makes pgid == pid,
        but children that setpgid/setsid themselves (Foundation Process does this
        by default) escape the group, so teardown also sweeps the descendant tree,
        snapshotted before the first signal since orphans reparent to launchd. */
    public func stop(graceSeconds: Double = 7) async -> ServerStatus {
        switch phase {
        case .stopped, .crashed, .failed:
            return status()
        case .stopping:
            await waitForRunTaskCompletion()
            return status()
        case .starting, .running, .unhealthy:
            break
        }
        guard let target = pid else {
            phase = .stopped
            return status()
        }
        stopRequested = true
        phase = .stopping
        let snapshot = ProcessTree.descendants(of: target)
        ProcessTree.signalTree(rootPid: target, descendants: snapshot, signal: SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(graceSeconds))
        while ContinuousClock.now < deadline {
            if runTask == nil { break }
            if kill(target, 0) != 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        /** Escalate: the pre-signal snapshot plus a fresh sweep (new children may
            have appeared during the grace window while the parent lived). */
        let escalation = Set(snapshot).union(ProcessTree.descendants(of: target))
        if kill(target, 0) == 0 {
            ProcessTree.signalTree(rootPid: target, descendants: Array(escalation), signal: SIGKILL)
        } else {
            for pid in escalation where kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
        await waitForRunTaskCompletion()
        return status()
    }

    public func status() -> ServerStatus {
        ServerStatus(
            declaredPort: spec.port,
            healthcheck: .none,
            lastExit: lastExit,
            logPath: paths.spoolFile(project: projectPath, server: spec.name).path,
            phase: phase,
            pid: pid.map(Int.init),
            project: projectPath,
            server: spec.name,
            spawnError: spawnError,
            uptimeSec: startedAt.map { Int(Date().timeIntervalSince($0)) },
            url: spec.url
        )
    }

    // MARK: - Internal bookkeeping

    private func effectiveArgv() -> [String] {
        if spec.shell == true {
            return ["/bin/zsh", "-lc", spec.command.joined(separator: " ")]
        }
        return spec.command
    }

    private func effectiveCwd() -> String {
        guard let cwd = spec.cwd, !cwd.isEmpty, cwd != "." else { return projectPath }
        return (projectPath as NSString).appendingPathComponent(cwd)
    }

    private func recordSpawn(pid childPid: pid_t, id: String) async {
        pid = childPid
        let spawnedAt = Date()
        startedAt = spawnedAt
        phase = .running
        try? await registryUpdate(id: id) { entry in
            entry.lastExit = nil
            entry.phase = .running
            entry.pid = Int(childPid)
            entry.spawnError = nil
            entry.startedAt = spawnedAt
        }
        settleSpawnWaiters()
    }

    private func recordSpawnFailure(_ error: SpawnError, id: String) async {
        spawnError = error
        phase = .failed
        pid = nil
        startedAt = nil
        runTask = nil
        try? await registryUpdate(id: id) { entry in
            entry.phase = .failed
            entry.pid = nil
            entry.spawnError = error
            entry.startedAt = nil
        }
        settleSpawnWaiters()
    }

    private func recordOutcome(_ outcome: ProcessOutcome, id: String) async {
        runTask = nil
        switch outcome {
        case .spawnFailed(let error):
            await recordSpawnFailure(error, id: id)
            return
        case .exited(let code):
            lastExit = LastExit(at: Date(), code: code, signal: nil)
        case .signaled(let signal):
            lastExit = LastExit(at: Date(), code: nil, signal: signal)
        }
        pid = nil
        startedAt = nil
        phase = stopRequested ? .stopped : .crashed
        stopRequested = false
        let finalPhase = phase
        let exit = lastExit
        try? await registryUpdate(id: id) { entry in
            entry.lastExit = exit
            entry.phase = finalPhase
            entry.pid = nil
            entry.startedAt = nil
        }
        settleSpawnWaiters()
    }

    private func registryUpdate(id: String, _ mutate: @escaping @Sendable (inout PersistedServerState) -> Void) async throws {
        try await registry.updateState(serverID: id, mutate)
    }

    private func settleSpawnWaiters() {
        let waiters = spawnWaiters
        spawnWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func waitForRunTaskCompletion() async {
        if let task = runTask { await task.value }
    }

    /** Blocks until the in-flight start has either produced a pid or failed. */
    private func waitForSpawnSettled() async {
        guard phase == .starting else { return }
        await withCheckedContinuation { continuation in
            if phase != .starting {
                continuation.resume()
            } else {
                spawnWaiters.append(continuation)
            }
        }
    }
}
